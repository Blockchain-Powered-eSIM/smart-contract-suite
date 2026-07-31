// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {Account4337} from "contracts/aa-helper/Account4337.sol";
import {P256Verifier} from "contracts/P256Verifier.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

/// @notice Runs a user operation through the deployed EntryPoint on both chains the protocol
///         lives on.
/// @dev The mock cannot answer the question this asks. The wallet builds its challenge around
///      `userOpHash`, and the real derivation is an EIP-712 typed hash over the whole packed
///      operation. Nothing in the unit suite proves the two agree, because the mock computes its
///      own hash. If they disagree, every signature the SDK produces fails onchain and no local
///      test notices.
///
///      Skipped rather than failed when the RPC variable is unset, so the suite stays runnable
///      without credentials.
contract EntryPointValidationForkTest is Test {

    /// @dev EntryPoint v0.8 singleton, identical on every chain it is deployed to.
    ///      Verified to carry code on OP Sepolia and Base Sepolia.
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108);

    uint256 private constant OP_SEPOLIA_BLOCK = 46_830_000;
    uint256 private constant BASE_SEPOLIA_BLOCK = 44_850_000;

    Account4337 private wallet;
    address private beneficiary = makeAddr("beneficiary");

    function _fork(string memory _rpcVariable, uint256 _blockNumber) internal returns (bool) {
        string memory rpcUrl = vm.envOr(_rpcVariable, string(""));
        if (bytes(rpcUrl).length == 0) {
            return false;
        }

        vm.createSelectFork(rpcUrl, _blockNumber);
        assertGt(address(ENTRY_POINT).code.length, 0, "The EntryPoint must be deployed at the pinned block");

        // Deployed with CREATE2 so the wallet lands at one address on every chain, which is both
        // what the live protocol does and what lets a signature be carried between forks
        Account4337 implementation = new Account4337{salt: bytes32(0)}(
            ENTRY_POINT,
            new P256Verifier{salt: bytes32(0)}()
        );
        wallet = Account4337(
            payable(
                new ERC1967Proxy{salt: bytes32(0)}(
                    address(implementation),
                    abi.encodeCall(Account4337.initialize, (WebAuthnSigner.publicKey()))
                )
            )
        );

        vm.deal(address(this), 10 ether);
        ENTRY_POINT.depositTo{value: 1 ether}(address(wallet));

        return true;
    }

    function _operation(uint48 _validUntil) internal returns (PackedUserOperation memory op) {
        op.sender = address(wallet);
        op.nonce = ENTRY_POINT.getNonce(address(wallet), 0);
        // verificationGasLimit in the high half, callGasLimit in the low half. Verification has to
        // cover a P256 check, which costs upwards of 200k when it falls back to FreshCryptoLib.
        op.accountGasLimits = bytes32((uint256(2_000_000) << 128) | uint256(200_000));
        op.preVerificationGas = 100_000;
        // maxPriorityFeePerGas in the high half, maxFeePerGas in the low half
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(10 gwei));
        op.signature = _sign(op, _validUntil);
    }

    /// @notice Signs the operation the way the wallet expects: the EIP-191 digest of a 39 byte
    /// precursor holding the version, the expiry and the hash the EntryPoint itself computed.
    function _sign(PackedUserOperation memory _op, uint48 _validUntil) internal returns (bytes memory) {
        bytes32 userOpHash = ENTRY_POINT.getUserOpHash(_op);
        bytes memory challenge = abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n39",
                    uint8(1),
                    _validUntil,
                    userOpHash
                )
            )
        );

        return abi.encodePacked(uint8(1), _validUntil, WebAuthnSigner.sign(challenge));
    }

    function _assertOperationValidates() internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(uint48(block.timestamp + 1 days));

        uint256 depositBefore = ENTRY_POINT.balanceOf(address(wallet));
        ENTRY_POINT.handleOps(ops, payable(beneficiary));

        // The EntryPoint only charges an operation it accepted, so a smaller deposit is what says
        // the signature verified rather than the call being silently skipped
        assertLt(
            ENTRY_POINT.balanceOf(address(wallet)),
            depositBefore,
            "An accepted operation must be charged against the wallet deposit"
        );
        assertEq(ENTRY_POINT.getNonce(address(wallet), 0), 1, "The nonce must advance once");
    }

    function _assertTamperedOperationIsRejected() internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(uint48(block.timestamp + 1 days));

        // Rewriting the expiry leaves the assertion intact but no longer matching the challenge
        ops[0].signature[1] = 0xff;

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        ENTRY_POINT.handleOps(ops, payable(beneficiary));
    }

    function test_fork_opSepolia_validatesAgainstTheDeployedEntryPoint() public {
        if (!_fork("ALCHEMY_OP_SEPOLIA_HTTPS", OP_SEPOLIA_BLOCK)) return;
        _assertOperationValidates();
    }

    function test_fork_opSepolia_rejectsATamperedOperation() public {
        if (!_fork("ALCHEMY_OP_SEPOLIA_HTTPS", OP_SEPOLIA_BLOCK)) return;
        _assertTamperedOperationIsRejected();
    }

    function test_fork_baseSepolia_validatesAgainstTheDeployedEntryPoint() public {
        if (!_fork("ALCHEMY_BASE_SEPOLIA_HTTPS", BASE_SEPOLIA_BLOCK)) return;
        _assertOperationValidates();
    }

    function test_fork_baseSepolia_rejectsATamperedOperation() public {
        if (!_fork("ALCHEMY_BASE_SEPOLIA_HTTPS", BASE_SEPOLIA_BLOCK)) return;
        _assertTamperedOperationIsRejected();
    }

    /// @notice The user operation path binds the chain without naming it. The precursor the wallet
    /// hashes carries only the version, the expiry and the operation hash, but the EntryPoint
    /// derives that hash through an EIP-712 domain separator that includes the chain id. This is
    /// what says so, rather than a reading of the library: one wallet address, one owner key, one
    /// signature, rejected on the chain it was not made for.
    function test_fork_aSignatureDoesNotCarryBetweenChains() public {
        // Fixed rather than relative to the fork clock, so the operation is unexpired on both
        uint48 validUntil = 4_000_000_000;

        if (!_fork("ALCHEMY_OP_SEPOLIA_HTTPS", OP_SEPOLIA_BLOCK)) return;
        PackedUserOperation memory signedOnOptimism = _operation(validUntil);
        address walletOnOptimism = address(wallet);

        if (!_fork("ALCHEMY_BASE_SEPOLIA_HTTPS", BASE_SEPOLIA_BLOCK)) return;
        assertEq(address(wallet), walletOnOptimism, "The wallet must land at one address on both chains");

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = signedOnOptimism;

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        ENTRY_POINT.handleOps(ops, payable(beneficiary));
    }
}
