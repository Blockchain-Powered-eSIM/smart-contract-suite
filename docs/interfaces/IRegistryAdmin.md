# Solidity API

## IRegistryAdmin

Minimal view of the admin role the protocol owner controls

_Holds only what `ProtocolAdmin` calls. `enableAdmin` is left out (the owner reaches it as a
     scheduled payload) so no instant restore is added by accident: suspending is instant and
     restoring waits, which stops a compromised key undoing its own suspension._

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

### adminOfRecord

```solidity
function adminOfRecord() external view returns (address)
```

The admin address on the books, whether or not its powers are live

