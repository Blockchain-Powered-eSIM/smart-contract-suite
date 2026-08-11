# Solidity API

## Errors

Every custom error the protocol reverts with, in one place

_An interface rather than a library so each contract reaches them as `Errors.Name` without
     inheriting anything. Grouped by the contract that raises them; several are shared, and the
     comment above each group names who uses it._

### ZeroAddress

```solidity
error ZeroAddress(string parameter)
```

### OwnershipCannotBeRenounced

```solidity
error OwnershipCannotBeRenounced()
```

### OnlyDeviceWallet

```solidity
error OnlyDeviceWallet()
```

### OnlyDeviceWalletFactory

```solidity
error OnlyDeviceWalletFactory()
```

### OnlyRequestedAdmin

```solidity
error OnlyRequestedAdmin(address requestedAdmin)
```

### NotTheESIMWalletOwnerOrItsDeviceWallet

```solidity
error NotTheESIMWalletOwnerOrItsDeviceWallet(address eSIMWallet)
```

### ESIMWalletOwnershipTransferPending

```solidity
error ESIMWalletOwnershipTransferPending(address eSIMWallet, address newRequestedOwner)
```

### NotTheAssociatedDeviceWallet

```solidity
error NotTheAssociatedDeviceWallet(address eSIMWallet, address associatedDeviceWallet)
```

### ProtocolPaused

```solidity
error ProtocolPaused()
```

### OnlyLazyWalletRegistry

```solidity
error OnlyLazyWalletRegistry()
```

### DeviceIdentifierAlreadyRegistered

```solidity
error DeviceIdentifierAlreadyRegistered(string deviceIdentifier)
```

### OwnerKeyAlreadyRegistered

```solidity
error OwnerKeyAlreadyRegistered(bytes32 ownerKeyHash)
```

### SaltTooHigh

```solidity
error SaltTooHigh(uint256 salt, uint256 count)
```

### DeviceWalletAlreadyExists

```solidity
error DeviceWalletAlreadyExists(string deviceIdentifier, address deviceWallet)
```

### NotAProtocolESIMWallet

```solidity
error NotAProtocolESIMWallet(address eSIMWallet)
```

### EmptyDeviceIdentifier

```solidity
error EmptyDeviceIdentifier()
```

### EmptyESIMIdentifier

```solidity
error EmptyESIMIdentifier()
```

### ArrayLengthMismatch

```solidity
error ArrayLengthMismatch(uint256 expected, uint256 actual)
```

### LazyWalletAlreadyDeployed

```solidity
error LazyWalletAlreadyDeployed(string deviceIdentifier)
```

### IdentifierTooLong

```solidity
error IdentifierTooLong(string identifier, uint256 maxLength)
```

### DepositDoesNotMatchValue

```solidity
error DepositDoesNotMatchValue(uint256 depositAmount, uint256 value)
```

### NoESIMIdentifiersForDevice

```solidity
error NoESIMIdentifiersForDevice(string deviceIdentifier)
```

### UnknownESIMIdentifier

```solidity
error UnknownESIMIdentifier(string eSIMIdentifier)
```

### ESIMBoundToADifferentDevice

```solidity
error ESIMBoundToADifferentDevice(string eSIMIdentifier, string boundDeviceIdentifier)
```

### CannotSwitchToTheSameDevice

```solidity
error CannotSwitchToTheSameDevice(string deviceIdentifier)
```

### ESIMWalletNotLazyDeployed

```solidity
error ESIMWalletNotLazyDeployed(string eSIMIdentifier)
```

### HistoryAlreadyCopied

```solidity
error HistoryAlreadyCopied(string eSIMIdentifier)
```

### TooManyHistoryEntries

```solidity
error TooManyHistoryEntries(uint256 requested, uint256 maxPerCall)
```

### LazyWalletNotDeployed

```solidity
error LazyWalletNotDeployed(string deviceIdentifier)
```

### AllESIMWalletsDeployed

```solidity
error AllESIMWalletsDeployed(string deviceIdentifier)
```

### TooManyESIMWallets

```solidity
error TooManyESIMWallets(uint256 requested, uint256 maxPerCall)
```

### OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet

```solidity
error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet()
```

### OnlyDeployForSelf

```solidity
error OnlyDeployForSelf()
```

### SaltAlreadyUsed

```solidity
error SaltAlreadyUsed(address deviceWallet, uint256 salt)
```

### RegistryAlreadySet

```solidity
error RegistryAlreadySet(address registry)
```

### ImplementationUnchanged

```solidity
error ImplementationUnchanged(address implementation)
```

### OnlyAdmin

```solidity
error OnlyAdmin()
```

### OnlyAdminOrRegistry

```solidity
error OnlyAdminOrRegistry()
```

### OnlyEntryPoint

```solidity
error OnlyEntryPoint()
```

### InvalidDeviceWalletOwnerKey

```solidity
error InvalidDeviceWalletOwnerKey()
```

### VaultUnchanged

```solidity
error VaultUnchanged(address vault)
```

### EmptyBatch

```solidity
error EmptyBatch()
```

### DeviceWalletInfoAlreadyAdded

```solidity
error DeviceWalletInfoAlreadyAdded(address deviceWallet)
```

### OnlySelf

```solidity
error OnlySelf()
```

### OnlyEntryPointOrSelf

```solidity
error OnlyEntryPointOrSelf()
```

### FailedToTransfer

```solidity
error FailedToTransfer()
```

### InsufficientBalance

```solidity
error InsufficientBalance(uint256 balance, uint256 amount)
```

### OnlyRegistry

```solidity
error OnlyRegistry()
```

### OnlyDeviceWalletOrESIMWalletAdmin

```solidity
error OnlyDeviceWalletOrESIMWalletAdmin()
```

### DataBundlePriceAboveCap

```solidity
error DataBundlePriceAboveCap(uint256 price, uint256 cap)
```

### ESIMIdentifierAlreadySet

```solidity
error ESIMIdentifierAlreadySet(string eSIMUniqueIdentifier)
```

### EmptyDataBundleID

```solidity
error EmptyDataBundleID()
```

### ZeroDataBundlePrice

```solidity
error ZeroDataBundlePrice()
```

### ZeroDataBundlePriceCap

```solidity
error ZeroDataBundlePriceCap()
```

### NotADeviceWallet

```solidity
error NotADeviceWallet(address account)
```

### OnlyRequestedOwner

```solidity
error OnlyRequestedOwner(address newRequestedOwner)
```

### UseAcceptOwnershipTransfer

```solidity
error UseAcceptOwnershipTransfer()
```

### UnknownESIMWallet

```solidity
error UnknownESIMWallet(address eSIMWallet)
```

### ZeroAmount

```solidity
error ZeroAmount()
```

### ETHAccessRevoked

```solidity
error ETHAccessRevoked(address eSIMWallet)
```

### ESIMWalletAlreadyAdded

```solidity
error ESIMWalletAlreadyAdded(address eSIMWallet)
```

### ESIMWalletNotOwnedByThisDeviceWallet

```solidity
error ESIMWalletNotOwnedByThisDeviceWallet(address eSIMWallet, address eSIMWalletOwner)
```

### OnlyRegistryOrDeviceWalletFactoryOrOwner

```solidity
error OnlyRegistryOrDeviceWalletFactoryOrOwner()
```

### OnlySelfOrAssociatedESIMWallet

```solidity
error OnlySelfOrAssociatedESIMWallet()
```

### OnlyESIMWalletAdminOrRegistry

```solidity
error OnlyESIMWalletAdminOrRegistry()
```

### OnlyAssociatedESIMWallets

```solidity
error OnlyAssociatedESIMWallets()
```

### OnlyESIMWalletAdmin

```solidity
error OnlyESIMWalletAdmin()
```

