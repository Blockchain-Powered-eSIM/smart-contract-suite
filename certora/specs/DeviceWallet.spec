/// DeviceWallet: the rights it hands to eSIM wallets, and the key that owns it.
///
/// A device wallet holds user ETH and decides which eSIM wallets may reach it. Two mappings carry
/// that decision, `isValidESIMWallet` for membership and `canPullETH` for the spending right, and
/// the second is meaningless without the first: `pullETH` checks `canPullETH` on its own, so a
/// wallet that kept the right after being let go would still be able to spend. The rules below fix
/// the relation between the two, fix the one ETH path against the balance, and fix the P256 key
/// that authorises everything this wallet does.
///
/// Scope. Calls out of this wallet, into the registry, the two factories and the eSIM wallets, are
/// summarised as NONDET, so what is proved is this contract's own storage. That is the same scope
/// the earlier milestones used and it carries the same limit: NONDET returns an arbitrary value and
/// writes nothing, so no rule here says anything about re-entrancy. The `nonReentrant` guard on the
/// path that makes an external call is what covers that, and it is covered by the unit tests rather
/// than here.
///
/// A second consequence of those summaries is that every access check reading the registry becomes
/// arbitrary. `onlyESIMWalletAdmin` asks the registry who the admin is and
/// `onlyRegistryOrDeviceWalletFactoryOrOwner` asks it for the factory address, so the prover may
/// answer with `msg.sender` and walk in. That is the conservative direction, exploring callers the
/// real protocol would refuse, and a rule holding anyway holds for a stronger reason. It does mean
/// no rule here states who may call what. The one guard that survives untouched is `onlySelf`, which
/// compares against `address(this)` and reads no storage.
///
/// `transferOwnership` and `toggleAccessToETH` are both `onlySelf`, so on chain they are reachable
/// only through `execute` with this wallet as the target, which needs a signature from the current
/// owner key. The rules drive them directly instead. That is the stronger statement about which
/// storage they write, and it says nothing about who could get there, which the paragraph above
/// already gave up.
///
/// Two bounded assumptions carry over from the earlier milestones. Loops unroll three times, so
/// `executeBatch` is covered for batches of at most three. Hashing of unbounded arguments is assumed
/// within 224 bytes, which the device identifiers and signature blobs reaching this contract are.
///
/// The curve check on a new owner key is summarised, because it is field arithmetic the prover would
/// spend the whole run on for an answer no rule reads. Stating it plainly: nothing here proves that
/// `transferOwnership` rejects an off-curve key. That one is in the unit tests. What the rules ask
/// is which storage a call may write, given that it got past whatever check it faced.
///
/// One method is genuinely out of reach here and it is expected. `init` calls the inherited
/// `initialize`, and OpenZeppelin lets a nested initialiser through on
/// `initialized == 1 && address(this).code.length == 0`, the branch that recognises a constructor.
/// The prover models this contract as carrying code, so that branch is false and `init` always
/// reverts. It shows up as a `rule_not_vacuous` record reading verified on the one rule that does
/// not filter `init` out. The long note on R-17 has the rest of it.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which is the outcome
/// wanted. A `rule_not_vacuous` record reading verified is the failure. Count the records carrying
/// no sanity suffix and ignore the fraction.

methods {
    function isValidESIMWallet(address) external returns (bool) envfree;
    function canPullETH(address) external returns (bool) envfree;
    function registry() external returns (address) envfree;
    function eSIMWalletFactory() external returns (address) envfree;

    /// `bytes32[2] public owner` generates an indexed getter, not one returning the pair.
    function owner(uint256) external returns (bytes32) envfree;

    /// Nothing outside this contract is in the scene. Without this the registry and eSIM wallet
    /// calls would havoc this wallet's own storage and every rule below would fail for the wrong
    /// reason.
    unresolved external in _._ => DISPATCH [] default NONDET;

    function FCL_Elliptic_ZZ.ecAff_isOnCurve(uint256 x, uint256 y) internal returns (bool) => NONDET;
}

/// R-13. A wallet that may pull ETH is a wallet this device wallet still recognises.
///
/// `canPullETH` is checked on its own in both spending paths, without a membership check beside it,
/// so this relation is the whole of what keeps a released wallet away from the balance.
/// `removeESIMWallet` clears both, and this says nothing anywhere leaves them apart.
///
/// A transition rule rather than an invariant because these wallets live behind a beacon proxy and
/// are set up in `init` rather than a constructor, so an invariant's base case would be arguing
/// about a state the proxy never occupies.
rule theRightToPullETHNeverOutlivesMembership(method f, address eSIMWallet) {
    require canPullETH(eSIMWallet) => isValidESIMWallet(eSIMWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert canPullETH(eSIMWallet) => isValidESIMWallet(eSIMWallet),
        "an eSIM wallet kept the right to pull ETH without being recognised";
}

/// R-14. The ETH path pays out no more than the wallet holds.
///
/// The route ends in `_transferETH`, which compares against the live balance. Stated over the entry
/// point rather than over the internal function, so the guard is proved where a caller meets it. It
/// is not payable, so the balance the call reads is the balance read here.
rule pullingMoreETHThanTheWalletHoldsAlwaysReverts(uint256 amount) {
    require amount > nativeBalances[currentContract];

    env callEnv;
    pullETH@withrevert(callEnv, amount);

    assert lastReverted, "an eSIM wallet pulled more ETH than the device wallet held";
}

/// R-15. The registry and the eSIM wallet factory are written once.
///
/// Both are set in `init` and both are read as authority: the registry answers who the admin is and
/// which factory is real, the factory is called to deploy. A second write to either would let the
/// wallet be pointed at a contract that answers those questions differently.
rule theRegistryAndFactoryAreWriteOnce(method f) filtered {
    f -> f.selector != sig:init(address, bytes32[2], string, address).selector
} {
    address registryBefore = registry();
    address factoryBefore = eSIMWalletFactory();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert registry() == registryBefore, "the registry address was overwritten";
    assert eSIMWalletFactory() == factoryBefore, "the eSIM wallet factory address was overwritten";
}

/// R-16. Removal withdraws both rights in the same call.
///
/// The call ends with a callback into the wallet being removed, which shares one upgradeable beacon
/// with every other eSIM wallet, so the logic that runs there is not fixed for the life of the
/// protocol. This says the two writes have landed before it runs, whatever it turns out to do.
rule removalWithdrawsMembershipAndTheRightToPullTogether(address eSIMWallet, bool callBackETH) {
    env callEnv;
    removeESIMWallet(callEnv, eSIMWallet, callBackETH);

    assert !isValidESIMWallet(eSIMWallet), "a removed eSIM wallet was still recognised";
    assert !canPullETH(eSIMWallet), "a removed eSIM wallet kept the right to pull ETH";
}

/// R-17. The owner key moves only through `transferOwnership`.
///
/// The key is the whole of the wallet's authority: every signature this contract checks is checked
/// against it, and a key written by anything other than the one guarded path is a wallet taken
/// over.
///
/// `init` is filtered out, being the function the deploy paths call to write the key in the first
/// place. Both deploy paths pass that call as the proxy's constructor argument, so a device wallet
/// is initialised in the same transaction that creates it and there is no window between the two.
/// The prover disagrees about reachability because of one line of OpenZeppelin's `initializer`,
/// `construction = initialized == 1 && address(this).code.length == 0`, which is how a nested
/// initialiser is allowed to run inside a constructor. The prover models this contract as already
/// carrying code, so that branch is false for it, which is why the reachability check reports `init`
/// unreachable in the rule above: the nested `initialize` inside it can never pass.
///
/// This rule once needed a second filter. The inherited `initialize(bytes32[2])` was public with
/// nothing but the `initializer` modifier on it, so the prover reached it from a wallet that had
/// never been initialised and wrote the key straight in. Nothing about the function refused a
/// caller; what kept it closed was entirely the atomicity of the deploy paths. It is internal now,
/// so there is no selector left to filter.
rule theOwnerKeyMovesOnlyThroughItsOwnEntryPoint(method f) filtered {
    f -> f.selector != sig:init(address, bytes32[2], string, address).selector
} {
    bytes32 xBefore = owner(0);
    bytes32 yBefore = owner(1);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert owner(0) != xBefore || owner(1) != yBefore =>
        f.selector == sig:transferOwnership(bytes32[2]).selector,
        "the owner key moved through something other than transferOwnership";
}

/// Membership is never granted twice over.
///
/// The add path refuses a wallet it already holds. That refusal is what stops a second grant quietly
/// resetting `canPullETH` on a wallet whose access the owner had already revoked, which would be a
/// revocation undone by a call that looks like it is only adding.
rule addingAWalletTwiceAlwaysReverts(address eSIMWallet, bool hasAccessToETH) {
    require isValidESIMWallet(eSIMWallet);

    env callEnv;
    addESIMWallet@withrevert(callEnv, eSIMWallet, hasAccessToETH);

    assert lastReverted, "an eSIM wallet already held by this device wallet was added again";
}

/// The toggle only ever moves a wallet this device wallet recognises.
///
/// The other half of R-13. That rule says the right never outlives membership; this says the right
/// is never granted to a wallet that never had membership in the first place, which is the case
/// where the two would come apart at the moment of the grant rather than later.
rule togglingETHAccessOnAnUnknownWalletAlwaysReverts(address eSIMWallet, bool hasAccessToETH) {
    require !isValidESIMWallet(eSIMWallet);

    env callEnv;
    toggleAccessToETH@withrevert(callEnv, eSIMWallet, hasAccessToETH);

    assert lastReverted, "ETH access was toggled on a wallet this device wallet does not recognise";
}

/// The right to pull ETH is only ever granted by the owner.
///
/// `toggleAccessToETH` is `onlySelf` and every bind path refuses the flag, so a revocation stands.
/// The admin used to undo one by deploying a second eSIM wallet with the flag set.
///
/// Stated over the whole method set, so a later function that writes the flag has to answer it too.
rule onlyToggleAccessToETHGrantsETHAccess(method f, address eSIMWallet) {
    require !canPullETH(eSIMWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert canPullETH(eSIMWallet) => f.selector == sig:toggleAccessToETH(address, bool).selector,
        "the right to pull ETH was granted by something other than toggleAccessToETH";
}
