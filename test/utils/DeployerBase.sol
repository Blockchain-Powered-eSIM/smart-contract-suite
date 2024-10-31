// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import "contracts/P256Verifier.sol";
import "contracts/Registry.sol";
import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/device-wallet/DeviceWallet.sol";
import "contracts/esim-wallet/ESIMWalletFactory.sol";

import "test/utils/mocks/MockEntryPoint.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";

contract DeployerBase is Test {

    address user1 = address(0x17F6AD8Ef982297579C203069C1DbfFE4348c372);
    address user2 = address(0x5c6B0f7Bf3E7ce046039Bd8FABdfD3f9F5021678);
    address user3 = address(0x1aE0EA34a72D944a8C7603FfB3eC30a6669E454C);
    address user4 = address(0x0A098Eda01Ce92ff4A4CCb7A4fFFb5A43EBC70DC);
    address user5 = address(0xCA35b7d915458EF540aDe6068dFe2F44E8fa733c);

    string[] public customDeviceUniqueIdentifiers = [ "Device_1", "Device_2", "Device_3", "Device_4", "Device_5" ];
    string[][] public customESIMUniqueIdentifiers;
    DataBundleDetails[][] public customDataBundleDetails;

    address eSIMWalletAdmin = address(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db);
    address upgradeManager = address(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2);
    address vault = address(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB);

    MockEntryPoint entryPoint;
    P256Verifier p256Verifier;
    DeviceWallet deviceWalletImpl;
    DeviceWalletFactory deviceWalletFactory;
    ESIMWalletFactory eSIMWalletFactory;
    Registry registry;
    MockLazyWalletRegistry lazyWalletRegistry;

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
        deviceWalletImpl = new DeviceWallet(
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
        MockLazyWalletRegistry lazyWalletRegistryImpl = new MockLazyWalletRegistry();
        console.log("lazyWalletRegistryImpl: ", address(lazyWalletRegistryImpl));
        // 7.b. Deploy Lazy Wallet Registry Proxy contract
        ERC1967Proxy lazyWalletRegistryProxy = new ERC1967Proxy(
            address(lazyWalletRegistryImpl),
            abi.encodeCall(
                lazyWalletRegistryImpl.initialize,
                (address(registry), upgradeManager)
            )
        );
        lazyWalletRegistry = MockLazyWalletRegistry(address(lazyWalletRegistryProxy));
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

        initializeCustomESIMUniqueIdentifiers();
        initializeCustomDataBundleDetails();
    }

    function initializeCustomESIMUniqueIdentifiers() public {
        customESIMUniqueIdentifiers.push(["eSIM_1_1", "eSIM_1_2", "eSIM_1_3", "eSIM_1_4", "eSIM_1_5"]);
        customESIMUniqueIdentifiers.push(["eSIM_2_1", "eSIM_2_2", "eSIM_2_3", "eSIM_2_4", "eSIM_2_5", "eSIM_2_6"]);
        customESIMUniqueIdentifiers.push(["eSIM_3_1", "eSIM_3_2", "eSIM_3_3", "eSIM_3_4"]);
        customESIMUniqueIdentifiers.push(["eSIM_4_1", "eSIM_4_2", "eSIM_4_3", "eSIM_4_4", "eSIM_4_5", "eSIM_4_6"]);
        customESIMUniqueIdentifiers.push(["eSIM_5_1", "eSIM_5_2"]);
    }

    function initializeCustomDataBundleDetails() public {
        // Initialize the first sub-array
        customDataBundleDetails.push();
        customDataBundleDetails[0].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[0].push(DataBundleDetails("DB_ID_2", 21));
        customDataBundleDetails[0].push(DataBundleDetails("DB_ID_3", 31));
        customDataBundleDetails[0].push(DataBundleDetails("DB_ID_4", 41));
        customDataBundleDetails[0].push(DataBundleDetails("DB_ID_5", 51));

        // Initialize the second sub-array
        customDataBundleDetails.push();
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_2", 21));
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_2", 21));
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_3", 31));
        customDataBundleDetails[1].push(DataBundleDetails("DB_ID_3", 31));

        // Initialize the third sub-array
        customDataBundleDetails.push();
        customDataBundleDetails[2].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[2].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[2].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[2].push(DataBundleDetails("DB_ID_1", 11));

        // Initialize the fourth sub-array
        customDataBundleDetails.push();
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_5", 51));
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_5", 51));
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_5", 51));
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_6", 61));
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_6", 61));
        customDataBundleDetails[3].push(DataBundleDetails("DB_ID_6", 61));

        // Initialize the fifth sub-array
        customDataBundleDetails.push();
        customDataBundleDetails[4].push(DataBundleDetails("DB_ID_1", 11));
        customDataBundleDetails[4].push(DataBundleDetails("DB_ID_1", 11));
    }
}
