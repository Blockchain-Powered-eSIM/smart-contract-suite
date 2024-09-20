# Solidity API

## Account4337

### owner

```solidity
bytes32[2] owner
```

### entryPoint

```solidity
contract IEntryPoint entryPoint
```

The ERC-4337 entry point singleton

### verifier

```solidity
contract P256Verifier verifier
```

Signature verifier contract

### Account4337Initialized

```solidity
event Account4337Initialized(contract IEntryPoint entryPoint, bytes32[2] owner)
```

### AccountOwnershipTransferred

```solidity
event AccountOwnershipTransferred(bytes32[2] newOwner)
```

### onlySelf

```solidity
modifier onlySelf()
```

### onlyEntryPoint

```solidity
modifier onlyEntryPoint()
```

### onlyOwnerOrEntryPoint

```solidity
modifier onlyOwnerOrEntryPoint()
```

### constructor

```solidity
constructor(contract IEntryPoint _entryPoint, contract P256Verifier _verifier) public
```

### initialize

```solidity
function initialize(bytes32[2] anOwner) public virtual
```

_The _entryPoint member is immutable, to reduce gas consumption.  To upgrade EntryPoint,
a new implementation of SimpleAccount must be deployed with the new EntryPoint address, then upgrading
the implementation by calling `upgradeTo()`_

### _initialize

```solidity
function _initialize(bytes32[2] anOwner) internal virtual
```

### transferOwnership

```solidity
function transferOwnership(bytes32[2] newOwner) public returns (bytes32[2])
```

### execute

```solidity
function execute(struct Call call) external
```

execute a transaction (called directly from owner, or by entryPoint)

### executeBatch

```solidity
function executeBatch(struct Call[] calls) external
```

execute a sequence of transactions

_to reduce gas consumption for trivial case (no value), use a zero-length array to mean zero value_

### isValidSignature

```solidity
function isValidSignature(bytes32 message, bytes signature) external view returns (bytes4 magicValue)
```

### validateUserOp

```solidity
function validateUserOp(struct PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds) external virtual returns (uint256 validationData)
```

Validate user's signature and nonce
the entryPoint will make the call to the recipient only if this validation call returns successfully.
signature failure should be reported by returning SIG_VALIDATION_FAILED (1).
This allows making a "simulation call" without a valid signature
Other failures (e.g. nonce mismatch, or invalid signature format) should still revert to signal failure.

_Must validate caller is the entryPoint.
     Must validate the signature and nonce_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| userOp | struct PackedUserOperation | - The operation that is about to be executed. |
| userOpHash | bytes32 | - Hash of the user's request data. can be used as the basis for signature. |
| missingAccountFunds | uint256 | - Missing funds on the account's deposit in the entrypoint.                              This is the minimum amount to transfer to the sender(entryPoint) to be                              able to make the call. The excess is left as a deposit in the entrypoint                              for future calls. Can be withdrawn anytime using "entryPoint.withdrawTo()".                              In case there is a paymaster in the request (or the current deposit is high                              enough), this value will be zero. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| validationData | uint256 | - Packaged ValidationData structure. use `_packValidationData` and                              `_unpackValidationData` to encode and decode.                              <20-byte> sigAuthorizer - 0 for valid signature, 1 to mark signature failure,                                 otherwise, an address of an "authorizer" contract.                              <6-byte> validUntil - Last timestamp this operation is valid. 0 for "indefinite"                              <6-byte> validAfter - First timestamp this operation is valid                                                    If an account doesn't use time-range, it is enough to                                                    return SIG_VALIDATION_FAILED value (1) for signature failure.                              Note that the validation code cannot use block.timestamp (or block.number) directly. |

### _requireFromEntryPointOrOwner

```solidity
function _requireFromEntryPointOrOwner() internal view
```

### _call

```solidity
function _call(address target, uint256 value, bytes data) internal
```

### getDeposit

```solidity
function getDeposit() public view returns (uint256)
```

check current account deposit in the entryPoint

### addDeposit

```solidity
function addDeposit() public payable
```

deposit more funds for this account in the entryPoint

### withdrawDepositTo

```solidity
function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public
```

withdraw value from the account's deposit

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| withdrawAddress | address payable | target to send to |
| amount | uint256 | to withdraw |

### _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation) internal view
```

UUPSUpsgradeable: only allow self-upgrade.

### receive

```solidity
receive() external payable
```

### fallback

```solidity
fallback() external payable
```

