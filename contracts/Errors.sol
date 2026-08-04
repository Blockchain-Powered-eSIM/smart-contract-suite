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
    error OnlyRequestedAdmin(address requestedAdmin);
    error NotTheESIMWalletOwnerOrItsDeviceWallet(address eSIMWallet);
    error ESIMWalletOwnershipTransferPending(address eSIMWallet, address newRequestedOwner);
    error NotTheAssociatedDeviceWallet(address eSIMWallet, address associatedDeviceWallet);

    // Registry, DeviceWallet and ESIMWallet
    error ProtocolPaused();

    // RegistryHelper
    error OnlyLazyWalletRegistry();
    error DeviceIdentifierAlreadyRegistered(string deviceIdentifier);
    error OwnerKeyAlreadyRegistered(bytes32 ownerKeyHash);
    error SaltTooHigh(uint256 salt, uint256 count);
    error DeviceWalletAlreadyExists(string deviceIdentifier, address deviceWallet);

    // LazyWalletRegistry
    error LazyWalletAlreadyDeployed(string deviceIdentifier);
    error IdentifierTooLong(string identifier, uint256 maxLength);

    // ESIMWalletFactory
    error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();
    error OnlyDeployForSelf();
    error SaltAlreadyUsed(address deviceWallet, uint256 salt);

    // Any factory holding a beacon: ESIMWalletFactory and DeviceWalletFactory
    error RegistryAlreadySet(address registry);
    error ImplementationUnchanged(address implementation);

    // DeviceWalletFactory
    error OnlyAdmin();
    error OnlyAdminOrRegistry();
    error OnlyEntryPoint();
    error InvalidDeviceWalletOwnerKey();

    // Account4337, and so DeviceWallet through it
    error OnlySelf();
    error OnlyEntryPointOrSelf();

    // ESIMWallet and DeviceWallet
    error FailedToTransfer();
    error InsufficientBalance(uint256 balance, uint256 amount);

    // ESIMWallet
    error OnlyRegistry();
    error OnlyDeviceWalletOrESIMWalletAdmin();
    error DataBundlePriceAboveCap(uint256 price, uint256 cap);
    error ESIMIdentifierAlreadySet(string eSIMUniqueIdentifier);
    error EmptyESIMIdentifier();
    error EmptyDataBundleID();
    error ZeroDataBundlePrice();
    error TransactionHistoryNotEmpty();
    error NotADeviceWallet(address account);
    error OnlyRequestedOwner(address newRequestedOwner);
    error UseAcceptOwnershipTransfer();

    // DeviceWallet
    error OnlyRegistryOrDeviceWalletFactoryOrOwner();
    error OnlySelfOrAssociatedESIMWallet();
    error OnlyESIMWalletAdminOrRegistry();
    error OnlyAssociatedESIMWallets();
    error OnlyESIMWalletAdmin();
}
