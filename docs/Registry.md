# Solidity API

## Registry

Single source of truth for who is who in the protocol, and the switchboard the wallets
        read on every guarded path

_Holds the admin address, the vault, the pause flag and the price ceiling in one place.
     Device wallets and eSIM wallets are beacon proxies tracked by mappings with no enumerable
     list, so there is no way to write a value into each of them: one write here is how a change
     reaches all of them in the same transaction.

     `IPausable` is declared so the compiler checks the one signature `ProtocolAdmin` calls
     through it. A guardian releases a pause with no delay, so the two drifting apart would only
     show as a revert during an incident. `pause()` stays outside the interface deliberately: it
     is the hot admin key's lever, while releasing it is the timelock's._

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

Entry point contract address (one entryPoint per chain)

### eSIMWalletAdmin

```solidity
address eSIMWalletAdmin
```

Admin address of the eSIM wallet project

_The only copy in the protocol. `DeviceWalletFactory`, `DeviceWallet`, `ESIMWallet` and
     `LazyWalletRegistry` all read it from here, so rotating it below reaches every one of
     them in the same transaction. Holding it in more than one place is what previously let
     a rotation update some readers and leave the rest authorising the retired key._

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

_Only the current admin can request the transfer. The nominated address has to accept
     it, and this resets once they do._

### paused

```solidity
bool paused
```

True while the ETH-moving paths are stopped protocol-wide

_Held here for the same reason the admin address is: device wallets and eSIM wallets are
     beacon proxies tracked by a mapping with no enumerable list, so there is no way to
     write a flag into each of them. Both already read this contract on their guarded paths,
     so one write here reaches every wallet in the same transaction._

### defaultDataBundlePriceCap

```solidity
uint256 defaultDataBundlePriceCap
```

Most an eSIM wallet may be charged for one data bundle unless it sets its own limit

_Held here rather than only on each wallet because a wallet deployed before this existed
     reads zero, and there is no enumerable list to write a value into. Never zero: `initialize`
     and `setDefaultDataBundlePriceCap` both reject it, since a zero here or on a wallet's own
     cap reads as "no ceiling" in `ESIMWallet._requirePriceWithinCap`._

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
     release it, and cannot upgrade anything._

### constructor

```solidity
constructor() public
```

_Locks the implementation contract itself. Without this, anyone can call initialize
     directly on the implementation and own it. The proxy is unaffected either way, but an
     owned implementation is a trap for any later upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _eSIMWalletAdmin, address _vault, address _upgradeManager, address _deviceWalletFactory, address _eSIMWalletFactory, contract IEntryPoint _entryPoint, uint256 _defaultDataBundlePriceCap) external
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
| _defaultDataBundlePriceCap | uint256 | Starting price ceiling. Must be non-zero: a zero cap, here        or on a wallet's own, reads as "no ceiling" in `ESIMWallet._requirePriceWithinCap`. |

### requestAdminUpdate

```solidity
function requestAdminUpdate(address _newAdmin) external
```

Nominates the next eSIM wallet admin, who then has to accept

_Deliberately does not check for an existing request. If the current admin nominates an
     unintended address, calling this again overrides it. Nominating the current admin
     revokes any outstanding request._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newAdmin | address | Address of the recipient to receive the admin role |

### acceptAdminUpdate

```solidity
function acceptAdminUpdate() external returns (address)
```

Takes up the admin role, callable only by the nominated address

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the new admin |

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

Stops the ETH-moving paths on every device wallet and eSIM wallet

_The admin trips this and the owner clears it. The admin key signs backend batches all
     day and is the one watching, so it needs to act without waiting; giving it the release
     as well would let a single hot key hold user funds indefinitely. Neither key can reach
     an owner's own `execute`, so a pause never stops someone spending their own ETH._

### unpause

```solidity
function unpause() external
```

Releases the pause

_Owner only, see `pause`_

### requireNotPaused

```solidity
function requireNotPaused() external view
```

Reverts while the protocol is paused

_Device wallets and eSIM wallets call this rather than reading `paused` and reverting
     themselves, so the revert reason is the same wherever it comes from._

### setDefaultDataBundlePriceCap

```solidity
function setDefaultDataBundlePriceCap(uint256 _cap) external
```

Sets the price ceiling eSIM wallets fall back to when they hold none of their own

_Owner and not admin, deliberately. The admin is the party this ceiling constrains, so
     letting it raise its own limit would leave the ceiling meaningless. Zero is refused:
     it would read as "no ceiling" in `ESIMWallet._requirePriceWithinCap` for every wallet
     that has not set its own._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _cap | uint256 | Maximum price in wei, non-zero |

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

     Taking a wallet on is the one moment both facts change together, which is why the flag
     is cleared here rather than in a second call. Nothing else in this function reads it._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet |
| _deviceWalletAddress | address | The device wallet taking it on, which must be the caller |

### toggleESIMWalletStandbyStatus

```solidity
function toggleESIMWalletStandbyStatus(address _eSIMWalletAddress, bool _isOnStandby) public
```

Marks an eSIM wallet as being moved from one device wallet to another, or cancels that

_Only the flag moves here. The association is a separate fact and keeps naming the device
     wallet that last held the eSIM wallet, so raising standby on a wallet this caller still
     holds is the ordinary case rather than a contradiction._

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

