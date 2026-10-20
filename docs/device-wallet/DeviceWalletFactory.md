# Solidity API

## DeviceWalletFactory

Deploys device wallets at deterministic addresses and owns the beacon they all point at

_The admin batch route deploys and registers in one go. `createAccount` runs inside ERC-4337
     validation and writes no external storage, so `postCreateAccount` registers it afterwards.
     Both routes give the same CREATE2 address for the same inputs._

### beacon

```solidity
contract UpgradeableBeacon beacon
```

Beacon every device wallet proxy reads its implementation from

_One update moves every wallet at once, and none can decline it._

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

ERC-4337 EntryPoint singleton passed into every device wallet implementation

### verifier

```solidity
contract P256Verifier verifier
```

Contract the device wallets verify WebAuthn assertions through

### registry

```solidity
contract Registry registry
```

Registry contract instance

### eSIMWalletFactory

```solidity
contract ESIMWalletFactory eSIMWalletFactory
```

eSIM wallet factory contract instance

### deviceWalletInfoAdded

```solidity
mapping(address => bool) deviceWalletInfoAdded
```

Tracks all the device wallets that have their data added into the registry upon deployment

### DeviceWalletFactoryDeployed

```solidity
event DeviceWalletFactoryDeployed(address _upgradeManager, address _deviceWalletImplementation, address _beacon)
```

Emitted when factory is deployed

### DeviceWalletDeployed

```solidity
event DeviceWalletDeployed(address _deviceWalletAddress, address _eSIMWalletAddress, bytes32[2] _deviceWalletOwnerKey)
```

Emitted when a new device wallet is deployed

### DeviceWalletImplementationUpdated

```solidity
event DeviceWalletImplementationUpdated(address _newDeviceImplementation)
```

Emitted when the device wallet implementation is updated

### AddedRegistry

```solidity
event AddedRegistry(address registry)
```

Emitted when the registry is added to the factory contract

### onlyAdminOrRegistry

```solidity
modifier onlyAdminOrRegistry()
```

Restricts a call to the eSIM wallet admin or the registry

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

_Otherwise anyone could initialize and own the implementation itself. The proxy is
     unaffected, but an owned implementation is a trap for a later upgrade that adds an
     outward call._

### initialize

```solidity
function initialize(address _deviceWalletImplementation, address _upgradeManager, address _eSIMWalletFactoryAddress, contract IEntryPoint _entryPoint, contract P256Verifier _verifier) external
```

Deploys the beacon and hands ownership of this factory to the upgrade manager

_The admin and the vault are read from the registry, set later by addRegistryAddress,
     so there is one source for each. Admin functions stay closed until then._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletImplementation | address | First device wallet logic contract the beacon points at |
| _upgradeManager | address | Admin address responsible for upgrading contracts |
| _eSIMWalletFactoryAddress | address | Factory the device wallets deploy their eSIM wallets through |
| _entryPoint | contract IEntryPoint | ERC-4337 EntryPoint singleton for this chain |
| _verifier | contract P256Verifier | Contract the device wallets verify WebAuthn assertions through |

### addRegistryAddress

```solidity
function addRegistryAddress(address _registryContractAddress) external returns (address)
```

Sets the registry, once, after it has been deployed

_Gated on the owner because the admin is read from the registry, so there is no admin
     to check until this lands. Same as ESIMWalletFactory._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registryContractAddress | address | Address of the registry |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The registry address now in force |

### updateDeviceWalletImplementation

```solidity
function updateDeviceWalletImplementation(address _newDeviceImpl) external returns (address)
```

Points the beacon at a new device wallet implementation

_A protocol-wide upgrade: every device wallet moves at once and none can decline it._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newDeviceImpl | address | Address of the new device implementation contract |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The implementation now in force |

### deployDeviceWalletForUsers

```solidity
function deployDeviceWalletForUsers(string[] _deviceUniqueIdentifiers, bytes32[2][] _deviceWalletOwnersKey, uint256[] _salts, uint256[] _depositAmounts) external payable returns (struct Wallets[])
```

Deploys device wallets, each with its first eSIM wallet and registry records

_Unspent ETH is returned to the caller. Refused while paused, since it moves ETH._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | Device identifier per wallet |
| _deviceWalletOwnersKey | bytes32[2][] | Owner P256 public key per wallet |
| _salts | uint256[] | CREATE2 salt per wallet |
| _depositAmounts | uint256[] | ETH to deposit per wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct Wallets[] | The deployed device and eSIM wallet addresses |

### postCreateAccount

```solidity
function postCreateAccount(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) external
```

Records a wallet the EntryPoint deployed through createAccount

_The key and identifier are proxy constructor arguments, so an address that matches the
     derivation and holds code was deployed by this factory with exactly those arguments._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWallet | address | Wallet that was deployed |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |
| _salt | uint256 | CREATE2 salt the wallet was deployed with |

### createAccount

```solidity
function createAccount(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) public payable returns (contract DeviceWallet deviceWallet)
```

Deploys a device wallet, returning the existing one if that address already holds it

_Runs in ERC-4337 validation, so it leaves the registry to `postCreateAccount`. Reading
     its own and the beacon's storage needs a staked factory. Returning an existing wallet
     instead of reverting keeps `entryPoint.getSenderAddress()` working after creation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |
| _salt | uint256 | CREATE2 salt for the wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| deviceWallet | contract DeviceWallet | The wallet at the computed address, new or already deployed |

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

Ownership of this contract is never renounced

_The owner alone upgrades this factory and the beacon, so renouncing would freeze every
     device wallet on its current logic for good._

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

Restricts UUPS upgrades of this factory to the owner

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Address of the implementation being moved to |

### _deployDeviceWallet

```solidity
function _deployDeviceWallet(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt, uint256 _depositAmount) internal returns (struct Wallets, uint256)
```

Deploys one device wallet, its first eSIM wallet and the binding between them

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _deviceWalletOwnerKey | bytes32[2] | Owner P256 public key of the device and eSIM wallets |
| _salt | uint256 | CREATE2 salt for both wallets |
| _depositAmount | uint256 | ETH to deposit into the device wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct Wallets | The device and eSIM wallet addresses |
| [1] | uint256 | ETH actually forwarded, zero if an already registered wallet was returned |

### _createAccountForUser

```solidity
function _createAccountForUser(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt, uint256 _depositAmount) internal returns (contract DeviceWallet deviceWallet, uint256 spentETH)
```

Deploys a device wallet and writes its registry records, or adopts one that already exists

_Callers holding a budget must charge `spentETH`, not the requested deposit. It is zero
     for an already registered wallet, and the full deposit for a new or adopted one._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |
| _salt | uint256 | CREATE2 salt for the wallet |
| _depositAmount | uint256 | ETH the caller asked to be deposited |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| deviceWallet | contract DeviceWallet | The wallet at the computed address |
| spentETH | uint256 | ETH actually forwarded to it |

### eSIMWalletAdmin

```solidity
function eSIMWalletAdmin() public view returns (address)
```

Admin address of the eSIM wallet project

_Read from the registry so a rotation there applies here too. Returns address(0), which
     no caller matches, until the registry is set, rather than calling into address(0)._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The current admin, or zero if the registry is not yet wired up |

### preCreateAccountValidation

```solidity
function preCreateAccountValidation(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) public view returns (address wallet)
```

Checks the inputs for a fresh device wallet against the registry

_For use before `createAccount`, which cannot read the registry itself_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _deviceWalletOwnerKey | bytes32[2] | Owner P256 public key of the device and eSIM wallets |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| wallet | address | address(0) if both are free, else the wallet already holding one of them |

### getCounterFactualAddress

```solidity
function getCounterFactualAddress(bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt) public view returns (address)
```

The address createAccount would deploy to for these inputs

_The key and identifier are proxy constructor arguments, so changing either, or the
     salt, moves the address._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning the wallet |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _salt | uint256 | CREATE2 salt |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The predicted device wallet address |

### getCurrentDeviceWalletImplementation

```solidity
function getCurrentDeviceWalletImplementation() public view returns (address)
```

The device wallet logic contract every device wallet currently runs

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The current implementation address |

