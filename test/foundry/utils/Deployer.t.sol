// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import "contracts/P256Verifier.sol";
import "contracts/Registry.sol";
import "contracts/LazyWalletRegistry.sol";
import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/device-wallet/DeviceWallet.sol";
import "contracts/esim-wallet/ESIMWalletFactory.sol";

import "test/foundry/utils/mocks/MockEntryPoint.sol";

contract Deployer is Test {

    address eSIMWalletAdmin = address(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db);
    address upgradeManager = address(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2);
    address vault = address(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB);

    MockEntryPoint entryPoint;
    P256Verifier p256Verifier;
    DeviceWalletFactory deviceWalletFactory;
    ESIMWalletFactory eSIMWalletFactory;
    Registry registry;
    LazyWalletRegistry lazyWalletRegistry;

    function setUp() public {
        // 1.a. Deploy Mock Entry Point
        entryPoint = new MockEntryPoint();
        // 1.b. Typecast for further use
        IEntryPoint typeCastEntryPoint = IEntryPoint(address(entryPoint));
        console.log("typeCastEntryPoint: ", address(typeCastEntryPoint));

        // 2. Deploy P256 Verifier
        p256Verifier = new P256Verifier();
        console.log("p256Verifier: ", address(p256Verifier));

        // 3. Deploy Device Wallet implementation
        DeviceWallet deviceWalletImpl = new DeviceWallet(
            typeCastEntryPoint,
            p256Verifier
        );
        console.log("deviceWalletImpl: ", address(deviceWalletImpl));

        // 4.a. Deploy Device Wallet Factory Implementation (Logic) contract
        DeviceWalletFactory deviceWalletFactoryImpl = new DeviceWalletFactory();
        console.log("deviceWalletFactoryImpl: ", address(deviceWalletFactoryImpl));
        // 4.b. Deploy Device Wallet Factory Proxy contract
        ERC1967Proxy deviceWalletFactoryProxy = new ERC1967Proxy(
            address(deviceWalletFactoryImpl),
            abi.encodeCall(
                deviceWalletFactoryImpl.initialize,
                (address(deviceWalletImpl), eSIMWalletAdmin, vault, upgradeManager, typeCastEntryPoint, p256Verifier)
            )
        );
        deviceWalletFactory = DeviceWalletFactory(address(deviceWalletFactoryProxy));
        console.log("deviceWalletFactory: ", address(deviceWalletFactory));

        // 5.a. Deploy ESIM Wallet Factory Implementation (Logic) contract
        ESIMWalletFactory eSIMWalletFactoryImpl = new ESIMWalletFactory();
        console.log("eSIMWalletFactoryImpl: ", address(eSIMWalletFactoryImpl));
        // 5.b. Deploy ESIM Wallet Factory Proxy contract
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            address(eSIMWalletFactoryImpl),
            abi.encodeCall(
                eSIMWalletFactoryImpl.initialize,
                (upgradeManager)
            )
        );
        eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));
        console.log("eSIMWalletFactory: ", address(eSIMWalletFactory));

        // 6.a. Deploy Registry Implementation (Logic) contract
        Registry registryImpl = new Registry();
        console.log("registryImpl: ", address(registryImpl));
        // 6.b. Deploy Registry Proxy contract
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (eSIMWalletAdmin, vault, upgradeManager, address(deviceWalletFactory), address(eSIMWalletFactory), typeCastEntryPoint, p256Verifier)
            )
        );
        registry = Registry(address(registryProxy));
        console.log("registry: ", address(registry));

        // 7.a. Deploy Lazy Wallet Registry Implementation (Logic) contract
        LazyWalletRegistry lazyWalletRegistryImpl = new LazyWalletRegistry();
        console.log("lazyWalletRegistryImpl: ", address(lazyWalletRegistryImpl));
        // 7.b. Deploy Lazy Wallet Registry Proxy contract
        ERC1967Proxy lazyWalletRegistryProxy = new ERC1967Proxy(
            address(lazyWalletRegistryImpl),
            abi.encodeCall(
                lazyWalletRegistryImpl.initialize,
                (address(registry), upgradeManager)
            )
        );
        lazyWalletRegistry = LazyWalletRegistry(address(lazyWalletRegistryProxy));
        console.log("lazyWalletRegistry: ", address(lazyWalletRegistry));

        // 8. Populate addresses deployed during the process
        vm.startPrank(upgradeManager);
        registry.addOrUpdateLazyWalletRegistryAddress(address(lazyWalletRegistry));
        vm.stopPrank();

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();

        vm.startPrank(upgradeManager);
        eSIMWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }
}