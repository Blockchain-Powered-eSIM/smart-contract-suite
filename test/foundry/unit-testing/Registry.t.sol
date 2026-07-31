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
}
