/// Registry association rules.
///
/// The registry holds four facts about every wallet the protocol knows: whether a device wallet is
/// valid, which device wallet holds a given eSIM wallet, whether that eSIM wallet is on standby,
/// and which device wallet a P256 key is registered to. Every rule here is about those four staying
/// consistent with each other under any call sequence, including ones no current caller makes.
///
/// Scope and what it costs. Calls out of the registry into wallets and factories are summarised as
/// NONDET, so the prover explores this contract's own storage rather than the whole protocol. That
/// is sound for reads. It is not sound for one call: `deployLazyWallet` reaches the device wallet
/// factory, which calls back into `updateDeviceWalletInfo`, and a NONDET summary removes that
/// return path. Rules quantifying over every method therefore prove less about that one function
/// than about the rest, and the cross-contract statement is the separate Milestone 3 work.
///
/// Two bounded assumptions, both recorded because a result quoted without them says more than it
/// proves. Loops unroll three times, so a proof covers batches of at most three rather than all
/// batches. Hashing of unbounded-length arguments is assumed to stay inside 224 bytes, which the
/// string identifiers and eSIM string arrays reaching this contract do; without it every method
/// taking a `string` reports a violation that is about the bound rather than about the contract.
///
/// Vacuity, reported by `rule_sanity`. The transition rules below are implications over every
/// method, so for any method that cannot touch the association the antecedent is unsatisfiable and
/// the sanity check fails. That is structural to a parametric implication and is not a result. What
/// matters is the methods that can reach the antecedent, which are the ones named in the assert
/// failures.

methods {
    function isDeviceWalletValid(address) external returns (bool) envfree;
    function isESIMWalletValid(address) external returns (address) envfree;
    function isESIMWalletOnStandby(address) external returns (bool) envfree;
    function registeredP256Keys(bytes32) external returns (address) envfree;
    function uniqueIdentifierToDeviceWallet(string) external returns (address) envfree;

    function vault() external returns (address) envfree;
    function eSIMWalletAdmin() external returns (address) envfree;
    function newRequestedAdmin() external returns (address) envfree;
    function entryPoint() external returns (address) envfree;
    function deviceWalletFactory() external returns (address) envfree;

    /// Nothing outside this contract is in the scene. Without this every external call would havoc
    /// the registry's own storage and every rule below would be unprovable for the wrong reason.
    unresolved external in _._ => DISPATCH [] default NONDET;
}

/// R-02, first half. Standby means no device wallet is holding it.
///
/// The plain biconditional `onStandby <=> valid == 0` is not provable, and the reason is not a bug.
/// Both halves read zero for an address nobody ever registered, so the biconditional is already
/// false in the post-constructor state and would fail before touching a single entry point. That
/// combination is a third state rather than a violation, and the contract already agrees:
/// `populateLazyHistory` reads exactly it as "not a protocol eSIM wallet" at
/// `RegistryHelper.sol:263`. What the code is trying to maintain is this implication plus the
/// transition rules below.
invariant standbyMeansNoDeviceWalletHoldsIt(address e)
    isESIMWalletOnStandby(e) => isESIMWalletValid(e) == 0;

/// R-02, second half. Releasing an eSIM wallet must put it on standby in the same call.
///
/// This is the half the two-call gap breaks. `bindESIMWallet` writes both, but it is not the only
/// way to clear the association.
rule releasingAnESIMWalletAlwaysRaisesStandby(method f, address e) {
    address heldBefore = isESIMWalletValid(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address heldAfter = isESIMWalletValid(e);

    assert heldBefore != 0 && heldAfter == 0 => isESIMWalletOnStandby(e),
        "an eSIM wallet was released without being put on standby";
}

/// R-02, third half. Taking an eSIM wallet on must clear standby in the same call.
rule takingOnAnESIMWalletAlwaysClearsStandby(method f, address e) {
    address heldBefore = isESIMWalletValid(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address heldAfter = isESIMWalletValid(e);

    assert heldBefore == 0 && heldAfter != 0 => !isESIMWalletOnStandby(e),
        "an eSIM wallet is held by a device wallet and on standby at the same time";
}

/// R-02, fourth half. Standby cannot be set on a wallet a device wallet still holds, whatever the
/// association did in the same call. Stated separately from the invariant because a rule reports
/// the entry point that broke it, which an invariant counterexample does not always name.
rule standbyIsNeverSetOnAHeldWallet(method f, address e) {
    require !isESIMWalletOnStandby(e) || isESIMWalletValid(e) == 0;

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isESIMWalletOnStandby(e) => isESIMWalletValid(e) == 0,
        "a wallet was put on standby while a device wallet still held it";
}

/// R-01. An eSIM wallet is only ever bound to a device wallet the registry considers valid.
invariant everyHeldESIMWalletNamesAValidDeviceWallet(address e)
    isESIMWalletValid(e) != 0 => isDeviceWalletValid(isESIMWalletValid(e));

/// R-03. A registered P256 key only ever names a device wallet the registry considers valid.
invariant everyRegisteredKeyNamesAValidDeviceWallet(bytes32 keyHash)
    registeredP256Keys(keyHash) != 0 => isDeviceWalletValid(registeredP256Keys(keyHash));

/// R-04. A device wallet becomes valid through one entry point and one caller.
///
/// Parametric, so it covers entry points added later as well as the ones there today. That is worth
/// more than the specific fact: the check is `onlyDeviceWalletFactory` today, and a second write
/// added anywhere later fails here without anyone remembering to extend a test.
rule aDeviceWalletBecomesValidOnlyThroughTheFactory(method f, address d) {
    require !isDeviceWalletValid(d);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isDeviceWalletValid(d) =>
        f.selector == sig:updateDeviceWalletInfo(address, string, bytes32[2]).selector,
        "a device wallet was made valid by something other than updateDeviceWalletInfo";

    assert isDeviceWalletValid(d) => callEnv.msg.sender == deviceWalletFactory(),
        "a device wallet was made valid by a caller that is not the device wallet factory";
}

/// R-05. Validity is one-way. Nothing revokes a device wallet, which is why every other rule here
/// can lean on `isDeviceWalletValid` without asking when it was set.
rule aValidDeviceWalletNeverBecomesInvalid(method f, address d) {
    require isDeviceWalletValid(d);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isDeviceWalletValid(d), "a device wallet lost its validity";
}

/// R-06, first half. The vault and the entry point are set once and never move.
///
/// Split from the admin below because the plan states all three as initialize-only and that is
/// wrong for one of them. These two are genuinely write-once.
rule theVaultAndEntryPointMoveOnlyAtInitialization(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address vaultBefore = vault();
    address entryPointBefore = entryPoint();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert vault() == vaultBefore, "the vault address moved outside initialization";
    assert entryPoint() == entryPointBefore, "the entry point moved outside initialization";
}

/// R-06, second half. The admin is not write-once, and stating it as such would have proved
/// nothing. It moves through a two-step handover, and the property worth having is that the
/// handover is the only route and that it lands on the address that was nominated.
rule theAdminMovesOnlyToTheNominatedAddress(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address adminBefore = eSIMWalletAdmin();
    address nominated = newRequestedAdmin();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address adminAfter = eSIMWalletAdmin();

    assert adminAfter != adminBefore => f.selector == sig:acceptAdminUpdate().selector,
        "the admin moved through something other than acceptAdminUpdate";

    assert adminAfter != adminBefore => adminAfter == nominated,
        "the admin moved to an address that was never nominated";
}

/// R-06, third half. Accepting the handover clears the nomination, so one nomination cannot be
/// replayed to take the role back after it has been passed on again.
rule acceptingTheAdminHandoverClearsTheNomination() {
    env callEnv;
    acceptAdminUpdate(callEnv);

    assert newRequestedAdmin() == 0, "the nomination survived being accepted";
}
