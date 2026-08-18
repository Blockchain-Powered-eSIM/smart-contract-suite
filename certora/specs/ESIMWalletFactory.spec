/// ESIMWalletFactory: the addresses it is wired to, and the record of what it deployed.
///
/// This contract owns the beacon every eSIM wallet runs on, so it is the single point from which all
/// of them can be moved onto new logic at once. Beside that it holds the registry every caller check
/// reads through, and a per-address flag saying a wallet came out of this factory. Nothing here is a
/// balance, and the rules are about which of those may move and through what.
///
/// The registry rule is not the one the plan described. That text said the registry is set in
/// `initialize` and moved only by `addRegistryAddress`. It is not: `initialize` never touches it, and
/// `addRegistryAddress` is the only writer there has ever been. So the rule below is stated as
/// exactly one writer, written once, and never back to zero, which is what the code does.
///
/// Scope. Calls out of this factory, into the registry and into the beacon, are summarised as NONDET,
/// one signature at a time. A wildcard on unresolved calls would not catch them: the selector is
/// known and the callee is not, since it comes off a storage field, so the prover would pick its own
/// summary and havoc every other contract in the scene instead. NONDET returns an arbitrary value and
/// writes nothing, so nothing here is a statement about re-entrancy.
///
/// The consequence to carry into every rule below is that the caller gate on `deployESIMWallet` reads
/// through the registry and therefore answers arbitrarily, so
/// `onlyRegistryOrDeviceWalletFactoryOrDeviceWallet` admits any caller as far as the prover is
/// concerned, and so does the `OnlyDeployForSelf` check inside the body. `onlyOwner` is the one guard
/// that survives, since it reads local storage. A rule holding over an arbitrary caller holds for a
/// stronger reason than the code gives; no rule here says who may deploy a wallet.
///
/// The beacon's implementation is summarised for the same reason, and that is why no rule reads it.
/// `getCurrentESIMWalletImplementation` answers arbitrarily, so a rule comparing it across a call
/// would fail on the summary rather than on the contract. What is stated instead is that the beacon
/// address never moves and that the one method able to call `upgradeTo` on it refuses a non-owner.
/// Since this factory is the beacon's owner, those two together say the implementation moves only on
/// the owner's word, which is the property the plan asked for.
///
/// Loops unroll three times. Hashing of unbounded arguments is assumed within 1600 bytes, and that
/// bound is deliberately not the 224 the other six confs use. `deployESIMWallet` hashes
/// `type(BeaconProxy).creationCode` to predict its CREATE2 address, which is 1252 bytes, plus 192 of
/// encoded constructor arguments. Under 224 the assumption is false, the method always reverts, and
/// the two rules about the deployment record would be proved over every method except the only one
/// that writes it. Raising the bound costs nothing here because the CREATE2 prediction is the only
/// hash of an unbounded argument in the contract. The same call in `DeviceWalletFactory` was left
/// uncovered rather than raised, and correctly, since that contract hashes in several other places
/// and the bound is global.
///
/// `renounceOwnership` is overridden to revert unconditionally, so no rule body can complete on it.
/// It is filtered out of the parametric rules and pinned by `theRenouncePathAlwaysReverts` instead.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which is the outcome
/// wanted. A `rule_not_vacuous` record reading verified is the failure. Count the records carrying no
/// sanity suffix and ignore the fraction.

methods {
    function registry() external returns (address) envfree;
    function beacon() external returns (address) envfree;
    function isESIMWalletDeployed(address) external returns (bool) envfree;
    function owner() external returns (address) envfree;
    function pendingOwner() external returns (address) envfree;

    unresolved external in _._ => DISPATCH [] default NONDET;

    function _.deviceWalletFactory() external => NONDET;
    function _.isDeviceWalletValid(address) external => NONDET;
    function _.implementation() external => NONDET;
    function _.upgradeTo(address) external => NONDET;
}

/// The one method no rule body can complete on.
///
/// `renounceOwnership` is overridden to revert on every input, so a parametric rule that leaves it
/// in buys a vacuity record per rule and proves nothing. Filtered out everywhere below and pinned by
/// the rule underneath instead.
definition alwaysReverts(method f) returns bool =
    f.selector == sig:renounceOwnership().selector;

/// The renounce path is closed.
///
/// What the filter above gives up, stated directly. This contract owns the beacon, so an owner of
/// zero freezes every wallet under it on its current logic with no way back.
rule theRenouncePathAlwaysReverts() {
    env callEnv;
    renounceOwnership@withrevert(callEnv);

    assert lastReverted, "the factory owner was able to renounce ownership";
}

/// The registry is written once.
///
/// Every caller check in this contract resolves through the registry, three reads of it in the one
/// modifier. A second write would point all of them at a contract naming a different device wallet
/// factory and a different set of valid device wallets, and the guard on that write is `onlyOwner`,
/// which is one key.
/// `addRegistryAddress` reads vacuous under this rule and that is the expected answer, not a gap. The
/// rule requires a registry already set and the setter refuses exactly that state, so the pair has no
/// reachable case. `settingTheRegistryTwiceAlwaysReverts` below is where that refusal is proved.
rule theRegistryIsWriteOnce(method f) filtered { f -> !alwaysReverts(f) } {
    address registryBefore = registry();
    require registryBefore != 0;

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert registry() == registryBefore, "the registry address was overwritten";
}

/// The registry setter refuses a second call outright.
///
/// The rule above says no method moves a registry already set. This says the one method that sets it
/// reverts rather than silently doing nothing, which is what makes a mistaken second call visible to
/// whoever sent it.
rule settingTheRegistryTwiceAlwaysReverts(address newRegistry) {
    require registry() != 0;

    env callEnv;
    addRegistryAddress@withrevert(callEnv, newRegistry);

    assert lastReverted, "the registry was set a second time";
}

/// The registry is never set to zero.
///
/// A zero registry does not fail closed. `deployESIMWallet` would call into an address with no code,
/// and the one write this contract accepts would be spent on a value that can never be corrected,
/// since the setter is write-once.
rule theRegistryIsNeverSetToZero(address newRegistry) {
    env callEnv;
    addRegistryAddress@withrevert(callEnv, newRegistry);

    assert !lastReverted => registry() != 0, "the registry was set to the zero address";
}

/// The beacon is written once.
///
/// The beacon is the one address deciding what every eSIM wallet in the protocol executes. It is
/// created in `initialize` and nothing is supposed to move it afterwards. Moving it would leave every
/// deployed wallet reading its logic from an object this factory no longer owns, and would strand the
/// upgrade path, which goes through the beacon rather than around it.
rule theBeaconIsWriteOnce(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    address beaconBefore = beacon();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert beacon() == beaconBefore, "the beacon was replaced";
}

/// A wallet's deployment record is never withdrawn.
///
/// `isESIMWalletDeployed` is what the rest of the protocol asks to tell a wallet this factory made
/// from an address that merely claims to be one. The registry reads it before binding a wallet to a
/// device wallet, so clearing it would strand a live wallet outside the protocol with no way back:
/// the flag is only ever set by a deployment, and the address is already taken.
rule aDeploymentRecordIsNeverWithdrawn(method f, address eSIMWallet) filtered { f -> !alwaysReverts(f) } {
    require isESIMWalletDeployed(eSIMWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isESIMWalletDeployed(eSIMWallet), "an eSIM wallet's deployment record was withdrawn";
}

/// Only a deployment adds a deployment record.
///
/// The other half of the rule above. The flag never comes down, and this says it only goes up through
/// the method that actually creates the wallet, so no method can vouch for an address that was never
/// deployed here. Stated parametrically so a method added later that writes the map directly fails
/// here rather than in review.
rule onlyADeploymentAddsARecord(method f, address eSIMWallet) filtered { f -> !alwaysReverts(f) } {
    require !isESIMWalletDeployed(eSIMWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isESIMWalletDeployed(eSIMWallet) => f.selector == sig:deployESIMWallet(address, uint256).selector,
        "an eSIM wallet was recorded as deployed by something other than a deployment";
}

/// The eSIM wallet implementation moves only on the owner's word.
///
/// This factory owns the beacon, so `updateESIMWalletImplementation` is the only route to
/// `upgradeTo`, and one call there moves every eSIM wallet in the protocol at once with no per-wallet
/// opt-out. `onlyOwner` reads local storage rather than the registry, so unlike the deployment gate it
/// is a guard the prover can actually see.
rule onlyTheOwnerCanMoveTheImplementation(address newImplementation) {
    env callEnv;
    require callEnv.msg.sender != owner();

    updateESIMWalletImplementation@withrevert(callEnv, newImplementation);

    assert lastReverted, "a non-owner moved the eSIM wallet implementation";
}

/// Ownership is never given up.
///
/// The owner is the only caller `_authorizeUpgrade` accepts, and this contract owns the beacon, so
/// the owner is also the only route to an eSIM wallet implementation change. Renouncing would leave
/// every eSIM wallet frozen on its current logic with no way back, which is why the function is
/// overridden to revert. Stated parametrically so a method added later that clears the owner without
/// going through the two-step handover fails here.
rule ownershipIsNeverGivenUp(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    require owner() != 0;

    env callEnv;
    calldataarg args;

    /// The zero address cannot originate a call. Without this the prover hands back
    /// `acceptOwnership` called by zero against a pending owner of zero, which passes its own
    /// `pendingOwner() == msg.sender` check and lands the owner at zero. Nothing on chain reaches
    /// that state, so a zero-check on the accept path would defend against nothing. Note that the
    /// outgoing owner really can name zero as the pending owner, since `Ownable2Step` does not refuse
    /// it; what stops the handover completing is that no caller can answer to it.
    require callEnv.msg.sender != 0;

    f(callEnv, args);

    assert owner() != 0, "the factory lost its owner";
}

/// The owner moves only through the two-step handover.
///
/// `Ownable2Step` is used deliberately here: a one-step transfer to a wrong address would hand away
/// the only key that can move the beacon, with nobody able to accept it back.
rule theOwnerMovesOnlyThroughTheHandover(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address).selector
} {
    address ownerBefore = owner();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert owner() != ownerBefore => f.selector == sig:acceptOwnership().selector,
        "the factory owner moved through something other than acceptOwnership";
}
