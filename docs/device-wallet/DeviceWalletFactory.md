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
event DeviceWalletDeployed(address _deviceWalletAddress, address _eSIMWalletAddress, bytes32[2] _deviceWalletOwnerKey)
```

Emitted when a new device wallet is deployed

### AdminUpdated

```solidity
event AdminUpdated(address _newAdmin)
```

Emitted when the admin address is updated

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

### verifier

```solidity
contract P256Verifier verifier
```

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
contract DeviceWallet deviceWalletImplementation
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
constructor(contract IEntryPoint _entryPoint, contract P256Verifier _verifier) public
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
function deployDeviceWalletForUsers(string[] _deviceUniqueIdentifiers, bytes32[2][] _deviceWalletOwnersKey, uint256[] _salts) public returns (address[])
```

To deploy multiple device wallets at once

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | Array of unique device identifiers for each device wallet |
| _deviceWalletOwnersKey | bytes32[2][] | Array of P256 public keys of owners of the respective device wallets |
| _salts | uint256[] |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] | Array of deployed device wallet address |

### deployDeviceWalletAsAdmin

```solidity
function deployDeviceWalletAsAdmin(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) public returns (address)
```

_Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwnerKey | bytes32[2] | User's P256 public key (owner of the device wallet and respective eSIM wallets) |
| _salt | uint256 |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Deployed device wallet address |

### deployDeviceWallet

```solidity
function deployDeviceWallet(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) public returns (address)
```

_Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwnerKey | bytes32[2] | User's P256 public key (owner of the device wallet and respective eSIM wallets) |
| _salt | uint256 |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Deployed device wallet address |

### createAccount

```solidity
function createAccount(address _registry, bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt) public payable returns (contract DeviceWallet ret)
```

create an account, and return its address.
returns the address even if the account is already deployed.
Note that during UserOperation execution, this method is called only if the account is not deployed.
This method returns an existing account address so that entryPoint.getSenderAddress() would work even after account creation

### getCounterFactualAddress

```solidity
function getCounterFactualAddress(address _registry, bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt) public view returns (address)
```

calculate the counterfactual address of this account as it would be returned by createAccount()

