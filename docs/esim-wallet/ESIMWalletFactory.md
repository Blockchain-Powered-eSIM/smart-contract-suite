# Solidity API

## ESIMWalletFactory

Deploys eSIM wallets and owns the beacon they all point at

_A UUPS singleton. It owns an `UpgradeableBeacon`, so one call here moves every eSIM wallet
     in the protocol onto new logic at once. There is no per-wallet opt-out._

### registry

```solidity
contract Registry registry
```

Address of the registry contract

### beacon

```solidity
contract UpgradeableBeacon beacon
```

Upgradeable beacon that points to the correct eSIM wallet logic contract

_Every eSIM wallet is a beacon proxy reading its implementation from here, so the
     implementation is replaced once rather than on each proxy:

     eSIM wallet beacon proxy ─┐
     eSIM wallet beacon proxy ─┼─> beacon ─> eSIM wallet implementation
     eSIM wallet beacon proxy ─┘_

### isESIMWalletDeployed

```solidity
mapping(address => bool) isESIMWalletDeployed
```

Set to true if eSIM wallet address is deployed using the factory, false otherwise

### ESIMWalletFactoryDeployed

```solidity
event ESIMWalletFactoryDeployed(address _upgradeManager, address _eSIMWalletImplementation, address _beacon)
```

Emitted when the eSIM wallet factory is deployed

### ESIMWalletDeployed

```solidity
event ESIMWalletDeployed(address _eSIMWalletAddress, address _deviceWalletAddress, address _caller)
```

Emitted when a new eSIM wallet is deployed

### ESIMWalletImplementationUpdated

```solidity
event ESIMWalletImplementationUpdated(address _newImplementation)
```

Emitted when the eSIM wallet implementation is updated

### AddedRegistry

```solidity
event AddedRegistry(address registry)
```

Emitted when the registry is added to the factory contract

### onlyRegistryOrDeviceWalletFactoryOrDeviceWallet

```solidity
modifier onlyRegistryOrDeviceWalletFactoryOrDeviceWallet()
```

Restricts a call to the registry, the device wallet factory or a known device wallet

_The first two deploy on behalf of a device wallet during setup. A device wallet reaching
     this directly is constrained further inside `deployESIMWallet`.

     That third caller is what makes `DeviceWallet.deployESIMWallet`'s admin gate a workflow
     convenience rather than a boundary: an owner can sign an `execute` straight at this
     function and get the same wallet with no admin in the call. Deliberate, since a device
     wallet reaches every external function through `execute` and no check downstream of its
     call can tell which of its owner's intents produced it._

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

_Locks the implementation contract itself. Without this, anyone can call initialize
     directly on the implementation, own it, and make it deploy a beacon it controls. The
     proxy is unaffected either way, but an owned implementation is a trap for any later
     upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _eSIMWalletImplementation, address _upgradeManager) external
```

Deploys the beacon and hands ownership of this factory to the upgrade manager

_The factory owns the beacon rather than the upgrade manager owning it directly, so the
     only way to move the implementation is `updateESIMWalletImplementation`, which is
     owner gated and emits an event._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletImplementation | address | First eSIM wallet logic contract the beacon points at |
| _upgradeManager | address | Admin address responsible for upgrading contracts |

### addRegistryAddress

```solidity
function addRegistryAddress(address _registryContractAddress) external returns (address)
```

Points the factory at the registry, which is deployed after it

_Write-once. Every caller check in this contract reads the registry, so allowing it to
     move would let a later owner redirect all of them at once._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registryContractAddress | address | Address of the registry |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The registry address now in force |

### deployESIMWallet

```solidity
function deployESIMWallet(address _deviceWalletAddress, uint256 _salt) external returns (address)
```

Deploys an eSIM wallet at a deterministic address and binds it to a device wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletAddress | address | Address of the associated device wallet |
| _salt | uint256 | CREATE2 salt, chosen by the caller and unique per wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | Address of the newly deployed eSIM wallet |

### getCounterFactualAddress

```solidity
function getCounterFactualAddress(address _deviceWalletAddress, uint256 _salt) public view returns (address)
```

The address deployESIMWallet would land on for these inputs

_Lets a caller probe a salt for occupancy before spending a deployment on it._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _deviceWalletAddress | address | Device wallet the eSIM wallet would be bound to |
| _salt | uint256 | CREATE2 salt |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The predicted eSIM wallet address |

### updateESIMWalletImplementation

```solidity
function updateESIMWalletImplementation(address _eSIMWalletImpl) external returns (address)
```

Update the eSIM wallet implementation address in the beacon contract

_Moves every eSIM wallet in the protocol at once. Treat any change here as a
     protocol-wide upgrade, since no wallet can decline it._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletImpl | address | Address of the new eSIM wallet implementation contract |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The implementation now in force |

### renounceOwnership

```solidity
function renounceOwnership() public pure
```

Ownership of this contract is never renounced

_The owner is the only caller _authorizeUpgrade accepts, and this contract owns the
     beacon, so it is also the only route to updateESIMWalletImplementation. Renouncing
     would freeze every eSIM wallet on its current logic permanently._

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal
```

Restricts UUPS upgrades of this factory to the owner

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newImplementation | address | Address of the implementation being moved to |

### getCurrentESIMWalletImplementation

```solidity
function getCurrentESIMWalletImplementation() public view returns (address)
```

The eSIM wallet logic contract every eSIM wallet currently runs

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The current implementation address |

