# Solidity API

## Registry

Holds the protocol's roles and switches: admin, vault, pause flag and price ceiling

Wallets are beacon proxies with no enumerable list, so one write here is the only way a
     change reaches all of them in the same transaction.
     `IPausable` and `IRegistryAdmin` let the compiler check what `ProtocolAdmin` calls, since a
     mismatch would only show as a revert mid-incident. `enableAdmin` is left out on purpose,
     so nothing invites a fast path for restoring a suspended key.

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

Entry point contract address (one entryPoint per chain)

### adminOfRecord

```solidity
address adminOfRecord
```

Address holding the admin role, whether or not its powers are currently live

The only copy, so a rotation reaches every reader at once and none keeps the old key.
     Use `eSIMWalletAdmin()` to ask who may act: this keeps naming a suspended admin so the
     suspension can be lifted without re-supplying the address.

### vault

```solidity
address vault
```

Address of the vault that receives payments for the eSIM data bundles

### newRequestedAdmin

```solidity
address newRequestedAdmin
```

Address of the admin to be appointed

Set by the owner, cleared on acceptance. While set the incumbent has no powers, so an
     unaccepted handover leaves the role dormant rather than shared.

### paused

```solidity
bool paused
```

True while the protocol's guarded purchase and pull paths are stopped

Held here so one write reaches every wallet; they all read it on their guarded paths.

### adminDisabled

```solidity
bool adminDisabled
```

True while the admin's powers are suspended, leaving the address on the books

Packs beside `paused`. Suspending is instant through a guardian but lifting it is an
     owner action that waits, so a compromised key cannot restore itself as fast.

### defaultPriceCapUSDCents

```solidity
uint64 defaultPriceCapUSDCents
```

Most an eSIM wallet may be charged for one data bundle, in USD cents, unless it sets
        its own limit

Never zero, both setters refuse it: zero on a wallet means "follow the registry", so it
     has no meaning here.

### paymentAdapter

```solidity
address paymentAdapter
```

Contract holding the accepted currencies

### usedPaymentReferences

```solidity
mapping(bytes32 => bool) usedPaymentReferences
```

Payment references already spent, scoped per eSIM wallet

Held here so replay protection survives `setPaymentAdapter`. Keyed by
     `keccak256(abi.encode(eSIMWallet, paymentReference))` so one wallet spending a reference
     cannot burn it for another wallet's pending settlement.

### defaultAdminAllowanceUSDCents

```solidity
uint64 defaultAdminAllowanceUSDCents
```

What a new eSIM wallet lets the admin charge it in total, in USD cents

Copied into each wallet at deploy and handover, so a change here never moves an existing
     wallet. Zero means new wallets take no admin charges.

### onlyESIMWallet

```solidity
modifier onlyESIMWallet()
```

Restricts a call to an eSIM wallet this registry has recorded

### onlyDeviceWallet

```solidity
modifier onlyDeviceWallet()
```

Restricts a call to a device wallet this registry has recorded

### onlyDeviceWalletFactory

```solidity
modifier onlyDeviceWalletFactory()
```

Restricts a call to the device wallet factory

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
```

Restricts a call to the current eSIM wallet admin

Reads the accessor, not `adminOfRecord`, so a suspended admin is refused here too.

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

Otherwise anyone could initialize and own the implementation. The proxy is unaffected,
     but an owned implementation is a trap for a later upgrade that adds an outward call.

### initialize

```solidity
function initialize(address _eSIMWalletAdmin, address _vault, address _upgradeManager, address _deviceWalletFactory, address _eSIMWalletFactory, contract IEntryPoint _entryPoint, uint64 _defaultPriceCapUSDCents, uint64 _defaultAdminAllowanceUSDCents) external
```

Wires the registry to the two factories and sets the protocol's addresses

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAdmin | address | Admin address of the eSIM wallet project |
| _vault | address | Address of the vault that receives payments for the data bundles |
| _upgradeManager | address | Admin address responsible for upgrading contracts |
| _deviceWalletFactory | address | Factory that deploys device wallets |
| _eSIMWalletFactory | address | Factory that deploys eSIM wallets |
| _entryPoint | contract IEntryPoint | ERC-4337 EntryPoint singleton for this chain |
| _defaultPriceCapUSDCents | uint64 | Starting price ceiling in USD cents. Non-zero, since zero        reads as "no ceiling" in `ESIMWallet._requirePriceWithinCap`. |
| _defaultAdminAllowanceUSDCents | uint64 | Total the admin may charge each new eSIM wallet, in USD cents |

### requestAdminUpdate

```solidity
function requestAdminUpdate(address _newAdmin) external
```

Nominates a new admin, which strips the incumbent until the nominee accepts

Owner, not admin: a compromised admin could never be replaced, and could hold the pause
     on with no other key able to end it.
     Nominating strips the incumbent at once (via `eSIMWalletAdmin()`), so the two never hold
     the role together; keep nomination and acceptance close. Calling again overrides a
     mistaken nomination, and naming the incumbent withdraws it and lifts a suspension.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newAdmin | address | Address of the recipient to receive the admin role |

### acceptAdminUpdate

```solidity
function acceptAdminUpdate() external returns (address)
```

Takes up the admin role, callable only by the nominated address

Clears the suspension too: it targets a key, not the role, so a fresh key accepting
     ends the incident.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the new admin |

### disableAdmin

```solidity
function disableAdmin() external
```

Suspends the admin's powers protocol-wide, leaving its address on the books

Every gate reads `eSIMWalletAdmin()`, which returns zero from here, so one write closes
     them all. Owner gated so `ProtocolAdmin` can give a guardian an instant route. A repeat
     reverts so a guardian mid-incident never believes it acted when it did not.

### enableAdmin

```solidity
function enableAdmin() external
```

Hands a suspended admin its powers back

Owner only with no instant route, so a compromised key cannot undo its suspension as
     fast as it is applied. An outstanding handover still keeps the incumbent powerless;
     withdraw it with `requestAdminUpdate` naming the incumbent.

### eSIMWalletAdmin

```solidity
function eSIMWalletAdmin() public view returns (address)
```

Admin address every gated call in the protocol is checked against

Zero while suspended or while a handover is outstanding. `msg.sender` is never zero, so
     both states close every gate at once.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address that may act as admin right now, or zero if nobody may |

### updateVaultAddress

```solidity
function updateVaultAddress(address _newVaultAddress) external returns (address)
```

Points every data bundle payment at a different vault

Owner, not admin: every payment lands here, so moving it belongs behind the upgrade
     delay. Device wallets read `vault` on every purchase, so one write reaches all of them.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newVaultAddress | address | Address that receives payments for the data bundles from now on |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The vault address now in force |

### pause

```solidity
function pause() external
```

Stops the token purchase and pull paths on every device wallet and eSIM wallet

The admin trips it and the owner clears it: the hot key must act fast, but holding the
     release too would let one key freeze user funds indefinitely. The owner can also trip
     it, so a guardian can pause through `ProtocolAdmin` while the admin is suspended. A
     pause never reaches a wallet owner's own `execute`, so users can still spend their ETH.

### unpause

```solidity
function unpause() external
```

Clears the pause

Owner only, see `pause`

### requireNotPaused

```solidity
function requireNotPaused() external view
```

Reverts while the protocol is paused

Wallets call this instead of reading `paused`, so the revert reason is the same
     everywhere.

### setDefaultPriceCapUSDCents

```solidity
function setDefaultPriceCapUSDCents(uint64 _cap) external
```

Sets the price ceiling eSIM wallets fall back to when they hold none of their own

Owner, not admin: the admin is the party this limits. Zero is refused because it reads
     as "no ceiling" in `ESIMWallet._requirePriceWithinCap` for wallets without their own.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _cap | uint64 | Maximum price in USD cents, non-zero |

### setDefaultAdminAllowanceUSDCents

```solidity
function setDefaultAdminAllowanceUSDCents(uint64 _allowance) external
```

Sets the admin allowance new eSIM wallets start with

Owner, not admin: the admin is the party this limits. Existing wallets keep theirs.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _allowance | uint64 | Total the admin may charge each new eSIM wallet, in USD cents |

### setPaymentAdapter

```solidity
function setPaymentAdapter(address _paymentAdapter) external
```

Points this registry at the payment adapter

Owner, not admin: the adapter decides where money goes. Spent payment references live
     on this registry, so they survive a swap.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentAdapter | address | Address of the payment adapter |

### consumePaymentReference

```solidity
function consumePaymentReference(bytes32 _paymentReference) external
```

Spends a payment reference for an eSIM wallet paying with an accepted ERC-20

Scoped to `msg.sender`, so this and `recordSettledPurchase` cannot spend the same
     reference once on each for the same wallet.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentReference | bytes32 | Hash tying the purchase to the offchain order behind it |

### recordSettledPurchase

```solidity
function recordSettledPurchase(address _eSIMWallet, struct DataBundleDetails _dataBundleDetail, bytes32 _asset, uint256 _tokenAmount, bytes32 _paymentReference) external
```

Records a data bundle paid for through an external wallet or a card

No money moves here. The admin's claim is bounded by the price cap, a once-only payment
     reference, and a settlement other than `DeviceWallet`. Written here, not by the adapter,
     because eSIM wallets accept history only from this address.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWallet | address | Wallet the purchase belongs to |
| _dataBundleDetail | struct DataBundleDetails | The purchase, priced in USD cents like everywhere else |
| _asset | bytes32 | Symbol of the currency the user paid in |
| _tokenAmount | uint256 | What the user actually paid, in that currency's smallest unit. Recorded        for offchain matching, never checked: it and the price both come from the admin. |
| _paymentReference | bytes32 | Hash tying this purchase to its offchain payment intent |

### requireLazyHistoryCopied

```solidity
function requireLazyHistoryCopied(address _eSIMWallet) external view
```

Refuses a new entry while older history is still waiting to be copied in

Otherwise the new entry lands before the older ones and the history is out of order.
     Enforced here because the backend retries whole steps on failure. External so wallets
     can run it on their own paths that see the money move.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWallet | address | Wallet being appended to |

### updateDeviceWalletInfo

```solidity
function updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) external
```

Records a device wallet the factory has just deployed

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Address of the device wallet |
| _deviceUniqueIdentifier | string | String unique identifier associated with the device wallet |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |

### updateDeviceWalletOwnerKey

```solidity
function updateDeviceWalletOwnerKey(bytes32[2] _newOwnerKey) external
```

Called by a device wallet when the P256 key that owns it is replaced

Without this the registry keeps the retired key and the new one could be claimed by a
     second wallet, breaking one key to one wallet. The key must be the one the wallet holds,
     or a wallet could claim a stranger's key through `execute` and block them registering.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key taking over |

### requireDeviceIdentifierNotReserved

```solidity
function requireDeviceIdentifierNotReserved(string _deviceUniqueIdentifier) external view
```

Refuses a device identifier a fiat user's eSIMs are already waiting on

Called by the ordinary deploy route. Taking such an identifier strands the lazy user:
     history copy, wallet deploy and device switch all refuse an identifier with a wallet.
     Passes while `lazyWalletRegistry` is unset, since nothing can be reserved before then.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the caller is about to take |

### bindESIMWallet

```solidity
function bindESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress) external
```

Binds an eSIM wallet to the calling device wallet and settles any outstanding transfer

The only writer of the association, which once set always names a device wallet, so
     zero is refused; a release raises standby via `toggleESIMWalletStandbyStatus` instead.
     Authorization reads `ESIMWallet.owner()` because the association can lag behind an
     accepted ownership transfer. Standby is cleared here since both facts change together.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet |
| _deviceWalletAddress | address | The device wallet taking it on, which must be the caller |

### assignESIMIdentifier

```solidity
function assignESIMIdentifier(address _eSIMWalletAddress, string _eSIMUniqueIdentifier) external returns (string)
```

Binds an eSIM identifier to an eSIM wallet and writes it onto the wallet

Admin only: which identifier a wallet is owed is known offchain, and a device wallet
     could fake any onchain proof through `execute`. Reserved identifiers are refused even on
     their own device, because the lazy route assigns them and taking one strands that batch.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Wallet receiving the identifier |
| _eSIMUniqueIdentifier | string | Identifier being assigned |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | string | The identifier now on the wallet |

### toggleESIMWalletStandbyStatus

```solidity
function toggleESIMWalletStandbyStatus(address _eSIMWalletAddress, bool _isOnStandby) public
```

Marks an eSIM wallet as being moved from one device wallet to another, or cancels that

Only the flag moves; the association keeps naming the last device wallet, so raising
     standby on a wallet the caller still holds is normal. Authorization reads
     `ESIMWallet.owner()` for the same reason as `bindESIMWallet`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet |
| _isOnStandby | bool | True while a transfer is outstanding, false once it is settled or revoked |

### addOrUpdateLazyWalletRegistryAddress

```solidity
function addOrUpdateLazyWalletRegistryAddress(address _lazyWalletRegistry) public returns (address)
```

Points the registry at the lazy wallet registry, which is deployed after it

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _lazyWalletRegistry | address | Address of the lazy wallet registry |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address now in force |

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

Ownership of this contract is never renounced

The owner is the only upgrade route, so renouncing would freeze this logic for good.

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

Address (owned/controlled by eSIM wallet project) that can upgrade contracts

Reads through to the owner, which `_authorizeUpgrade` checks, since a separate copy
     could only disagree with it.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address that may upgrade this contract |

