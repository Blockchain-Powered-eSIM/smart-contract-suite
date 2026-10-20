# Solidity API

## ProtocolAdmin

Owner of the five upgradeable protocol contracts, with a delay on every change

_Owns `Registry`, `LazyWalletRegistry`, `DeviceWalletFactory`, `ESIMWalletFactory` and
     `PaymentAdapter` once `TransferOwnership.s.sol` has run, and through the factories both
     wallet beacons.

     Proposers schedule, the delay runs, then anyone may execute, so no single key has to stay
     available. The delay is the safeguard.

     A guardian has exactly four powers, each its own function so nothing else is expressible:
     1. Raise a pause, which still works while the admin key is suspended.
     2. Release a pause, since an outage should not wait out the delay.
     3. Strip `CANCELLER_ROLE`. Without it a canceller can cancel its own eviction forever.
     4. Suspend the admin key.
     None grants anything, and restoring a canceller or admin waits, so taking power away wins.

     A guardian may not hold `CANCELLER_ROLE`, or it could become the only canceller. It may not
     touch `PROPOSER_ROLE`: with no proposers, nothing can ever be scheduled again.

     Known limit: a rogue guardian plus a rogue proposer can strip every canceller. Keep their
     Safes on disjoint signers and alert on `CancellerRevoked`.

     Not upgradeable: an upgradeable owner would move the trust to whoever can upgrade it._

### GUARDIAN_ROLE

```solidity
bytes32 GUARDIAN_ROLE
```

Raises and releases a pause, strips a canceller and suspends the admin, all without
        waiting for the delay

_Always paired with `EXECUTOR_ROLE`, so it still works if open execution is closed.
     Never paired with `CANCELLER_ROLE`, which would make a guardian impossible to evict._

### minDelayFloor

```solidity
uint256 minDelayFloor
```

Shortest delay this contract will ever accept, whatever `updateDelay` was given

_`updateDelay` accepts zero, so without a floor one scheduled call would remove the
     delay for good. Applied through `getMinDelay`, which `schedule` checks against._

### PauseRaised

```solidity
event PauseRaised(address target, address guardian)
```

A guardian raised a pause

### PauseReleased

```solidity
event PauseReleased(address target, address guardian)
```

A guardian released a pause

### CancellerRevoked

```solidity
event CancellerRevoked(address account, address guardian)
```

A guardian took the cancel power away from an account

### AdminDisabled

```solidity
event AdminDisabled(address target, address guardian)
```

A guardian suspended a protocol contract's admin key

### AdminDisabledAndNominated

```solidity
event AdminDisabledAndNominated(address target, address newAdmin)
```

A scheduled operation suspended an admin key and nominated its replacement

### OwnershipAccepted

```solidity
event OwnershipAccepted(address target)
```

Ownership of a protocol contract was accepted

### DelayBelowFloor

```solidity
error DelayBelowFloor(uint256 delay, uint256 floor)
```

The initial delay was below the floor

### NoGuardians

```solidity
error NoGuardians()
```

No guardian was named at construction

### NoProposers

```solidity
error NoProposers()
```

No proposer was named at construction

### ZeroAddress

```solidity
error ZeroAddress(string parameter)
```

A zero address appeared in one of the constructor role lists

### RolesMustNotOverlap

```solidity
error RolesMustNotOverlap(address account)
```

An account was named in two role lists that have to stay separate

### NotACanceller

```solidity
error NotACanceller(address account)
```

The account named does not hold the cancel power

### OwnershipNotOffered

```solidity
error OwnershipNotOffered(address target)
```

The contract was not offered ownership of this target

### NomineeIsTheIncumbent

```solidity
error NomineeIsTheIncumbent(address target, address admin)
```

A replacement nomination named the admin already on the books

### constructor

```solidity
constructor(uint256 _initialDelay, uint256 _minDelayFloor, address[] _proposers, address[] _cancellers, address[] _guardians) public
```

Sets up the timelock's roles and delay bounds

_No admin account: this contract holds its own `DEFAULT_ADMIN_ROLE`, so every role
     change is scheduled and waited out. Rotating signers never touches the protocol contracts.

     Proposers also get `CANCELLER_ROLE` from the base. `_cancellers` is for veto-only keys,
     typically the signers behind a proposer multisig, so one key can veto but not schedule.

     `EXECUTOR_ROLE` on the zero address opens execution to everyone.

     Empty `_cancellers` is fine, as proposers already cancel. Empty `_guardians` is not:
     adding one would wait out the delay, and nothing could evict a compromised canceller._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _initialDelay | uint256 | Delay new operations wait before they can be executed |
| _minDelayFloor | uint256 | Shortest delay `updateDelay` can ever bring the contract down to |
| _proposers | address[] | Accounts that may schedule operations, and that may also cancel them |
| _cancellers | address[] | Further accounts that may cancel, holding no other role |
| _guardians | address[] | Accounts holding the four guardian powers |

### getMinDelay

```solidity
function getMinDelay() public view virtual returns (uint256)
```

_Never below the floor, whatever `updateDelay` stored. `schedule` reads this, so the
     floor binds without intercepting the setter. Offchain readers should call this rather
     than follow `MinDelayChange`, which reports the stored value._

### grantRole

```solidity
function grantRole(bytes32 role, address account) public virtual
```

_Enforces the constructor's guardian overlap rules on later grants, so one proposer
     cannot schedule the pairing that makes a guardian impossible to evict.

     Authority is checked first, as in the base, so an unauthorized caller still gets
     `AccessControlUnauthorizedAccount` rather than an overlap error.

     The canceller and proposer split is not enforced here. It only shapes the deployment,
     and pairing those roles later is a fair call for a scheduled operation.

     A new guardian gets `EXECUTOR_ROLE` too, as in the constructor. `revokeRole` cannot
     tell that grant apart, so evicting a guardian means revoking both in one batch._

### pauseInstantly

```solidity
function pauseInstantly(address target) external
```

Raises a pause on a protocol contract immediately

_A rogue guardian can only stop the protocol, which the admin key could already do, and
     it can be released at once._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract to pause |

### unpauseInstantly

```solidity
function unpauseInstantly(address target) external
```

Releases a pause on a protocol contract immediately

_The selector is fixed, so this cannot call anything else on the target. The worst a
     rogue guardian can do is unpause something, which can be paused again._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract to unpause |

### revokeCancellersInstantly

```solidity
function revokeCancellersInstantly(address[] accounts) external
```

Takes the cancel power away from accounts immediately

_Only `CANCELLER_ROLE`, and restoring it is scheduled. A batch because one signer set
     often holds the role on several keys, and one transaction beats the operation it races.

     All or nothing. An account without the role reverts, so a guardian never wrongly
     believes a veto is gone._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| accounts | address[] | Accounts to strip |

### disableAdminInstantly

```solidity
function disableAdminInstantly(address target) external
```

Suspends a protocol contract's admin key immediately

_Against a compromised admin key, which holds `Registry.pause` and could re-pause after
     every release for the whole delay. Suspending it makes `unpauseInstantly` stick.

     Grants nothing. Only the owner, after the delay, can reinstate or replace the key, so
     the worst a rogue guardian can cause is a stopped backend that the owner ends._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract whose admin is being suspended |

### disableAndNominate

```solidity
function disableAndNominate(address target, address newAdmin) external
```

Suspends the current admin and nominates its replacement in one operation

_Scheduled like anything else, not a fast path. A pending nomination already suspends
     the incumbent, and naming that effect lets a reviewer read the intent off the operation.

     The nominee must still accept, so the role cannot go to an address that cannot act.

     The incumbent is refused: the registry would read it as a withdrawal and lift the
     suspension._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract whose admin is being replaced |
| newAdmin | address | Address nominated to take the role |

### acceptOwnershipBatch

```solidity
function acceptOwnershipBatch(address[] targets) external
```

Completes the handover of every contract that has offered this one its ownership

_Permissionless because the current owner's offer is the decision. Scheduling it would
     make even the deployment wait out the delay.

     Events go before each call so they keep order with the target's own, and a failed
     handover reverts the batch, so no event outlives its call.

     Any contract can fake `pendingOwner()` and `acceptOwnership()`, so `OwnershipAccepted`
     is only a claim. Filter it against the expected targets. A fake costs nothing more: this
     contract holds no funds, and a target cannot gain a role by being called._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| targets | address[] | Contracts whose `pendingOwner` is this address |

