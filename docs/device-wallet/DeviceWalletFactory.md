# Solidity API

## OnlyAdmin

```solidity
error OnlyAdmin()
```

## DeviceWalletFactory

Contract for deploying a new eSIM wallet

### SetESIMWalletFactoryAddress

```solidity
event SetESIMWalletFactoryAddress(address _eSIMWalletFactoryAddress)
```

Emitted when the admin sets the eSIM wallet factory address

### DeviceWalletFactoryDeployed

```solidity
event DeviceWalletFactoryDeployed(address _factoryAddress, address _admin, address _vault, address _upgradeManager, address _deviceWalletImplementation, address _beacon)
```

Emitted when factory is deployed and admin is set

### VaultAddressUpdated

```solidity
event VaultAddressUpdated(address _updatedVaultAddress)
```

Emitted when the Vault address is updated

### DeviceWalletDeployed

```solidity
event DeviceWalletDeployed(address _deviceWalletAddress, string[] _eSIMUniqueIdentifiers)
```

Emitted when a new device wallet is deployed

### AdminUpdated

```solidity
event AdminUpdated(address _newAdmin)
```

Emitted when the admin address is updated

### eSIMWalletAdmin

```solidity
address eSIMWalletAdmin
```

Admin address of the eSIM wallet project

### vault

```solidity
address vault
```

Vault address that receives payments for eSIM data bundles

### deviceWalletImplementation

```solidity
address deviceWalletImplementation
```

Implementation (logic) contract address of the device wallet

### beacon

```solidity
address beacon
```

Beacon contract address for this contract

### eSIMWalletFactoryAddress

```solidity
address eSIMWalletFactoryAddress
```

eSIM wallet factory contract address;

### walletAddressOfDeviceUniqueIdentifier

```solidity
mapping(string => address) walletAddressOfDeviceUniqueIdentifier
```

deviceUniqueIdentifier <> deviceWalletAddress

### isDeviceWalletValid

```solidity
mapping(address => bool) isDeviceWalletValid
```

Set to true if device wallet was deployed by the device wallet factory, false otherwise.

### onlyAdmin

```solidity
modifier onlyAdmin()
```

### constructor

```solidity
constructor(address _eSIMWalletAdmin, address _vault, address _upgradeManager) public
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAdmin | address | Admin address of the eSIM wallet project |
| _vault | address | Address of the vault that receives payments for the data bundles |
| _upgradeManager | address | Admin address responsible for upgrading contracts |

### updateVaultAddress

```solidity
function updateVaultAddress(address _newVaultAddress) public returns (address)
```

Function to update vault address.

_Can only be called by the admin_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newVaultAddress | address | New vault address |

### updateAdmin

```solidity
function updateAdmin(address _newAdmin) public returns (address)
```

Function to update admin address

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newAdmin | address | New admin address |

### setESIMWalletFactoryAddress

```solidity
function setESIMWalletFactoryAddress(address _eSIMWalletFactoryAddress) public returns (address)
```

### deployMultipleDeviceWalletsWithESIMWallets

```solidity
function deployMultipleDeviceWalletsWithESIMWallets(string[] _deviceUniqueIdentifiers, string[][] _dataBundleIDs, uint256[][] _dataBundlePrices, string[][] _eSIMUniqueIdentifiers) public payable returns (address[])
```

To deploy multiple device wallets at once

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | Array of unique device identifiers for each device wallet |
| _dataBundleIDs | string[][] | 2D array of IDs of data bundles to be bought for respective eSIMs |
| _dataBundlePrices | uint256[][] | 2D array of price of respective data bundles for respective eSIMs |
| _eSIMUniqueIdentifiers | string[][] | 2D array of unique eSIM identifiers for each device wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] | Array of deployed device wallet address |

### deployDeviceWalletWithESIMWallets

```solidity
function deployDeviceWalletWithESIMWallets(string _deviceUniqueIdentifier, string[] _dataBundleIDs, uint256[] _dataBundlePrices, string[] _eSIMUniqueIdentifiers, address _deviceWalletOwner) public payable returns (address)
```

_To deploy a device wallet and eSIM wallets for given unique eSIM identifiers_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _dataBundleIDs | string[] | List of IDs of data bundles to be bought for respective eSIMs |
| _dataBundlePrices | uint256[] | List of price of respective data bundles |
| _eSIMUniqueIdentifiers | string[] | Array of unique eSIM identifiers for the device wallet |
| _deviceWalletOwner | address | User's address (owner of the device wallet and respective eSIM wallets) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Deployed device wallet address |

