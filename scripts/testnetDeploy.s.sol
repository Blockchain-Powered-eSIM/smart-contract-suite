// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {P256Verifier} from "../contracts/P256Verifier.sol";
import {ESIMWalletFactory} from "../contracts/esim-wallet/ESIMWalletFactory.sol";
import {DeviceWalletFactory} from "../contracts/device-wallet/DeviceWalletFactory.sol";
import {Registry} from "../contracts/Registry.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";

import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployContracts is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy EntryPoint
        address entryPointZeroPointSeven = 0x0000000071727De22E5E9d8BAf0edAc6f37da032; // mainnet
        IEntryPoint typeCastEntryPoint = IEntryPoint(address(entryPointZeroPointSeven));
        // console.log("EntryPoint deployed at:", address(typeCastEntryPoint));

        // 2. Deploy P256 Verifier
        P256Verifier p256Verifier = new P256Verifier();
        console.log("P256Verifier deployed at:", address(p256Verifier));

        // 3. Deploy Device Wallet implementation
        DeviceWallet deviceWalletImpl = new DeviceWallet(typeCastEntryPoint, p256Verifier);
        console.log("DeviceWalletImpl deployed at:", address(deviceWalletImpl));

        // 4. Deploy Device Wallet Factory (Logic + Proxy)
        DeviceWalletFactory deviceWalletFactoryImpl = new DeviceWalletFactory();
        ERC1967Proxy deviceWalletFactoryProxy = new ERC1967Proxy(
            address(deviceWalletFactoryImpl),
            abi.encodeCall(
                deviceWalletFactoryImpl.initialize,
                (address(deviceWalletImpl), vm.envAddress("ESIM_WALLET_ADMIN"), vm.envAddress("VAULT"), vm.envAddress("UPGRADE_MANAGER"), typeCastEntryPoint, p256Verifier)
            )
        );
        DeviceWalletFactory deviceWalletFactory = DeviceWalletFactory(address(deviceWalletFactoryProxy));
        console.log("DeviceWalletFactory deployed at:", address(deviceWalletFactory));

        // 5. Deploy ESIM Wallet implementation
        ESIMWallet eSIMWalletImpl = new ESIMWallet();
        console.log("ESIMWalletImpl deployed at:", address(eSIMWalletImpl));

        // 6. Deploy ESIM Wallet Factory (Logic + Proxy)
        ESIMWalletFactory eSIMWalletFactoryImpl = new ESIMWalletFactory();
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            address(eSIMWalletFactoryImpl),
            abi.encodeCall(eSIMWalletFactoryImpl.initialize, (address(eSIMWalletImpl), vm.envAddress("UPGRADE_MANAGER")))
        );
        ESIMWalletFactory eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));
        console.log("ESIMWalletFactory deployed at:", address(eSIMWalletFactory));

        // 7. Deploy Registry (Logic + Proxy)
        Registry registryImpl = new Registry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (vm.envAddress("ESIM_WALLET_ADMIN"), vm.envAddress("VAULT"), vm.envAddress("UPGRADE_MANAGER"), address(deviceWalletFactory), address(eSIMWalletFactory), typeCastEntryPoint, p256Verifier)
            )
        );
        Registry registry = Registry(address(registryProxy));
        console.log("Registry deployed at:", address(registry));

        // 8. Deploy Lazy Wallet Registry (Logic + Proxy)
        LazyWalletRegistry lazyWalletRegistryImpl = new LazyWalletRegistry();
        ERC1967Proxy lazyWalletRegistryProxy = new ERC1967Proxy(
            address(lazyWalletRegistryImpl),
            abi.encodeCall(lazyWalletRegistryImpl.initialize, (address(registry), vm.envAddress("UPGRADE_MANAGER")))
        );
        LazyWalletRegistry lazyWalletRegistry = LazyWalletRegistry(address(lazyWalletRegistryProxy));
        console.log("LazyWalletRegistry deployed at:", address(lazyWalletRegistry));

        vm.stopBroadcast();

        // 9. Configure registry addresses
        // vm.startBroadcast(vm.envAddress("UPGRADE_MANAGER"));
        // registry.addOrUpdateLazyWalletRegistryAddress(address(lazyWalletRegistry));
        // vm.stopBroadcast();

        // vm.startBroadcast(vm.envAddress("ESIM_WALLET_ADMIN"));
        // deviceWalletFactory.addRegistryAddress(address(registry));
        // vm.stopBroadcast();

        // vm.startBroadcast(vm.envAddress("UPGRADE_MANAGER"));
        // eSIMWalletFactory.addRegistryAddress(address(registry));
        // vm.stopBroadcast();
    }
}
