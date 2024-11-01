// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockDeviceWalletV2.sol";
import "test/utils/mocks/MockESIMWallet.sol";

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

    function test_deployDeviceWalletAsAdmin_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdmin()")));
        deviceWalletFactory.deployDeviceWalletAsAdmin(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            0
        );
        vm.stopPrank();
    }

    function test_deployDeviceWalletAsAdmin() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletAsAdmin(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            0
        );
        vm.stopPrank();

        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(wallet.deviceWallet));
        MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallet.eSIMWallet));

        assertNotEq(address(deviceWallet), address(0), "Device wallet address cannot be address(0)");
        assertNotEq(address(eSIMWallet), address(0), "ESIM wallet address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet)), address(deviceWallet), "ESIM wallet should have been associated with device wallet");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet)), false, "ESIM wallet should not have been on standby");
        
        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet)), true, "ESIMWallet should have been set to valid");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet)), true, "ESIMWallet should be able to pull ETH");

        // Check storage variables in eSIM wallet
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
    }

    function test_deployDeviceWalletAsAdmin_withETHDeposit() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.deal(admin, 10 ether);
        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletAsAdmin{value: 1 ether}(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            1000000000000000000 // 1 ether
        );
        vm.stopPrank();

        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(wallet.deviceWallet));
        MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallet.eSIMWallet));

        assertNotEq(address(deviceWallet), address(0), "Device wallet address cannot be address(0)");
        assertNotEq(address(eSIMWallet), address(0), "ESIM wallet address cannot be address(0)");
        assertEq(address(deviceWallet).balance, 1 ether, "Device wallet balance should have been 1 ether");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet)), address(deviceWallet), "ESIM wallet should have been associated with device wallet");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet)), false, "ESIM wallet should not have been on standby");
        
        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet)), true, "ESIMWallet should have been set to valid");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet)), true, "ESIMWallet should be able to pull ETH");

        // Check storage variables in eSIM wallet
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
    }

    function test_updateDeviceWalletImplementation_admin() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        vm.expectRevert();
        deviceWalletFactory.updateDeviceWalletImplementation(user2);
        vm.stopPrank();
    }

    function test_updateDeviceWalletImplementation() public {
        // First deploy a device wallet
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletAsAdmin(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            0
        );
        vm.stopPrank();

        // Now upgrade the Device Wallet implementation contract
        address owner = deviceWalletFactory.owner();
        assertEq(owner, upgradeManager, "Upgrade manager should have been the owner");

        MockDeviceWalletV2 newDeviceWalletImpl = new MockDeviceWalletV2(
            typeCastEntryPoint,
            p256Verifier
        );
        assertNotEq(address(newDeviceWalletImpl), deviceWalletFactory.getCurrentDeviceWalletImplementation(), "Should have been different implementations");

        vm.prank(owner);
        deviceWalletFactory.updateDeviceWalletImplementation(address(newDeviceWalletImpl));
        vm.stopPrank();

        address currentImpl = deviceWalletFactory.getCurrentDeviceWalletImplementation();
        assertEq(currentImpl, address(newDeviceWalletImpl), "Device wallet implementation should have been updated");

        // Check if the new implementation works
        MockDeviceWalletV2 upgradedDeviceWallet = MockDeviceWalletV2(payable(wallet.deviceWallet));
        uint256 result = upgradedDeviceWallet.addTwoNumbers(2, 3);
        assertEq(result, 5, "Device wallet should have been upgraded");

        // Check storage variables in device wallet are still the same
        assertEq(upgradedDeviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(upgradedDeviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(upgradedDeviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(upgradedDeviceWallet.isValidESIMWallet(wallet.eSIMWallet), true, "ESIMWallet should have been set to valid");
        assertEq(upgradedDeviceWallet.canPullETH(wallet.eSIMWallet), true, "ESIMWallet should be able to pull ETH");
    }
}