# Solidity API

## Asset

One currency the protocol will price a data bundle in

_23 bytes, so it fits one slot with nine to spare. New fields have to stay inside those
     nine bytes: a second slot moves every entry in the mapping, and a live table cannot be
     moved._

```solidity
struct Asset {
  bool allowed;
  bool isDollarUnit;
  uint8 decimals;
  address token;
}
```

## PaymentAdapter

Holds the accepted currencies, converts prices, moves tokens to the vault, and spends
        payment references

_Prices cross contract boundaries in USD cents only, and this is the one place a cent
     figure becomes a token amount, so a decimals mismatch cannot happen rather than having to
     be checked for. There are no price feeds, so a currency not already in dollars has no
     conversion here. UUPS and not swappable: `usedReferences` is replay protection, and a
     fresh copy would re-open every reference already spent.

     Tokens pass through in one call and never rest here._

### registry

```solidity
address registry
```

Registry contract address, the only caller allowed to spend a payment reference

### settlementToken

```solidity
address settlementToken
```

Currency the vault is meant to end up holding

_Nothing reads it yet. Set at initialisation anyway, so adding the swap path later needs
     no migration transaction on every chain._

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

_One reference is one offchain payment. The backend retries the whole onchain step on
     any failure, so without this a retry of a call that already landed records it twice._

### PaymentAdapterInitialized

```solidity
event PaymentAdapterInitialized(address _registry, address _settlementToken)
```

Emitted when this contract is wired up

### AssetUpdated

```solidity
event AssetUpdated(bytes32 _symbol, bool _allowed, bool _isDollarUnit, uint8 _decimals, address _token)
```

Emitted when a currency enters the vocabulary or its entry changes

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

_One address for an indexer to watch instead of every eSIM wallet. The vault is
     recorded because it can be rotated, and reconciliation needs the one that was paid._

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

_Read from the registry on every call rather than held here, so a wallet the registry
     has let go cannot keep paying through this contract._

### constructor

```solidity
constructor() public
```

_Locks the implementation contract itself, so nobody can initialise and own it directly._

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

_Owner and not admin. The admin names the price on every purchase, so letting it add
     currencies too would let it invent a token address to be paid into._

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

_Separate from `registerAsset` so a typo in a new symbol cannot silently overwrite a
     currency already in use. Set `allowed` to false to withdraw one._

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

_The only place in the protocol that does this, so there is never a second figure to
     check this one against. A currency not already in dollars needs a rate, and there are
     no price feeds here, so it reverts instead of guessing._

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

_Callers read the token address and decimals from here rather than passing them in, so
     they stay the same across every record._

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

_The caller funds this contract and calls settle in the same transaction, which leaves
     the tokens here for a swap to be added later without changing this signature.

     The refund is bounded by what the caller funded rather than by the balance, so a token
     sent here by mistake is not swept out by the next purchase. A fee-on-transfer token
     delivers less than declared and fails the funding check._

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
| refunded | uint256 | Amount returned to `_refundTo`, always zero until a swap can overshoot |

### consumePaymentReference

```solidity
function consumePaymentReference(bytes32 _paymentReference) external
```

Spends a payment reference, refusing one already spent

_Registry only, on both payment paths, so one reference cannot be spent once on each._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentReference | bytes32 | Hash tying this purchase to the offchain payment behind it |

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

Ownership of this contract is never renounced

_The owner is the only caller `_authorizeUpgrade` accepts and the only one that can
     change the list of currencies. Renouncing would freeze both for good._

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

_Reads through to the owner rather than holding a second copy that could disagree._

