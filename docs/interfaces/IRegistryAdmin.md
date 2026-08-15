# Solidity API

## IRegistryAdmin

Minimal view of the admin role the protocol owner controls

_Holds only the two calls `ProtocolAdmin` makes. `enableAdmin` is deliberately absent: the
     owner reaches it as an ordinary scheduled payload, and putting it here would invite a
     named function beside the guardian's, which is the one place a fast path could be added by
     accident. Suspending is instant and restoring waits, and the split is what stops a
     compromised key from undoing its own suspension._

### disableAdmin

```solidity
function disableAdmin() external
```

Suspends the admin's powers protocol-wide, leaving its address on the books

### requestAdminUpdate

```solidity
function requestAdminUpdate(address _newAdmin) external
```

Nominates a new admin, which strips the incumbent until the nominee accepts

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newAdmin | address | Address of the recipient to receive the admin role |

