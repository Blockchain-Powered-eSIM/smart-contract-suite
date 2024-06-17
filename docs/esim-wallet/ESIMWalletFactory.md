# Solidity API

## OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet

```solidity
error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet()
```

## ESIMWalletFactory

Contract for deploying a new eSIM wallet

### ESIMWalletFactorydeployed

```solidity
event ESIMWalletFactorydeployed(address _upgradeManager, address _eSIMWalletImplementation, address beacon)
```

Emitted when the eSIM wallet factory is deployed

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, address _owner, address _deviceWalletAddress)
```

Emitted when a new eSIM wallet is deployed

### registry

```solidity
contract Registry registry
```

Address of the registry contract

### eSIMWalletImplementation

```solidity
address eSIMWalletImplementation
```

Implementation at the time of deployment

### beacon

```solidity
address beacon
```

Beacon referenced by each deployment of a savETH vault

### isESIMWalletDeployed

```solidity
mapping(address => bool) isESIMWalletDeployed
```

Set to true if eSIM wallet address is deployed using the factory, false otherwise

### onlyRegistryOrDeviceWalletFactoryOrDeviceWallet

```solidity
modifier onlyRegistryOrDeviceWalletFactoryOrDeviceWallet()
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
function initialize(address _registryContractAddress, address _upgradeManager) external
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registryContractAddress | address | Address of the registry contract |
| _upgradeManager | address | Admin address responsible for upgrading contracts |

### deployESIMWallet

```solidity
function deployESIMWallet(address _owner) external returns (address)
```

Function to deploy an eSIM wallet

_can only be called by the respective deviceWallet contract_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _owner | address | Owner of the eSIM wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the newly deployed eSIM wallet |

