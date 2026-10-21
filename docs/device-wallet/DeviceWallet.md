# Solidity API

## DeviceWallet

A user's device: an ERC-4337 account that owns the eSIM wallets bought for that device

Beacon proxy owned by the user's P256 key. Key rotation also updates the registry, so
     the two records cannot drift apart.

### registry

```solidity
contract Registry registry
```

Registry contract instance

### eSIMWalletFactory

```solidity
contract ESIMWalletFactory eSIMWalletFactory
```

eSIM wallet factory address

### deviceUniqueIdentifier

```solidity
string deviceUniqueIdentifier
```

String identifier to uniquely identify user's device

### isValidESIMWallet

```solidity
mapping(address => bool) isValidESIMWallet
```

Set to true if the eSIM wallet belongs to this device wallet

### canPullFunds

```solidity
mapping(address => bool) canPullFunds
```

Tracks if an associated eSIM wallet may pull this wallet's tokens

One flag for all tokens: a wallet trusted with funds can drain them anyway, so
     per-token flags would cost signatures and limit nothing.

### FundsAccessUpdated

```solidity
event FundsAccessUpdated(address _eSIMWalletAddress, bool _hasAccessToFunds)
```

Emitted when owner updates an eSIM wallet's access to this wallet's money

### TokenSent

```solidity
event TokenSent(address _token, address _eSIMWalletAddress, uint256 _amount)
```

Emitted when an associated eSIM wallet pulls an ERC-20 from this wallet

### ESIMWalletAdded

```solidity
event ESIMWalletAdded(address _eSIMWalletAddress, bool _hasAccessToFunds, address _caller)
```

Emitted when eSIM wallet is added to this Device Wallet

### ESIMWalletRemoved

```solidity
event ESIMWalletRemoved(address _eSIMWalletAddress, address _deviceWalletAddress, address _caller)
```

Emitted when the eSIM wallet is removed from this Device Wallet

### NoETHToCallback

```solidity
event NoETHToCallback()
```

Emitted when the eSIM wallet being removed has no ETH to call back

### ETHCalledBack

```solidity
event ETHCalledBack(uint256 _amount)
```

Emitted when the eSIM being removed sends back ETH to this device wallet

### onlyRegistryOrDeviceWalletFactoryOrOwner

```solidity
modifier onlyRegistryOrDeviceWalletFactoryOrOwner(address _eSIMWalletAddress)
```

Restricts a call to the registry, the device wallet factory, this wallet itself, or
        the named eSIM wallet re-adding itself

### onlySelfOrESIMWalletBeingRemoved

```solidity
modifier onlySelfOrESIMWalletBeingRemoved(address _eSIMWalletAddress)
```

Restricts a call to this wallet itself or to the eSIM wallet being removed

### onlyAssociatedESIMWallets

```solidity
modifier onlyAssociatedESIMWallets()
```

Restricts a call to an eSIM wallet this device wallet holds

### onlyESIMWalletAdmin

```solidity
modifier onlyESIMWalletAdmin()
```

Restricts a call to the eSIM wallet admin

Read from the registry on every call, so a rotation there takes effect immediately.

### constructor

```solidity
constructor(contract IEntryPoint anEntryPoint, contract P256Verifier _verifier) public
```

Wires the entry point and WebAuthn verifier used by this wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| anEntryPoint | contract IEntryPoint | EntryPoint singleton this wallet validates against |
| _verifier | contract P256Verifier | Contract used to verify WebAuthn assertions |

### init

```solidity
function init(address _registry, bytes32[2] _deviceWalletOwnerKey, string _deviceUniqueIdentifier, address _eSIMWalletFactory) external
```

Wires the wallet to the registry and the factory, and sets its owner key

Runs from the beacon proxy's constructor, in the deployment transaction. It is the only
     path to the internal `Account4337.initialize`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _registry | address | Registry contract this wallet reads the admin, vault and pause flag from |
| _deviceWalletOwnerKey | bytes32[2] | X,Y co-ordinates of the P256 key owning this wallet |
| _deviceUniqueIdentifier | string | Identifier the device is reached by |
| _eSIMWalletFactory | address | Factory this wallet deploys its eSIM wallets through |

### deployESIMWallet

```solidity
function deployESIMWallet(bool _hasAccessToFunds, uint256 _salt) external returns (address)
```

Deploys an eSIM wallet for this device and binds it

Fund access is granted later by the owner with `toggleAccessToFunds`. The admin gate is
     a convenience, not a boundary: the owner can call the factory directly via `execute`.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _hasAccessToFunds | bool | Must be false |
| _salt | uint256 | CREATE2 salt for the new eSIM wallet |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | eSIM wallet address |

### pullToken

```solidity
function pullToken(address _token, uint256 _amount) external returns (uint256)
```

Allow an associated eSIM wallet to pull an ERC-20 (for data bundles)

Lets the admin charge this wallet without an owner signature. An owner buying for
     themselves can batch the transfer and purchase in `executeBatch` instead.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _token | address | ERC-20 being pulled |
| _amount | uint256 | Amount in that token's smallest unit |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The amount pulled |

### _transferOwnership

```solidity
function _transferOwnership(bytes32[2] newOwner, bytes newOwnerSignature) internal
```

Moves ownership to a new key once that key has proved it can sign

The registry keeps one key to one wallet, so it must follow every rotation. It is told
     after the local write because it reads the key back from this wallet.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking over |
| newOwnerSignature | bytes | ABI-encoded WebAuthn assertion by the new key over the challenge |

### toggleAccessToFunds

```solidity
function toggleAccessToFunds(address _eSIMWalletAddress, bool _hasAccessToFunds) public
```

Allow owner to revoke or give an associated eSIM wallet access to this wallet's money

The only way that access is ever granted. Binding a wallet never carries it, so a
     revocation stands until the owner signs a grant.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to toggle access for |
| _hasAccessToFunds | bool | Set to true to give access, false to revoke access |

### addESIMWallet

```solidity
function addESIMWallet(address _eSIMWalletAddress, bool _hasAccessToFunds) public
```

Binds an eSIM wallet; callable by the registry, the device wallet factory, this
        wallet, or a factory-deployed eSIM wallet adding itself

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to be added |
| _hasAccessToFunds | bool | Must be false. Access is granted only through `toggleAccessToFunds` |

### removeESIMWallet

```solidity
function removeESIMWallet(address _eSIMWalletAddress, bool _callBackETH) public
```

Unbinds an eSIM wallet; callable by this wallet or by that eSIM wallet itself

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to be removed |
| _callBackETH | bool | Whether to pull the eSIM wallet's ETH back to this wallet |

### _addESIMWallet

```solidity
function _addESIMWallet(address _eSIMWalletAddress, bool _hasAccessToFunds) internal
```

Binds an eSIM wallet to this device wallet and records it with the registry

Refuses a wallet not yet owned by this one, so binding cannot run ahead of a handover.
     Never grants fund access, so no bind can undo an owner's revocation. Asking for access
     reverts rather than being silently dropped.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to bind |
| _hasAccessToFunds | bool | Must be false |

### getVaultAddress

```solidity
function getVaultAddress() public view returns (address)
```

Fetches the vault address that receives payment for data bundles

Not cached, so a vault change in the registry reaches every wallet at once.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The vault address |

