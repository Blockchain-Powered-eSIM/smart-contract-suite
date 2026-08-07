# Solidity API

## ProtocolAdmin

Owner of the four upgradeable protocol contracts, with a delay on every change

_Replaces the single externally owned account that owns `Registry`, `LazyWalletRegistry`,
     `DeviceWalletFactory` and `ESIMWalletFactory` today. Both wallet beacons sit under the two
     factories, so owning the factories reaches every device wallet and every eSIM wallet.

     Everything this contract can do to the protocol goes one way: a proposer schedules it, the
     delay elapses, and anyone at all executes it. Execution is open on purpose. The
     announcement is what the delay buys, and once the wait is served there is no reason to make
     the protocol depend on one key still being available to press the button.

     A guardian does not get a general fast path. It can say exactly two things, and both are
     written here as their own functions rather than as payloads, so no third sentence is
     expressible however the role is held:

     1. Release a pause. An upgrade that waits is reviewable; an outage that waits is an outage.
     2. Take `CANCELLER_ROLE` away from an account.

     The second one exists because without it a compromised canceller is permanent. Evicting any
     role holder means scheduling `revokeRole`, a scheduled operation can be cancelled by any
     canceller, and so a compromised canceller cancels its own eviction forever. Nothing else can
     break that loop, because the delay is what every other route waits on.

     Two limits on that power carry the whole recovery argument, and both are enforced rather
     than documented. A guardian may not hold `CANCELLER_ROLE` itself, or it could revoke every
     other canceller, become the only one, and cancel its own eviction. And it may not touch
     `PROPOSER_ROLE`, because reaching zero proposers is unrecoverable: re-granting any role
     needs a scheduled operation, scheduling needs a proposer, and `Registry.unpause` is owner
     only, so a bricked admin plus a pause is a pause nobody can ever release. Reaching zero
     cancellers is fine by comparison. It costs the veto, and a proposer can schedule it back.

     Not upgradeable, deliberately. An upgradeable owner of upgradeable contracts moves the
     trust to whoever can upgrade it, and there is no delay left to protect that step._

### GUARDIAN_ROLE

```solidity
bytes32 GUARDIAN_ROLE
```

Releases a pause and strips a canceller, both without waiting for the delay

_Also granted `EXECUTOR_ROLE` at construction, which keeps the role useful if open
     execution is ever closed off. Deliberately not granted `CANCELLER_ROLE`; see the note on
     the contract for why that pairing is what makes a guardian un-evictable._

### minDelayFloor

```solidity
uint256 minDelayFloor
```

Shortest delay this contract will ever accept, whatever `updateDelay` was given

_`updateDelay` takes any value including zero, and it is reachable by scheduling a call
     to this contract like any other. Without a floor, one scheduled operation turns the
     timelock into a plain multisig and nothing after it ever waits again. Read through
     `getMinDelay`, which is what `schedule` measures against._

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

### constructor

```solidity
constructor(uint256 _initialDelay, uint256 _minDelayFloor, address[] _proposers, address[] _cancellers, address[] _guardians) public
```

_No admin account. The zero passed to `TimelockController` leaves this contract holding
     its own `DEFAULT_ADMIN_ROLE`, so granting or revoking any role is itself an operation
     that has to be scheduled and waited out. Rotating a signer set is a role change here and
     never touches the protocol contracts, whose owner stays this address.

     The base constructor gives every proposer `CANCELLER_ROLE` as well, which is kept.
     `_cancellers` is for the accounts that cancel and do nothing else, typically the
     individual keys behind a proposer multisig, so that one key can veto on its own without
     being able to schedule anything on its own.

     `EXECUTOR_ROLE` goes to the zero address, which `onlyRoleOrOpenRole` reads as open to
     everyone. See the note on the contract for why.

     An empty `_cancellers` is allowed, since the proposers already carry the role. An empty
     `_guardians` is not: there would be no way to add one without the delay it exists to
     skip, and no way at all to break a compromised canceller loose._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| _initialDelay | uint256 | Delay new operations wait before they can be executed |
| _minDelayFloor | uint256 | Shortest delay `updateDelay` can ever bring the contract down to |
| _proposers | address[] | Accounts that may schedule operations, and that may also cancel them |
| _cancellers | address[] | Further accounts that may cancel, holding no other role |
| _guardians | address[] | Accounts that may release a pause and strip a canceller |

### getMinDelay

```solidity
function getMinDelay() public view virtual returns (uint256)
```

_Held at the floor whatever `updateDelay` last wrote. `schedule` reads this rather than
     the stored value, so the floor binds every new operation without needing to intercept
     the setter._

### unpauseInstantly

```solidity
function unpauseInstantly(address target) external
```

Releases a pause on a protocol contract immediately

_The selector is fixed in the interface rather than passed in, so this cannot be pointed
     at anything else on the target. Whatever a guardian does here, the worst outcome
     reachable is that something is unpaused which someone wanted paused, and the key that
     applies a pause is not this one and can simply apply it again._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract to unpause |

### revokeCancellersInstantly

```solidity
function revokeCancellersInstantly(address[] accounts) external
```

Takes the cancel power away from accounts immediately

_Only `CANCELLER_ROLE`, never anything else, and adding it back is an ordinary scheduled
     operation. A batch because the account being evicted is usually one signer set holding
     the role several times over, and doing that in one transaction rather than several is
     the difference between the eviction landing and the operation it is racing landing
     first.

     All or nothing, and an account that does not hold the role reverts rather than passing
     quietly. A guardian doing this is acting on a named list during an incident, and a
     silent no-op would leave it believing a veto is gone while the veto is still there._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| accounts | address[] | Accounts to strip |

### acceptOwnershipBatch

```solidity
function acceptOwnershipBatch(address[] targets) external
```

Completes the handover of every contract that has offered this one its ownership

_Permissionless, and safe to be: it only takes ownership that the current owner already
     offered, and the offer is the decision. Scheduling it instead would mean waiting out
     the delay before this contract could own anything, including during the deployment it
     is being installed by.

     Each event is emitted ahead of the call it describes, so a target that emits its own
     events on handover cannot interleave them out of order. A failing handover takes the
     whole batch down with it, so no event here can outlive the call it announced._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| targets | address[] | Contracts whose `pendingOwner` is this address |

