# Solidity API

## OnlyDeviceWallet

```solidity
error OnlyDeviceWallet()
```

## OnlyRegistry

```solidity
error OnlyRegistry()
```

## FailedToTransfer

```solidity
error FailedToTransfer()
```

## ESIMWallet

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, address _deviceWalletAddress, address _owner)
```

Emitted when the eSIM wallet is deployed

### DataBundleBought

```solidity
event DataBundleBought(string _dataBundleID, uint256 _dataBundlePrice, uint256 _ethFromUser)
```

Emitted when the payment for a data bundle is made

### ESIMUniqueIdentifierInitialised

```solidity
event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier)
```

Emitted when the eSIM unique identifier is initialised

### TransactionHistoryPopulated

```solidity
event TransactionHistoryPopulated(struct DataBundleDetails[] _dataBundleDetails)
```

Emitted when the lazy wallet registry populates history after wallet deployment

### ETHSent

```solidity
event ETHSent(address _recipient, uint256 _amount)
```

Emitted when ETH moves out of this contract

### eSIMWalletFactory

```solidity
address eSIMWalletFactory
```

Address of the eSIM wallet factory contract

### eSIMUniqueIdentifier

```solidity
string eSIMUniqueIdentifier
```

String identifier to uniquely identify eSIM wallet

### deviceWallet

```solidity
contract DeviceWallet deviceWallet
```

Device wallet contract instance associated with this eSIM wallet

### transactionHistory

```solidity
struct DataBundleDetails[] transactionHistory
```

Array of all the data bundle purchase

### _isTransferApproved

```solidity
mapping(address => mapping(address => bool)) _isTransferApproved
```

_A map from owner and spender to transfer approval. Determines whether
     the spender can transfer this wallet from the owner._

### onlyDeviceWallet

```solidity
modifier onlyDeviceWallet()
```

### onlyRegistry

```solidity
modifier onlyRegistry()
```

### constructor

```solidity
constructor() public
```

### initialize

```solidity
function initialize(address _eSIMWalletFactoryAddress, address _deviceWalletAddress) external
```

ESIMWallet initialize function to initialise the contract

_If _eSIMUniqueIdentifier is empty, the eSIM wallet is being deployed before buying an eSIM
     If _eSIMUniqueIdentifier is non-empty, the eSIM wallet is being deployed after the eSIM has been bought by the user_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletFactoryAddress | address | eSIM wallet factory contract address |
| _deviceWalletAddress | address | Device wallet contract address (the contract that deploys this eSIM wallet) |

### setESIMUniqueIdentifier

```solidity
function setESIMUniqueIdentifier(string _eSIMUniqueIdentifier) external
```

Since buying the eSIM (along with data bundle) happens before the identifier is generated,
        the identifier is to be set separately after the wallet is deployed and eSIM is created

_This function can only be called once_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMUniqueIdentifier | string | String that uniquely identifies eSIM wallet |

### buyDataBundle

```solidity
function buyDataBundle(struct DataBundleDetails _dataBundleDetail) public payable returns (bool)
```

Function to make payment for the data bundle

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetail | struct DataBundleDetails | Details of the data bundle being bought. (dataBundleID, dataBundlePrice) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if the transaction is successful |

### populateHistory

```solidity
function populateHistory(struct DataBundleDetails[] _dataBundleDetails) external returns (bool)
```

Function to populate history for lazy wallets. Can only be called once, by lazy wallet registry

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetails | struct DataBundleDetails[] | Array of all the data bundle purchase details before the wallet was deployed |

### owner

```solidity
function owner() public view returns (address)
```

_Returns the current owner of the wallet_

### transferOwnership

```solidity
function transferOwnership(address newOwner) public
```

_Transfers ownership from the current owner to another address_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | address | The address that will be the new owner |

### isTransferApproved

```solidity
function isTransferApproved(address from, address to) public view returns (bool)
```

The owner can always transfer the wallet to someone, i.e.,
        approval from an address to itself is always 'true'

_Returns whether the address 'to' can transfer a wallet from address 'from'_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | The owner address |
| to | address | The spender address |

### setApproval

```solidity
function setApproval(address to, bool status) external
```

_Changes authorization status for transfer approval from msg.sender to an address_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address to change allowance status for |
| status | bool | The new approval status |

### _setApproval

```solidity
function _setApproval(address from, address to, bool status) internal
```

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | The owner address |
| to | address | The spender address |
| status | bool | Status of approval |

### _transferETH

```solidity
function _transferETH(address _recipient, uint256 _amount) internal virtual
```

_Internal function to send ETH from this contract_

### receive

```solidity
receive() external payable
```

