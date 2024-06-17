# Solidity API

## OnlyRegistryOrDeviceWalletFactoryOrOwner

```solidity
error OnlyRegistryOrDeviceWalletFactoryOrOwner()
```

## OnlyDeviceWalletOrOwner

```solidity
error OnlyDeviceWalletOrOwner()
```

## OnlyESIMWalletAdmin

```solidity
error OnlyESIMWalletAdmin()
```

## OnlyESIMWalletAdminOrDeviceWalletOwner

```solidity
error OnlyESIMWalletAdminOrDeviceWalletOwner()
```

## OnlyESIMWalletAdminOrDeviceWalletFactory

```solidity
error OnlyESIMWalletAdminOrDeviceWalletFactory()
```

## OnlyAssociatedESIMWallets

```solidity
error OnlyAssociatedESIMWallets()
```

## FailedToTransfer

```solidity
error FailedToTransfer()
```

## DeviceWallet

### ETHPaidForDataBundle

```solidity
event ETHPaidForDataBundle(address _vault, address _eSIMWallet, uint256 _amount)
```

Emitted when the contract pays ETH for data bundle

### ETHAccessUpdated

```solidity
event ETHAccessUpdated(address _eSIMWalletAddress, bool _hasAccessToETH)
```

Emitted when ower updates ETH access to a particular eSIM wallet

### ETHSent

```solidity
event ETHSent(address _eSIMWalletAddress, uint256 _amount)
```

Emitted when ETH is sent out from the contract

_mostly when an eSIM wallet pulls ETH from this contract_

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, bool _hasAccessToETH)
```

Emitted when eSIM wallet is deployed

### registry

```solidity
contract Registry registry
```

Registry contract instance

### deviceUniqueIdentifier

```solidity
string deviceUniqueIdentifier
```

String identifier to uniquely identify user's device

### uniqueIdentifierToESIMWallet

```solidity
mapping(string => address) uniqueIdentifierToESIMWallet
```

Mapping from eSIMUniqueIdentifier to the respective eSIM wallet address

### isValidESIMWallet

```solidity
mapping(address => bool) isValidESIMWallet
```

Set to true if the eSIM wallet belongs to this device wallet

### canPullETH

```solidity
mapping(address => bool) canPullETH
```

Mapping that tracks if an associated eSIM wallet can pull ETH or not

### onlyRegistryOrDeviceWalletFactoryOrOwner

```solidity
modifier onlyRegistryOrDeviceWalletFactoryOrOwner()
```

### onlyDeviceWalletFactoryOrOwner

```solidity
modifier onlyDeviceWalletFactoryOrOwner()
```

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
```

### onlyAssociatedESIMWallets

```solidity
modifier onlyAssociatedESIMWallets()
```

### constructor

```solidity
constructor() public
```

### initialize

```solidity
function initialize(address _registry, address _deviceWalletOwner, string _deviceUniqueIdentifier) external
```

Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs

### deployESIMWallet

```solidity
function deployESIMWallet(bool _hasAccessToETH) external returns (address)
```

Allow device wallet owner to deploy new eSIM wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _hasAccessToETH | bool | Set to true if the eSIM wallet is allowed to pull ETH from this wallet. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | eSIM wallet address |

### setESIMUniqueIdentifierForAnESIMWallet

```solidity
function setESIMUniqueIdentifierForAnESIMWallet(address _eSIMWalletAddress, string _eSIMUniqueIdentifier) public returns (string)
```

Allow wallet owner or admin to set unique identifier for their eSIM wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet smart contract |
| _eSIMUniqueIdentifier | string | String unique identifier for the eSIM wallet |

### payETHForDataBundles

```solidity
function payETHForDataBundles(uint256 _amount) external returns (uint256)
```

Allow the eSIM wallets associated with this device wallet to pay ETH for data bundles

_Instead of pulling the ETH into the eSIM wallet and then sending to the vault,
     the eSIM wallet can directly request the device wallet to pay ETH for the data bundles_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _amount | uint256 | Amount of ETH to pull |

### pullETH

```solidity
function pullETH(uint256 _amount) external returns (uint256)
```

Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _amount | uint256 | Amount of ETH to pull |

### getVaultAddress

```solidity
function getVaultAddress() public view returns (address)
```

Fetches the vault address (that receives payment for data bundles) from the device wallet factory

_Mostly used by the associated eSIM wallets for reference_

### toggleAccessToETH

```solidity
function toggleAccessToETH(address _eSIMWalletAddress, bool _hasAccessToETH) external
```

Allow owner to revoke or give access to any associated eSIM wallet for pulling ETH

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to toggle ETH access for |
| _hasAccessToETH | bool | Set to true to give access, false to revoke access |

### _transferETH

```solidity
function _transferETH(address _recipient, uint256 _amount) internal virtual
```

### updateESIMInfo

```solidity
function updateESIMInfo(address _eSIMWalletAddress, bool _isESIMWalletValid, bool _hasAccessToETH) external
```

### _updateESIMInfo

```solidity
function _updateESIMInfo(address _eSIMWalletAddress, bool _isESIMWalletValid, bool _hasAccessToETH) internal
```

### updateDeviceWalletAssociatedWithESIMWallet

```solidity
function updateDeviceWalletAssociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress) external
```

### _updateDeviceWalletAssociatedWithESIMWallet

```solidity
function _updateDeviceWalletAssociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress) internal
```

### receive

```solidity
receive() external payable
```

