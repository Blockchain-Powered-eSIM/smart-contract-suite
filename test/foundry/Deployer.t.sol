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

    function test_lazyWalletRegistry_setUp() public view {
        assertEq(lazyWalletRegistry.upgradeManager(), upgradeManager);
        assertEq(address(lazyWalletRegistry.registry()), address(registry));
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
}
