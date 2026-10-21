# Solidity API

## Asset

One currency the protocol will price a data bundle in

23 bytes, one slot. New fields must fit the nine spare bytes: a second slot would change
     the layout of every entry already stored behind the proxy.

```solidity
struct Asset {
  bool allowed;
  bool isDollarUnit;
  uint8 decimals;
  address token;
}
```

## PaymentAdapter

Holds the accepted currencies, converts prices and moves tokens to the vault

The one place a cent price becomes a token amount, so decimals cannot drift between
     callers. No price feeds, so only dollar currencies convert.

### registry

```solidity
address registry
```

Registry contract address, which this reads the vault and the eSIM wallet list from

### settlementToken

```solidity
address settlementToken
```

Currency the vault is meant to end up holding

Not read yet. Set now so a later swap path needs no migration on every chain.

### assets

```solidity
mapping(bytes32 => struct Asset) assets
```

Every currency the protocol will accept or record a payment in

### usedReferences

```solidity
mapping(bytes32 => bool) usedReferences
```

Payment references already spent, protocol-wide

Retired. Replay protection lives in `Registry.usedPaymentReferences`, which survives an
     adapter rotation and is scoped per wallet. Kept at this slot (pinned by
     `StorageLayout.t.sol`) because removing it would shift every variable below.

### PaymentAdapterInitialized

```solidity
event PaymentAdapterInitialized(address _registry, address _settlementToken)
```

Emitted when this contract is wired up

### AssetUpdated

```solidity
event AssetUpdated(bytes32 _symbol, bool _allowed, bool _isDollarUnit, uint8 _decimals, address _token)
```

Emitted when a currency is added or its entry changes

### PaymentReferenceConsumed

```solidity
event PaymentReferenceConsumed(bytes32 _paymentReference)
```

Emitted when a payment reference is spent

### PaymentSettled

```solidity
event PaymentSettled(bytes32 _symbol, address _eSIMWallet, address _vault, uint64 _priceUSDCents, uint256 _spent, uint256 _refunded)
```

Emitted when a data bundle is paid for in tokens through this contract

One address to watch instead of every eSIM wallet. The vault is logged because it can
     be rotated, and reconciliation needs the one that was paid.

### TokensRecovered

```solidity
event TokensRecovered(address _token, address _to, uint256 _amount)
```

Emitted when tokens sent here by mistake are returned

### onlyRegistry

```solidity
modifier onlyRegistry()
```

Restricts a call to the registry

### onlyProtocolESIMWallet

```solidity
modifier onlyProtocolESIMWallet()
```

Restricts a call to an eSIM wallet the registry has a record of

Read from the registry each call, so a wallet it has dropped cannot keep paying here.

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

### initialize

```solidity
function initialize(address _registry, address _settlementToken, address _upgradeManager) external
```

Wires the adapter to the registry and names the currency the vault should hold

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registry | address | Registry contract address |
| _settlementToken | address | Token the vault is meant to end up holding, normally USDC |
| _upgradeManager | address | Address that owns this contract and authorises its upgrades |

### registerAsset

```solidity
function registerAsset(bytes32 _symbol, struct Asset _asset) external
```

Adds a currency the protocol will accept or record a payment in

Owner, not admin: the admin names the price on its purchases, so it must not also be
     able to invent a token address to be paid into.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _symbol | bytes32 | Short ASCII symbol, "USDC" or "USD" or "TON" |
| _asset | struct Asset | The entry to write |

### updateAsset

```solidity
function updateAsset(bytes32 _symbol, struct Asset _asset) external
```

Changes an existing currency entry, including withdrawing it

Separate from `registerAsset` so a typo in a new symbol cannot overwrite a live one.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _symbol | bytes32 | Symbol of the currency being changed |
| _asset | struct Asset | The entry to write in its place |

### quote

```solidity
function quote(bytes32 _symbol, uint64 _priceUSDCents) external view returns (uint256 amountIn)
```

Turns a price in USD cents into an amount of one currency's smallest unit

A non-dollar currency would need a rate, and there are no price feeds, so it reverts.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _symbol | bytes32 | Currency the price is being expressed in |
| _priceUSDCents | uint64 | Price in USD cents |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| amountIn | uint256 | Amount in that currency's own smallest unit |

### resolveAsset

```solidity
function resolveAsset(bytes32 _symbol) external view returns (struct Asset)
```

Reads back a currency entry, reverting if it is not allowed

Callers read token and decimals here rather than pass them, so every record agrees.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _symbol | bytes32 | Currency to read |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct Asset | The stored entry |

### settle

```solidity
function settle(bytes32 _symbol, uint64 _priceUSDCents, uint256 _amountIn, address _refundTo) external returns (uint256 spent, uint256 refunded)
```

Pays the vault for one data bundle out of tokens the caller has already sent here

Funded first, then called, so a swap can be added later without changing the signature.
     `_amountIn` is checked only against the balance, so overstating it would sweep tokens
     left here by mistake. Only safe because the one caller passes at most `quote`. Keep it so.
     A fee-on-transfer token delivers less than declared and fails the funding check.
     `spent` is recomputed, matching the caller's `quote` only because nothing changes
     `assets` in between. A swap path that can must check the caller's quoted value instead.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _symbol | bytes32 | Currency being paid in |
| _priceUSDCents | uint64 | Price of the data bundle, in USD cents |
| _amountIn | uint256 | Amount the caller has funded, and the most it is willing to spend |
| _refundTo | address | Address anything unspent goes back to |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| spent | uint256 | Amount that reached the vault |
| refunded | uint256 | `_amountIn` over the price, sent back to `_refundTo` |

### consumePaymentReference

```solidity
function consumePaymentReference(bytes32 _paymentReference) external
```

Spends a payment reference against this adapter's own record, refusing a repeat

Retired, see `usedReferences`. Nothing in the protocol calls it any more.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentReference | bytes32 | Hash tying this purchase to the offchain payment behind it |

### recoverTokens

```solidity
function recoverTokens(address _token, address _to, uint256 _amount) external
```

Returns tokens sent to this contract by mistake

Safe because `settle` is funded and spent in the same transaction, so nothing a purchase
     paid rests here between transactions. The owner is the timelock, so every recovery is
     public for the delay before it runs.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _token | address | Token to send out |
| _to | address | Address that receives it, normally whoever sent it here |
| _amount | uint256 | Amount in the token's smallest unit |

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

Ownership of this contract is never renounced

Only the owner can upgrade or change currencies, so renouncing would freeze both.

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

Restricts UUPS upgrades to the owner

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Address of the implementation being moved to |

### upgradeManager

```solidity
function upgradeManager() public view returns (address)
```

Address that can upgrade this contract

Reads the owner rather than a second copy that could disagree.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address that may upgrade this contract |

