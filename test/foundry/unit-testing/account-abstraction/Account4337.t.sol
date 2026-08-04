// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {SIG_VALIDATION_FAILED} from "@account-abstraction/contracts/core/Helpers.sol";

import "test/utils/DeployerBase.sol";

/// @notice A target that refuses every call, so the revert data the wallet passes back can be
///         compared against something specific rather than against "it reverted".
contract RevertingTarget {
    error TargetRefused(uint256 value);

    fallback() external payable {
        revert TargetRefused(msg.value);
    }
}

/// @notice Covers the execution, authorisation and entry point deposit surface a device wallet
///         inherits from `Account4337`.
/// @dev The signature paths are covered elsewhere: the user operation path in
///      `UserOpValidation.t.sol` and the ERC-1271 path in `DeviceWallet.t.sol`. What is left here
///      is everything reachable without a real assertion, which is where the reject arms sit.
contract Account4337Test is DeployerBase {

    /// @dev Any signature this length parses far enough to read a version byte, so a test using it
    ///      is refused by the version and not by the length check above it.
    uint256 constant PARSEABLE_SIGNATURE_LENGTH = 100;

    /// @dev A shortfall the entry point claims back during validation. Any non-zero value works;
    ///      this one is small enough to leave the wallet solvent afterwards.
    uint256 constant MISSING_PREFUND = 0.25 ether;

    DeviceWallet wallet;
    address recipient = address(0xBEEF01);
    address otherRecipient = address(0xBEEF02);

    /// @notice Deploys one wallet owned by a static key. Called per test rather than from setUp,
    ///         which DeployerBase does not declare virtual.
    function _deployWallet() internal {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = "Device_Account4337";
        keys[0] = pubKey1;
        salts[0] = 2082026;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
        wallet = DeviceWallet(payable(wallets[0].deviceWallet));
    }

    /// @notice Builds a signature with a version the wallet does not implement
    function _unknownVersionSignature() internal pure returns (bytes memory signature) {
        signature = new bytes(PARSEABLE_SIGNATURE_LENGTH);
        signature[0] = 0x02;
    }

    function _call(address _dest, uint256 _value) internal pure returns (Call memory) {
        return Call({dest: _dest, value: _value, data: ""});
    }

    // ---------------------------------------------------------------------------------------------
    // Execution authorisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Nobody but the entry point or the wallet itself can move the wallet's ETH
    function test_execute_rejectsAnArbitraryCaller() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyEntryPointOrSelf.selector);
        wallet.execute(_call(recipient, 1 ether));
    }

    /// @notice The same gate applies to the batch entry point
    /// @dev Worth its own test: the two functions check separately, so one could be left open.
    function test_executeBatch_rejectsAnArbitraryCaller() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);

        Call[] memory calls = new Call[](1);
        calls[0] = _call(recipient, 1 ether);

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyEntryPointOrSelf.selector);
        wallet.executeBatch(calls);
    }

    /// @notice The eSIM wallet admin has no more claim on the wallet's ETH than anyone else
    /// @dev The admin authorises most of the protocol, so the one place it does not reach is worth
    ///      pinning: a compromised admin key cannot spend a device wallet's balance directly.
    function test_execute_rejectsTheESIMWalletAdmin() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyEntryPointOrSelf.selector);
        wallet.execute(_call(recipient, 1 ether));
    }

    // ---------------------------------------------------------------------------------------------
    // Execution behaviour
    // ---------------------------------------------------------------------------------------------

    /// @notice A batch runs every call it was given, not just the first
    function test_executeBatch_runsEveryCall() public {
        _deployWallet();
        vm.deal(address(wallet), 3 ether);

        Call[] memory calls = new Call[](2);
        calls[0] = _call(recipient, 1 ether);
        calls[1] = _call(otherRecipient, 2 ether);

        vm.prank(address(wallet));
        wallet.executeBatch(calls);

        assertEq(recipient.balance, 1 ether, "The first call in the batch must have run");
        assertEq(otherRecipient.balance, 2 ether, "The second call in the batch must have run");
        assertEq(address(wallet).balance, 0, "The wallet must have spent both amounts");
    }

    /// @notice An empty batch is a no-op rather than a revert
    /// @dev The loop bound is the only thing standing between this and an out of bounds read.
    function test_executeBatch_acceptsAnEmptyBatch() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);

        vm.prank(address(wallet));
        wallet.executeBatch(new Call[](0));

        assertEq(address(wallet).balance, 1 ether, "An empty batch must not move anything");
    }

    /// @notice A failing call takes the wallet down with the target's own revert data
    /// @dev The wallet copies the returned bytes back verbatim in assembly. If it swallowed them,
    ///      a caller simulating an operation would see a bare failure and no reason for it.
    function test_execute_passesBackTheTargetsRevertReason() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);
        RevertingTarget target = new RevertingTarget();

        vm.prank(address(wallet));
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.TargetRefused.selector, 1 ether));
        wallet.execute(_call(address(target), 1 ether));
    }

    /// @notice A batch that fails partway leaves nothing behind
    /// @dev There is no try/catch in the loop, so the first failure reverts the whole call and the
    ///      earlier transfers go with it.
    function test_executeBatch_revertsTheWholeBatchOnOneFailedCall() public {
        _deployWallet();
        vm.deal(address(wallet), 2 ether);
        RevertingTarget target = new RevertingTarget();

        Call[] memory calls = new Call[](2);
        calls[0] = _call(recipient, 1 ether);
        calls[1] = _call(address(target), 1 ether);

        vm.prank(address(wallet));
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.TargetRefused.selector, 1 ether));
        wallet.executeBatch(calls);

        assertEq(recipient.balance, 0, "The call that succeeded must be rolled back with the batch");
    }

    // ---------------------------------------------------------------------------------------------
    // Signature version handling
    // ---------------------------------------------------------------------------------------------

    /// @notice Only the entry point may ask the wallet to validate an operation
    /// @dev Validation pays the prefund out of the wallet's balance to whoever called it.
    function test_validateUserOp_rejectsACallerOtherThanTheEntryPoint() public {
        _deployWallet();
        PackedUserOperation memory operation;
        operation.sender = address(wallet);

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyEntryPoint.selector);
        wallet.validateUserOp(operation, bytes32(uint256(1)), 0);
    }

    /// @notice A signature carrying a version the wallet does not implement fails the operation
    /// @dev It has to fail as packed validation data. A bytes4 sentinel here decodes as an
    ///      aggregator address and takes the whole bundle down instead of this one operation.
    function test_validateUserOp_rejectsAnUnknownSignatureVersion() public {
        _deployWallet();
        PackedUserOperation memory operation;
        operation.sender = address(wallet);
        operation.signature = _unknownVersionSignature();

        vm.prank(address(entryPoint));
        uint256 validationData = wallet.validateUserOp(operation, bytes32(uint256(1)), 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "An unknown version must fail the signature");
    }

    /// @notice The ERC-1271 path refuses an unknown version too
    function test_isValidSignature_rejectsAnUnknownSignatureVersion() public {
        _deployWallet();

        assertEq(
            wallet.isValidSignature(keccak256("any message"), _unknownVersionSignature()),
            bytes4(0xffffffff),
            "An unknown version must not return the magic value"
        );
    }

    /// @notice A signature too short to hold a header and a hash is refused before it is parsed
    /// @dev One byte under the bound. Slicing this would read past the end of the calldata.
    function test_isValidSignature_rejectsASignatureTooShortToParse() public {
        _deployWallet();

        assertEq(
            wallet.isValidSignature(keccak256("any message"), new bytes(39)),
            bytes4(0xffffffff),
            "A signature too short to parse must not return the magic value"
        );
    }

    /// @notice Validation forwards the shortfall the entry point asked for out of the wallet balance
    /// @dev Every other validation test passes a zero prefund, which skips this transfer entirely.
    ///      It runs whatever the signature check decided, so a wallet pays for a bundled operation
    ///      even when that operation's signature is refused. The amount goes to `msg.sender` rather
    ///      than to a stored address, which is why the caller gate above it is load-bearing.
    function test_validateUserOp_forwardsTheMissingPrefundToTheEntryPoint() public {
        _deployWallet();
        vm.deal(address(wallet), 1 ether);
        uint256 entryPointBalanceBefore = address(entryPoint).balance;

        PackedUserOperation memory operation;
        operation.sender = address(wallet);
        operation.signature = _unknownVersionSignature();

        vm.prank(address(entryPoint));
        wallet.validateUserOp(operation, bytes32(uint256(1)), MISSING_PREFUND);

        assertEq(address(wallet).balance, 1 ether - MISSING_PREFUND, "The wallet must have paid the shortfall");
        assertEq(
            address(entryPoint).balance - entryPointBalanceBefore,
            MISSING_PREFUND,
            "The entry point must have received exactly the amount it asked for"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Entry point deposit
    // ---------------------------------------------------------------------------------------------

    /// @notice A deposit lands at the entry point and not in the wallet's own balance
    /// @dev The two are separate pots and the wallet spends from both. Deployment funds the
    ///      balance, while unused gas is refunded into the deposit.
    function test_addDeposit_creditsTheEntryPointRatherThanTheWallet() public {
        _deployWallet();
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        wallet.addDeposit{value: 1 ether}();

        assertEq(wallet.getDeposit(), 1 ether, "The entry point must hold the deposit");
        assertEq(address(wallet).balance, 0, "The wallet must not hold the deposit as well");
    }

    /// @notice Nobody but the wallet itself can take its deposit back out
    function test_withdrawDepositTo_rejectsACallerOtherThanTheWallet() public {
        _deployWallet();
        _fundDeposit(1 ether);

        vm.prank(user1);
        vm.expectRevert(Errors.OnlySelf.selector);
        wallet.withdrawDepositTo(payable(user1), 1 ether);
    }

    /// @notice A withdrawal to the zero address is refused rather than burning the deposit
    function test_withdrawDepositTo_rejectsTheZeroAddress() public {
        _deployWallet();
        _fundDeposit(1 ether);

        vm.prank(address(wallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "withdrawAddress"));
        wallet.withdrawDepositTo(payable(address(0)), 1 ether);
    }

    /// @notice A withdrawal moves exactly the amount asked for, to whoever was named
    /// @dev The recipient is a third party rather than the wallet, which is the case that would
    ///      otherwise hide a withdrawal going to the wrong place.
    function test_withdrawDepositTo_movesExactlyTheAmountWithdrawn() public {
        _deployWallet();
        _fundDeposit(1 ether);

        vm.prank(address(wallet));
        wallet.withdrawDepositTo(payable(recipient), 0.4 ether);

        assertEq(recipient.balance, 0.4 ether, "The recipient must receive the amount withdrawn");
        assertEq(wallet.getDeposit(), 0.6 ether, "The deposit must fall by the amount withdrawn");
        assertEq(address(wallet).balance, 0, "A withdrawal to a third party must not touch the wallet");
    }

    /// @notice A withdrawal larger than the deposit is refused
    /// @dev The entry point holds deposits for every account it serves, so an unchecked
    ///      withdrawal would be spending somebody else's.
    function test_withdrawDepositTo_rejectsAnAmountAboveTheDeposit() public {
        _deployWallet();
        _fundDeposit(1 ether);

        vm.prank(address(wallet));
        vm.expectRevert("Insufficient deposit");
        wallet.withdrawDepositTo(payable(recipient), 1 ether + 1);

        assertEq(wallet.getDeposit(), 1 ether, "A refused withdrawal must leave the deposit alone");
    }

    /// @notice Puts a deposit in the entry point for the wallet without going through the wallet
    /// @param _amount The amount to deposit
    function _fundDeposit(uint256 _amount) internal {
        vm.deal(user2, _amount);
        vm.prank(user2);
        entryPoint.depositTo{value: _amount}(address(wallet));
    }
}
