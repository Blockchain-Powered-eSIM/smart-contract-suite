// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "contracts/Registry.sol";
import "contracts/LazyWalletRegistry.sol";
import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/esim-wallet/ESIMWalletFactory.sol";

/// @notice The four UUPS implementation contracts must be locked against direct initialization.
/// A proxy holds its own storage, so an initialized implementation does not compromise the live
/// protocol today, but it hands an attacker ownership of a contract the protocol delegates into and
/// defeats the invariant the upgrades tooling relies on.
contract ImplementationLocksTest is Test {

    address attacker = makeAddr("attacker");

    /// @notice Every implementation is deployed exactly as the deploy script deploys it, with no
    /// proxy in front of it, so this reflects what sits at the implementation address on chain.
    function test_Registry_implementationCannotBeInitialized() public {
        Registry implementation = new Registry();

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            attacker,
            attacker,
            attacker,
            attacker,
            attacker,
            IEntryPoint(attacker),
            P256Verifier(attacker)
        );

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");
        assertEq(implementation.eSIMWalletAdmin(), address(0), "Implementation must have no admin");
    }

    /// @notice The lazy wallet registry implementation must reject a direct initialize call.
    function test_LazyWalletRegistry_implementationCannotBeInitialized() public {
        LazyWalletRegistry implementation = new LazyWalletRegistry();

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(attacker, attacker);

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");
        assertEq(implementation.upgradeManager(), address(0), "Implementation must have no upgrade manager");
    }

    /// @notice The device wallet factory implementation must reject a direct initialize call, which
    /// would otherwise also make it deploy an UpgradeableBeacon under the caller's control.
    /// @dev The wallet implementation argument is a real contract address, because UpgradeableBeacon
    ///      rejects one without code. Without that, the call reverts for the wrong reason and the
    ///      test would pass even against an unlocked implementation.
    function test_DeviceWalletFactory_implementationCannotBeInitialized() public {
        DeviceWalletFactory implementation = new DeviceWalletFactory();

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(this),
            attacker,
            attacker,
            attacker,
            attacker,
            IEntryPoint(attacker),
            P256Verifier(attacker)
        );

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");
        assertEq(implementation.eSIMWalletAdmin(), address(0), "Implementation must have no admin");
        assertEq(address(implementation.beacon()), address(0), "Implementation must not own a beacon");
    }

    /// @notice The eSIM wallet factory implementation must reject a direct initialize call, for the
    /// same beacon reason as the device wallet factory.
    function test_ESIMWalletFactory_implementationCannotBeInitialized() public {
        ESIMWalletFactory implementation = new ESIMWalletFactory();

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(this), attacker);

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");
        assertEq(address(implementation.beacon()), address(0), "Implementation must not own a beacon");
    }
}
