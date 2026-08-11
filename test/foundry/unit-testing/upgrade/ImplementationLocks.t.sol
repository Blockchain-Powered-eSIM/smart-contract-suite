// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

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
            IEntryPoint(attacker)
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

    /// @notice A device wallet proxy created without its setup call in the same transaction must be
    ///         unclaimable rather than up for grabs.
    /// @dev Both deploy paths pass `init` as the proxy's constructor argument, so this state is not
    ///      reachable today. It is pinned because the atomicity of those paths is the whole of what
    ///      keeps setup closed, and a future path that creates the proxy first would open it. The
    ///      inherited `initialize` used to be public with nothing but the `initializer` modifier on
    ///      it, which handed such a proxy to whoever called in between. It is internal now, so an
    ///      outsider has no selector to reach the owner key through and `init` is the only way in.
    function test_DeviceWallet_orphanedProxyCannotBeClaimed() public {
        DeviceWallet walletImplementation = new DeviceWallet(IEntryPoint(attacker), P256Verifier(attacker));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(walletImplementation), address(this));

        // Empty init data, so the proxy is created and never set up
        DeviceWallet orphan = DeviceWallet(payable(address(new BeaconProxy(address(beacon), ""))));

        bytes32[2] memory attackerKey = [bytes32(uint256(1)), bytes32(uint256(2))];

        // `init` is reachable only from a constructor, because the nested initialiser inside it
        // needs `initialized == 1 && address(this).code.length == 0`. The proxy carries code by now
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        orphan.init(address(this), attackerKey, "device", address(this));

        // The inherited initialiser by its old signature. Raw, because there is no selector left to
        // compile against. This is the assertion that fails if it ever becomes reachable again
        vm.prank(attacker);
        (bool claimed, ) = address(orphan).call(
            abi.encodeWithSignature("initialize(bytes32[2])", attackerKey)
        );
        assertFalse(claimed, "The inherited initialiser must not be reachable from outside");

        assertEq(orphan.owner(0), bytes32(0), "Orphaned wallet must have no owner key");
        assertEq(orphan.owner(1), bytes32(0), "Orphaned wallet must have no owner key");
        assertEq(address(orphan.registry()), address(0), "Orphaned wallet must have no registry");
    }

    /// @notice The eSIM wallet implementation must be locked at the maximum version, not merely at
    ///         version one.
    /// @dev `constructor() initializer {}` leaves the version at 1, which a later `reinitializer(2)`
    ///      would still accept on the implementation itself. `_disableInitializers` pins it at the
    ///      maximum so no version can ever run there. Nothing in the contracts declares a
    ///      `reinitializer` today, so this guards the upgrade that adds the first one.
    function test_ESIMWallet_implementationIsLockedAtTheMaximumVersion() public {
        ESIMWallet implementation = new ESIMWallet();

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(attacker, attacker);

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");

        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~0xff
        bytes32 initializableSlot = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        uint64 version = uint64(uint256(vm.load(address(implementation), initializableSlot)));

        assertEq(version, type(uint64).max, "Implementation must be locked against every version");
    }
}
