/// ProtocolAdmin: the delay nothing gets around, and the two sentences a guardian can say.
///
/// This contract is the owner of the four upgradeable protocol contracts, and both wallet beacons
/// sit under two of them, so every power it holds reaches every wallet. What makes that safe is not
/// who holds a key but that every route into the protocol waits, and that the one role which does
/// not wait can express exactly two things. The rules below fix both halves: the delay floor binds
/// whatever `updateDelay` was last given, an operation never completes before the clock it was
/// scheduled against, and the guardian fast paths write nothing but the cancel power.
///
/// Scope. Every call leaving this contract is summarised, `unpause` and the two `Ownable2Step`
/// methods by signature and everything else by the unresolved default. The low level call inside
/// `_execute` reaches an arbitrary target with arbitrary calldata, so its selector is genuinely
/// unresolved and the default applies to it. NONDET writes nothing, so nothing here says anything
/// about a target that calls back in. The one call that would matter is a scheduled operation
/// pointing at this contract, which is how `updateDelay` and every role change are reached on chain.
/// Those are driven directly instead, which is the stronger statement about which storage they
/// write and says nothing about the route to them.
///
/// Two assumptions about the role table, both true of the deployed shape and both preserved by the
/// code rather than merely asserted at construction. The prover starts from an arbitrary state, so
/// they have to be written down.
///
/// First, no account other than this contract holds `DEFAULT_ADMIN_ROLE`. The base constructor
/// grants it to `address(this)` and this contract passes zero for the optional admin, so there is no
/// second holder, and granting one is itself an operation that has to be scheduled and served.
/// Without this the prover hands `DEFAULT_ADMIN_ROLE` to an arbitrary caller and every role rule
/// fails for a state the deployment cannot reach.
///
/// Second, every role's admin is `DEFAULT_ADMIN_ROLE`. `_setRoleAdmin` is internal and no function
/// in `AccessControl` or `TimelockController` calls it, so the mapping is whatever construction left
/// and construction never writes it. The prover would otherwise pick an arbitrary admin role per
/// role.
///
/// Loops unroll three times, so `revokeCancellersInstantly`, `acceptOwnershipBatch`,
/// `scheduleBatch` and `executeBatch` are covered for batches of at most three. Hashing of unbounded
/// arguments is assumed within 224 bytes, which the operation payloads reaching this contract are
/// not necessarily: an upgrade payload carrying an initializer call can exceed that. The rules below
/// are stated over `getTimestamp` on an arbitrary identifier rather than over a payload, so none of
/// them recompute an operation hash and the bound does not weaken what they say.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which is the outcome
/// wanted. A `rule_not_vacuous` record reading verified is the failure. Count the records carrying
/// no sanity suffix and ignore the fraction.

methods {
    function GUARDIAN_ROLE() external returns (bytes32) envfree;
    function PROPOSER_ROLE() external returns (bytes32) envfree;
    function CANCELLER_ROLE() external returns (bytes32) envfree;
    function EXECUTOR_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;

    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;

    function minDelayFloor() external returns (uint256) envfree;
    function getMinDelay() external returns (uint256) envfree;
    function getTimestamp(bytes32) external returns (uint256) envfree;

    /// The two `Ownable2Step` methods and the pause release all have resolved selectors and an
    /// unknown callee, so the unresolved default below never applies to them and the prover would
    /// pick its own summary. Naming each one is what keeps this contract's own storage alone.
    function _.unpause() external => NONDET;
    function _.pendingOwner() external => NONDET;
    function _.acceptOwnership() external => NONDET;

    /// The arbitrary call inside `_execute`, whose selector really is unresolved.
    unresolved external in _._ => DISPATCH [] default NONDET;
}

/// This contract is the only holder of `DEFAULT_ADMIN_ROLE`, and every role is administered by it.
/// See the header for why both hold on chain and why the prover has to be told.
function theRoleTableIsAsDeployed(env callEnv, bytes32 role) {
    require callEnv.msg.sender != currentContract =>
        !hasRole(DEFAULT_ADMIN_ROLE(), callEnv.msg.sender);
    require getRoleAdmin(role) == DEFAULT_ADMIN_ROLE();
}

/// A-01. The floor binds whatever the stored delay says.
///
/// `updateDelay` accepts any value including zero and is reachable by scheduling a call to this
/// contract like any other, so without the clamp one served operation turns the timelock into a
/// plain multisig and nothing after it ever waits again. `getMinDelay` is what `_schedule` measures
/// against, so clamping there is what makes the floor bind every new operation rather than only the
/// setter.
rule theDelayIsNeverBelowTheFloor(method f) {
    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert getMinDelay() >= minDelayFloor(),
        "the effective delay fell below the floor";
}

/// A-02. Nothing is scheduled to mature inside the floor.
///
/// The other half of A-01, stated where it lands rather than where it is read. `_schedule` is the
/// only writer that raises a timestamp, and it writes `block.timestamp + delay` having already
/// refused a delay under `getMinDelay`. Parametric rather than over `schedule`, so `scheduleBatch`
/// is covered by the same statement and so a future writer cannot slip a timestamp in beside them.
rule nothingIsScheduledToMatureInsideTheFloor(method f, bytes32 id) {
    uint256 timestampBefore = getTimestamp(id);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    uint256 timestampAfter = getTimestamp(id);

    assert timestampAfter > timestampBefore =>
        timestampAfter >= callEnv.block.timestamp + minDelayFloor(),
        "an operation was scheduled to become ready sooner than the floor allows";
}

/// A-03. An operation never completes before the clock it was scheduled against.
///
/// The whole point of the contract in one line. `_beforeCall` refuses an operation that is not
/// ready, and ready means the stored timestamp has passed. Stated over every method so that no path
/// other than `execute` and `executeBatch` can mark an operation done either.
/// Both halves of the precondition are load-bearing. Waiting and done are told apart by the stored
/// timestamp alone, done being the literal 1, so `getTimestamp(id) > block.timestamp` does not on its
/// own exclude a done operation: at `block.timestamp == 0` it admits a timestamp of 1, which is done
/// already, and the rule then fails on every method including pure views. Pending is exactly
/// `getTimestamp(id) > 1`, which is what separates the two.
///
/// Stated through `getTimestamp` rather than through `isOperationPending` and `isOperationDone`
/// because those two read the clock to tell a waiting operation from a ready one, which no rule here
/// asks about, and reading it makes them ineligible for `envfree`. The stored timestamp answers both
/// questions on its own.
rule nothingCompletesBeforeItsTimestamp(method f, bytes32 id) {
    env callEnv;
    calldataarg args;

    require getTimestamp(id) > 1;
    require getTimestamp(id) > callEnv.block.timestamp;

    f(callEnv, args);

    assert getTimestamp(id) != 1,
        "an operation completed before its delay had been served";
}

/// A-04. A completed operation is never reopened.
///
/// Done is written as the timestamp 1, which `_schedule` reads as an operation already existing and
/// `cancel` reads as not pending. Both refusals are what stops a served payload being replayed under
/// its own identifier, and the identifier is a hash of the payload, so replaying one means running
/// the same calls again with no new wait.
rule aCompletedOperationIsNeverReopened(method f, bytes32 id) {
    require getTimestamp(id) == 1;

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert getTimestamp(id) == 1,
        "a completed operation was reopened";
}

/// A-05. The delay moves only through a served operation.
///
/// `updateDelay` compares the caller against `address(this)`, which reads no role table and no
/// storage, so this is one of the few guards in the whole protocol that survives every summary
/// above intact. Reaching it means scheduling a call to this contract and waiting the current delay
/// out, so a delay change announces itself for as long as the delay it is changing.
rule theDelayMovesOnlyThroughAServedOperation(method f) {
    uint256 delayBefore = getMinDelay();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert getMinDelay() != delayBefore =>
        f.selector == sig:updateDelay(uint256).selector && callEnv.msg.sender == currentContract,
        "the delay moved through something other than a served operation";
}

/// A-06. Every role change waits, renounces, or is the guardian taking the cancel power.
///
/// The role table is the contract's own authority, so this is the statement that says the fast path
/// is exactly as wide as it was meant to be. Three ways a role moves and no fourth. A grant or a
/// revocation comes from this contract itself, meaning it was scheduled and served. An account may
/// always drop a role it holds. And a guardian may strip `CANCELLER_ROLE`, which A-07 then pins to
/// that role alone.
///
/// The guardian exception is what stops a compromised canceller being permanent: evicting any role
/// holder is a scheduled operation, and any canceller can cancel a scheduled operation, so without
/// an instant route a compromised canceller cancels its own eviction forever.
rule everyRoleChangeIsServedRenouncedOrTheGuardianException(method f, bytes32 role, address account) {
    env callEnv;
    theRoleTableIsAsDeployed(callEnv, role);

    bool heldBefore = hasRole(role, account);

    calldataarg args;
    f(callEnv, args);

    assert hasRole(role, account) != heldBefore => (
        callEnv.msg.sender == currentContract
     || f.selector == sig:renounceRole(bytes32, address).selector
     || f.selector == sig:revokeCancellersInstantly(address[]).selector
    ), "a role moved without being scheduled, renounced, or stripped by a guardian";
}

/// A-07. The guardian's instant path takes the cancel power and nothing else.
///
/// The half of A-06 that its third branch leaves open. A guardian that could reach any other role
/// through this function would be a general fast path wearing a narrow name: `PROPOSER_ROLE` most
/// of all, because reaching zero proposers is unrecoverable. Re-granting any role needs a scheduled
/// operation, scheduling needs a proposer, and `Registry.unpause` is owner only, so a bricked admin
/// plus a pause is a pause nobody can ever release.
///
/// Note the direction as well as the role: this path only ever takes away. It cannot hand the cancel
/// power to an account that did not have it, which is what would let a guardian install its own
/// veto.
rule theGuardianTakesNothingButTheCancelPower(bytes32 role, address account) {
    env callEnv;
    theRoleTableIsAsDeployed(callEnv, role);

    bool heldBefore = hasRole(role, account);

    address[] accounts;
    revokeCancellersInstantly(callEnv, accounts);

    bool heldAfter = hasRole(role, account);

    assert heldAfter != heldBefore => (heldBefore && role == CANCELLER_ROLE()),
        "the guardian's instant path moved a role other than the cancel power, or granted one";
}

/// A-08. Both instant paths refuse an account without the guardian role.
///
/// `onlyRole` reads the role table on this contract and calls nothing out, so unlike every access
/// check elsewhere in the protocol this one survives the summaries above and can actually be
/// stated. The two rules are separate because they are separate powers and a future edit could
/// loosen one without the other.
rule releasingAPauseWithoutTheGuardianRoleAlwaysReverts(address target) {
    env callEnv;
    require !hasRole(GUARDIAN_ROLE(), callEnv.msg.sender);

    unpauseInstantly@withrevert(callEnv, target);

    assert lastReverted, "a pause was released by an account holding no guardian role";
}

rule strippingACancellerWithoutTheGuardianRoleAlwaysReverts() {
    env callEnv;
    require !hasRole(GUARDIAN_ROLE(), callEnv.msg.sender);

    address[] accounts;
    revokeCancellersInstantly@withrevert(callEnv, accounts);

    assert lastReverted, "the cancel power was stripped by an account holding no guardian role";
}

/// A-09. Taking ownership writes nothing here.
///
/// `acceptOwnershipBatch` is permissionless, which is safe only because it takes ownership the
/// current owner already offered and changes nothing about who controls this contract. That second
/// half is what this says: an open function on the owner of the whole protocol touches no role, no
/// operation and no delay.
rule acceptingOwnershipWritesNoAdminState(bytes32 role, address account, bytes32 id) {
    env callEnv;
    theRoleTableIsAsDeployed(callEnv, role);

    bool heldBefore = hasRole(role, account);
    uint256 timestampBefore = getTimestamp(id);
    uint256 delayBefore = getMinDelay();

    address[] targets;
    acceptOwnershipBatch(callEnv, targets);

    assert hasRole(role, account) == heldBefore, "taking ownership moved a role";
    assert getTimestamp(id) == timestampBefore, "taking ownership moved an operation";
    assert getMinDelay() == delayBefore, "taking ownership moved the delay";
}

/// A-10. A guardian never also holds the cancel power, whatever call sequence ran.
///
/// The constructor refuses this overlap and used to be the only place that did: an account holding
/// both could revoke every other canceller, become the only one, and cancel its own eviction
/// forever. `grantRole` now refuses it too, so this restates A-06's guardian exception as a standing
/// invariant of the role table rather than only a constructor-time check.
///
/// This rule is expected to report one violation on `grantRole` under via-IR, on a counterexample
/// where `account` is the zero address. It is a prover artifact, not a defect: the same source and
/// the same rule verify when the contract is compiled without via-IR, job
/// `bd9b8400f48045538134cbae342d9eb5`. The override at `ProtocolAdmin.grantRole` reverts on exactly
/// the state the counterexample reaches, so no call can produce it.
///
/// The counterexample state is also inert, which is worth stating because the zero address means
/// two different things in this contract. `GUARDIAN_ROLE`, `CANCELLER_ROLE` and `PROPOSER_ROLE` are
/// all read through `onlyRole`, which compares the holder against `msg.sender`, and no transaction
/// has a sender of zero. Zero holding one of those roles therefore empowers nobody, and zero
/// holding both empowers nobody twice. `EXECUTOR_ROLE` is the single exception: it is read through
/// `onlyRoleOrOpenRole`, which treats a grant to the zero address as a sentinel meaning execution
/// is open to everyone. That reading applies at two call sites in `TimelockController`, both for
/// `EXECUTOR_ROLE`, and nowhere else.
///
/// Do not narrow this rule with `require account != 0` to make the via-IR job read clean. That
/// would hide a genuine overlap at any other account just as effectively as it hides this one.
rule theGuardianAndCancellerRolesNeverOverlap(method f, address account) {
    require !(hasRole(GUARDIAN_ROLE(), account) && hasRole(CANCELLER_ROLE(), account));

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert !(hasRole(GUARDIAN_ROLE(), account) && hasRole(CANCELLER_ROLE(), account)),
        "an account ended up holding both the guardian role and the cancel power";
}
