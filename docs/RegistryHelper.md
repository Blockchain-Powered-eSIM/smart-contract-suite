# Solidity API

## OnlyLazyWalletRegistry

```solidity
error OnlyLazyWalletRegistry()
```

## RegistryHelper

### WalletDeployed

```solidity
event WalletDeployed(string _deviceUniqueIdentifier, address _deviceWallet, address _eSIMWallet)
```

### DeviceWalletInfoUpdated

```solidity
event DeviceWalletInfoUpdated(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey)
```

### UpdatedDeviceWalletassociatedWithESIMWallet

```solidity
event UpdatedDeviceWalletassociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress)
```

### UpdatedLazyWalletRegistryAddress

```solidity
event UpdatedLazyWalletRegistryAddress(address _lazyWalletRegistry)
```

### lazyWalletRegistry

```solidity
address lazyWalletRegistry
```

Address of the Lazy wallet registry

### deviceWalletFactory

```solidity
contract DeviceWalletFactory deviceWalletFactory
```

Device wallet factory instance

### eSIMWalletFactory

```solidity
contract ESIMWalletFactory eSIMWalletFactory
```

eSIM wallet factory instance

### uniqueIdentifierToDeviceWallet

```solidity
mapping(string => address) uniqueIdentifierToDeviceWallet
```

device unique identifier <> device wallet address
        Mapping for all the device wallets deployed by the registry

_Use this to check if a device identifier has already been used or not_

### deviceWalletToOwner

```solidity
mapping(address => bytes32[2]) deviceWalletToOwner
```

device wallet address <> owner P256 public key.

### isDeviceWalletValid

```solidity
mapping(address => bool) isDeviceWalletValid
```

device wallet address <> boolean (true if deployed by the registry or device wallet factory)
        Mapping of all the device wallets deployed by the registry (or the device wallet factory)
        to their respective owner.

### isESIMWalletValid

```solidity
mapping(address => address) isESIMWalletValid
```

eSIM wallet address <> device wallet address
        All the eSIM wallets deployed using this registry are valid and set to true

### onlyLazyWalletRegistry

```solidity
modifier onlyLazyWalletRegistry()
```

### deployLazyWallet

```solidity
function deployLazyWallet(bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt, string[] _eSIMUniqueIdentifiers, struct DataBundleDetails[][] _dataBundleDetails) external returns (address, address[])
```

Allow LazyWalletRegistry to deploy a device wallet and an eSIM wallet on behalf of a user

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletOwnerKey | bytes32[2] | P256 public key of user |
| _deviceUniqueIdentifier | string | Unique device identifier associated with the device |
| _salt | uint256 |  |
| _eSIMUniqueIdentifiers | string[] |  |
| _dataBundleDetails | struct DataBundleDetails[][] |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Return device wallet address and list of addresses of all the eSIM wallets |
| [1] | address[] |  |

### _updateDeviceWalletInfo

```solidity
function _updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) internal
```

### _updateESIMInfo

```solidity
function _updateESIMInfo(address _eSIMWalletAddress, address _deviceWalletAddress) internal
```

