// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface Errors {
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
