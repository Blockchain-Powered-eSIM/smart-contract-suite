# Solidity API

## OnlyDeviceWallet

```solidity
error OnlyDeviceWallet()
```

## OnlyDeviceWalletFactory

```solidity
error OnlyDeviceWalletFactory()
```

## Registry

Contract for deploying the factory contracts and maintaining registry

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

Entry point contract address (one entryPoint per chain)

### admin

```solidity
address admin
```

eSIM wallet project admin address

### vault

```solidity
address vault
```

Address of the vault that receives payments for the eSIM data bundles

### upgradeManager

```solidity
address upgradeManager
```

Address (owned/controlled by eSIM wallet project) that can upgrade contracts

### onlyDeviceWallet

```solidity
modifier onlyDeviceWallet()
```

### onlyDeviceWalletFactory

```solidity
modifier onlyDeviceWalletFactory()
```

### constructor

```solidity
constructor(contract IEntryPoint _entryPoint) public
```

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

_Owner based upgrades_

### initialize

```solidity
function initialize(address _eSIMWalletAdmin, address _vault, address _upgradeManager, contract P256Verifier _verifier) external
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAdmin | address | Admin address of the eSIM wallet project |
| _vault | address | Address of the vault that receives payments for the data bundles |
| _upgradeManager | address | Admin address responsible for upgrading contracts |
| _verifier | contract P256Verifier |  |

### addOrUpdateLazyWalletRegistryAddress

```solidity
function addOrUpdateLazyWalletRegistryAddress(address _lazyWalletRegistry) public returns (address)
```

Function to add or update the lazy wallet registry address

### deployWallet

```solidity
function deployWallet(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) external returns (address, address)
```

Allow anyone to deploy a device wallet and an eSIM wallet for themselves

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier associated with the device |
| _deviceWalletOwnerKey | bytes32[2] |  |
| _salt | uint256 |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Return device wallet address and eSIM wallet address |
| [1] | address |  |

### updateDeviceWalletAssociatedWithESIMWallet

```solidity
function updateDeviceWalletAssociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress) external
```

### updateDeviceWalletInfo

```solidity
function updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) external
```

_For all the device wallets deployed by the esim wallet admin using the device wallet factory,
     update the mappings_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Address of the device wallet |
| _deviceUniqueIdentifier | string | String unique identifier associated with the device wallet |
| _deviceWalletOwnerKey | bytes32[2] |  |

