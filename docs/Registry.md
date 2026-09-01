# Solidity API

## Registry

Single source of truth for who is who in the protocol, and the switchboard the wallets
        read on every guarded path

_Holds the admin address, the vault, the pause flag and the price ceiling in one place.
     Device wallets and eSIM wallets are beacon proxies tracked by mappings with no enumerable
     list, so there is no way to write a value into each of them: one write here is how a change
     reaches all of them in the same transaction.

     `IPausable` and `IRegistryAdmin` are declared so the compiler checks the signatures
     `ProtocolAdmin` calls through them. A guardian acts with no delay, so a drift between the
     two would only show as a revert during an incident. What each interface leaves out is
     deliberate: `pause()` is the hot admin key's lever while releasing it is the timelock's,
     and `enableAdmin()` is absent for the same reason in reverse, so nothing invites a fast
     path for handing a suspended key its powers back._

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

_The only copy in the protocol. `DeviceWalletFactory`, `DeviceWallet`, `ESIMWallet` and
     `LazyWalletRegistry` all read it from here, so rotating it below reaches every one of
     them in the same transaction. Holding it in more than one place is what previously let
     a rotation update some readers and leave the rest authorising the retired key.

     Read `eSIMWalletAdmin()` rather than this to find out who may act: this is the address
     on the books, and it keeps naming a suspended admin so the suspension can be lifted
     without anyone having to remember who it was._

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

_Only the owner can request the transfer. The nominated address has to accept it, and
     this resets once they do. While it is set the incumbent has no powers, so a handover
     that is never accepted leaves the role dormant rather than shared._

### paused

```solidity
bool paused
```

True while the protocol's guarded purchase and pull paths are stopped

_Held here for the same reason the admin address is: device wallets and eSIM wallets are
     beacon proxies tracked by a mapping with no enumerable list, so there is no way to
     write a flag into each of them. Both already read this contract on their guarded paths,
     so one write here reaches every wallet in the same transaction._

### adminDisabled

```solidity
bool adminDisabled
```

True while the admin's powers are suspended, leaving the address on the books

_Packs into the spare bytes beside `paused`, so it costs no slot of its own. Suspension
     is the lever against a compromised admin key: it is instant through a guardian, while
     lifting it is an owner action and therefore waits. A key that could restore itself as
     fast as it was suspended would leave the two sides trading transactions forever._

### defaultPriceCapUSDCents

```solidity
uint64 defaultPriceCapUSDCents
```

Most an eSIM wallet may be charged for one data bundle, in USD cents, unless it sets
        its own limit

_Held here because there is no way to list every wallet and write into each one, so one
     write here is how a change reaches all of them. Never zero: both setters reject it,
     because zero on a wallet means "follow the registry" and would mean nothing here._

### paymentAdapter

```solidity
address paymentAdapter
```

Contract holding the accepted currencies and the spent payment references

_A pointer and a setter, the same shape this registry already uses for the lazy wallet
     registry._

### usedPaymentReferences

```solidity
mapping(bytes32 => bool) usedPaymentReferences
```

Payment references already spent, scoped per eSIM wallet

_Held here rather than on the payment adapter, so replay protection survives an adapter
     rotation through `setPaymentAdapter` instead of resetting with it. Keyed by
     `keccak256(abi.encode(eSIMWallet, paymentReference))` rather than by the reference
     alone, so one wallet spending a reference cannot burn it for an unrelated wallet's
     pending settlement._

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

_The hot key the backend signs with, not the owner. It can trip the pause but not
     release it, and cannot upgrade anything. Reads the accessor rather than the stored
     address, so a suspended admin is refused here for the same reason it is refused
     everywhere else._

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

_Locks the implementation contract itself. Without this, anyone can call initialize
     directly on the implementation and own it. The proxy is unaffected either way, but an
     owned implementation is a trap for any later upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _eSIMWalletAdmin, address _vault, address _upgradeManager, address _deviceWalletFactory, address _eSIMWalletFactory, contract IEntryPoint _entryPoint, uint64 _defaultPriceCapUSDCents) external
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
| _defaultPriceCapUSDCents | uint64 | Starting price ceiling in USD cents. Must be non-zero: a        zero cap, here or on a wallet's own, reads as "no ceiling" in        `ESIMWallet._requirePriceWithinCap`. |

### requestAdminUpdate

```solidity
function requestAdminUpdate(address _newAdmin) external
```

Nominates a new admin, which strips the incumbent until the nominee accepts

_Owner and not the admin, deliberately. An admin that had to nominate its own
     replacement could not be removed once its key was in someone else's hands, and the
     pause is the admin's own lever, so a compromised key could hold the protocol stopped
     for as long as it liked and no other key could end it.

     Nominating strips the incumbent at once, through the accessor rather than through a
     write: a handover in flight leaves the role dormant until the nominee accepts, so the
     two never hold it at the same time. A rotation therefore has a gap in it, and the
     nomination and the acceptance belong close together.

     Deliberately does not check for an existing request, so an unintended nomination is
     overridden by calling this again. Naming the incumbent withdraws the request and hands
     the powers back, which also lifts a suspension, so one call undoes either mistake._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newAdmin | address | Address of the recipient to receive the admin role |

### acceptAdminUpdate

```solidity
function acceptAdminUpdate() external returns (address)
```

Takes up the admin role, callable only by the nominated address

_Clears the suspension as well as the request. The suspension names a key, not the
     role, so a fresh key accepting is the end of the incident rather than something that
     has to be lifted separately afterwards._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the new admin |

### disableAdmin

```solidity
function disableAdmin() external
```

Suspends the admin's powers protocol-wide, leaving its address on the books

_Every gate in the protocol reads `eSIMWalletAdmin()`, which answers zero from here on,
     and no transaction can arrive from the zero address, so one write closes all of them
     in the same transaction. The address itself is kept so the suspension can be lifted
     without anyone having to supply it again.

     Owner gated, which is what lets `ProtocolAdmin` offer a guardian an instant route to
     it. Refuses a repeat rather than passing quietly: a guardian doing this during an
     incident should not be left believing it acted when it did not._

### enableAdmin

```solidity
function enableAdmin() external
```

Hands a suspended admin its powers back

_Owner only, with no instant route for anyone. Suspending is instant and restoring
     waits, so a compromised key cannot undo its own suspension as fast as it is applied.
     Reversing that would recreate the deadlock the suspension exists to break.

     Does nothing for an outstanding handover, which keeps the incumbent powerless on its
     own. Withdraw that with `requestAdminUpdate` naming the incumbent._

### eSIMWalletAdmin

```solidity
function eSIMWalletAdmin() public view returns (address)
```

Admin address every gated call in the protocol is checked against

_Zero while the admin is suspended or while a handover is outstanding, which is how
     both states close every gate at once: `msg.sender` is never zero, so no caller matches.
     `adminOfRecord` holds the address itself either way._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address that may act as admin right now, or zero if nobody may |

### updateVaultAddress

```solidity
function updateVaultAddress(address _newVaultAddress) external returns (address)
```

Points every data bundle payment at a different vault

_Owner and not admin, deliberately. This is the destination of every payment the protocol
     collects, so moving it is a fund-flow change and belongs behind the same delay as an
     upgrade rather than on the hot key that signs backend batches all day.

     Device wallets read `vault` here on every purchase instead of caching it, so one write
     reaches all of them in the same transaction. This used to live on `DeviceWalletFactory`,
     which nothing on the payment path ever read, so rotating the vault there changed nothing
     and the real address could not be moved at all._

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

_The admin trips this and the owner clears it. The admin key signs backend batches all
     day and is the one watching, so it needs to act without waiting; giving it the release
     as well would let a single hot key hold user funds indefinitely. Neither key can reach
     an owner's own `execute`, so a pause never stops someone spending their own ETH._

### unpause

```solidity
function unpause() external
```

Clears the pause

_Owner only, see `pause`_

### requireNotPaused

```solidity
function requireNotPaused() external view
```

Reverts while the protocol is paused

_Device wallets and eSIM wallets call this rather than reading `paused` and reverting
     themselves, so the revert reason is the same wherever it comes from._

### setDefaultPriceCapUSDCents

```solidity
function setDefaultPriceCapUSDCents(uint64 _cap) external
```

Sets the price ceiling eSIM wallets fall back to when they hold none of their own

_Owner and not admin, deliberately. The admin is the party this ceiling constrains, so
     letting it raise its own limit would leave the ceiling meaningless. Zero is refused:
     it would read as "no ceiling" in `ESIMWallet._requirePriceWithinCap` for every wallet
     that has not set its own._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _cap | uint64 | Maximum price in USD cents, non-zero |

### setPaymentAdapter

```solidity
function setPaymentAdapter(address _paymentAdapter) external
```

Points this registry at the payment adapter

_Owner and not admin. The adapter holds the spent payment references, so an admin that
     could swap it would get an empty set back and record every purchase a second time._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentAdapter | address | Address of the payment adapter |

### consumePaymentReference

```solidity
function consumePaymentReference(bytes32 _paymentReference) external
```

Spends a payment reference for an eSIM wallet paying with USDC (or any other acceptable stablecoin/ERC20)

_Scoped to `msg.sender`, so this and `recordSettledPurchase` cannot spend the same
     reference once on each for the same wallet._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _paymentReference | bytes32 | Hash tying the purchase to the offchain order behind it |

### recordSettledPurchase

```solidity
function recordSettledPurchase(address _eSIMWallet, struct DataBundleDetails _dataBundleDetail, bytes32 _asset, uint256 _tokenAmount, bytes32 _paymentReference) external
```

Records a data bundle paid for through an external wallet or a card

_No money moves here. Three things bound what the admin can state: the price ceiling,
     the payment reference being spendable once, and the settlement not being
     `DeviceWallet`. Written here and not by the adapter, because eSIM wallets accept
     history from this address alone._

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

_The new entry would land first and the older ones append after it, leaving the history
     out of order. The backend retries the whole onchain step on failure, so this cannot be
     left as an ordering rule for the caller to follow. External so a wallet can run the same
     check on its own paths that see the money move; `recordSettledPurchase` uses the
     private form since it already has this contract's own state in scope._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWallet | address | Wallet being appended to |

### updateDeviceWalletInfo

```solidity
function updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) external
```

Records a device wallet the factory has just deployed

_Factory only. Writes the identifier, the address and the owner key together, so the
     three stay consistent with each other._

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

_Only the wallet itself can move its own bindings, so `msg.sender` is the subject
     rather than a parameter. Without this the registry keeps naming the retired key after
     a rotation, and the key taking over stays unregistered and can be claimed by a second
     wallet, which breaks the one key to one wallet rule the deploy paths enforce._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key taking over |

### requireDeviceIdentifierNotReserved

```solidity
function requireDeviceIdentifierNotReserved(string _deviceUniqueIdentifier) external view
```

Refuses a device identifier a fiat user's eSIMs are already waiting on

_The ordinary deployment route calls this. Taking such an identifier used to succeed and
     strand the lazy user: the history copy, the wallet deployment and the device switch all
     refuse an identifier that has a wallet.

     Passes while `lazyWalletRegistry` is unset, the window between deploying this contract
     and wiring the two together. Nothing can be reserved before the contract holding
     reservations exists, so the window is empty rather than unguarded._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the caller is about to take |

### bindESIMWallet

```solidity
function bindESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress) external
```

Binds an eSIM wallet to the calling device wallet and settles any outstanding transfer

_The association is a registration: once the registry has named a device wallet for an
     eSIM wallet it always names one, and this is the only place it moves. Zero is refused
     for that reason, so releasing an eSIM wallet raises the standby flag through
     `toggleESIMWalletStandbyStatus` and leaves the association naming the last device
     wallet that held it.

     Authorization reads `ESIMWallet.owner()` rather than the association above, because the
     association can still name a former device wallet after an ownership transfer has been
     accepted and never bound back through `addESIMWallet`.

     Taking a wallet on is the one moment both facts change together, which is why the flag
     is cleared here rather than in a second call. Nothing else in this function reads it._

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

_Admin only. Which identifier a wallet is owed is known offchain when the eSIM is
     bought, and no onchain check replaces that: a device wallet reaches every external
     function through `execute`, and any fact it could present about its own wallets is one
     it writes itself. The lazy route shares the same internal claim._

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

_Only the flag moves here. The association is a separate fact and keeps naming the device
     wallet that last held the eSIM wallet, so raising standby on a wallet this caller still
     holds is the ordinary case rather than a contradiction.

     Authorization reads `ESIMWallet.owner()` rather than the association, for the same reason
     as `bindESIMWallet`: the association can still name a former device wallet after an
     accepted transfer that was never bound back._

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

_The owner is the only caller _authorizeUpgrade accepts, and there is no other route to
     replace this implementation. Renouncing would freeze the contract on its current logic
     permanently._

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

_Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
     gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
     copy could only ever disagree with it._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address that may upgrade this contract |

