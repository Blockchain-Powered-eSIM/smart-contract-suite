// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Every custom error the protocol reverts with, in one place
/// @dev An interface so each contract reaches them as `Errors.Name` without inheriting anything.
///      Grouped by the contract that raises them; a trailing note marks one raised elsewhere.
interface Errors {
    // Names the argument, since one function often checks several
    error ZeroAddress(string parameter);

    // Registry, LazyWalletRegistry, DeviceWalletFactory, ESIMWalletFactory, ESIMWallet and PaymentAdapter
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
    error OwnerKeyNotHeldByWallet(address deviceWallet);

    // Registry, DeviceWallet and ESIMWallet
    error ProtocolPaused();

    // RegistryHelper
    error OnlyLazyWalletRegistry();
    error DeviceIdentifierAlreadyRegistered(string deviceIdentifier);
    error OwnerKeyAlreadyRegistered(bytes32 ownerKeyHash);
    error SaltTooHigh(uint256 salt, uint256 count); // raised by LazyWalletRegistry
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
    error OnlyAdmin(); // raised by Registry
    error OnlyAdminOrRegistry();
    error OnlyEntryPoint(); // raised by Account4337
    error InvalidDeviceWalletOwnerKey(); // also DeviceWallet
    error VaultUnchanged(address vault); // raised by Registry
    error EmptyBatch();
    error DeviceWalletInfoAlreadyAdded(address deviceWallet);
    error DeviceWalletMismatch(address deviceWallet, address derived);
    error DeviceWalletNotDeployed(address deviceWallet);

    // Account4337, and so DeviceWallet through it
    error OnlySelf();
    error NewOwnerKeyCannotSign();
    error OnlyEntryPointOrSelf();

    // ESIMWallet and DeviceWallet
    error FailedToTransfer();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error ZeroAmount();
    // A currency with no token address, so nothing can be transferred in it
    error AssetNotTransferable(bytes32 asset);

    // ESIMWallet
    error OnlyRegistry();
    error OnlyDeviceWalletOrESIMWalletAdmin();
    error DataBundlePriceAboveCap(uint64 priceUSDCents, uint64 cap);
    error AdminAllowanceExceeded(uint64 priceUSDCents, uint64 remaining);
    error ESIMIdentifierAlreadySet(string eSIMUniqueIdentifier);
    error EmptyDataBundleID();
    error ZeroDataBundlePrice();
    error ZeroDataBundlePriceCap();
    error NotADeviceWallet(address account); // also RegistryHelper
    error OnlyRequestedOwner(address newRequestedOwner);
    error UseAcceptOwnershipTransfer();

    // DeviceWallet
    error UnknownESIMWallet(address eSIMWallet); // also RegistryHelper
    error FundsAccessRevoked(address eSIMWallet);
    error FundsAccessNotGrantableAtBind(address eSIMWallet);
    error ESIMWalletAlreadyAdded(address eSIMWallet);
    error ESIMWalletNotOwnedByThisDeviceWallet(address eSIMWallet, address eSIMWalletOwner);
    error OnlyRegistryOrDeviceWalletFactoryOrOwner();
    error OnlySelfOrAssociatedESIMWallet();
    error OnlyESIMWalletAdminOrRegistry();
    error OnlyAssociatedESIMWallets();
    error OnlyESIMWalletAdmin();

    // Registry, on the path for purchases paid for outside the protocol
    error PaymentAdapterNotSet();
    error PaymentAdapterUnchanged(address paymentAdapter);
    // Only ESIMWallet.buyDataBundleWithToken may claim the protocol saw the money move
    error SettlementNotAsserted();
    // Older history is still waiting to be copied, so a new entry would land out of order
    error HistoryNotFullyCopied(string eSIMIdentifier, uint256 outstanding);

    // PaymentAdapter
    error EmptyAssetSymbol();
    error EmptyPaymentReference(); // also Registry
    error AssetNotAllowed(bytes32 asset);
    error AssetAlreadyRegistered(bytes32 asset);
    error AssetNotRegistered(bytes32 asset);
    // quote divides by 100, so fewer than two decimals loses the cents
    error AssetDecimalsTooLow(bytes32 asset, uint8 decimals);
    // Past the ceiling, quote overflows and the currency can never be priced
    error AssetDecimalsTooHigh(bytes32 asset, uint8 decimals);
    // No price feeds, so only a currency already in dollars can be converted from cents
    error AssetNeedsSwap(bytes32 asset);
    error PaymentReferenceAlreadyUsed(bytes32 paymentReference); // also Registry
    // The price costs more of the currency than the buyer was willing to spend
    error SettlementAboveMax(uint256 required, uint256 maxAmountIn);
    // The caller has to send the tokens before calling settle, and sent less than it declared
    error SettlementNotFunded(uint256 amountIn, uint256 balance);
}
