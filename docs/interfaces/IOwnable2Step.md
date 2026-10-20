# Solidity API

## IOwnable2Step

Minimal view of the two-step ownership handover the protocol contracts use

_The part of OpenZeppelin's `Ownable2Step` a contract taking ownership calls._

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

