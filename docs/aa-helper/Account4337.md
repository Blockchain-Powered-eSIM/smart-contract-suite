# Solidity API

## Account4337

ERC-4337 account owned by a P256 key rather than by an address

_`validateUserOp` and `isValidSignature` each hash a different precursor, so a signature
        made for one is never accepted by the other._

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

The ERC-4337 EntryPoint singleton this account answers to

_Immutable to keep validation cheap, so a new EntryPoint needs a new implementation._

### verifier

```solidity
contract P256Verifier verifier
```

Contract that verifies every WebAuthn assertion for this account

### owner

```solidity
bytes32[2] owner
```

X and Y co-ordinates of the P256 key that owns this account

_DeviceWallet's storage starts right after this slot. A new state variable here would
     shift it on deployed wallets, which then read zeros. Put new state in an ERC-7201
     namespace instead._

### Account4337Initialized

```solidity
event Account4337Initialized(contract IEntryPoint entryPoint, bytes32[2] owner)
```

Emitted once, when the account's owner key is first set

### AccountOwnershipTransferred

```solidity
event AccountOwnershipTransferred(bytes32[2] newOwner)
```

Emitted when the owner key is replaced

### onlySelf

```solidity
modifier onlySelf()
```

Restricts a call to the account itself

_Reached from outside only by an owner-signed `execute` or `executeBatch` to this address_

### onlyEntryPoint

```solidity
modifier onlyEntryPoint()
```

Restricts a call to the EntryPoint singleton

### constructor

```solidity
constructor(contract IEntryPoint _entryPoint, contract P256Verifier _verifier) public
```

Wires the entry point and WebAuthn verifier used by this account

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _entryPoint | contract IEntryPoint | EntryPoint singleton this account validates against |
| _verifier | contract P256Verifier | Contract used to verify WebAuthn assertions |

### initialize

```solidity
function initialize(bytes32[2] anOwner) internal virtual
```

Sets the owner key on a freshly deployed account

_Internal so a proxy deployed without its init call cannot be claimed by anyone with a
     key of their choosing. Only a subclass initializer can reach it._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| anOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking ownership |

### _initialize

```solidity
function _initialize(bytes32[2] anOwner) internal virtual
```

Writes the owner key without the initializer guard

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| anOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking ownership |

### execute

```solidity
function execute(struct Call call) external
```

Makes one call from this account

_Callable by the EntryPoint or this account. The P256 key has no address, so it reaches
     this only through a signed user operation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| call | struct Call | Target, value and calldata of the call to make |

### executeBatch

```solidity
function executeBatch(struct Call[] calls) external
```

Makes a sequence of calls from this account, reverting all of them if one fails

_Same callers as `execute`_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| calls | struct Call[] | Targets, values and calldata, executed in order |

### isValidSignature

```solidity
function isValidSignature(bytes32 _messageHash, bytes _signature) external view returns (bytes4 magicValue)
```

Validates a signature over an arbitrary message, per ERC-1271

_The signed challenge is not `_messageHash` but the EIP-191 digest over version,
     validUntil, chain id, this address and `_messageHash`, so a signer needs all five._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _messageHash | bytes32 | EIP-191 digest of the original message |
| _signature | bytes | Packed version, validUntil and WebAuthn assertion |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| magicValue | bytes4 | `0x1626ba7e` when the signature is valid and unexpired, `0xffffffff` otherwise |

### validateUserOp

```solidity
function validateUserOp(struct PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds) external virtual returns (uint256 validationData)
```

Validate user's signature and nonce
the entryPoint will make the call to the recipient only if this validation call returns successfully.
signature failure should be reported by returning SIG_VALIDATION_FAILED (1).
This allows making a "simulation call" without a valid signature
Other failures (e.g. nonce mismatch, or invalid signature format) should still revert to signal failure.

_TIMESTAMP is banned here, so expiry goes back in the packed result. The beacon read
     may need a staked entity on a strict ERC-7562 bundler._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| userOp | struct PackedUserOperation | - The operation that is about to be executed. |
| userOpHash | bytes32 | - Hash of the user's request data. can be used as the basis for signature. |
| missingAccountFunds | uint256 | - Missing funds on the account's deposit in the entrypoint.                              This is the minimum amount to transfer to the sender(entryPoint) to be                              able to make the call. The excess is left as a deposit in the entrypoint                              for future calls. Can be withdrawn anytime using "entryPoint.withdrawTo()".                              In case there is a paymaster in the request (or the current deposit is high                              enough), this value will be zero. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| validationData | uint256 | - Packaged ValidationData structure. use `_packValidationData` and                              `_unpackValidationData` to encode and decode.                              <20-byte> aggregatorOrSigFail - 0 for valid signature, 1 to mark signature failure,                                 otherwise, an address of an "aggregator" contract.                              <6-byte> validUntil - Last timestamp this operation is valid at, or 0 for "indefinitely"                              <6-byte> validAfter - First timestamp this operation is valid                                                    If an account doesn't use time-range, it is enough to                                                    return SIG_VALIDATION_FAILED value (1) for signature failure.                              Note that the validation code cannot use block.timestamp (or block.number) directly. |

### transferOwnership

```solidity
function transferOwnership(bytes32[2] newOwner, bytes newOwnerSignature) public returns (bytes32[2])
```

Replaces the P256 key that owns this account

_The current owner signs the call, and the new key must sign `rotationChallenge`, so
     an owner cannot rotate onto a key it does not control._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking over |
| newOwnerSignature | bytes | ABI-encoded WebAuthn assertion by the new key over the challenge |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32[2] | The owner key now in force |

### _transferOwnership

```solidity
function _transferOwnership(bytes32[2] newOwner, bytes newOwnerSignature) internal virtual
```

Moves ownership to a new key once that key has proved it can sign

_The single rotation path, so any later recovery route gets the same check. A subclass
     with its own owner record overrides this to keep it in step._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking over |
| newOwnerSignature | bytes | ABI-encoded WebAuthn assertion by the new key over the challenge |

### rotationChallenge

```solidity
function rotationChallenge(bytes32[2] newOwner) public view returns (bytes)
```

The challenge a new owner key signs to accept this account

_Binds chain, wallet and key, and its length differs from the other two precursors, so
     the proof cannot be reused anywhere else._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newOwner | bytes32[2] | X,Y co-ordinates of the P256 key taking over |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes | The raw challenge bytes the WebAuthn assertion must carry |

### getDeposit

```solidity
function getDeposit() public view returns (uint256)
```

This account's gas deposit held by the EntryPoint

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The deposited amount |

### addDeposit

```solidity
function addDeposit() public payable
```

Tops up this account's gas deposit at the EntryPoint

_Open to anyone, since only the payer loses anything._

### withdrawDepositTo

```solidity
function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public
```

Withdraws part of this account's gas deposit from the EntryPoint

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| withdrawAddress | address payable | Recipient of the withdrawn ETH |
| amount | uint256 | Amount to withdraw |

### _requireFromEntryPointOrOwner

```solidity
function _requireFromEntryPointOrOwner() internal view
```

Reverts unless the caller is the EntryPoint or this account itself

_"Owner" here means `address(this)`, since the P256 key has no address._

### _call

```solidity
function _call(address target, uint256 value, bytes data) internal
```

Calls a target and bubbles its revert data unchanged

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Address to call |
| value | uint256 | ETH to send with the call |
| data | bytes | Calldata for the call |

### receive

```solidity
receive() external payable
```

Accepts plain ETH transfers

