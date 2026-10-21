# Solidity API

## ESIMWallet

One eSIM, its purchase history, and the funds that move through it while it buys data bundles

Beacon proxy owned by a device wallet, so every owner call has been signed via `execute`.
     The admin can charge for data bundles but cannot raise the ceiling on those charges.

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

Every data bundle purchase recorded for this wallet

### newRequestedOwner

```solidity
address newRequestedOwner
```

Device wallet nominated to take this wallet over, or zero if none

### priceCapUSDCents

```solidity
uint64 priceCapUSDCents
```

Most this wallet may be charged for one data bundle, in USD cents, or zero to follow
        the registry

Shares a slot with `newRequestedOwner`, so do not move this line. A handover clears
     both in one write.

### adminAllowanceUSDCents

```solidity
uint64 adminAllowanceUSDCents
```

What the eSIM wallet admin may still charge this wallet in total, in USD cents

Starts at the registry default and resets to it on handover. Only admin charges spend
     it and only the owner sets it.

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, address _deviceWalletAddress, address _owner)
```

Emitted when the eSIM wallet is deployed

### DataBundleBoughtWithToken

```solidity
event DataBundleBoughtWithToken(bytes32 _dataBundleID, uint64 _priceUSDCents, bytes32 _asset, address _token, uint256 _amountSpent, bytes32 _paymentReference)
```

Emitted when a data bundle is paid for in USDC (or any other acceptable stablecoin/ERC20)

The adapter emits the settlement. This one is for an indexer watching one wallet.

### TokenSentToDeviceWallet

```solidity
event TokenSentToDeviceWallet(address _token, address _deviceWallet, uint256 _amount)
```

Emitted when an ERC-20 is returned to the owning device wallet

### DataBundleSettlementRecorded

```solidity
event DataBundleSettlementRecorded(bytes32 _dataBundleID, uint64 _priceUSDCents, enum Settlement _settlement)
```

Emitted when a purchase paid for outside the protocol is recorded here

The registry emits the full record. This one is for an indexer watching one wallet.

### ESIMUniqueIdentifierInitialised

```solidity
event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier)
```

Emitted when the eSIM unique identifier is initialised

### TransactionHistoryPopulated

```solidity
event TransactionHistoryPopulated(struct DataBundleDetails[] _dataBundleDetails, uint256 _totalEntries)
```

Emitted for each batch of history the lazy wallet registry copies in

`_totalEntries` is the history length after the batch, so a partial copy can be told apart.

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

### PriceCapUSDCentsUpdated

```solidity
event PriceCapUSDCentsUpdated(uint64 _cap)
```

Emitted when the owner sets this wallet's own price ceiling

### AdminAllowanceUSDCentsUpdated

```solidity
event AdminAllowanceUSDCentsUpdated(uint64 _allowance)
```

Emitted whenever what the admin may still charge changes: set, spent or reset

### onlyDeviceWallet

```solidity
modifier onlyDeviceWallet()
```

Restricts a call to the device wallet that owns this eSIM wallet

A device wallet only calls out through `execute`, so this means the owner signed.

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

Disables initializers on the implementation contract

Pins the version at max. An `initializer` modifier would leave it at 1, and a later
     `reinitializer(2)` could then still run on the implementation.

### initialize

```solidity
function initialize(address _eSIMWalletFactoryAddress, address _deviceWalletAddress) external
```

Binds a freshly deployed eSIM wallet to its factory and its owning device wallet

The eSIM identifier does not exist until the eSIM is bought, so it is set later through
     `setESIMUniqueIdentifier`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletFactoryAddress | address | eSIM wallet factory contract address |
| _deviceWalletAddress | address | Device wallet that owns this eSIM wallet |

### setESIMUniqueIdentifier

```solidity
function setESIMUniqueIdentifier(string _eSIMUniqueIdentifier) external
```

Sets the eSIM identifier once the eSIM exists, which is after this wallet is deployed

Set once, and only by the registry, which records the claim in the same call. Any
     other caller could write an identifier the registry has no record of.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMUniqueIdentifier | string | String that uniquely identifies eSIM wallet |

### setPriceCapUSDCents

```solidity
function setPriceCapUSDCents(uint64 _cap) external
```

Sets the most this wallet may be charged for one data bundle

Owner only: the admin names the price on a purchase, so it must not also set the
     ceiling. Zero follows the registry ceiling. A handover resets it to zero.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _cap | uint64 | Maximum price in USD cents, or zero to follow the registry |

### setAdminAllowanceUSDCents

```solidity
function setAdminAllowanceUSDCents(uint64 _allowance) external
```

Sets what the eSIM wallet admin may still charge this wallet in total

Owner only, since it limits the admin. Zero stops admin charges; the owner can still buy.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _allowance | uint64 | Total the admin may charge from now on, in USD cents |

### populateHistory

```solidity
function populateHistory(struct DataBundleDetails[] _dataBundleDetails) external returns (bool)
```

Appends pre-deployment purchase history, one batch at a time, on behalf of the lazy
        wallet registry

The registry tracks how much has been copied, so repeats are not checked here. Not held
     to the price ceiling: these are past payments, no charge happens, and refusing one
     would only drop true history.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetails | struct DataBundleDetails[] | One batch of purchases from before the wallet was deployed |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True once the batch has been appended |

### requestTransferOwnership

```solidity
function requestTransferOwnership(address _newOwner) external
```

Nominates a new device wallet to take this eSIM wallet over, in two steps

A pending request is overwritten, so a wrong nominee is fixed by calling again.
     Nominating the current owner cancels and re-binds, with fund access off since the old
     flag is not recorded. Only ETH is swept back; ERC-20s go to whoever accepts, so sweep
     them with `sendTokenToDeviceWallet` in the same `executeBatch`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newOwner | address | Address of the new device wallet to transfer ownership of this wallet |

### acceptOwnershipTransfer

```solidity
function acceptOwnershipTransfer() external
```

Takes this eSIM wallet on, callable only by the nominated device wallet

With no request pending this only passes for the zero address, which cannot send a
     transaction. Keep that in mind when reasoning about this check.

### sendETHToDeviceWallet

```solidity
function sendETHToDeviceWallet(uint256 _amount) external returns (uint256)
```

Sends ETH from this eSIM wallet back to the owning device wallet

Deliberately not nonReentrant. removeESIMWallet calls it in a try/catch while
     requestTransferOwnership holds the guard, so a guard here would strand the ETH silently.
     It writes no state and only pays the owner, so re-entering gains nothing.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _amount | uint256 | Amount of ETH to be sent |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The amount sent |

### buyDataBundleWithToken

```solidity
function buyDataBundleWithToken(struct DataBundleDetails _dataBundleDetail, bytes32 _asset, uint256 _maxAmountIn, bytes32 _paymentReference) external returns (bool)
```

Pays the vault for one data bundle in USDC (or any other acceptable stablecoin/ERC20) and records the purchase

The adapter derives the amount from the price, so no caller figure is trusted. Any
     shortfall is pulled from the device wallet. Forwarding the real balance makes a
     fee-on-transfer token fail at `settle`'s funding check with a clear reason. Such tokens
     are still unsupported, since `settle` needs the full price.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetail | struct DataBundleDetails | Data bundle being bought. Its settlement field is overwritten here. |
| _asset | bytes32 | Symbol of the currency to pay in |
| _maxAmountIn | uint256 | Most of that currency the buyer will spend, in its smallest unit |
| _paymentReference | bytes32 | The offchain order id. Spent once, so a retry of a call that        already landed cannot charge the user twice. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if the transaction is successful |

### sendTokenToDeviceWallet

```solidity
function sendTokenToDeviceWallet(address _token, uint256 _amount) external returns (uint256)
```

Sends an ERC-20 held here back to the owning device wallet

The `removeESIMWallet` callback moves ETH only, so tokens would otherwise pass to the
     next owner.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _token | address | ERC-20 to send back |
| _amount | uint256 | Amount in that token's smallest unit |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The amount sent |

### recordSettledPurchase

```solidity
function recordSettledPurchase(struct DataBundleDetails _dataBundleDetail) external
```

Appends a purchase paid for outside the protocol

Nothing onchain saw this payment, so the ceiling is the only limit on what the admin
     can write into history. Checked here because the wallet's own ceiling lives here.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _dataBundleDetail | struct DataBundleDetails | The purchase to record |

### transferOwnership

```solidity
function transferOwnership(address) public pure
```

The inherited one-step transfer is closed

It would move `owner()` without `deviceWallet`. The two-step handover moves both.

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

An eSIM wallet always belongs to a device wallet, so ownership is never renounced

A zero owner makes sendETHToDeviceWallet revert and _addESIMWallet refuse this wallet
     forever, so any ETH held here would be locked.

### _secureTransferOwnership

```solidity
function _secureTransferOwnership() internal
```

Completes a handover, moving `deviceWallet`, `owner()`, the price ceiling and the
        admin allowance together

Clears the request first, so a second acceptance finds nothing. The ceiling and
     allowance were the old owner's choices, so the new owner starts on the defaults.

### _transferETH

```solidity
function _transferETH(address _recipient, uint256 _amount) internal virtual
```

Sends ETH out of this contract, reverting if the call fails

A zero amount is a no-op rather than a revert, so callers that may have nothing to send
     do not need their own guard.

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

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The owning device wallet address |

### receive

```solidity
receive() external payable
```

Accepts plain ETH transfers, which is how the device wallet tops this wallet up

