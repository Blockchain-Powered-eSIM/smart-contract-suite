# Solidity API

## DeviceWalletFactory

Deploys device wallets at deterministic addresses and owns the beacon they all point at

_A UUPS singleton with two deployment routes. The admin batch route deploys a wallet, its
     first eSIM wallet and the registry records together. The EntryPoint route, `createAccount`,
     writes no external storage at all, so a wallet created that way is registered afterwards
     through `postCreateAccount`. Both land on the same CREATE2 address for the same inputs._

### beacon

```solidity
contract UpgradeableBeacon beacon
```

Upgradeable beacon that points to correct Device wallet implementation

_Every device wallet is a beacon proxy reading its implementation from here, so one
     update moves all of them at once and none can decline it._

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

_Locks the implementation contract itself. Without this, anyone can call initialize
     directly on the implementation, own it, and make it deploy a beacon it controls. The
     proxy is unaffected either way, but an owned implementation is a trap for any later
     upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _deviceWalletImplementation, address _upgradeManager, address _eSIMWalletFactoryAddress, contract IEntryPoint _entryPoint, contract P256Verifier _verifier) external
```

Deploys the beacon and hands ownership of this factory to the upgrade manager

_Neither the admin nor the vault is taken here. Both come from the registry, which is
     added afterwards through addRegistryAddress, so admin functions stay closed until that
     is done and every payment reads one address._

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

Allow the owner to add the registry contract after it has been deployed

_Write-once, and the owner rather than the admin, because the admin is read from the
     registry and there is no admin to check against until this call lands. Matches
     ESIMWalletFactory, which has always gated its own version on the owner._

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

Function to update the device wallet implementation

_Moves every device wallet in the protocol at once. Treat any change here as a
     protocol-wide upgrade, since no wallet can decline it._

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

To deploy multiple device wallets at once

_Each entry deploys a device wallet, its first eSIM wallet and the registry records in
     one go. ETH left over once the batch has been funded is returned to the caller._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifiers | string[] | Array of unique device identifiers for each device wallet |
| _deviceWalletOwnersKey | bytes32[2][] | Array of P256 public keys of owners of the respective device wallets |
| _salts | uint256[] | Array of CREATE2 salts, one per device wallet |
| _depositAmounts | uint256[] | Array of all the ETH to be deposited into each of the device wallets |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct Wallets[] | Array of deployed device wallet address |

### postCreateAccount

```solidity
function postCreateAccount(address _deviceWallet, string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt) external
```

Records a wallet the EntryPoint deployed through createAccount

_Not needed on the admin batch route, which writes the registry itself. Callable by the
     admin directly and by the registry on the lazy deployment path.

     The wallet was not deployed in this call, so nothing binds the arguments to it. The
     re-derivation does: the key and the identifier are proxy constructor arguments, so an
     address matching the derivation and holding code was deployed here with exactly those._

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

_Called by the EntryPoint during a user operation, so it must not read or write any
     other contract's storage: that is barred by the ERC-4337 validation rules. The registry
     is therefore not consulted here and not written, and `postCreateAccount` records the
     wallet afterwards. Validation the registry would have done happens offchain, through
     `preCreateAccountValidation`.

     Returning an existing address rather than reverting is what makes
     `entryPoint.getSenderAddress()` keep working once the account has been created._

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

_The owner is the only caller _authorizeUpgrade accepts, and this contract owns the
     beacon, so it is also the only route to updateDeviceWalletImplementation. Renouncing
     would freeze every device wallet on its current logic permanently._

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
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwnerKey | bytes32[2] | User's P256 public key (owner of the device wallet and respective eSIM wallets) |
| _salt | uint256 | CREATE2 salt for both wallets |
| _depositAmount | uint256 | Amount of ETH to be deposited into the device wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct Wallets | Deployed device wallet address |
| [1] | uint256 | ETH actually forwarded to the wallet, zero if an existing wallet was returned |

### _createAccountForUser

```solidity
function _createAccountForUser(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey, uint256 _salt, uint256 _depositAmount) internal returns (contract DeviceWallet deviceWallet, uint256 spentETH)
```

Deploys a device wallet and writes its registry records, or adopts one that already exists

_Returns the ETH actually forwarded to the wallet, which is zero whenever an existing
     wallet is returned instead of a new one being deployed. Callers holding a budget must
     decrement by this value, not by the requested deposit._

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

_Held by the registry, which is where it is rotated, so this contract cannot fall
     behind the rest of the protocol after a rotation. Answers address(0) before the
     registry is wired up, which no caller can match, so admin functions stay closed until
     then rather than reverting on a call into address(0)._

### preCreateAccountValidation

```solidity
function preCreateAccountValidation(string _deviceUniqueIdentifier, bytes32[2] _deviceWalletOwnerKey) public view returns (address wallet)
```

Checks that all the input params needed for deploying a fresh device wallet are valid

_This is needed when deploying the device wallet via the EntryPoint using userops_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceUniqueIdentifier | string | Unique device identifier for the device wallet |
| _deviceWalletOwnerKey | bytes32[2] | User's P256 public key (owner of the device wallet and respective eSIM wallets) |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| wallet | address | address(0) if valid. device wallet address for any existing wallet |

### getCounterFactualAddress

```solidity
function getCounterFactualAddress(bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, uint256 _salt) public view returns (address)
```

The address createAccount would deploy to for these inputs

_The owner key and the device identifier are part of the proxy's constructor arguments,
     so they are folded into the address alongside the salt. Changing any of them moves it._

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

