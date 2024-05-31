# Solidity API

## IOwnableESIMWalletEvents

### TransferApprovalChanged

```solidity
event TransferApprovalChanged(address from, address to, bool status)
```

## IOwnableESIMWallet

### init

```solidity
function init(address eSIMWalletFactoryAddress, address deviceWalletAddress, address owner, string _dataBundleID, uint256 _dataBundlePrice, string eSIMUniqueIdentifier) external payable
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

