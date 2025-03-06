// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "test/utils/DeployerBase.sol";

contract Deployer is DeployerBase {

    function test_registry_setUp() public view {
        assertEq(registry.owner(), upgradeManager);
        assertEq(address(registry.entryPoint()), address(entryPoint));
        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin);
        assertEq(registry.vault(), vault);
        assertEq(registry.upgradeManager(), upgradeManager);
        assertEq(registry.lazyWalletRegistry(), address(lazyWalletRegistry));
        assertEq(address(registry.deviceWalletFactory()), address(deviceWalletFactory));
        assertEq(address(registry.eSIMWalletFactory()), address(eSIMWalletFactory));
    }

    function test_registry_ownable2step() public {
        vm.startPrank(upgradeManager);
        registry.transferOwnership(user5);
        vm.stopPrank();

        assertNotEq(registry.owner(), user5, "Registry owner should have not changed yet");
        assertEq(registry.pendingOwner(), user5, "Pending registry owner should have been updated");

        vm.startPrank(upgradeManager);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, upgradeManager));
        registry.acceptOwnership();
        vm.stopPrank();

        vm.startPrank(user5);
        registry.acceptOwnership();
        vm.stopPrank();

        assertEq(registry.pendingOwner(), address(0), "Pending registry owner should have reset");
        assertEq(registry.owner(), user5, "Registry ownership should have transferred");
    }

    function test_lazyWalletRegistry_setUp() public view {
        assertEq(lazyWalletRegistry.upgradeManager(), upgradeManager);
        assertEq(address(lazyWalletRegistry.registry()), address(registry));
    }

    function test_lazywalletRegistry_ownable2Step() public {
        vm.startPrank(upgradeManager);
        lazyWalletRegistry.transferOwnership(user5);
        vm.stopPrank();

        assertNotEq(lazyWalletRegistry.owner(), user5, "Owner should have not changed yet");
        assertEq(lazyWalletRegistry.pendingOwner(), user5, "Pending owner should have been updated");

        vm.startPrank(upgradeManager);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, upgradeManager));
        lazyWalletRegistry.acceptOwnership();
        vm.stopPrank();

        vm.startPrank(user5);
        lazyWalletRegistry.acceptOwnership();
        vm.stopPrank();

        assertEq(lazyWalletRegistry.pendingOwner(), address(0), "Pending owner should have reset");
        assertEq(lazyWalletRegistry.owner(), user5, "Ownership should have transferred");
    }

    function test_deviceWalletFactory_setUp() public view {
        assertEq(address(deviceWalletFactory.entryPoint()), address(entryPoint));
        assertEq(address(deviceWalletFactory.verifier()), address(p256Verifier));
        assertEq(address(deviceWalletFactory.eSIMWalletAdmin()), eSIMWalletAdmin);
        assertEq(address(deviceWalletFactory.vault()), vault);
        assertEq(address(deviceWalletFactory.registry()), address(registry));
        assertEq(address(deviceWalletFactory.newRequestedAdmin()), address(0));
        assertNotEq(address(deviceWalletFactory.beacon()), address(0));

        assertEq(deviceWalletFactory.getCurrentDeviceWalletImplementation(), address(deviceWalletImpl));
    }

    function test_deviceWalletFactory_ownable2Step() public {
        vm.startPrank(upgradeManager);
        deviceWalletFactory.transferOwnership(user5);
        vm.stopPrank();

        assertNotEq(deviceWalletFactory.owner(), user5, "Owner should have not changed yet");
        assertEq(deviceWalletFactory.pendingOwner(), user5, "Pending owner should have been updated");

        vm.startPrank(upgradeManager);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, upgradeManager));
        deviceWalletFactory.acceptOwnership();
        vm.stopPrank();

        vm.startPrank(user5);
        deviceWalletFactory.acceptOwnership();
        vm.stopPrank();

        assertEq(deviceWalletFactory.pendingOwner(), address(0), "Pending owner should have reset");
        assertEq(deviceWalletFactory.owner(), user5, "Ownership should have transferred");
    }

    function test_eSIMWalletFactory_setUp() public view {
        assertEq(address(eSIMWalletFactory.registry()), address(registry), "Registry address should have been correct");
        assertNotEq(address(eSIMWalletFactory.beacon()), address(0), "Beacon address cannot be zero");
        assertEq(eSIMWalletFactory.getCurrentESIMWalletImplementation(), address(eSIMWalletImpl), "eSIM wallet implementation address should have been correct");
    }

    function test_eSIMWalletFactory_ownable2Step() public {
        vm.startPrank(upgradeManager);
        eSIMWalletFactory.transferOwnership(user5);
        vm.stopPrank();

        assertNotEq(eSIMWalletFactory.owner(), user5, "Owner should have not changed yet");
        assertEq(eSIMWalletFactory.pendingOwner(), user5, "Pending owner should have been updated");

        vm.startPrank(upgradeManager);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, upgradeManager));
        eSIMWalletFactory.acceptOwnership();
        vm.stopPrank();

        vm.startPrank(user5);
        eSIMWalletFactory.acceptOwnership();
        vm.stopPrank();

        assertEq(eSIMWalletFactory.pendingOwner(), address(0), "Pending owner should have reset");
        assertEq(eSIMWalletFactory.owner(), user5, "Ownership should have transferred");
    }
}
