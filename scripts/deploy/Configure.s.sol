// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Registry} from "../../contracts/Registry.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";

// Config
import {DeployConfig} from "./config/DeployConfig.sol";
import {DeploymentRecord} from "./config/DeploymentRecord.sol";

/// @notice Wires the deployed contracts to each other and sets the price ceiling
/// @dev Run after `Deploy.s.sol` and before `TransferOwnership.s.sol`. Every call here is owner
///      gated, and the deployer is still the owner at this point, so none of them waits on the
///      timelock. After the handover each of them would be a scheduled operation.
///
///      The three wiring calls exist because the dependency between the registry and the two
///      factories is circular: both factories are constructor arguments to the registry, and the
///      registry cannot be an argument to either of them. There is no ordering that removes this
///      step.
///
///      Every step checks whether it has already been done and skips it if so. Both
///      `addRegistryAddress` functions revert once set, so without that a single failed
///      transaction would leave this script unable to finish the run it started.
contract Configure is Script {

    /// @notice A wiring call did not take effect
    error NotWired(string what, address expected, address actual);

    /// @notice The registry is already bound to a different address than the one recorded
    error BoundElsewhere(string what, address recorded, address bound);

    /// @notice Wires the protocol together and records that it is configured
    /// @dev Broadcasts as the deployer, which is still the owner of all four singletons.
    function run() external {
        DeployConfig.Config memory config = DeployConfig.load();

        address registryAddress = DeploymentRecord.readAddress("RegistryProxy");
        address lazyWalletRegistry = DeploymentRecord.readAddress("LazyWalletRegistryProxy");
        address deviceWalletFactory = DeploymentRecord.readAddress("DeviceWalletFactoryProxy");
        address eSIMWalletFactory = DeploymentRecord.readAddress("ESIMWalletFactoryProxy");

        vm.startBroadcast(config.deployerPrivateKey);

        _bindRegistryToFactory("DeviceWalletFactory", deviceWalletFactory, registryAddress);
        _bindRegistryToFactory("ESIMWalletFactory", eSIMWalletFactory, registryAddress);
        _bindLazyWalletRegistry(registryAddress, lazyWalletRegistry);
        _setPriceCap(registryAddress, config.priceCapUSDCents);

        vm.stopBroadcast();

        _verify(registryAddress, lazyWalletRegistry, deviceWalletFactory, eSIMWalletFactory);
        DeploymentRecord.writeStatus("configured", true);

        console.log("");
        console.log("Configured. Next: TransferOwnership.s.sol.");
    }

    /// @notice Points a factory at the registry, unless it already is
    /// @dev Both factories store the registry as `Registry public registry` and both refuse a
    ///      second write, so a factory already bound to the right address is a finished step and a
    ///      factory bound to a different one is a mismatch nothing here can fix.
    function _bindRegistryToFactory(string memory name, address factory, address registryAddress)
        private
    {
        // Both factories declare the same getter, so either type reads the other correctly.
        address bound = address(DeviceWalletFactory(factory).registry());

        if(bound == registryAddress) {
            console.log(string.concat(name, ": already bound, skipping"));
            return;
        }
        if(bound != address(0)) revert BoundElsewhere(name, registryAddress, bound);

        DeviceWalletFactory(factory).addRegistryAddress(registryAddress);
        console.log(string.concat(name, ": bound to registry"));
    }

    /// @notice Tells the registry where the lazy wallet registry lives
    /// @dev This one is an update rather than a one-time set, so re-running it is harmless. It is
    ///      still skipped when already correct, to keep a resumed run from spending gas on nothing.
    function _bindLazyWalletRegistry(address registryAddress, address lazyWalletRegistry) private {
        if(Registry(registryAddress).lazyWalletRegistry() == lazyWalletRegistry) {
            console.log("Registry: lazy wallet registry already set, skipping");
            return;
        }

        Registry(registryAddress).addOrUpdateLazyWalletRegistryAddress(lazyWalletRegistry);
        console.log("Registry: lazy wallet registry set");
    }

    /// @notice Rotates the fallback ceiling on what an eSIM wallet may be charged for a data bundle
    /// @dev `Registry.initialize` already required a non-zero cap, so this only ever handles a
    ///      later change to it. Zero is not a legal configuration at any point after deployment
    ///      either: `setDefaultPriceCapUSDCents` refuses it the same way `initialize` does.
    function _setPriceCap(address registryAddress, uint64 cap) private {
        if(Registry(registryAddress).defaultPriceCapUSDCents() == cap) {
            console.log("Registry: price cap already set, skipping");
            return;
        }

        Registry(registryAddress).setDefaultPriceCapUSDCents(cap);
        console.log("Registry: price cap set to", cap);
    }

    /// @notice Reads every wiring back out of the contracts that hold it
    function _verify(
        address registryAddress,
        address lazyWalletRegistry,
        address deviceWalletFactory,
        address eSIMWalletFactory
    ) private view {
        address boundOnDevice = address(DeviceWalletFactory(deviceWalletFactory).registry());
        if(boundOnDevice != registryAddress) {
            revert NotWired("DeviceWalletFactory.registry", registryAddress, boundOnDevice);
        }

        address boundOnESIM = address(ESIMWalletFactory(eSIMWalletFactory).registry());
        if(boundOnESIM != registryAddress) {
            revert NotWired("ESIMWalletFactory.registry", registryAddress, boundOnESIM);
        }

        address boundLazy = Registry(registryAddress).lazyWalletRegistry();
        if(boundLazy != lazyWalletRegistry) {
            revert NotWired("Registry.lazyWalletRegistry", lazyWalletRegistry, boundLazy);
        }
    }
}
