# Solidity API

## IOwnable2Step

Minimal view of the two-step ownership handover the protocol contracts use

_Matches the part of OpenZeppelin's `Ownable2Step` an incoming owner needs. The offer is made
     by the current owner and completed by the nominee, so a contract taking ownership only ever
     calls these two._

### acceptOwnership

```solidity
function acceptOwnership() external
```

Completes a handover the current owner already offered to the caller

### pendingOwner

```solidity
function pendingOwner() external view returns (address)
```

Address the current owner has offered ownership to, or zero

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The nominated address |

