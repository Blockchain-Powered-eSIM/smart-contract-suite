// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import "contracts/CustomStructs.sol";
import "contracts/P256Verifier.sol";
import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/esim-wallet/ESIMWalletFactory.sol";

import "test/utils/mocks/MockEntryPoint.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";
import "test/utils/mocks/MockRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

contract DeployerBase is Test {

    address user1 = address(0x17F6AD8Ef982297579C203069C1DbfFE4348c372);
    address user2 = address(0x5c6B0f7Bf3E7ce046039Bd8FABdfD3f9F5021678);
    address user3 = address(0x1aE0EA34a72D944a8C7603FfB3eC30a6669E454C);
    address user4 = address(0x0A098Eda01Ce92ff4A4CCb7A4fFFb5A43EBC70DC);
    address user5 = address(0xCA35b7d915458EF540aDe6068dFe2F44E8fa733c);

    bytes32[2] public pubKey1 = [
        bytes32(0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296),
        bytes32(0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)
    ];
    bytes32[2] public pubKey2 = [
        bytes32(0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978),
        bytes32(0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1)
    ];
    bytes32[2] public pubKey3 = [
        bytes32(0x5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C),
        bytes32(0x8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032)
    ];
    bytes32[2] public pubKey4 = [
        bytes32(0xE2534A3532D08FBBA02DDE659EE62BD0031FE2DB785596EF509302446B030852),
        bytes32(0xE0F1575A4C633CC719DFEE5FDA862D764EFC96C3F30EE0055C42C23F184ED8C6)
    ];
    bytes32[2] public pubKey5 = [
        bytes32(0x51590B7A515140D2D784C85608668FDFEF8C82FD1F5BE52421554A0DC3D033ED),
        bytes32(0xE0C17DA8904A727D8AE1BF36BF8A79260D012F00D4D80888D1D0BB44FDA16DA4)
    ];

    string[] public customDeviceUniqueIdentifiers = [ "Device_1", "Device_2", "Device_3", "Device_4", "Device_5" ];
    string[][] public customESIMUniqueIdentifiers;
    string [][] public duplicateESIMUniqueIdentifiers;
    DataBundleDetails[][] public customDataBundleDetails;
    bytes32[2][] public listOfOwnerKeys;

    // Interchanged params to test if the code correctly reverts
    string[] public modifiedDeviceUniqueIdentifiers = [ "Device_1", "Device_2" ];
    string[][] public modifiedESIMUniqueIdentifiers;
    DataBundleDetails[][] public modifiedDataBundleDetails;

    address eSIMWalletAdmin = address(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db);
    address upgradeManager = address(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2);
    address vault = address(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB);

    MockEntryPoint entryPoint;
    IEntryPoint typeCastEntryPoint;
    P256Verifier p256Verifier;
    DeviceWalletFactory deviceWalletFactory;
    ESIMWalletFactory eSIMWalletFactory;
    MockRegistry registry;
    MockLazyWalletRegistry lazyWalletRegistry;

    MockDeviceWallet deviceWalletImpl;
    MockESIMWallet eSIMWalletImpl;

    function setUp() public {
        // 1.a. Deploy Mock Entry Point
        entryPoint = new MockEntryPoint();
        // 1.b. Typecast for further use
        typeCastEntryPoint = IEntryPoint(address(entryPoint));
        console.log("typeCastEntryPoint: ", address(typeCastEntryPoint));

        // 2. Deploy P256 Verifier
        p256Verifier = new P256Verifier();
        console.log("p256Verifier: ", address(p256Verifier));

        // 3. Deploy Device Wallet implementation
        deviceWalletImpl = new MockDeviceWallet(
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

        // 5. Deploy ESIM Wallet implementation
        eSIMWalletImpl = new MockESIMWallet();
        console.log("eSIMWalletImpl: ", address(eSIMWalletImpl));

        // 6.a. Deploy ESIM Wallet Factory Implementation (Logic) contract
        ESIMWalletFactory eSIMWalletFactoryImpl = new ESIMWalletFactory();
        console.log("eSIMWalletFactoryImpl: ", address(eSIMWalletFactoryImpl));
        // 6.b. Deploy ESIM Wallet Factory Proxy contract
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            address(eSIMWalletFactoryImpl),
            abi.encodeCall(
                eSIMWalletFactoryImpl.initialize,
                (address(eSIMWalletImpl), upgradeManager)
            )
        );
        eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));
        console.log("eSIMWalletFactory: ", address(eSIMWalletFactory));

        // 7.a. Deploy Registry Implementation (Logic) contract
        MockRegistry registryImpl = new MockRegistry();
        console.log("registryImpl: ", address(registryImpl));
        // 7.b. Deploy Registry Proxy contract
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (eSIMWalletAdmin, vault, upgradeManager, address(deviceWalletFactory), address(eSIMWalletFactory), typeCastEntryPoint, p256Verifier)
            )
        );
        registry = MockRegistry(address(registryProxy));
        console.log("registry: ", address(registry));

        // 8.a. Deploy Lazy Wallet Registry Implementation (Logic) contract
        MockLazyWalletRegistry lazyWalletRegistryImpl = new MockLazyWalletRegistry();
        console.log("lazyWalletRegistryImpl: ", address(lazyWalletRegistryImpl));
        // 8.b. Deploy Lazy Wallet Registry Proxy contract
        ERC1967Proxy lazyWalletRegistryProxy = new ERC1967Proxy(
            address(lazyWalletRegistryImpl),
            abi.encodeCall(
                lazyWalletRegistryImpl.initialize,
                (address(registry), upgradeManager)
            )
        );
        lazyWalletRegistry = MockLazyWalletRegistry(address(lazyWalletRegistryProxy));
        console.log("lazyWalletRegistry: ", address(lazyWalletRegistry));

        // 9. Populate addresses deployed during the process
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
        initializeIncorrectParams();
        initializeDeviceOwnerKeys();
        initializeDuplicateESIMUniqueIdentifiers();
    }

    function initializeCustomESIMUniqueIdentifiers() public {
        customESIMUniqueIdentifiers.push(["eSIM_1_1", "eSIM_1_2", "eSIM_1_3", "eSIM_1_4", "eSIM_1_5"]);
        customESIMUniqueIdentifiers.push(["eSIM_2_1", "eSIM_2_2", "eSIM_2_3", "eSIM_2_4", "eSIM_2_5", "eSIM_2_6"]);
        customESIMUniqueIdentifiers.push(["eSIM_3_1", "eSIM_3_2", "eSIM_3_3", "eSIM_3_4"]);
        customESIMUniqueIdentifiers.push(["eSIM_4_1", "eSIM_4_2", "eSIM_4_3", "eSIM_4_4", "eSIM_4_5", "eSIM_4_6"]);
        customESIMUniqueIdentifiers.push(["eSIM_5_1", "eSIM_5_2"]);
    }

    function initializeDuplicateESIMUniqueIdentifiers() public {
        duplicateESIMUniqueIdentifiers.push(["eSIM_1_1", "eSIM_1_1", "eSIM_1_1", "eSIM_1_1", "eSIM_1_1"]);
        duplicateESIMUniqueIdentifiers.push(["eSIM_2_1", "eSIM_2_2", "eSIM_2_3", "eSIM_2_4", "eSIM_2_5", "eSIM_2_6"]);
        duplicateESIMUniqueIdentifiers.push(["eSIM_3_1", "eSIM_3_2", "eSIM_3_3", "eSIM_3_4"]);
        duplicateESIMUniqueIdentifiers.push(["eSIM_4_1", "eSIM_4_2", "eSIM_4_3", "eSIM_4_4", "eSIM_4_5", "eSIM_4_6"]);
        duplicateESIMUniqueIdentifiers.push(["eSIM_5_1", "eSIM_5_2"]);
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

    function initializeIncorrectParams() public {
        modifiedESIMUniqueIdentifiers.push(["eSIM_4_1", "eSIM_4_2", "eSIM_4_3", "eSIM_4_4", "eSIM_4_5", "eSIM_4_6"]);
        modifiedESIMUniqueIdentifiers.push(["eSIM_5_1", "eSIM_5_2"]);

        modifiedDataBundleDetails.push();
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_5", 51));
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_5", 51));
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_6", 61));
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_6", 61));
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_6", 61));
        modifiedDataBundleDetails[0].push(DataBundleDetails("DB_ID_5", 51));

        modifiedDataBundleDetails.push();
        modifiedDataBundleDetails[1].push(DataBundleDetails("DB_ID_1", 11));
        modifiedDataBundleDetails[1].push(DataBundleDetails("DB_ID_1", 11));
    }

    function initializeDeviceOwnerKeys() public {
        listOfOwnerKeys.push(pubKey1);
        listOfOwnerKeys.push(pubKey2);
        listOfOwnerKeys.push(pubKey3);
        listOfOwnerKeys.push(pubKey4);
        listOfOwnerKeys.push(pubKey5);
    }
}
