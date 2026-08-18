// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeployerBase} from "test/utils/DeployerBase.sol";
import {Errors} from "contracts/Errors.sol";
import {Registry} from "contracts/Registry.sol";
import {Call, Wallets} from "contracts/CustomStructs.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Pins that a device wallet owner cannot take an eSIM identifier meant for someone else
/// @dev The registry used to expose `claimESIMIdentifier` to any recorded device wallet. A device
///      wallet calls anything through `execute`, admin batches go through the public mempool, and
///      `claimedESIMIdentifiers` is never cleared, so any onboarded customer could watch for an
///      assignment and burn the identifier first. No check fixed it: every fact a device wallet
///      could present about its own wallets is one it writes itself. The claim moved to the admin
///      instead. These tests hold that shut.
contract NemesisIdentifierSquatPoC is DeployerBase {

    string internal constant TARGET_IDENTIFIER = "eSIM_1_1";

    MockDeviceWallet internal victimDevice;
    MockESIMWallet internal victimESIM;

    MockDeviceWallet internal attackerDevice;
    MockESIMWallet internal attackerESIM;

    function setUp() public override {
        super.setUp();

        (victimDevice, victimESIM) = _deploy(customDeviceUniqueIdentifiers[0], 0, 1000);
        (attackerDevice, attackerESIM) = _deploy(customDeviceUniqueIdentifiers[1], 1, 2000);
    }

    /// @notice The old attack, run against the fix
    function test_NM007_aDeviceWalletCannotBurnAnIdentifierItHasNoClaimTo() public {
        assertEq(registry.claimedESIMIdentifiers(_hash(TARGET_IDENTIFIER)), address(0));

        // The claim is admin only now, so the front-run reverts on its first line.
        vm.prank(address(entryPoint));
        vm.expectRevert(Errors.OnlyAdmin.selector);
        attackerDevice.execute(
            Call({
                dest: address(registry),
                value: 0,
                data: abi.encodeCall(
                    Registry.assignESIMIdentifier,
                    (address(attackerESIM), TARGET_IDENTIFIER)
                )
            })
        );

        assertEq(
            registry.claimedESIMIdentifiers(_hash(TARGET_IDENTIFIER)),
            address(0),
            "the identifier stays unheld"
        );

        // The wallet it was bought for still gets it.
        vm.prank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(address(victimESIM), TARGET_IDENTIFIER);

        assertEq(registry.claimedESIMIdentifiers(_hash(TARGET_IDENTIFIER)), address(victimESIM));
        assertEq(victimESIM.eSIMUniqueIdentifier(), TARGET_IDENTIFIER);
    }

    /// @notice The device-wallet claim is gone, not merely guarded
    /// @dev A selector nothing answers is a stronger guarantee than a check, since there is no
    ///      argument that reaches it.
    function test_NM007_theOldClaimSelectorIsUnreachable() public {
        bytes memory oldCall = abi.encodeWithSignature(
            "claimESIMIdentifier(string,address)",
            TARGET_IDENTIFIER,
            address(attackerESIM)
        );

        (bool ok,) = address(registry).call(oldCall);
        assertFalse(ok, "the registry must not answer the old claim");
    }

    /// @notice An owner cannot write its own wallet's identifier slot either
    /// @dev This was the other half. `setESIMUniqueIdentifier` took the owning device wallet, so an
    ///      owner could fill the slot with a string the registry has no record of, and satisfy any
    ///      "the wallet already holds it" check offered. Only the registry writes it now, and it
    ///      records the claim in the same call.
    function test_NM007_theOwnerCannotWriteTheWalletFieldItself() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(Errors.OnlyRegistry.selector);
        attackerDevice.execute(
            Call({
                dest: address(attackerESIM),
                value: 0,
                data: abi.encodeWithSignature("setESIMUniqueIdentifier(string)", TARGET_IDENTIFIER)
            })
        );

        assertEq(attackerESIM.eSIMUniqueIdentifier(), "", "the slot stays empty");
    }

    /// @notice Extra eSIM wallets buy the attacker nothing
    /// @dev An onboarded wallet can still deploy as many eSIM wallets as it likes with no admin in
    ///      the call. That was the supply of claiming wallets the attack ran on, and it is now
    ///      irrelevant, because none of them reaches a claim.
    function test_NM007_extraESIMWalletsGiveNoRouteIn() public {
        address extraESIM = eSIMWalletFactory.getCounterFactualAddress(address(attackerDevice), 2001);

        _execute(
            attackerDevice,
            address(eSIMWalletFactory),
            abi.encodeWithSignature(
                "deployESIMWallet(address,uint256)",
                address(attackerDevice),
                uint256(2001)
            )
        );

        vm.prank(address(entryPoint));
        vm.expectRevert(Errors.OnlyAdmin.selector);
        attackerDevice.execute(
            Call({
                dest: address(registry),
                value: 0,
                data: abi.encodeCall(
                    Registry.assignESIMIdentifier,
                    (extraESIM, TARGET_IDENTIFIER)
                )
            })
        );

        assertEq(registry.claimedESIMIdentifiers(_hash(TARGET_IDENTIFIER)), address(0));
    }

    /// @notice One holder per identifier, whoever the admin points it at second
    function test_NM007_theAdminCannotAssignOneIdentifierTwice() public {
        vm.prank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(address(victimESIM), TARGET_IDENTIFIER);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ESIMIdentifierAlreadyClaimed.selector,
                TARGET_IDENTIFIER,
                address(victimESIM)
            )
        );
        registry.assignESIMIdentifier(address(attackerESIM), TARGET_IDENTIFIER);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a device wallet and its first eSIM wallet through the admin path
    function _deploy(
        string memory _identifier,
        uint256 _keyIndex,
        uint256 _salt
    ) internal returns (MockDeviceWallet deviceWallet, MockESIMWallet eSIMWallet) {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = listOfOwnerKeys[_keyIndex];
        salts[0] = _salt;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        deviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));
    }

    /// @notice Sends one call out of a device wallet the way a signed user operation would
    function _execute(
        MockDeviceWallet _wallet,
        address _target,
        bytes memory _data
    ) internal {
        vm.prank(address(entryPoint));
        _wallet.execute(Call({dest: _target, value: 0, data: _data}));
    }

    function _hash(string memory _identifier) internal pure returns (bytes32) {
        return keccak256(bytes(_identifier));
    }
}
