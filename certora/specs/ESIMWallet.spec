/// ESIMWallet ownership state machine.
///
/// An eSIM wallet holds five facts worth proving about: who owns it, which device wallet it belongs
/// to, who has been offered it, the identifier it was issued under, and its purchase history. The
/// first two are supposed to be the same address at all times and the rules below say so directly,
/// because a wallet whose owner and device wallet disagree is one neither side can act on. Four of
/// the five are covered here. Purchase history is not, for a prover limitation recorded at the foot
/// of this file.
///
/// Scope. Calls out of this wallet into the device wallet, the registry and the vault are
/// summarised as NONDET, so the prover explores this contract's own storage rather than the whole
/// protocol. Sound for the properties here, all of which are about storage this contract writes
/// itself. It does mean a proof says nothing about whether the device wallet agreed: that
/// two-sided statement is the cross-contract rule in the later milestone.
///
/// Two bounded assumptions, recorded because a result quoted without them says more than it proves.
/// The history loop unrolls three times, so `populateHistory` is covered for batches of at most
/// three. Hashing of unbounded arguments is assumed within 224 bytes, which the identifiers and
/// bundle IDs reaching this contract are; without it every method taking a `string` reports a
/// violation about the bound rather than about the contract.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// A record reading `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which
/// is the outcome wanted. A `rule_not_vacuous` record reading verified is the failure.
///
/// Three methods used to read verified on every run and none of them does now. `renounceOwnership()`
/// and `transferOwnership(address)` are both overridden to revert unconditionally, so no rule body
/// could complete on them; they are filtered out of the parametric rules and pinned by
/// `theOverriddenOwnershipEntryPointsAlwaysRevert` instead. `setESIMUniqueIdentifier(string)` read
/// verified on `noMethodReopensTheIdentifier` alone, since that rule issues an identifier before it
/// runs the method and the setter is meant to refuse a second one; it is filtered out there and
/// covered by `theIdentifierIsIssuedAtMostOnce` directly above. Count the records carrying no sanity
/// suffix and ignore the fraction.

methods {
    function owner() external returns (address) envfree;
    function newRequestedOwner() external returns (address) envfree;
    function deviceWallet() external returns (address) envfree;
    function eSIMWalletFactory() external returns (address) envfree;
    function priceCapUSDCents() external returns (uint64) envfree;

    /// Nothing outside this contract is in the scene. Without this the device wallet and registry
    /// calls would havoc this wallet's own storage and every rule below would fail for the wrong
    /// reason.
    unresolved external in _._ => DISPATCH [] default NONDET;
}

/// The two methods no rule body can complete on.
///
/// Both are overridden to revert on every input, so a parametric rule that leaves them in buys two
/// vacuity records per rule and proves nothing. Filtered out everywhere below and pinned by the rule
/// underneath instead, so removing an override fails a check rather than quietly turning a pile of
/// vacuity records into real ones nobody reads.
definition alwaysReverts(method f) returns bool =
    f.selector == sig:renounceOwnership().selector
 || f.selector == sig:transferOwnership(address).selector;

/// Neither OpenZeppelin ownership entry point is reachable.
///
/// What the filter above gives up, stated directly. `transferOwnership` would move the owner in one
/// step past the offer this contract's whole state machine is built on, and `renounceOwnership`
/// would leave the wallet owned by nobody while `deviceWallet` still named the old holder, stranding
/// its ETH.
rule theOverriddenOwnershipEntryPointsAlwaysRevert(address candidate) {
    env callEnv;

    renounceOwnership@withrevert(callEnv);
    assert lastReverted, "an eSIM wallet owner was able to renounce ownership";

    transferOwnership@withrevert(callEnv, candidate);
    assert lastReverted, "ownership moved through the one-step OpenZeppelin entry point";
}

/// The identifier is issued once and never reissued.
///
/// Stated as two calls rather than as a comparison of the stored string, which CVL handles poorly.
/// Driving the setter twice is the stronger statement anyway: it covers a second call with any
/// argument at all, including the one already stored.
rule theIdentifierIsIssuedAtMostOnce() {
    env firstCall;
    env secondCall;
    string first;
    string second;

    setESIMUniqueIdentifier(firstCall, first);
    setESIMUniqueIdentifier@withrevert(secondCall, second);

    assert lastReverted, "a second identifier was accepted after one was already issued";
}

/// R-07. No method reopens an identifier once one has been issued.
///
/// Parametric, so a method added later has to satisfy it without anyone remembering to extend a
/// test. Written as issue, run anything, try to issue again, because CVL cannot read a stored
/// string to compare it. Driving the setter is the stronger statement in any case: it is the only
/// writer, so a method that cleared the identifier would show up here as the setter succeeding
/// twice, whatever it wrote.
///
/// The setter is filtered out of the middle call only. It is driven either side regardless, and as
/// the middle call it can never run, since the rule has just issued an identifier. Leaving it in
/// bought one vacuity record; the case it stands for is `theIdentifierIsIssuedAtMostOnce` above.
rule noMethodReopensTheIdentifier(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:setESIMUniqueIdentifier(string).selector
} {
    env issuing;
    string identifier;
    setESIMUniqueIdentifier(issuing, identifier);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    env reissuing;
    string another;
    setESIMUniqueIdentifier@withrevert(reissuing, another);

    assert lastReverted, "a method reopened an identifier that had already been issued";
}

/// R-08. An owned wallet never becomes unowned.
///
/// The original plan expected this to fail, catching the renounce path that leaves `owner()` at zero
/// while `deviceWallet` still names the old holder, stranding the wallet's ETH. `renounceOwnership`
/// has since been overridden to revert, which is pinned by
/// `theOverriddenOwnershipEntryPointsAlwaysRevert` rather than here. This stays parametric so a
/// future method that clears the owner some other way fails here.
///
/// A transition rule rather than an invariant on purpose: the owner is set in `initialize` rather
/// than a constructor, so an invariant would have to fail its base case before saying anything.
rule anOwnedWalletNeverBecomesUnowned(method f) filtered { f -> !alwaysReverts(f) } {
    require owner() != 0;

    env callEnv;
    calldataarg args;

    /// The zero address cannot originate a call. Without this the prover hands back
    /// `acceptOwnershipTransfer` called by zero with nothing offered, which passes its own
    /// `msg.sender == newRequestedOwner` guard and lands the owner at zero. That state is
    /// unreachable on chain, so a zero-check on the accept path would defend nothing.
    require callEnv.msg.sender != 0;

    f(callEnv, args);

    assert owner() != 0, "an owned eSIM wallet lost its owner";
}

/// R-09. An outstanding offer never names the address that already holds the wallet.
///
/// Offering a wallet to its own holder is how the code spells revoking the offer, so the state this
/// forbids is the one where a revoke was recorded as a transfer.
///
/// `initialize` is filtered out because it is the one method that moves the owner without reading
/// the offer. Left in, the prover starts from an arbitrary state carrying an offer, initializes the
/// owner onto that same address and reports it. That prestate does not exist: the offer is written
/// only by `requestTransferOwnership`, which admits only the device wallet, and the device wallet is
/// named by this very function.
rule anOutstandingOfferNeverNamesTheCurrentOwner(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    require newRequestedOwner() == 0 || newRequestedOwner() != owner();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert newRequestedOwner() == 0 || newRequestedOwner() != owner(),
        "an eSIM wallet was left offered to the device wallet already holding it";
}

/// R-10. Accepting an offer consumes it and lands the wallet on the address that accepted.
///
/// An offer that survived being accepted could be replayed to take the wallet back after it had
/// moved on to somebody else.
rule acceptingAnOfferConsumesItAndMovesTheWallet() {
    address requested = newRequestedOwner();

    env callEnv;
    acceptOwnershipTransfer(callEnv);

    assert newRequestedOwner() == 0, "the offer survived being accepted";
    assert owner() == requested, "the wallet landed somewhere other than the address that accepted it";
}

/// R-11. Ownership moves through one entry point and only onto the address that was offered it.
///
/// `initialize` is filtered out because it is where the owner is first set. Everything else,
/// including the two OpenZeppelin entry points this contract overrides to revert, has to leave the
/// owner alone or go through the offer.
rule theOwnerMovesOnlyToTheOfferedAddress(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    address ownerBefore = owner();
    address offered = newRequestedOwner();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address ownerAfter = owner();

    assert ownerAfter != ownerBefore => f.selector == sig:acceptOwnershipTransfer().selector,
        "ownership moved through something other than acceptOwnershipTransfer";

    assert ownerAfter != ownerBefore => ownerAfter == offered,
        "ownership moved to an address that was never offered the wallet";
}

/// The owner and the device wallet are the same address, always.
///
/// Two slots holding one fact, written together in `initialize` and again in
/// `_secureTransferOwnership`. This is the rule that would catch them drifting apart, which is the
/// shape of defect that a separate registry mapping already produced once elsewhere in this
/// protocol. `sendETHToDeviceWallet` pays out to `owner()` while `onlyDeviceWallet` admits
/// `deviceWallet`, so a drift is directly a misdirected payment.
rule theOwnerIsAlwaysTheDeviceWallet(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    require owner() == deviceWallet();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert owner() == deviceWallet(),
        "the owner and the device wallet came apart";
}

/// R-12. Purchase history is append-only.
///
/// Two writers, `buyDataBundleWithToken` and the registry's `populateHistory`, and neither is
/// allowed to drop an entry. History is what a dispute is settled from, so losing one is not
/// recoverable.
///
/// Not stated here, because the prover cannot reach the array length on this contract. The storage
/// analysis fails on `setESIMUniqueIdentifier`, and every phrasing needs it:
///
///   - reading `currentContract.transactionHistory.length` fails to compile against that analysis
///   - a ghost mirror fed by storage hooks is worse, since one hook anywhere makes the analysis run
///     over every method and errors out all the rules, not just this one
///   - the generated getter is not modelled as reverting out of bounds, so "an entry that was
///     readable stays readable" passes while proving nothing
///
/// Lowering the optimizer to 200 does not shift it either. The property is real and stays owed, so
/// it is carried by a Foundry invariant instead of a rule here.

/// The wallet's own price ceiling is only ever set by its setter, and only ever cleared by a
/// handover.
///
/// Not in the original milestone list, since the ceiling postdates it. Worth stating because the
/// ceiling is what stops the admin naming its own price on `buyDataBundleWithToken`, and the guard
/// on the setter is the whole of that protection.
///
/// The second assert is what makes the handover exception safe. A handover may only take the
/// ceiling to zero, which hands the wallet to the registry default rather than to a figure the
/// outgoing owner chose. Anything else on that path would be a second, unguarded writer.
rule thePriceCeilingIsSetOnlyByItsSetter(method f) filtered { f -> !alwaysReverts(f) } {
    uint64 capBefore = priceCapUSDCents();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    uint64 capAfter = priceCapUSDCents();

    assert capAfter != capBefore =>
        (f.selector == sig:setPriceCapUSDCents(uint64).selector ||
         f.selector == sig:acceptOwnershipTransfer().selector),
        "the price ceiling moved through something other than its setter or a handover";

    assert (capAfter != capBefore && f.selector == sig:acceptOwnershipTransfer().selector) =>
        capAfter == 0,
        "a handover left the wallet on a ceiling rather than on the registry default";
}

/// The factory that deployed this wallet is write-once.
rule theFactoryIsWriteOnce(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    address factoryBefore = eSIMWalletFactory();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert eSIMWalletFactory() == factoryBefore, "the deploying factory was overwritten";
}
