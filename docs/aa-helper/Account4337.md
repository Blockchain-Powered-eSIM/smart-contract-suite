# Solidity API

## Account4337

### owner

```solidity
address owner
```

### Account4337Initialized

```solidity
event Account4337Initialized(contract IEntryPoint entryPoint, address owner)
```

### AccountOwnershipTransferred

```solidity
event AccountOwnershipTransferred(address oldOwner, address newOwner)
```

### onlyOwner

```solidity
modifier onlyOwner()
```

### entryPoint

```solidity
function entryPoint() public view virtual returns (contract IEntryPoint)
```

Return the entryPoint used by this account.
Subclass should return the current entryPoint used by this account.

### constructor

```solidity
constructor(contract IEntryPoint anEntryPoint) public
```

### _onlyOwner

```solidity
function _onlyOwner() internal view
```

### transferOwnership

```solidity
function transferOwnership(address newOwner) public returns (address)
```

### execute

```solidity
function execute(address dest, uint256 value, bytes func) external
```

execute a transaction (called directly from owner, or by entryPoint)

### executeBatch

```solidity
function executeBatch(address[] dest, uint256[] value, bytes[] func) external
```

execute a sequence of transactions

_to reduce gas consumption for trivial case (no value), use a zero-length array to mean zero value_

### initialize

```solidity
function initialize(address anOwner) public virtual
```

_The _entryPoint member is immutable, to reduce gas consumption.  To upgrade EntryPoint,
a new implementation of SimpleAccount must be deployed with the new EntryPoint address, then upgrading
the implementation by calling `upgradeTo()`_

### _initialize

```solidity
function _initialize(address anOwner) internal virtual
```

### _requireFromEntryPointOrOwner

```solidity
function _requireFromEntryPointOrOwner() internal view
```

### _validateSignature

```solidity
function _validateSignature(struct PackedUserOperation userOp, bytes32 userOpHash) internal virtual returns (uint256 validationData)
```

implement template method of BaseAccount

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

_Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
{upgradeToAndCall}.

Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.

```solidity
function _authorizeUpgrade(address) internal onlyOwner {}
```_

### receive

```solidity
receive() external payable
```

