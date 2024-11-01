// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/device-wallet/DeviceWalletFactory.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract DeviceWalletFactoryTest is DeployerBase {

    function test_addRegistryAddress_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdmin()")));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_addRegistryAddress_onlyOnce() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Already added");
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_updateVaultAddress_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdmin()")));
        deviceWalletFactory.updateVaultAddress(user2);
        vm.stopPrank();
    }

    function test_updateVaultAddress_sameAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Cannot update to same address");
        deviceWalletFactory.updateVaultAddress(currentVault);
        vm.stopPrank();
    }

    function test_updateVaultAddress_zeroAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Vault address cannot be zero");
        deviceWalletFactory.updateVaultAddress(address(0));
        vm.stopPrank();
    }

    function test_updateVaultAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.updateVaultAddress(user2);
        vm.stopPrank();

        address newVault = deviceWalletFactory.vault();
        assertEq(newVault, user2, "Vault should have updated");
    }

    function test_requestAdminUpdate_withoutAdmin() public {
        address currentAdmin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(currentAdmin, eSIMWalletAdmin, "Admin should have been eSIMWalletAdmin");

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdmin()")));
        deviceWalletFactory.requestAdminUpdate(user2);
        vm.stopPrank();
    }

    function test_requestAdminUpdate() public {
        address currentAdmin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(currentAdmin, eSIMWalletAdmin, "Admin should have been eSIMWalletAdmin");

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.requestAdminUpdate(user2);
        vm.stopPrank();

        assertEq(deviceWalletFactory.newRequestedAdmin(), user2, "newRequestedAdmin should have been updated");

        currentAdmin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(currentAdmin, eSIMWalletAdmin, "Admin should not havechanged yet");
    }

    function test_requestAdminUpdate_revoke() public {
        test_requestAdminUpdate();

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.requestAdminUpdate(eSIMWalletAdmin);
        vm.stopPrank();

        assertEq(deviceWalletFactory.newRequestedAdmin(), address(0), "newRequestedAdmin should be reset to address(0)");

        address currentAdmin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(currentAdmin, eSIMWalletAdmin, "Admin should not have changed yet");
    }

    function test_acceptAdminUpdate_withoutRequest() public {
        address newAdmin = user2;
        vm.startPrank(newAdmin);
        vm.expectRevert("Unauthorised");
        deviceWalletFactory.acceptAdminUpdate();
        vm.stopPrank();
    }

    function test_acceptAdminUpdate_currentAdmin() public {
        test_requestAdminUpdate();

        address currentAdmin = deviceWalletFactory.eSIMWalletAdmin();
        vm.startPrank(currentAdmin);
        vm.expectRevert("Unauthorised");
        deviceWalletFactory.acceptAdminUpdate();
        vm.stopPrank();
    }

    function test_acceptAdminUpdate() public {
        test_requestAdminUpdate();

        address requestedAdmin = deviceWalletFactory.newRequestedAdmin();

        vm.startPrank(requestedAdmin);
        deviceWalletFactory.acceptAdminUpdate();
        vm.stopPrank();

        address newAdmin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(newAdmin, requestedAdmin, "newAdmin should have accepted the admin role");

        requestedAdmin = deviceWalletFactory.newRequestedAdmin();
        assertEq(requestedAdmin, address(0), "newRequestedAdmin should have reset to address(0)");
    }

    function test_acceptAdminUpdate_afterRevoke() public {
        address requestedAdmin = user2;
        test_requestAdminUpdate_revoke();

        vm.startPrank(requestedAdmin);
        vm.expectRevert("Unauthorised");
        deviceWalletFactory.acceptAdminUpdate();
        vm.stopPrank();

        address admin = deviceWalletFactory.eSIMWalletAdmin();
        assertEq(admin, eSIMWalletAdmin, "Admin should not have updated");
    }
}
