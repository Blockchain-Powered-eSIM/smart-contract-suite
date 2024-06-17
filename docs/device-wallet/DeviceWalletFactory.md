# Solidity API

## OnlyAdmin

```solidity
error OnlyAdmin()
```

## DeviceWalletFactory

Contract for deploying a new eSIM wallet

### DeviceWalletFactoryDeployed

```solidity
event DeviceWalletFactoryDeployed(address _admin, address _vault, address _upgradeManager, address _deviceWalletImplementation, address _beacon)
```

Emitted when factory is deployed and admin is set

### VaultAddressUpdated

```solidity
event VaultAddressUpdated(address _updatedVaultAddress)
```

Emitted when the Vault address is updated

### DeviceWalletDeployed

```solidity
event DeviceWalletDeployed(address _deviceWalletAddress, address _eSIMWalletAddress, address _deviceWalletOwner)
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

### registry

```solidity
contract Registry registry
```

Registry contract instance

### onlyAdmin

```solidity
modifier onlyAdmin()
```

### constructor

```solidity
constructor() public
```

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

_Owner based upgrades_

### initialize

```solidity
function initialize(address _registryContractAddress, address _eSIMWalletAdmin, address _vault, address _upgradeManager) external
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registryContractAddress | address |  |
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

### deployDeviceWalletForUsers

```solidity
function deployDeviceWalletForUsers(string[] _deviceUniqueIdentifiers, address[] _deviceWalletOwners) public returns (address[])
```

To deploy multiple device wallets at once

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | Array of unique device identifiers for each device wallet |
| _deviceWalletOwners | address[] | Array of owner address of the respective device wallets |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] | Array of deployed device wallet address |

### deployDeviceWalletAsAdmin

```solidity
function deployDeviceWalletAsAdmin(string _deviceUniqueIdentifier, address _deviceWalletOwner) public returns (address)
```

_Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwner | address | User's address (owner of the device wallet and respective eSIM wallets) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Deployed device wallet address |

### deployDeviceWallet

```solidity
function deployDeviceWallet(string _deviceUniqueIdentifier, address _deviceWalletOwner) public returns (address)
```

_Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwner | address | User's address (owner of the device wallet and respective eSIM wallets) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Deployed device wallet address |

