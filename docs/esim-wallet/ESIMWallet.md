# Solidity API

## ESIMWallet

One eSIM, its purchase history and the ETH that pays for its data bundles

_A beacon proxy deployed by `ESIMWalletFactory`, always owned by a device wallet. The owner
     is a contract rather than a key, so every call that moves ETH or ownership arrives through
     a device wallet `execute` and has already been signed for. The admin can charge this wallet
     for a data bundle but cannot raise the ceiling that limits what it may charge._

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

### newRequestedOwner

```solidity
address newRequestedOwner
```

Address of the owner (device wallet) that becomes the new owner

### dataBundlePriceCap

```solidity
uint256 dataBundlePriceCap
```

Most this wallet may be charged for one data bundle, or zero to follow the registry

_Appended, and this contract is a leaf, so the slot lands past everything a live proxy
     already holds and reads zero there. Zero has to keep meaning "no limit of my own" for
     that reason, which is why the fallback lives on the registry rather than here._

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
event TransactionHistoryPopulated(struct DataBundleDetails[] _dataBundleDetails, uint256 _totalEntries)
```

Emitted for every batch of history the lazy wallet registry copies in after deployment.
        `_totalEntries` is the transaction history length once the batch has landed, which is
        what tells a partial copy apart from a finished one.

### ETHSent

```solidity
event ETHSent(address _recipient, uint256 _amount)
```

Emitted when ETH moves out of this contract

### OwnershipTransferRequested

```solidity
event OwnershipTransferRequested(address _currentOwner, address _newOwner)
```

Emitted when the current owner wants to transfer the ownership to a new device wallet

### OwnershipTransferRevoked

```solidity
event OwnershipTransferRevoked(address _currentOwner, address _revokedOwner)
```

Emitted when the current owner revoked the ownership transfer request

### DataBundlePriceCapUpdated

```solidity
event DataBundlePriceCapUpdated(uint256 _cap)
```

Emitted when the owner sets this wallet's own price ceiling

### onlyDeviceWallet

```solidity
modifier onlyDeviceWallet()
```

Restricts a call to the device wallet that owns this eSIM wallet

_Reaching this means the owner signed for it, since a device wallet only calls out
     through `execute`._

### onlyRegistry

```solidity
modifier onlyRegistry()
```

Restricts a call to the registry

### onlyDeviceWalletOrESIMWalletAdmin

```solidity
modifier onlyDeviceWalletOrESIMWalletAdmin()
```

Restricts a call to the owning device wallet or the eSIM wallet admin

### constructor

```solidity
constructor() public
```

_`_disableInitializers` rather than an `initializer` modifier. The modifier leaves the
     version at 1, which a later `reinitializer(2)` would still accept on the implementation
     itself. This pins it at the maximum so no version can ever run there._

### initialize

```solidity
function initialize(address _eSIMWalletFactoryAddress, address _deviceWalletAddress) external
```

Binds a freshly deployed eSIM wallet to its factory and its owning device wallet

_The eSIM identifier is not set here. It does not exist until the eSIM itself has been
     bought, so it arrives later through `setESIMUniqueIdentifier`._

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

### setDataBundlePriceCap

```solidity
function setDataBundlePriceCap(uint256 _cap) external
```

Sets the most this wallet may be charged for one data bundle

_Only the owning device wallet, which means the person holding its P256 key: reaching
     this needs a device wallet `execute`, and that needs a signature. The admin names the
     price on `buyDataBundle`, so it must not also be able to raise the ceiling on that
     price. Setting zero hands the wallet back to the registry's ceiling._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _cap | uint256 | Maximum price in wei, or zero to follow the registry |

### populateHistory

```solidity
function populateHistory(struct DataBundleDetails[] _dataBundleDetails) external returns (bool)
```

Appends pre-deployment purchase history, one batch at a time, on behalf of the lazy
        wallet registry

_The registry carries the cursor that says how much of an eSIM's history has already been
     copied, so this function appends whatever it is handed and does not police repeats._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetails | struct DataBundleDetails[] | One batch of data bundle purchase details from before the wallet        was deployed |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True once the batch has been appended |

### requestTransferOwnership

```solidity
function requestTransferOwnership(address _newOwner) external
```

Nominates a new device wallet to take this eSIM wallet over, in two steps

_Any outstanding request is overwritten rather than refused, so an owner who nominated
     the wrong address just calls this again. Nominating the current owner cancels the
     request and re-binds the wallet to its device wallet in the same call, with ETH access
     left off since the flag it had before the removal is not recorded anywhere._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newOwner | address | Address of the new device wallet to transfer ownership of this wallet |

### acceptOwnershipTransfer

```solidity
function acceptOwnershipTransfer() external
```

Takes this eSIM wallet on, callable only by the nominated device wallet

_The check compares the caller to `newRequestedOwner`, which both sides satisfy when
     they are zero. No transaction can arrive from the zero address, so this holds onchain,
     but any reasoning about this function has to exclude that caller explicitly._

### sendETHToDeviceWallet

```solidity
function sendETHToDeviceWallet(uint256 _amount) external returns (uint256)
```

Allow the owner device wallet to callback all the ETH from this eSIM wallet

_This function is generally called before the owner device wallet removes this eSIM wallet
Deliberately not nonReentrant. removeESIMWallet calls this from inside a try/catch while
     requestTransferOwnership already holds this contract's guard, so guarding here would
     make the callback revert into that catch and strand the wallet's ETH with no error.
     It writes no state of its own, and only the owner can call it to move ETH to itself,
     so re-entering it gains nothing._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _amount | uint256 | Amount of ETH to be sent |

### buyDataBundle

```solidity
function buyDataBundle(struct DataBundleDetails _dataBundleDetail) public payable returns (bool)
```

Pays the vault for one data bundle and records the purchase

_Callable by the owning device wallet or by the admin, since the admin is the party that
     knows the price. Any shortfall is pulled from the device wallet, which is why the price
     is checked against a ceiling the admin cannot raise._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetail | struct DataBundleDetails | Details of the data bundle being bought. (dataBundleID, dataBundlePrice) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if the transaction is successful |

### transferOwnership

```solidity
function transferOwnership(address) public pure
```

The inherited one-step transfer is closed

_Ownership moves through `requestTransferOwnership` and `acceptOwnershipTransfer`, which
     also keep `deviceWallet` in step with `owner()`. A one-step transfer would move only
     the latter._

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

An eSIM wallet always belongs to a device wallet, so ownership is never renounced

_Renouncing leaves owner() at zero while deviceWallet still points at the old device
     wallet. sendETHToDeviceWallet then reverts on its own zero-owner check and
     DeviceWallet._addESIMWallet can never accept this wallet again, so the ETH held here
     is unreachable for the rest of the wallet's life._

### _secureTransferOwnership

```solidity
function _secureTransferOwnership() internal
```

Completes a handover, moving `deviceWallet` and `owner()` together

_Clears the request before it writes anything, so a second acceptance finds nothing._

### _transferETH

```solidity
function _transferETH(address _recipient, uint256 _amount) internal virtual
```

Sends ETH out of this contract, reverting if the call fails

_A zero amount is a no-op rather than a revert, so callers that may have nothing to send
     do not need their own guard._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _recipient | address | Address receiving the ETH |
| _amount | uint256 | Amount in wei |

### owner

```solidity
function owner() public view returns (address)
```

The device wallet that owns this eSIM wallet

_Declared so subclasses and mocks have one place to override._

### receive

```solidity
receive() external payable
```

Accepts plain ETH transfers, which is how the device wallet tops this wallet up

