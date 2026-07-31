// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface Errors {
    // Any contract rejecting a zero address argument. The parameter name identifies which
    // argument was zero, since a single function often checks several.
    error ZeroAddress(string parameter);

    // Every Ownable contract: Registry, LazyWalletRegistry, DeviceWalletFactory,
    // ESIMWalletFactory and ESIMWallet
    error OwnershipCannotBeRenounced();

    // Registry and ESIMWallet
    error OnlyDeviceWallet();

    // Registry
    error OnlyDeviceWalletFactory();

    // RegistryHelper
    error OnlyLazyWalletRegistry();
    error DeviceIdentifierAlreadyRegistered(string deviceIdentifier);
    error OwnerKeyAlreadyRegistered(bytes32 ownerKeyHash);

    // LazyWalletRegistry
    error LazyWalletAlreadyDeployed(string deviceIdentifier);

    // ESIMWalletFactory
    error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();
    error OnlyDeployForSelf();
    error SaltAlreadyUsed(address deviceWallet, uint256 salt);

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
