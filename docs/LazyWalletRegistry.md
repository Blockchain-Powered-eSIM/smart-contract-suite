# Solidity API

## LazyWalletRegistry

Contract for deploying the factory contracts and maintaining registry

### DataUpdatedForDevice

```solidity
event DataUpdatedForDevice(string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, struct DataBundleDetails[] _dataBundleDetails)
```

Emitted when data related to a device is updated

### LazyWalletDeployed

```solidity
event LazyWalletDeployed(bytes32[2] _deviceOwnerPublicKey, address deviceWallet, string _deviceUniqueIdentifier, address[] eSIMWallets, string[] _eSIMUniqueIdentifiers)
```

### upgradeManager

```solidity
address upgradeManager
```

Address (owned/controlled by eSIM wallet project) that can upgrade contracts

### registry

```solidity
contract Registry registry
```

Registry contract instance

### deviceIdentifierToESIMDetails

```solidity
mapping(string => mapping(string => struct DataBundleDetails[])) deviceIdentifierToESIMDetails
```

Device identifier <> eSIM identifier <> DataBundleDetails[](list of purchase history)

### eSIMIdentifierToDeviceIdentifier

```solidity
mapping(string => string) eSIMIdentifierToDeviceIdentifier
```

Mapping from eSIM unique identifier to device unique identifier

_A device identifier can have multiple associated eSIM identifiers.
But an eSIM identifier can have only a single device identifier._

### eSIMIdentifiersAssociatedWithDeviceIdentifier

```solidity
mapping(string => string[]) eSIMIdentifiersAssociatedWithDeviceIdentifier
```

Device identifier <> List of associated eSIM identifiers

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
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
function initialize(address _registry, address _upgradeManager) external
```

### isLazyWalletDeployed

```solidity
function isLazyWalletDeployed(string _deviceUniqueIdentifier) public view returns (bool)
```

Function to check if a lazy wallet has been deployed or not

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Boolean. True if deployed, false otherwise |

### batchPopulateHistory

```solidity
function batchPopulateHistory(string[] _deviceUniqueIdentifiers, string[][] _eSIMUniqueIdentifiers, struct DataBundleDetails[][] _dataBundleDetails) external
```

Function to populate all the device and eSIM related data along with the data bundles

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | List of device unique identifiers associated with the eSIM related data |
| _eSIMUniqueIdentifiers | string[][] | 2D array of all the eSIMs corresponding to their device identifiers. |
| _dataBundleDetails | struct DataBundleDetails[][] | 2D array of all the new data bundles bought for the respective eSIMs |

### deployLazyWalletAndSetESIMIdentifier

```solidity
function deployLazyWalletAndSetESIMIdentifier(bytes32[2] _deviceOwnerPublicKey, string _deviceUniqueIdentifier, uint256 _salt) external returns (address, address[])
```

Function to deploy a device wallet and eSIM wallets on behalf of a user, also setting the eSIM identifiers

__salt should never be near to max value of uint256, if it is, the function call fails_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceOwnerPublicKey | bytes32[2] | P256 public key of the device owner |
| _deviceUniqueIdentifier | string | Unique device identifier associated with the device |
| _salt | uint256 |  |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Return device wallet address and list of eSIM wallet addresses |
| [1] | address[] |  |

### _populateHistory

```solidity
function _populateHistory(string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, struct DataBundleDetails[] _dataBundleDetails) internal
```

Internal function for populating information of all the eSIMs related to a device

_The _eSIMUniqueIdentifiers array can have multiple repeating occurrences since there can be multiple purchases per eSIM_

