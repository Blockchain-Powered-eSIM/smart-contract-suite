# Solidity API

## RegistryHelper

### WalletDeployed

```solidity
event WalletDeployed(string _deviceUniqueIdentifier, address _deviceWallet, address _eSIMWallet)
```

### DeviceWalletInfoUpdated

```solidity
event DeviceWalletInfoUpdated(address _deviceWallet, string _deviceUniqueIdentifier, address _deviceWalletOwner)
```

### UpdatedDeviceWalletassociatedWithESIMWallet

```solidity
event UpdatedDeviceWalletassociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress)
```

### ownerToDeviceWallet

```solidity
mapping(address => address) ownerToDeviceWallet
```

owner <> device wallet address

_There can only be one device wallet per user (ETH address)_

### uniqueIdentifierToDeviceWallet

```solidity
mapping(string => address) uniqueIdentifierToDeviceWallet
```

device unique identifier <> device wallet address
        Mapping for all the device wallets deployed by the registry

_Use this to check if a device identifier has already been used or not_

### isDeviceWalletValid

```solidity
mapping(address => address) isDeviceWalletValid
```

device wallet address <> owner.
        Mapping of all the devce wallets deployed by the registry (or the device wallet factory)
        to their respecitve owner.
        Mapping returns address(0) if device wallet doesn't exist or if not deployed by the said contracts

### isESIMWalletValid

```solidity
mapping(address => address) isESIMWalletValid
```

eSIM wallet address <> device wallet address
        All the eSIM wallets deployed using this registry are valid and set to true

### _updateDeviceWalletInfo

```solidity
function _updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, address _deviceWalletOwner) internal
```

### _updateESIMInfo

```solidity
function _updateESIMInfo(address _eSIMWalletAddress, address _deviceWalletAddress) internal
```

