# Solidity API

## IOwnableESIMWalletEvents

### TransferApprovalChanged

```solidity
event TransferApprovalChanged(address from, address to, bool status)
```

## IOwnableESIMWallet

### initialize

```solidity
function initialize(address eSIMWalletFactoryAddress, address deviceWalletAddress) external
```

### setESIMUniqueIdentifier

```solidity
function setESIMUniqueIdentifier(string eSIMUniqueIdentifier) external
```

### owner

```solidity
function owner() external view returns (address)
```

### transferOwnership

```solidity
function transferOwnership(address newOwner) external
```

### isTransferApproved

```solidity
function isTransferApproved(address from, address to) external view returns (bool)
```

### setApproval

```solidity
function setApproval(address to, bool status) external
```

