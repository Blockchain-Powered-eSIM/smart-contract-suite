// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/esim-wallet/ESIMWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";

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
        vm.startPrank(address(registry));
        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(user2, 999);
        vm.stopPrank();

        assertEq(eSIMWalletFactory.isESIMWalletDeployed(eSIMWallet), true, "isESIMWalletDeployed should have been set to true");
    }
}