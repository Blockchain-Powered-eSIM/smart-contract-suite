// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/esim-wallet/ESIMWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockESIMWallet.sol";

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

    function test_deployESIMWallet_notAuthorise() public {
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
}
