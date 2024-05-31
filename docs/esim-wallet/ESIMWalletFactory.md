# Solidity API

## OnlyDeviceWalletFactory

```solidity
error OnlyDeviceWalletFactory()
```

## ESIMWalletFactory

Contract for deploying a new eSIM wallet

### ESIMWalletFactorydeployed

```solidity
event ESIMWalletFactorydeployed(address _eSIMWalletFactory, address _deviceWalletFactory, address _upgradeManager, address _eSIMWalletImplementation, address beacon)
```

Emitted when the eSIM wallet factory is deployed

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, string _dataBundleID, uint256 _dataBundlePrice, address _deviceWalletAddress)
```

Emitted when a new eSIM wallet is deployed

### deviceWalletFactory

```solidity
contract DeviceWalletFactory deviceWalletFactory
```

Address of the device wallet factory

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

### onlyDeviceWalletFactory

```solidity
modifier onlyDeviceWalletFactory()
```

### constructor

```solidity
constructor(address _deviceWalletFactoryAddress, address _upgradeManager) public
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletFactoryAddress | address | Address of the device wallet factory address |
| _upgradeManager | address | Admin address responsible for upgrading contracts |

### deployESIMWallet

```solidity
function deployESIMWallet(address _owner, string _dataBundleID, uint256 _dataBundlePrice, string _eSIMUniqueIdentifier) external payable returns (address)
```

Function to deploy an eSIM wallet

_can only be called by the respective deviceWallet contract_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _owner | address | Owner of the eSIM wallet |
| _dataBundleID | string | String ID of data bundle to buy for the new eSIM |
| _dataBundlePrice | uint256 | uint256 USD price for data bundle |
| _eSIMUniqueIdentifier | string |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the newly deployed eSIM wallet |

