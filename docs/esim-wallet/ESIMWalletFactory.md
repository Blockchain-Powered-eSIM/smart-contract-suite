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

_Every eSIM wallet proxy reads its implementation from here, so one change moves them all._

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

_A device wallet calling directly may only deploy for itself (checked in the function).
     This also means the admin gate on `DeviceWallet.deployESIMWallet` is not a boundary: an
     owner can `execute` straight here. Deliberate, since nothing here can tell which of the
     owner's signed calls led to this one._

### constructor

```solidity
constructor() public
```

Disables initializers on the implementation contract

_Otherwise anyone could initialize and own the implementation. The proxy is unaffected,
     but an owned implementation is a trap for a later upgrade that adds an outward call._

### initialize

```solidity
function initialize(address _eSIMWalletImplementation, address _upgradeManager) external
```

Deploys the beacon and hands ownership of this factory to the upgrade manager

_The factory owns the beacon, so the only way to move the implementation is the
     owner-gated `updateESIMWalletImplementation`, which emits an event._

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

_A protocol-wide upgrade: every eSIM wallet moves at once and none can decline._

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

_The owner is the only one who can upgrade this factory or the beacon, so renouncing
     would freeze every eSIM wallet on its current logic._

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

