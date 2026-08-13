# Solidity API

## RegistryHelper

Storage and the lazy deployment paths that `Registry` inherits

_Split out so `Registry` holds the admin and pause logic while the mappings and the calls
     into the two factories live here. Only the lazy wallet registry reaches the functions in
     this file; everything else goes through `Registry` itself._

### lazyWalletRegistry

```solidity
address lazyWalletRegistry
```

Address of the Lazy wallet registry

### deviceWalletFactory

```solidity
contract DeviceWalletFactory deviceWalletFactory
```

Device wallet factory instance

### eSIMWalletFactory

```solidity
contract ESIMWalletFactory eSIMWalletFactory
```

eSIM wallet factory instance

### uniqueIdentifierToDeviceWallet

```solidity
mapping(string => address) uniqueIdentifierToDeviceWallet
```

Mapping for all the device wallets deployed by the registry

_Use this to check if a device identifier has already been used or not_

### deviceWalletToOwner

```solidity
mapping(address => bytes32[2]) deviceWalletToOwner
```

X,Y co-ordinates of the P256 keys associated with the device wallet

### registeredP256Keys

```solidity
mapping(bytes32 => address) registeredP256Keys
```

keccak256 hash to device wallet address

_keccak256(abi.encode(X, Y)) <> device wallet address
Used to maintain one-to-one relationship between P256 keys and device wallet_

### isDeviceWalletValid

```solidity
mapping(address => bool) isDeviceWalletValid
```

true if deployed by the registry or device wallet factory
        Mapping of all the device wallets deployed by the registry (or the device wallet factory) are set to true

### isESIMWalletValid

```solidity
mapping(address => address) isESIMWalletValid
```

All the eSIM wallets deployed using this registry are valid and mapped to their owner device wallet

_This is the registration record. A non-zero entry means the protocol deployed this eSIM
     wallet, and it stays non-zero for the rest of the wallet's life. Mid-transfer it names
     the device wallet that last held it, so it is never zero to mean "released"._

### isESIMWalletOnStandby

```solidity
mapping(address => bool) isESIMWalletOnStandby
```

If an existing eSIM wallet is in the process of being transferred from one device wallet to another

_If bool is `true`, the eSIM wallet is in a transient state. `isESIMWalletValid` still
     points at the old device wallet. Do not use this mapping to check whether an eSIM
     wallet belongs to the protocol; that is what `isESIMWalletValid` is for. Its job is to
     hold transactions on this eSIM wallet until it reads false again, meaning the new
     device wallet has accepted it._

### LazyWalletDeployed

```solidity
event LazyWalletDeployed(address _deviceWallet, string _deviceUniqueIdentifier, address _eSIMWallet, string _eSIMUniqueIdentifier)
```

Emitted for each eSIM wallet deployed on behalf of the lazy wallet registry

### DeviceWalletInfoUpdated

```solidity
event DeviceWalletInfoUpdated(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey)
```

Emitted when a device wallet is first recorded, with its identifier and owner key

### DeviceWalletOwnerKeyUpdated

```solidity
event DeviceWalletOwnerKeyUpdated(address _deviceWallet, bytes32[2] _oldOwnerKey, bytes32[2] _newOwnerKey)
```

Emitted when a device wallet rotates the P256 key that owns it

### UpdatedDeviceWalletassociatedWithESIMWallet

```solidity
event UpdatedDeviceWalletassociatedWithESIMWallet(address _eSIMWalletAddress, address _deviceWalletAddress)
```

Emitted when an eSIM wallet is bound to a device wallet

### UpdatedLazyWalletRegistryAddress

```solidity
event UpdatedLazyWalletRegistryAddress(address _lazyWalletRegistry)
```

Emitted when the owner points the registry at the lazy wallet registry

### RegistryInitialized

```solidity
event RegistryInitialized(address _eSIMWalletAdmin, address _vault, address _upgradeManager, address _deviceWalletFactory, address _eSIMWalletFactory)
```

Emitted once, when the registry is initialised

### AdminUpdateRequested

```solidity
event AdminUpdateRequested(address eSIMWalletAdmin, address _newAdmin)
```

Emitted when the owner nominates a new address for the admin role

_The incumbent is powerless from here until the nominee accepts, so a reader following
     the admin has to treat this as the moment the role went dormant._

### AdminUpdated

```solidity
event AdminUpdated(address _newAdmin)
```

Emitted when the newly requested admin accepts the role

### AdminUpdateRevoked

```solidity
event AdminUpdateRevoked(address _caller, address _revokedAddress)
```

Emitted when the owner withdraws an outstanding nomination

### AdminDisabled

```solidity
event AdminDisabled(address _adminOfRecord, address _caller)
```

Emitted when the admin's powers are suspended, naming the address left on the books

### AdminEnabled

```solidity
event AdminEnabled(address _adminOfRecord, address _caller)
```

Emitted when a suspended admin is given its powers back

### VaultAddressUpdated

```solidity
event VaultAddressUpdated(address _updatedVaultAddress)
```

Emitted when the owner points data bundle payments at a different vault

### Paused

```solidity
event Paused(address _admin)
```

Emitted when the admin stops the ETH-moving paths protocol-wide

### Unpaused

```solidity
event Unpaused(address _owner)
```

Emitted when the owner releases the pause

### DefaultDataBundlePriceCapUpdated

```solidity
event DefaultDataBundlePriceCapUpdated(uint256 _cap)
```

Emitted when the owner changes the price ceiling eSIM wallets fall back to

### ESIMWalletSetOnStandby

```solidity
event ESIMWalletSetOnStandby(address _eSIMWalletAddress, bool _isOnStandby, address _deviceWalletAddress)
```

Emitted when an eSIM wallet's outstanding transfer is raised or settled

### onlyLazyWalletRegistry

```solidity
modifier onlyLazyWalletRegistry()
```

Restricts a call to the lazy wallet registry

### deployLazyWallet

```solidity
function deployLazyWallet(bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt, string[] _eSIMUniqueIdentifiers, uint256 _depositAmount) external payable returns (address, address[])
```

Allow LazyWalletRegistry to deploy a device wallet and its first eSIM wallets

_Deploys the wallets and sets their identifiers only. Purchase history is copied in
     afterwards through `populateLazyHistory`, because carrying it here made one transaction
     grow with the eSIM count and each eSIM's history at the same time.

     `_eSIMUniqueIdentifiers` is the first batch rather than the device's whole list, and any
     identifier past it reaches `deployMoreLazyESIMWallets`. The lazy wallet registry owns
     the cursor deciding where one batch ends and the next begins, and it reserves the whole
     salt range before this runs, so no bound on the salt is needed here._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletOwnerKey | bytes32[2] | P256 public key of user |
| _deviceUniqueIdentifier | string | Unique device identifier associated with the device |
| _salt | uint256 | CREATE2 salt the device wallet and its first eSIM wallet are deployed at |
| _eSIMUniqueIdentifiers | string[] | First batch of eSIM identifiers, in the order the full list holds them |
| _depositAmount | uint256 | ETH forwarded to the new device wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Return device wallet address and the eSIM wallet addresses this call deployed |
| [1] | address[] |  |

### deployMoreLazyESIMWallets

```solidity
function deployMoreLazyESIMWallets(address _deviceWallet, string _deviceUniqueIdentifier, uint256 _baseSalt, uint256 _startIndex, string[] _eSIMUniqueIdentifiers) external returns (address[])
```

Deploys the next batch of eSIM wallets for a device the lazy registry already set up

_Separate from `deployLazyWallet` because that call deploys the device wallet itself, and
     the owner key, salt and deposit it takes describe a one-time act. Reaching a device this
     way needs none of them, and repeating them would either be ignored or checked against a
     key the owner is free to rotate between batches.

     The salt continues from where the first batch stopped rather than starting over, because
     the eSIM wallet factory salts CREATE2 with it and a repeat would land on an address that
     already holds a wallet._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Device wallet the new eSIM wallets are bound to |
| _deviceUniqueIdentifier | string | Device identifier the wallets belong to |
| _baseSalt | uint256 | Salt the device's deployment started from |
| _startIndex | uint256 | Position of this batch's first identifier in the device's full list |
| _eSIMUniqueIdentifiers | string[] | This batch's identifiers, in the order the full list holds them |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] | Addresses of the eSIM wallets this call deployed |

### populateLazyHistory

```solidity
function populateLazyHistory(address _eSIMWallet, struct DataBundleDetails[] _dataBundleDetails) external
```

Forwards one batch of pre-deployment purchase history to an eSIM wallet on behalf of
        the lazy wallet registry

_eSIM wallets accept history from this contract and nothing else, so the copy is routed
     through here rather than giving them a second address to trust. The lazy wallet
     registry owns the cursor that decides which entries a batch carries._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWallet | address | Wallet receiving the batch |
| _dataBundleDetails | struct DataBundleDetails[] | One batch of data bundle purchase details |

### _deployLazyESIMWallet

```solidity
function _deployLazyESIMWallet(address _deviceWallet, string _deviceUniqueIdentifier, uint256 _salt, string _eSIMUniqueIdentifier) internal returns (address)
```

Deploys one eSIM wallet, binds it to the device wallet and sets its eSIM identifier

_Shared by the first batch and every batch after it so the two cannot drift apart. The
     identifier is known up front on this route, unlike the ordinary one, so setting it here
     saves the admin a second transaction per wallet._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Device wallet the eSIM wallet is bound to |
| _deviceUniqueIdentifier | string | Device identifier the wallet belongs to |
| _salt | uint256 | CREATE2 salt for this eSIM wallet |
| _eSIMUniqueIdentifier | string | Identifier written onto the new eSIM wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the eSIM wallet deployed |

### _updateDeviceWalletInfo

```solidity
function _updateDeviceWalletInfo(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) internal
```

Records a device wallet against its identifier and its owner key

_Writes all four mappings together, so a wallet is either fully recorded or not recorded._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Address of the device wallet |
| _deviceUniqueIdentifier | string | Identifier the wallet is reached by |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |

### _updateDeviceWalletOwnerKey

```solidity
function _updateDeviceWalletOwnerKey(address _deviceWallet, bytes32[2] _newOwnerKey) internal
```

Moves a device wallet's registry bindings from its current owner key to a new one

_The retired key comes from `deviceWalletToOwner` rather than from the caller, so a
     wallet cannot name a key it never held and free someone else's reservation. Clearing
     the old hash before checking the new one is what lets a wallet rotate onto the key it
     already holds: the clear removes its own reservation, so the check sees a free slot._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Wallet whose owner key is rotating |
| _newOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key taking over |

