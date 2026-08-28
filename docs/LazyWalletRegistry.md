# Solidity API

## LazyWalletRegistry

Holds what a fiat user bought before they had a wallet, then deploys the wallets and
        copies the record onto them

_Everything here is keyed by string identifiers rather than by address, because a lazy user
     has no address yet. Deployment and the history copy are both batched and both carry their
     own cursor in storage, so a dropped transaction is retried by repeating the same call. Each
     batch loop reverts on its terminal condition rather than returning quietly, which is what
     lets a caller loop until it stops._

### MAX_HISTORY_ENTRIES_PER_CALL

```solidity
uint256 MAX_HISTORY_ENTRIES_PER_CALL
```

Most purchase history entries `setHistoryForLazyWallet` will copy in one call

_Each entry costs roughly 50,000 gas to write into the wallet, so a full batch is around
     2,500,000. The limit is about keeping a failed batch cheap to retry rather than about
     the block limit, which is 30,000,000 at its tightest across the deployment chains.
     Refused rather than clamped, so a caller never believes it wrote more than it did._

### MAX_ESIM_WALLETS_PER_CALL

```solidity
uint256 MAX_ESIM_WALLETS_PER_CALL
```

Most eSIM wallets a single call will deploy for one device

_A deployment costs roughly 500,000 gas per eSIM wallet, so a full batch is around
     10,000,000. As with the history cap this is set for retry cost rather than the block
     limit: a batch that runs out of gas is paid for and thrown away, and a device with forty
     eSIMs should not lose a whole block's worth of gas to one bad estimate. It also leaves
     room for `forge coverage --ir-minimum`, which inflates the same call by about a fifth.
     Refused rather than clamped, so a caller never believes it deployed more than it did._

### registry

```solidity
contract Registry registry
```

Registry contract instance

### deviceIdentifierToESIMDetails

```solidity
mapping(string => mapping(string => struct DataBundleDetails[])) deviceIdentifierToESIMDetails
```

eSIM identifiers and their details associated with the device identifiers

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

List of eSIM identifiers associated with the device identifiers

### historyEntriesCopied

```solidity
mapping(string => uint256) historyEntriesCopied
```

How many of an eSIM's stored purchase entries have already reached its wallet

_The wallet appends whatever batch it is handed, so this is the only thing stopping a
     repeated call from writing the same entries twice. Reading it rather than taking start
     and end indexes from the caller also makes two admin transactions in flight at once
     safe: the second reads the position the first left._

### lazyDeployedESIMWallet

```solidity
mapping(string => address) lazyDeployedESIMWallet
```

The eSIM wallet this contract deployed for an eSIM identifier

_Nothing enforces that an eSIM identifier is unique across eSIM wallets, so without this
     record a wallet deployed through the ordinary route could claim an identifier that
     already belongs to a lazy user and receive their purchase history. Written from the
     addresses the deployment returns, and unaffected by any later ownership transfer, so
     the copy follows the wallet rather than whichever device is holding it._

### eSIMWalletsDeployed

```solidity
mapping(string => uint256) eSIMWalletsDeployed
```

How many of a device's eSIM wallets this contract has already deployed

_Also the marker for the lazy route itself. The first batch always deploys at least one
     wallet, so a non-zero value means this contract set the device up. Reading the registry
     for a device wallet instead would accept one deployed through the ordinary route under
     an identifier a lazy user's eSIMs are already bound to, and hand that device their
     wallets._

### lazyDeploymentSalt

```solidity
mapping(string => uint256) lazyDeploymentSalt
```

Salt the device's first deployment batch started from

_Every later batch derives its salts from this, so the sequence continues rather than
     restarting on an address that already holds a wallet. Stored rather than taken from the
     caller again, because a value that disagrees with the first batch is not something the
     contract can detect: it just produces different addresses._

### DataUpdatedForDevice

```solidity
event DataUpdatedForDevice(string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, struct DataBundleDetails[] _dataBundleDetails)
```

Emitted when data related to a device is updated

### ESIMBindedWithDevice

```solidity
event ESIMBindedWithDevice(string _eSIMUniqueIdentifier, string _deviceUniqueIdentifier)
```

Emitted when an eSIM identifier is associated with a device identifier

### LazyWalletDeployed

```solidity
event LazyWalletDeployed(bytes32[2] _deviceOwnerPublicKey, address deviceWallet, string _deviceUniqueIdentifier, address[] eSIMWallets, string[] _eSIMUniqueIdentifiers)
```

Emitted when the Lazy wallet is deployed

_The device wallet is indexed so an indexer can follow one device without reading every
     log. The two string arrays are left unindexed on purpose: indexing a dynamic type stores
     its hash instead of its value, which no consumer of these can use._

### LazyESIMWalletsDeployed

```solidity
event LazyESIMWalletsDeployed(string _deviceUniqueIdentifier, address _deviceWallet, address[] _eSIMWallets, string[] _eSIMUniqueIdentifiers, uint256 _remaining)
```

Emitted for every batch of eSIM wallets deployed for a device, including the first.
        `_remaining` reaching zero is what says the device is fully deployed.

_`LazyWalletDeployed` fires once, when the device wallet itself is created, and carries
     only the first batch. Anything waiting for the whole set has to follow this instead._

### LazyHistoryCopied

```solidity
event LazyHistoryCopied(string _eSIMIdentifier, address _eSIMWallet, uint256 _copied, uint256 _remaining)
```

Emitted for every batch of purchase history copied into a deployed eSIM wallet.
        `_remaining` reaching zero is what says the copy is finished.

### ESIMIdentifierSwitchedToNewDeviceIdentifier

```solidity
event ESIMIdentifierSwitchedToNewDeviceIdentifier(string _eSIMIdentifier, string _oldDeviceIdentifier, string currentDeviceIdentifier)
```

Emitted when the user switches eSIM to a new device

### NewDeviceIdentifierAssociatedWithESIMIdentifier

```solidity
event NewDeviceIdentifierAssociatedWithESIMIdentifier(string _eSIMIdentifier, string _oldDeviceIdentifier, string _newDeviceIdentifier)
```

Emitted when the device identifier associated with an eSIM identifier is updated

### DataBundleDetailsTransferredToNewDeviceIdentifier

```solidity
event DataBundleDetailsTransferredToNewDeviceIdentifier(string _newDeviceIdentifier, struct DataBundleDetails[] _newDataBundleDetails)
```

Emitted when the Data bundle related details of an eSIM are transferred to a new device identifier

### DataBundleDetailsDeletedFromOldDeviceIdentifier

```solidity
event DataBundleDetailsDeletedFromOldDeviceIdentifier(string _oldDeviceIdentifier, string _eSIMIdentifier)
```

Emitted when the data bundle details are deleted from the old device identifier

### ESIMIdentifierRemovedFromOldDeviceIdentifier

```solidity
event ESIMIdentifierRemovedFromOldDeviceIdentifier(string _oldDeviceIdentifier, string _eSIMIdentifier, string[] _eSIMIdentifierOfOldDevice)
```

Emitted when an eSIM identifier is removed from a device identifier's list

### ESIMIdentifierAddedToNewDeviceIdentifier

```solidity
event ESIMIdentifierAddedToNewDeviceIdentifier(string _newDeviceIdentifier, string _eSIMIdentifier, string[] _eSIMIdentifierOfNewDevice)
```

Emitted when an eSIM identifier is added to a new device identifier's list

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
```

Restricts a call to the eSIM wallet admin

_Read from the registry on every call, so a rotation there takes effect immediately.
     Every state-changing function in this contract sits behind it._

### constructor

```solidity
constructor() public
```

_Locks the implementation contract itself. Without this, anyone can call initialize
     directly on the implementation and own it. The proxy is unaffected either way, but an
     owned implementation is a trap for any later upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _registry, address _upgradeManager) external
```

Points this contract at the registry and hands ownership to the upgrade manager

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registry | address | Registry this contract reads the admin from and deploys wallets through |
| _upgradeManager | address | Admin address responsible for upgrading contracts |

### batchPopulateHistory

```solidity
function batchPopulateHistory(string[] _deviceUniqueIdentifiers, string[][] _eSIMUniqueIdentifiers, struct DataBundleDetails[][] _dataBundleDetails) external
```

Function to populate all the device and eSIM related data along with the data bundles

_Refused for any device that already has a wallet, which is what freezes a device's eSIM
     list and its history for the whole time a deployment is walking them._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | List of device unique identifiers associated with the eSIM related data |
| _eSIMUniqueIdentifiers | string[][] | 2D array of all the eSIMs corresponding to their device identifiers. |
| _dataBundleDetails | struct DataBundleDetails[][] | 2D array of all the new data bundles bought for the respective eSIMs |

### deployLazyWalletAndSetESIMIdentifier

```solidity
function deployLazyWalletAndSetESIMIdentifier(bytes32[2] _deviceOwnerPublicKey, string _deviceUniqueIdentifier, uint256 _salt, uint256 _depositAmount, uint256 _maxWallets) external payable returns (address deviceWallet, address[] eSIMWallets, uint256 remaining)
```

Deploys a device wallet and the first batch of its eSIM wallets, setting their identifiers

_Only the first `_maxWallets` eSIM wallets are deployed here. Anything left goes through
     `deployMoreESIMWalletsForLazyDevice`, because one transaction carrying every wallet grew
     without bound with the eSIM count and stopped fitting in a block somewhere past forty.

     The device wallet is usable the moment this returns. Its eSIM wallets are complete and
     independent of each other, so holding it back until the last one lands would mean one
     dropped transaction leaves the user with nothing rather than with most of what they
     bought. Switching an eSIM to another device is refused for the whole time the rest are
     outstanding, which `switchESIMIdentifierToNewDeviceIdentifier` already does by refusing
     any device that has a wallet._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceOwnerPublicKey | bytes32[2] | P256 public key of the device owner |
| _deviceUniqueIdentifier | string | Unique device identifier associated with the device |
| _salt | uint256 | Salt the whole deployment derives its eSIM wallet addresses from |
| _depositAmount | uint256 | Amount of ETH to be deposited in the device wallet |
| _maxWallets | uint256 | Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| deviceWallet | address | Address of the deployed device wallet |
| eSIMWallets | address[] | eSIM wallets this call deployed, in the order of the device's identifiers |
| remaining | uint256 | eSIM wallets still waiting after this call |

### deployMoreESIMWalletsForLazyDevice

```solidity
function deployMoreESIMWalletsForLazyDevice(string _deviceUniqueIdentifier, uint256 _maxWallets) external returns (address[] eSIMWallets, uint256 remaining)
```

Deploys the next batch of eSIM wallets for a device already set up by the lazy route

_Call it repeatedly until it reverts `AllESIMWalletsDeployed`, which is the terminal
     condition rather than a failure. Reverting instead of returning quietly is what lets a
     caller loop on it. The cursor is read here rather than taken as an argument, so a
     dropped transaction is retried by repeating the same call.

     No pause check and no deposit. This moves no ETH, and the identifier list it walks was
     frozen when the device wallet appeared: `_populateHistory` refuses a device that already
     has one, so nothing can be appended to the list under a running deployment._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Device whose remaining eSIM wallets are being deployed |
| _maxWallets | uint256 | Most eSIM wallets to deploy here, at most MAX_ESIM_WALLETS_PER_CALL |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| eSIMWallets | address[] | eSIM wallets this call deployed, in the order of the device's identifiers |
| remaining | uint256 | eSIM wallets still waiting after this call |

### setHistoryForLazyWallet

```solidity
function setHistoryForLazyWallet(string _eSIMIdentifier, uint256 _maxEntries) external returns (uint256 copied, uint256 remaining)
```

Copies the next batch of an eSIM's stored purchase history into its deployed wallet

_Split out of the deployment because carrying history there made one transaction grow
     with the eSIM count and the history length at the same time. Call it repeatedly until
     it reverts `HistoryAlreadyCopied`, which is the terminal condition rather than a
     failure. Reverting instead of returning quietly is what lets a caller loop on it.

     No pause check. This moves no ETH, and the entries it writes were frozen when the
     wallet was deployed: `_populateHistory` refuses a device that already has one._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMIdentifier | string | eSIM whose history is being copied |
| _maxEntries | uint256 | Most entries to copy in this call, at most MAX_HISTORY_ENTRIES_PER_CALL |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| copied | uint256 | Entries written by this call |
| remaining | uint256 | Entries still waiting after this call |

### switchESIMIdentifierToNewDeviceIdentifier

```solidity
function switchESIMIdentifierToNewDeviceIdentifier(string _eSIMIdentifier, string _oldDeviceIdentifier, string _newDeviceIdentifier) external returns (bool)
```

This function should be called when the fiat user wants to switch their eSIM to a new device

_Only ever before deployment. Once a wallet exists onchain, the onchain graph is the
     record and the eSIM moves through ESIMWallet's ownership transfer instead._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMIdentifier | string | unique eSIM identifier that needs to be switched to a new device |
| _oldDeviceIdentifier | string | device identifier that the eSIM is currently associated with |
| _newDeviceIdentifier | string | new device identifier that the eSIM needs to be switched to |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool Returns `true` if the switching of eSIM was successful |

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

### _populateHistory

```solidity
function _populateHistory(string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, struct DataBundleDetails[] _dataBundleDetails) internal
```

Records one device's eSIM identifiers and the purchases made against them

_`_eSIMUniqueIdentifiers` may repeat an identifier, since one eSIM can have several
     purchases. An identifier already bound to a different device is refused._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Device the purchases belong to |
| _eSIMUniqueIdentifiers | string[] | One entry per purchase, naming the eSIM it was made for |
| _dataBundleDetails | struct DataBundleDetails[] | The purchases themselves, aligned with the identifiers |

### _moveESIMPurchaseHistory

```solidity
function _moveESIMPurchaseHistory(string _eSIMIdentifier, string _oldDeviceIdentifier, string _newDeviceIdentifier) internal
```

Moves what an eSIM bought to the device taking it over

_Carries the purchase entries themselves. Its counterpart
     `_moveESIMIdentifierBetweenDeviceLists` carries the membership record saying the eSIM
     exists at all, and a switch needs both._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMIdentifier | string | eSIM being switched |
| _oldDeviceIdentifier | string | Device it is leaving |
| _newDeviceIdentifier | string | Device it is joining |

### _moveESIMIdentifierBetweenDeviceLists

```solidity
function _moveESIMIdentifierBetweenDeviceLists(string _eSIMIdentifier, string _oldDeviceIdentifier, string _newDeviceIdentifier) internal
```

Moves an eSIM identifier between the two devices' lists

_Carries the membership record, which is what a deployment walks to know an eSIM exists.
     Its counterpart `_moveESIMPurchaseHistory` carries the purchases. The removal is a swap
     with the last element and a pop, so the old device's list keeps its members but not
     their order._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMIdentifier | string | eSIM being switched |
| _oldDeviceIdentifier | string | Device it is leaving |
| _newDeviceIdentifier | string | Device it is joining |

### upgradeManager

```solidity
function upgradeManager() public view returns (address)
```

Address (owned/controlled by eSIM wallet project) that can upgrade contracts

_Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
     gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
     copy could only ever disagree with it._

### outstandingHistoryEntries

```solidity
function outstandingHistoryEntries(string _eSIMIdentifier) external view returns (uint256)
```

How many history entries are still waiting to be copied into this eSIM's wallet

_Needed because the public getter on `deviceIdentifierToESIMDetails` takes an index and
     never returns a length, so nothing outside this contract can count the entries.
     Returns zero for an eSIM this contract never handled, which has nothing waiting anyway._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMIdentifier | string | eSIM being asked about |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Entries still waiting to be copied |

### isDeviceIdentifierReserved

```solidity
function isDeviceIdentifierReserved(string _deviceUniqueIdentifier) public view returns (bool)
```

Whether a device identifier has purchases recorded against it here

_The ordinary deployment route asks this before taking an identifier, since a wallet
     created under a reserved one strands every eSIM bound to it: the deploy, the history
     copy and the device switch all refuse an identifier that has a wallet.

     Stays true once the lazy deployment finishes. Harmless, since the registry's own
     identifier check refuses the second claim by then, and clearing it would mean walking
     the whole list._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Device identifier being checked |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if a lazy user is waiting on this identifier |

### isESIMIdentifierReserved

```solidity
function isESIMIdentifierReserved(string _eSIMUniqueIdentifier) public view returns (bool)
```

Whether an eSIM identifier is bound to a device here

_The registry refuses a claim on a reserved identifier from any device but the one that
     reserved it, and reads `eSIMIdentifierToDeviceIdentifier` itself to make that
     comparison. This is the plain question, for a caller that only wants the fact._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMUniqueIdentifier | string | eSIM identifier being checked |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if a lazy user is waiting on this identifier |

