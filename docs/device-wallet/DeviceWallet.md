# Solidity API

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

### eSIMWalletFactory

```solidity
contract ESIMWalletFactory eSIMWalletFactory
```

ESIM wallet factory contract instance

### deviceWalletFactory

```solidity
contract DeviceWalletFactory deviceWalletFactory
```

Device wallet factory contract instance

### deviceUniqueIdentifier

```solidity
string deviceUniqueIdentifier
```

String identifier to uniquely identify user's device

### eSIMUniqueIdentifierToESIMWalletAddress

```solidity
mapping(string => address) eSIMUniqueIdentifierToESIMWalletAddress
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

### InitParams

Parameters required to deploy Device Wallet

_Used to solve stack too deep error_

```solidity
struct InitParams {
  address _deviceWalletFactoryAddress;
  address _eSIMWalletFactoryAddress;
  address _deviceWalletOwner;
  string _deviceUniqueIdentifier;
  string[] _dataBundleIDs;
  uint256[] _dataBundlePrices;
  string[] _eSIMUniqueIdentifiers;
}
```

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
```

### onlyESIMWalletAdminOrDeviceWalletFactory

```solidity
modifier onlyESIMWalletAdminOrDeviceWalletFactory()
```

### onlyESIMWalletAdminOrDeviceWalletOwner

```solidity
modifier onlyESIMWalletAdminOrDeviceWalletOwner()
```

### onlyAssociatedESIMWallets

```solidity
modifier onlyAssociatedESIMWallets()
```

### constructor

```solidity
constructor() public
```

### init

```solidity
function init(struct DeviceWallet.InitParams _initParams) external payable
```

Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs

### deployESIMWallet

```solidity
function deployESIMWallet(string _dataBundleID, uint256 _dataBundlePrice, string _eSIMUniqueIdentifier, bool _hasAccessToETH) external payable returns (address)
```

Allow device wallet owner to deploy new eSIM wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleID | string | String data bundle ID to be bought for the eSIM |
| _dataBundlePrice | uint256 | Price in uint256 for the data bundle |
| _eSIMUniqueIdentifier | string | String unique identifier for the eSIM wallet |
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

### receive

```solidity
receive() external payable
```

