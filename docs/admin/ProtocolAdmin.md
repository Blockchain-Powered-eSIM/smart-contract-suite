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

     A guardian does not get a general fast path. It can say exactly three things, and each is
     written here as its own function rather than as a payload, so no fourth sentence is
     expressible however the role is held:

     1. Release a pause. An upgrade that waits is reviewable; an outage that waits is an outage.
     2. Take `CANCELLER_ROLE` away from an account.
     3. Suspend the protocol's admin key.

     All three take something away and none of them grants anything, which is what keeps the
     role away from user funds. Releasing a pause cannot move ETH, stripping a canceller cannot,
     and a suspended admin is an admin that has stopped being able to spend rather than one
     chosen by the guardian. Restoring any of the three is an owner action and waits, so the
     side taking power away always wins the race against the side handing it back. A guardian
     able to reinstate an admin would lose that, and a guardian able to appoint one would reach
     `ESIMWallet.buyDataBundleWithToken` and every wallet holding funds access through it.

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

_Always granted `EXECUTOR_ROLE` alongside it, which keeps the role useful if open
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

### constructor

```solidity
constructor(uint256 _initialDelay, uint256 _minDelayFloor, address[] _proposers, address[] _cancellers, address[] _guardians) public
```

Sets up the timelock's roles and delay bounds

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
     the setter.

     Anything reporting the delay should call this rather than follow `MinDelayChange`,
     which carries the value `updateDelay` stored and not the floor that overrides it._

### grantRole

```solidity
function grantRole(bytes32 role, address account) public virtual
```

_The constructor refuses these overlaps and nothing else did. Granting is a scheduled
     operation like any other, so without this a single proposer can schedule the pairing
     that makes a guardian un-evictable and anyone can execute it once the delay is served.

     Authority is checked first, exactly where the base checks it, so a caller with no right
     to grant the role still gets `AccessControlUnauthorizedAccount`. Answering that caller
     with an overlap instead would name a problem it never reached.

     The constructor's other rule, that `_cancellers` and `_proposers` do not intersect, is
     deliberately not repeated here. That one shapes the deployment, keeping a veto key off
     the schedule path. It is not a safety property, and pairing the two roles later is a
     legitimate decision for a scheduled operation to make.

     A guardian granted here picks up `EXECUTOR_ROLE` with it, as the constructor does, so
     the two ways of installing one leave the same state behind. The reverse is not paired:
     `revokeRole` cannot tell that grant from an independent one, so evicting a guardian
     means scheduling both revocations in one batch._

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

### disableAdminInstantly

```solidity
function disableAdminInstantly(address target) external
```

Suspends a protocol contract's admin key immediately

_The lever against a compromised hot key. That key holds `Registry.pause`, so leaving
     its removal to the delay would mean an outage running for the whole wait while the key
     re-applies the pause after every release. Suspending it is what makes
     `unpauseInstantly` stick.

     Takes powers away and hands none out. The suspended address stays on the target's
     books, and only the owner can reinstate it or name a replacement, both of which wait.
     Whatever a guardian does here, the worst outcome reachable is a stopped backend, which
     the owner ends._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | Contract whose admin is being suspended |

### disableAndNominate

```solidity
function disableAndNominate(address target, address newAdmin) external
```

Suspends the current admin and nominates its replacement in one operation

_Scheduled like anything else, so this is not a fast path and holds no role of its own.
     It exists because the two effects belong in one transaction: the target strips the
     incumbent the moment a nomination is outstanding, so scheduling the nomination alone
     already suspends the old key, and naming the compound effect is the difference between
     a reviewer reading the intent off the operation and having to infer it from a payload.

     The nominee still has to accept, so this cannot hand the role to an address that
     cannot act, and the role stays dormant until it does._

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

_Permissionless, and safe to be: it only takes ownership that the current owner already
     offered, and the offer is the decision. Scheduling it instead would mean waiting out
     the delay before this contract could own anything, including during the deployment it
     is being installed by.

     Each event is emitted ahead of the call it describes, so a target that emits its own
     events on handover cannot interleave them out of order. A failing handover takes the
     whole batch down with it, so no event here can outlive the call it announced.

     `OwnershipAccepted` names an address the caller chose, and anyone can call this with a
     contract they wrote that answers this address to `pendingOwner()` and returns quietly
     from `acceptOwnership()`. Both answers come from the target, so no check here can tell
     a protocol contract from one written to look like it. Read the event as a claim about
     an address, and filter it against the contracts this one is meant to own. It costs the
     protocol nothing beyond the log line: this contract holds no funds, and the powers it
     does hold are gated on roles a target cannot obtain by being called._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| targets | address[] | Contracts whose `pendingOwner` is this address |

