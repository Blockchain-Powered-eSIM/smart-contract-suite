// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "test/utils/DeployerBase.sol";

/// @notice The registry holds the only copy of the admin address and is where it is rotated.
/// Every other contract in the protocol reads it from here, so these tests cover both the rotation
/// itself and the readers following it.
contract RegistryTest is DeployerBase {

    function test_requestAdminUpdate_withoutAdmin() public {
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should have been eSIMWalletAdmin");

        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.requestAdminUpdate(user2);
        vm.stopPrank();
    }

    function test_requestAdminUpdate_zeroAddress() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Admin address cannot be zero");
        registry.requestAdminUpdate(address(0));
        vm.stopPrank();
    }

    function test_requestAdminUpdate() public {
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should have been eSIMWalletAdmin");

        vm.startPrank(eSIMWalletAdmin);
        registry.requestAdminUpdate(user2);
        vm.stopPrank();

        assertEq(registry.newRequestedAdmin(), user2, "newRequestedAdmin should have been updated");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should not have changed yet");
    }

    function test_requestAdminUpdate_revoke() public {
        test_requestAdminUpdate();

        vm.startPrank(eSIMWalletAdmin);
        registry.requestAdminUpdate(eSIMWalletAdmin);
        vm.stopPrank();

        assertEq(registry.newRequestedAdmin(), address(0), "newRequestedAdmin should be reset to address(0)");
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should not have changed");
    }

    function test_acceptAdminUpdate_withoutRequest() public {
        vm.startPrank(user2);
        vm.expectRevert("Unauthorised");
        registry.acceptAdminUpdate();
        vm.stopPrank();
    }

    function test_acceptAdminUpdate_currentAdmin() public {
        test_requestAdminUpdate();

        vm.startPrank(registry.eSIMWalletAdmin());
        vm.expectRevert("Unauthorised");
        registry.acceptAdminUpdate();
        vm.stopPrank();
    }

    function test_acceptAdminUpdate() public {
        test_requestAdminUpdate();

        address requestedAdmin = registry.newRequestedAdmin();

        vm.startPrank(requestedAdmin);
        registry.acceptAdminUpdate();
        vm.stopPrank();

        assertEq(registry.eSIMWalletAdmin(), requestedAdmin, "newAdmin should have accepted the admin role");
        assertEq(registry.newRequestedAdmin(), address(0), "newRequestedAdmin should have reset to address(0)");
    }

    function test_acceptAdminUpdate_afterRevoke() public {
        test_requestAdminUpdate_revoke();

        vm.startPrank(user2);
        vm.expectRevert("Unauthorised");
        registry.acceptAdminUpdate();
        vm.stopPrank();

        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "Admin should not have updated");
    }

    /// @notice One rotation has to reach every contract that authorises against the admin
    /// @dev The address used to be held in two places, and only one of them could be rotated, so a
    ///      retired key kept the functions gated on the copy that had no setter while the incoming
    ///      key could not use them.
    function test_acceptAdminUpdate_reachesEveryReader() public {
        vm.prank(eSIMWalletAdmin);
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

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        deviceWalletFactory.updateVaultAddress(user4);

        vm.prank(user3);
        deviceWalletFactory.updateVaultAddress(user4);
        assertEq(deviceWalletFactory.vault(), user4, "The rotated admin's write must have landed");
    }

    /// @notice The admin trips the pause, so an operator watching the backend can act without
    /// waiting on the upgrade key. Nobody else can, including the owner.
    function test_pause_onlyTheAdminCanTripIt() public {
        vm.prank(registry.owner());
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        assertEq(registry.paused(), false, "The rejected calls must leave the protocol running");

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();
        assertEq(registry.paused(), true, "The admin's call must have tripped the pause");
    }

    /// @notice Release is the owner's, not the admin's. The admin key signs backend batches all
    /// day, and holding both ends would let one hot key freeze user funds indefinitely.
    function test_unpause_onlyTheOwnerCanReleaseIt() public {
        // Read outside the prank. A view call here would consume it before unpause is reached.
        address admin = registry.eSIMWalletAdmin();

        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", admin));
        registry.unpause();

        assertEq(registry.paused(), true, "The admin must not be able to release its own pause");

        vm.prank(registry.owner());
        registry.unpause();
        assertEq(registry.paused(), false, "The owner's call must have released the pause");
    }

    /// @notice The flag has to survive an admin rotation, and the incoming admin has to inherit the
    /// ability to trip it.
    function test_pause_survivesAnAdminRotation() public {
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(retiredAdmin);
        registry.pause();

        vm.prank(retiredAdmin);
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        assertEq(registry.paused(), true, "The rotation must not have cleared the pause");

        vm.prank(registry.owner());
        registry.unpause();

        vm.prank(retiredAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(user3);
        registry.pause();
        assertEq(registry.paused(), true, "The incoming admin must be able to trip it");
    }

    /// @notice requireNotPaused is what the wallets call, so it has to carry the same named revert
    /// wherever it is reached from.
    function test_requireNotPaused_revertsOnlyWhilePaused() public {
        registry.requireNotPaused();

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        vm.expectRevert(Errors.ProtocolPaused.selector);
        registry.requireNotPaused();
    }

    /// @notice The fallback price ceiling is the owner's to set, not the admin's.
    /// @dev The admin names the price on every purchase, so an admin that could also raise the
    /// ceiling would be constrained by nothing.
    function test_setDefaultDataBundlePriceCap_rejectsTheAdmin() public {
        address admin = registry.eSIMWalletAdmin();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", admin));
        registry.setDefaultDataBundlePriceCap(100 ether);

        assertEq(registry.defaultDataBundlePriceCap(), 0, "The admin must not be able to set the ceiling");

        vm.prank(registry.owner());
        registry.setDefaultDataBundlePriceCap(1 ether);
        assertEq(registry.defaultDataBundlePriceCap(), 1 ether, "The owner must be able to set it");
    }
}
