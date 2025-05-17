// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/esim-wallet/ESIMWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockESIMWalletV2.sol";

contract ESIMWalletFactoryTest is DeployerBase {

    function test_addRegistryAddress_withoutOwner() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Only Owner");
        eSIMWalletFactory.addRegistryAddress(user2);
        vm.stopPrank();
    }

    function test_addRegistryAddress_onlyOnce() public {
        address owner = eSIMWalletFactory.owner();
        vm.startPrank(owner);
        vm.expectRevert("Already added");
        eSIMWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();

        assertEq(address(eSIMWalletFactory.registry()), address(registry), "Registry address should have been set");
    }

    function test_deployESIMWallet_unauthorised() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet()")));
        eSIMWalletFactory.deployESIMWallet(user2, 999);
        vm.stopPrank();
    }

    function test_deployESIMWallet() public {
        address deviceWalletAddress = user2;

        vm.startPrank(address(registry));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(
            deviceWalletAddress,
            999
        );
        vm.stopPrank();

        MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWalletAddress));

        // Check storage variables in eSIM wallet
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWallet)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), deviceWalletAddress, "ESIM wallet should have correct device wallet");
        assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), deviceWalletAddress, "ESIMWallet owner should have been device wallet");
    }

    function test_updateESIMWalletImplementation_unauthorised() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert();
        eSIMWalletFactory.updateESIMWalletImplementation(user2);
        vm.stopPrank();
    }

    function test_updateESIMWalletImplementation() public {
        // Deploy the device wallet
        vm.startPrank(address(typeCastEntryPoint));
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            0
        )));
        vm.stopPrank();
        
        // Update storage variables after createAccount
        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(
            address(deviceWallet),
            customDeviceUniqueIdentifiers[0],
            pubKey1
        );
        vm.stopPrank();

        // Deploy eSIM wallet
        vm.startPrank(address(deviceWallet));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(
            address(deviceWallet),
            999
        );
        vm.stopPrank();

        // Add eSIM wallet to device wallet
        vm.startPrank(address(registry));
        deviceWallet.addESIMWallet(eSIMWalletAddress, true);
        vm.stopPrank();

        // Set eSIM unique identifier
        vm.startPrank(eSIMWalletAdmin);
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(eSIMWalletAddress, "ESIM_0_0");
        vm.stopPrank();

        MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWalletAddress));

        // Check storage variables in eSIM wallet
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWallet)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(eSIMWallet.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");

        address oldESIMWalletImpl = eSIMWalletFactory.getCurrentESIMWalletImplementation();

        address owner = eSIMWalletFactory.owner();

        vm.startPrank(owner);
        MockESIMWalletV2 newESIMWalletImpl = new MockESIMWalletV2();
        eSIMWalletFactory.updateESIMWalletImplementation(address(newESIMWalletImpl));
        vm.stopPrank();

        assertNotEq(oldESIMWalletImpl, address(newESIMWalletImpl), "Implementation address should not have been same");
        assertEq(eSIMWalletFactory.getCurrentESIMWalletImplementation(), address(newESIMWalletImpl), "ESIM wallet implementation address should have updated");

        MockESIMWalletV2 eSIMWalletV2 = MockESIMWalletV2(payable(eSIMWalletAddress));

        // Check data stored initially still persists
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWalletV2)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWalletV2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWalletV2.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(eSIMWalletV2.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should be empty");
        assertEq(eSIMWalletV2.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWalletV2.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWalletV2.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
        assertEq(eSIMWalletV2.addTwoNumbers(2, 3), 5, "ESIMWallet implementation should have updated");
    }
}
