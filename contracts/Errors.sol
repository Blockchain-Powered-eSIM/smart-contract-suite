// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Every custom error the protocol reverts with, in one place
/// @dev An interface rather than a library so each contract reaches them as `Errors.Name` without
///      inheriting anything. Grouped by the contract that raises them; several are shared, and the
///      comment above each group names who uses it.
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
    error AdminAlreadyDisabled();
    error AdminNotDisabled();

    // Registry, DeviceWallet and ESIMWallet
    error ProtocolPaused();

    // RegistryHelper
    error OnlyLazyWalletRegistry();
    error DeviceIdentifierAlreadyRegistered(string deviceIdentifier);
    error OwnerKeyAlreadyRegistered(bytes32 ownerKeyHash);
    error SaltTooHigh(uint256 salt, uint256 count);
    error DeviceWalletAlreadyExists(string deviceIdentifier, address deviceWallet);
    error NotAProtocolESIMWallet(address eSIMWallet);
    error DeviceIdentifierReservedForLazyWallet(string deviceIdentifier);
    error ESIMIdentifierReservedForLazyWallet(string eSIMIdentifier);
    error ESIMIdentifierAlreadyClaimed(string eSIMIdentifier, address eSIMWallet);

    // Any contract rejecting an identifier it was handed empty
    error EmptyDeviceIdentifier();
    error EmptyESIMIdentifier();

    // Any contract taking parallel arrays: LazyWalletRegistry and DeviceWalletFactory
    error ArrayLengthMismatch(uint256 expected, uint256 actual);

    // LazyWalletRegistry
    error LazyWalletAlreadyDeployed(string deviceIdentifier);
    error IdentifierTooLong(string identifier, uint256 maxLength);
    error DepositDoesNotMatchValue(uint256 depositAmount, uint256 value);
    error NoESIMIdentifiersForDevice(string deviceIdentifier);
    error UnknownESIMIdentifier(string eSIMIdentifier);
    error ESIMBoundToADifferentDevice(string eSIMIdentifier, string boundDeviceIdentifier);
    error ESIMIdentifierNotFound(string eSIMIdentifier, string deviceIdentifier);
    error CannotSwitchToTheSameDevice(string deviceIdentifier);
    error ESIMWalletNotLazyDeployed(string eSIMIdentifier);
    error HistoryAlreadyCopied(string eSIMIdentifier);
    error TooManyHistoryEntries(uint256 requested, uint256 maxPerCall);
    error LazyWalletNotDeployed(string deviceIdentifier);
    error AllESIMWalletsDeployed(string deviceIdentifier);
    error TooManyESIMWallets(uint256 requested, uint256 maxPerCall);

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
    error VaultUnchanged(address vault);
    error EmptyBatch();
    error DeviceWalletInfoAlreadyAdded(address deviceWallet);
    error DeviceWalletMismatch(address deviceWallet, address derived);
    error DeviceWalletNotDeployed(address deviceWallet);

    // Account4337, and so DeviceWallet through it
    error OnlySelf();
    error OnlyEntryPointOrSelf();

    // ESIMWallet and DeviceWallet
    error FailedToTransfer();
    error InsufficientBalance(uint256 balance, uint256 amount);

    // ESIMWallet
    error OnlyRegistry();
    error OnlyDeviceWalletOrESIMWalletAdmin();
    error DataBundlePriceAboveCap(uint64 priceUSDCents, uint64 cap);
    error ESIMIdentifierAlreadySet(string eSIMUniqueIdentifier);
    error EmptyDataBundleID();
    error ZeroDataBundlePrice();
    error ZeroDataBundlePriceCap();
    error NotADeviceWallet(address account);
    error OnlyRequestedOwner(address newRequestedOwner);
    error UseAcceptOwnershipTransfer();

    // DeviceWallet
    error UnknownESIMWallet(address eSIMWallet);
    error ZeroAmount();
    error ETHAccessRevoked(address eSIMWallet);
    error ETHAccessNotGrantableAtBind(address eSIMWallet);
    error ESIMWalletAlreadyAdded(address eSIMWallet);
    error ESIMWalletNotOwnedByThisDeviceWallet(address eSIMWallet, address eSIMWalletOwner);
    error OnlyRegistryOrDeviceWalletFactoryOrOwner();
    error OnlySelfOrAssociatedESIMWallet();
    error OnlyESIMWalletAdminOrRegistry();
    error OnlyAssociatedESIMWallets();
    error OnlyESIMWalletAdmin();

    // Registry, on the path that records a purchase the contracts did not witness
    error PaymentAdapterNotSet();
    error PaymentAdapterUnchanged(address paymentAdapter);
    // buyDataBundle is the only caller allowed to claim the protocol saw the money move
    error SettlementNotAsserted();
    // The lazy registry still owes this eSIM history, so a new entry would land out of order
    error HistoryNotFullyCopied(string eSIMIdentifier, uint256 outstanding);

    // PaymentAdapter
    error EmptyAssetSymbol();
    error EmptyPaymentReference();
    error AssetNotAllowed(bytes32 asset);
    error AssetAlreadyRegistered(bytes32 asset);
    error AssetNotRegistered(bytes32 asset);
    // quote scales cents by 10**decimals and divides by 100, so anything under two truncates
    error AssetDecimalsTooLow(bytes32 asset, uint8 decimals);
    // No oracle, so a price only becomes a token amount for an asset already denominated in dollars
    error AssetNeedsSwap(bytes32 asset);
    // Record-only assets, fiat and non-EVM, carry no token address to move
    error AssetNotSettleable(bytes32 asset);
    error PaymentReferenceAlreadyUsed(bytes32 paymentReference);
    error SettlementNotAvailable();
}
