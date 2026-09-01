# Solidity API

## DeviceWallet

A user's device: an ERC-4337 account that owns the eSIM wallets bought for that device

_A beacon proxy deployed by `DeviceWalletFactory`, owned by a P256 key the user holds. It
     funds its eSIM wallets, decides which of them may spend its money, and is the only party that can
     move one to another device. Its own owner key rotates through `transferOwnership`, which
     also tells the registry so the two records cannot drift apart._

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

_A wallet trusted with the funds can already drain the owner, so a second flag per
     asset would cost another signature and limit nothing._

### FundsAccessUpdated

```solidity
event FundsAccessUpdated(address _eSIMWalletAddress, bool _hasAccessToFunds)
```

Emitted when owner updates an eSIM wallet's access to this wallet's money

### TokenSent

```solidity
event TokenSent(address _token, address _eSIMWalletAddress, uint256 _amount)
```

Emitted when an ERC-20 leaves this contract

_mostly when an eSIM wallet pulls tokens to pay for a data bundle_

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

_Read from the registry on every call, so a rotation there takes effect immediately._

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

_Called as the beacon proxy's constructor argument, so it always runs in the same
     transaction as the deployment. `Account4337.initialize` is internal, and this is the
     only path to it._

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

_The new wallet has no eSIM identifier yet. That arrives through
     `setESIMUniqueIdentifierForAnESIMWallet` once the eSIM itself has been created.

     Access to this wallet's money is granted only afterwards, by the owner, with
     `toggleAccessToFunds`.

     The admin gate here is a workflow convenience, not a security boundary against this
     wallet's own owner: `ESIMWalletFactory.deployESIMWallet` also accepts a call from any
     device wallet the registry knows, so the owner can reach the same outcome directly
     through `execute` with no admin involved. Closing that would need the deployment
     triggered by the admin rather than by this wallet, since nothing downstream of a device
     wallet's own call can tell one caller's signed intent from another's._

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

_Refused while the protocol is paused, and refused for a wallet whose access the owner
     has revoked. It exists so the admin can charge this wallet without an owner signature
     in that transaction; an owner buying for themselves can batch the transfer and the
     purchase through `executeBatch` instead._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _token | address | ERC-20 being pulled |
| _amount | uint256 | Amount in that token's smallest unit |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The amount pulled |

### transferOwnership

```solidity
function transferOwnership(bytes32[2] newOwner) public returns (bytes32[2])
```

Replaces the P256 key that owns this account

_The registry holds its own record of which key owns this wallet, and the deploy paths
     keep one key to one wallet. Rotating without telling it leaves the retired key named
     as the owner and leaves the key taking over unregistered, free for a second wallet to
     claim. `super` runs after the key check because it carries the `onlySelf` guard and
     because the registry call is an external one, so the local write has to land before it.

     A key that cannot verify a signature bricks the wallet for good: this function is
     reachable only through `execute`, which needs a signature, so there is no rotating
     back and no reaching the balance. The deploy paths reject such a key and this path
     writes the same storage, so it has to reject it too._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking over |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32[2] | The owner key now in force |

### toggleAccessToFunds

```solidity
function toggleAccessToFunds(address _eSIMWalletAddress, bool _hasAccessToFunds) public
```

Allow owner to revoke or give an associated eSIM wallet access to this wallet's money

_The only way that access is ever granted. Binding a wallet never carries it, so a
     revocation stands until the owner signs a grant._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to toggle access for |
| _hasAccessToFunds | bool | Set to true to give access, false to revoke access |

### addESIMWallet

```solidity
function addESIMWallet(address _eSIMWalletAddress, bool _hasAccessToFunds) public
```

Allow the device wallet factory or the wallet owner to add new eSIM wallet to this device wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to be added |
| _hasAccessToFunds | bool | Must be false. Access is granted only through `toggleAccessToFunds` |

### removeESIMWallet

```solidity
function removeESIMWallet(address _eSIMWalletAddress, bool _callBackETH) public
```

Allow the device wallet owner or the eSIM wallet to remove any eSIM wallet bound with this device wallet

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eSIMWalletAddress | address | Address of the eSIM wallet to be removed |
| _callBackETH | bool | `true` if any remaining ETH needs to be called back from the ESIM wallet to this device wallet, `false` otherwise |

### _addESIMWallet

```solidity
function _addESIMWallet(address _eSIMWalletAddress, bool _hasAccessToFunds) internal
```

Binds an eSIM wallet to this device wallet and records it with the registry

_Refuses a wallet this device wallet does not already own, so binding cannot run ahead
     of the ownership handover.

     A bind never carries access to this wallet's money. `toggleAccessToFunds` is `onlySelf` and the only writer
     of a `true`, so no bind can undo the owner's revocation. Asking for access here reverts
     rather than being downgraded in silence._

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

_Read through to the registry rather than cached, so a vault change reaches every
     wallet at once. The associated eSIM wallets call this before paying._

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The vault address |

