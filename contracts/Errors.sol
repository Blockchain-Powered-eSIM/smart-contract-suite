// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface Errors {
    // Every Ownable contract: Registry, LazyWalletRegistry, DeviceWalletFactory,
    // ESIMWalletFactory and ESIMWallet
    error OwnershipCannotBeRenounced();

    // Registry and ESIMWallet
    error OnlyDeviceWallet();

    // Registry
    error OnlyDeviceWalletFactory();

    // RegistryHelper
    error OnlyLazyWalletRegistry();

    // ESIMWalletFactory
    error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();

    // DeviceWalletFactory
    error OnlyAdmin();
    error OnlyAdminOrRegistry();
    error OnlyEntryPoint();
    error InvalidDeviceWalletOwnerKey();

    // ESIMWallet and DeviceWallet
    error FailedToTransfer();

    // ESIMWallet
    error OnlyRegistry();
    error OnlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet();
    error OnlyDeviceWalletOrESIMWalletAdmin();

    // DeviceWallet
    error OnlyRegistryOrDeviceWalletFactoryOrOwner();
    error OnlySelfOrAssociatedESIMWallet();
    error OnlyESIMWalletAdminOrRegistry();
    error OnlyESIMWalletAdminOrDeviceWalletOwner();
    error OnlyESIMWalletAdminOrDeviceWalletFactory();
    error OnlyAssociatedESIMWallets();
    error OnlyESIMWalletAdmin();
}
