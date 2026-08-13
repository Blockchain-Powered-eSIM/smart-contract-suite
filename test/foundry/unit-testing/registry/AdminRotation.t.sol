// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import "test/utils/DeployerBase.sol";

/// @notice The admin role: who nominates, who accepts, and how its powers are taken away.
/// @dev Nomination is the owner's, not the admin's, so a key in the wrong hands can be removed by
///      somebody other than itself. Suspension is the same lever without the handover, for the case
///      where there is no replacement ready yet. Both close every gate in the protocol through one
///      accessor rather than through a flag each reader has to remember to check, so what most of
///      these tests assert is that a reader nobody edited still refuses the call.
contract AdminRotationTest is DeployerBase {

    /// @notice Deploys one device wallet with its first eSIM wallet, so the two wallet-side readers
    ///         of the admin address can be exercised alongside the three singleton ones
    /// @param _identifier Device identifier to deploy under
    /// @param _ownerKey P256 key owning the wallet
    /// @param _salt CREATE2 salt for both wallets
    /// @return deviceWallet The device wallet deployed
    /// @return eSIMWallet Its first eSIM wallet
    function _deployWallet(string memory _identifier, bytes32[2] memory _ownerKey, uint256 _salt)
        internal
        returns (address deviceWallet, address eSIMWallet)
    {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _ownerKey;
        salts[0] = _salt;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets =
            deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        return (wallets[0].deviceWallet, wallets[0].eSIMWallet);
    }

    /// @notice Asserts that the three singleton readers of the admin address all refuse `_who`
    /// @param _who Address expected to be turned away
    function _assertAdminGatesClosed(address _who) internal {
        vm.prank(_who);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(_who);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );

        bytes32[2] memory ownerKey;
        vm.prank(_who);
        vm.expectRevert(Errors.OnlyAdminOrRegistry.selector);
        deviceWalletFactory.postCreateAccount(user4, "", ownerKey, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Nomination
    // ---------------------------------------------------------------------------------------------

    /// @notice Only the owner nominates. The admin nominating its own replacement is what made a
    /// compromised key unremovable, since the one action that would remove it needed its signature.
    function test_requestAdminUpdate_rejectsAnyoneButTheOwner() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin)
        );
        registry.requestAdminUpdate(user2);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.requestAdminUpdate(user2);

        assertEq(registry.newRequestedAdmin(), address(0), "no nomination should have landed");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "the incumbent should still hold it");
    }

    /// @notice A zero nominee would leave the role dormant with nobody able to accept it
    function test_requestAdminUpdate_zeroAddress() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_newAdmin"));
        registry.requestAdminUpdate(address(0));
    }

    /// @notice A nomination records the nominee and does not hand over the role yet
    function test_requestAdminUpdate() public {
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should have been eSIMWalletAdmin");

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user2);

        assertEq(registry.newRequestedAdmin(), user2, "newRequestedAdmin should have been updated");
        assertEq(registry.adminOfRecord(), eSIMWalletAdmin, "the incumbent is still the address on record");
    }

    /// @notice The incumbent loses its powers the moment a nomination lands, so the two never hold
    /// the role at once and a handover left half done leaves it dormant rather than shared.
    function test_requestAdminUpdate_stripsTheIncumbentImmediately() public {
        (address deviceWallet, address eSIMWallet) = _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 1);

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user2);

        assertEq(registry.eSIMWalletAdmin(), address(0), "nobody may act while a handover is outstanding");
        assertEq(registry.adminOfRecord(), eSIMWalletAdmin, "but the address stays on the books");
        assertFalse(registry.adminDisabled(), "and this is the handover, not a suspension");

        _assertAdminGatesClosed(eSIMWalletAdmin);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        DeviceWallet(payable(deviceWallet)).deployESIMWallet(true, 99);

        DataBundleDetails memory bundle = DataBundleDetails("bundle", 1);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWalletOrESIMWalletAdmin.selector);
        ESIMWallet(payable(eSIMWallet)).buyDataBundle(bundle);

        // The nominee has nothing yet either. The role is dormant, not transferred.
        _assertAdminGatesClosed(user2);
    }

    /// @notice Naming the incumbent withdraws an outstanding nomination
    function test_requestAdminUpdate_revoke() public {
        test_requestAdminUpdate();

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(eSIMWalletAdmin);

        assertEq(registry.newRequestedAdmin(), address(0), "newRequestedAdmin should be reset to address(0)");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should not have changed");
    }

    /// @notice Withdrawing a nomination hands the incumbent its powers back, which is how a
    /// nomination sent in error is undone without a second kind of call
    function test_requestAdminUpdate_namingTheIncumbentRestoresItsPowers() public {
        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user2);
        _assertAdminGatesClosed(eSIMWalletAdmin);

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(eSIMWalletAdmin);

        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "the incumbent is back");

        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused(), "and it can act again");
    }

    /// @notice Naming the incumbent lifts a suspension too, so one call undoes either mistake
    function test_requestAdminUpdate_namingTheIncumbentLiftsASuspension() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();
        assertTrue(registry.adminDisabled(), "suspended");

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(eSIMWalletAdmin);

        assertFalse(registry.adminDisabled(), "naming the incumbent lifts it");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "and the powers are back");
    }

    // ---------------------------------------------------------------------------------------------
    // Acceptance
    // ---------------------------------------------------------------------------------------------

    /// @notice Nobody can accept a role that was never offered
    function test_acceptAdminUpdate_withoutRequest() public {
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedAdmin.selector, registry.newRequestedAdmin()));
        registry.acceptAdminUpdate();
    }

    /// @notice The incumbent cannot accept a handover aimed at somebody else
    function test_acceptAdminUpdate_currentAdmin() public {
        test_requestAdminUpdate();

        vm.prank(registry.adminOfRecord());
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedAdmin.selector, registry.newRequestedAdmin()));
        registry.acceptAdminUpdate();
    }

    /// @notice Acceptance moves the role and clears the request
    function test_acceptAdminUpdate() public {
        test_requestAdminUpdate();

        address requestedAdmin = registry.newRequestedAdmin();

        vm.prank(requestedAdmin);
        registry.acceptAdminUpdate();

        assertEq(registry.eSIMWalletAdmin(), requestedAdmin, "newAdmin should have accepted the admin role");
        assertEq(registry.adminOfRecord(), requestedAdmin, "and should be the address on record");
        assertEq(registry.newRequestedAdmin(), address(0), "newRequestedAdmin should have reset to address(0)");
    }

    /// @notice A withdrawn nomination cannot be accepted afterwards
    function test_acceptAdminUpdate_afterRevoke() public {
        test_requestAdminUpdate_revoke();

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedAdmin.selector, registry.newRequestedAdmin()));
        registry.acceptAdminUpdate();

        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should not have updated");
    }

    /// @notice A fresh key accepting ends a suspension, since the suspension named the old key and
    /// not the role. Otherwise a recovery would land an admin that still could not act.
    function test_acceptAdminUpdate_clearsASuspension() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();

        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        assertFalse(registry.adminDisabled(), "the suspension went with the key it named");
        assertEq(registry.eSIMWalletAdmin(), user3, "the incoming key holds the role");

        vm.prank(user3);
        registry.pause();
        assertTrue(registry.paused(), "and can act");
    }

    /// @notice One rotation has to reach every contract that authorises against the admin
    /// @dev The address used to be held in two places, and only one of them could be rotated, so a
    ///      retired key kept the functions gated on the copy that had no setter while the incoming
    ///      key could not use them.
    function test_acceptAdminUpdate_reachesEveryReader() public {
        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        assertEq(
            deviceWalletFactory.eSIMWalletAdmin(),
            user3,
            "The device wallet factory must follow the rotation"
        );
        assertEq(
            registry.eSIMWalletAdmin(),
            user3,
            "The registry must report the rotated admin to the lazy registry and the eSIM wallets"
        );

        // The retired key is stopped at the gate, and the incoming one gets past it and is stopped
        // by the input check behind it. Reaching a different revert is what proves the gate opened.
        bytes32[2] memory ownerKey;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdminOrRegistry.selector);
        deviceWalletFactory.postCreateAccount(user4, "", ownerKey, 0);

        vm.prank(user3);
        vm.expectRevert(Errors.EmptyDeviceIdentifier.selector);
        deviceWalletFactory.postCreateAccount(user4, "", ownerKey, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Suspension
    // ---------------------------------------------------------------------------------------------

    /// @notice Suspending closes every gate in the protocol through one write, because each reader
    /// asks the registry rather than holding a copy, and the accessor answers zero
    function test_disableAdmin_closesEveryGate() public {
        (address deviceWallet, address eSIMWallet) = _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 1);

        vm.prank(upgradeManager);
        registry.disableAdmin();

        assertTrue(registry.adminDisabled(), "the suspension is recorded");
        assertEq(registry.eSIMWalletAdmin(), address(0), "and nobody may act");
        assertEq(registry.adminOfRecord(), eSIMWalletAdmin, "while the address stays on the books");

        _assertAdminGatesClosed(eSIMWalletAdmin);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        DeviceWallet(payable(deviceWallet)).deployESIMWallet(true, 99);

        DataBundleDetails memory bundle = DataBundleDetails("bundle", 1);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWalletOrESIMWalletAdmin.selector);
        ESIMWallet(payable(eSIMWallet)).buyDataBundle(bundle);
    }

    /// @notice Suspension is the owner's, which is what lets a guardian reach it through the
    /// timelock without anyone else being able to
    function test_disableAdmin_rejectsAnyoneButTheOwner() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin)
        );
        registry.disableAdmin();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.disableAdmin();

        assertFalse(registry.adminDisabled(), "the rejected calls must leave the admin running");
    }

    /// @notice A repeat reverts rather than passing quietly, so a guardian acting during an
    /// incident is never left believing it took a power away that it did not
    function test_disableAdmin_rejectsARepeat() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.AdminAlreadyDisabled.selector);
        registry.disableAdmin();
    }

    /// @notice Lifting a suspension puts every gate back
    function test_enableAdmin_restoresTheGates() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();
        _assertAdminGatesClosed(eSIMWalletAdmin);

        vm.prank(upgradeManager);
        registry.enableAdmin();

        assertFalse(registry.adminDisabled(), "the suspension is lifted");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "and the incumbent holds it again");

        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused(), "the admin can act again");
    }

    /// @notice Restoring is the owner's and has no fast route for anyone, so a suspended key cannot
    /// be handed back as quickly as it was taken away
    function test_enableAdmin_rejectsAnyoneButTheOwner() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin)
        );
        registry.enableAdmin();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.enableAdmin();

        assertTrue(registry.adminDisabled(), "the rejected calls must leave the suspension in place");
    }

    /// @notice Lifting a suspension that was never applied reverts, for the same reason applying
    /// one twice does
    function test_enableAdmin_rejectsWhenNotDisabled() public {
        vm.prank(upgradeManager);
        vm.expectRevert(Errors.AdminNotDisabled.selector);
        registry.enableAdmin();
    }

    /// @notice Lifting a suspension does not settle an outstanding handover, which keeps the
    /// incumbent powerless on its own
    function test_enableAdmin_leavesAnOutstandingHandoverAlone() public {
        vm.prank(upgradeManager);
        registry.disableAdmin();
        vm.prank(upgradeManager);
        registry.requestAdminUpdate(user2);

        vm.prank(upgradeManager);
        registry.enableAdmin();

        assertFalse(registry.adminDisabled(), "the suspension is lifted");
        assertEq(registry.eSIMWalletAdmin(), address(0), "but the handover still holds the role dormant");
        _assertAdminGatesClosed(eSIMWalletAdmin);
    }

    // ---------------------------------------------------------------------------------------------
    // The deadlock this exists to break
    // ---------------------------------------------------------------------------------------------

    /// @notice A compromised admin key used to be able to hold the protocol stopped forever: it
    /// trips the pause, the owner releases it, and it trips it again, while the only call that
    /// could remove the key needed that same key to sign. Suspending it ends the loop.
    function test_disableAdmin_endsThePauseLoopAgainstACompromisedKey() public {
        // The loop, as it stood. The owner releases and the key re-applies.
        for(uint256 round = 0; round < 3; ++round) {
            vm.prank(eSIMWalletAdmin);
            registry.pause();

            vm.prank(upgradeManager);
            registry.unpause();
        }

        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused(), "the key has the protocol stopped");

        // Take the key's powers away first, then release. Now the release holds.
        vm.prank(upgradeManager);
        registry.disableAdmin();

        vm.prank(upgradeManager);
        registry.unpause();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        assertFalse(registry.paused(), "and it stays released");

        registry.requireNotPaused();
    }
}
