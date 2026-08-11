/// Registry association rules.
///
/// The registry holds four facts about every wallet the protocol knows: whether a device wallet is
/// valid, which device wallet an eSIM wallet is registered to, whether that eSIM wallet is in
/// transit between devices, and which device wallet a P256 key is registered to. Every rule here is
/// about how those four move under any call sequence, including ones no current caller makes.
///
/// The association and the transit marker are deliberately independent. The association is a
/// registration that also names the last device wallet to hold the eSIM wallet, and it stays put
/// through a transfer; the marker says a transfer is outstanding. Rules that tie them to each other
/// are not just unprovable, they are wrong about the design.
///
/// Scope and what it costs. Calls out of the registry into wallets and factories are summarised as
/// NONDET, so the prover explores this contract's own storage rather than the whole protocol. That
/// is sound for reads. It is not sound for one call: `deployLazyWallet` reaches the device wallet
/// factory, which calls back into `updateDeviceWalletInfo`, and a NONDET summary removes that
/// return path. Rules quantifying over every method therefore prove less about that one function
/// than about the rest, and the cross-contract statement is the separate Milestone 3 work.
///
/// The dispatch list is empty, so the one delegate call in this contract, `upgradeToAndCall`
/// reaching `Address.functionDelegateCall`, always takes the NONDET default. Nothing below says
/// anything about what a new implementation's initializer does to registry storage on the way
/// through an upgrade. That is deliberate, since the implementation is not known here, but it means
/// the write-once rules cover every caller except the one that replaces the code.
///
/// Two bounded assumptions, both recorded because a result quoted without them says more than it
/// proves. Loops unroll three times, so a proof covers batches of at most three rather than all
/// batches. Hashing of unbounded-length arguments is assumed to stay inside 224 bytes, which the
/// string identifiers and eSIM string arrays reaching this contract do; without it every method
/// taking a `string` reports a violation that is about the bound rather than about the contract.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` adds `assert false`
/// to the end of each rule and reports the verdict of that modified rule rather than a verdict on
/// the check. A record reading `Violated: <rule>-<method>-rule_not_vacuous` means the body was
/// reachable, which is the outcome wanted. The inverse, a `rule_not_vacuous` record reading
/// verified, is the one that says the rule proved nothing for that method.
///
/// `renounceOwnership()` is the only method that reads verified there, and it is right to: it is
/// overridden to revert unconditionally, so no rule body can complete on it. Every other method
/// reaches the body. The headline count adds the reachability records to the assert failures and so
/// reports a clean run as mostly violated. Count the records without a sanity suffix instead.

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

/// R-02, first part. A registration is never withdrawn.
///
/// The association and the standby flag are unrelated facts, so the rules here are about each on
/// its own rather than about the two agreeing. An earlier version of this spec stated R-02 as
/// `onStandby <=> valid == 0`, taken from the mapping's own comment. That comment was wrong about
/// the design and has been corrected: the association names the device wallet that last held the
/// eSIM wallet and keeps naming it through a transfer, so the two are true at once by design.
///
/// This is the property everything else leans on. Zero is how the registry spells an address it
/// never heard of, so a wallet that has been registered must never read it again.
rule aRegistrationIsNeverWithdrawn(method f, address e) {
    require isESIMWalletValid(e) != 0;

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert isESIMWalletValid(e) != 0, "a registered eSIM wallet lost its registration";
}

/// R-02, second part. The association moves through one entry point, and only onto its caller.
///
/// Parametric, so an entry point added later has to satisfy it without anyone remembering to
/// extend a test.
rule theAssociationMovesOnlyThroughBind(method f, address e) {
    address heldBefore = isESIMWalletValid(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address heldAfter = isESIMWalletValid(e);

    assert heldAfter != heldBefore =>
        f.selector == sig:bindESIMWallet(address, address).selector,
        "the association moved through something other than bindESIMWallet";

    assert heldAfter != heldBefore => heldAfter == callEnv.msg.sender,
        "a device wallet took on an eSIM wallet for somebody else";
}

/// R-02, third part. The marker is raised only by the release, and lowered only by those two.
///
/// Two writers rather than one, which is why this is stated as a rule over every method instead of
/// left to the access control on either.
rule theStandbyMarkerHasExactlyTwoWriters(method f, address e) {
    bool markedBefore = isESIMWalletOnStandby(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    bool markedAfter = isESIMWalletOnStandby(e);

    assert !markedBefore && markedAfter =>
        f.selector == sig:toggleESIMWalletStandbyStatus(address, bool).selector,
        "an eSIM wallet was marked in transit by something other than the release";

    assert markedBefore && !markedAfter =>
        f.selector == sig:toggleESIMWalletStandbyStatus(address, bool).selector ||
        f.selector == sig:bindESIMWallet(address, address).selector,
        "the transit marker was lowered by something that neither binds nor releases";
}

/// R-02, fourth part. The two facts are independent, so no call moves both.
///
/// `bindESIMWallet` is the one exception and it is named here rather than hidden: taking a wallet
/// on is the single moment both change, which is the whole reason it is one call and not two.
rule nothingButBindMovesBothFacts(method f, address e) {
    address heldBefore = isESIMWalletValid(e);
    bool markedBefore = isESIMWalletOnStandby(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert (isESIMWalletValid(e) != heldBefore && isESIMWalletOnStandby(e) != markedBefore) =>
        f.selector == sig:bindESIMWallet(address, address).selector,
        "a call moved the association and the transit marker together";
}

/// R-01. An eSIM wallet is only ever associated with a device wallet the registry considers valid.
///
/// Stated as a transition rule rather than an invariant. The invariant form held over a state
/// nothing had to reach, so it said the association was consistent without ever watching one move.
/// The rule form asserts against the value the call actually wrote, which is the statement worth
/// having and is what the induction step was standing in for.
rule everyAssociationNamesAValidDeviceWallet(method f, address e) {
    address heldBefore = isESIMWalletValid(e);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address heldAfter = isESIMWalletValid(e);

    assert heldAfter != heldBefore => isDeviceWalletValid(heldAfter),
        "an eSIM wallet was associated with something the registry does not consider a device wallet";
}

/// R-03. A registered P256 key only ever names a device wallet the registry considers valid.
///
/// Same reformulation as R-01, for the same reason.
rule everyRegisteredKeyNamesAValidDeviceWallet(method f, bytes32 keyHash) {
    address namedBefore = registeredP256Keys(keyHash);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    address namedAfter = registeredP256Keys(keyHash);

    assert namedAfter != namedBefore && namedAfter != 0 => isDeviceWalletValid(namedAfter),
        "a P256 key was registered to something the registry does not consider a device wallet";
}

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

/// R-06, first half. The entry point is set once and never moves.
///
/// Split from the admin below because the plan states all three as initialize-only and that is
/// wrong for two of them. This one is genuinely write-once.
rule theEntryPointMovesOnlyAtInitialization(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address entryPointBefore = entryPoint();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert entryPoint() == entryPointBefore, "the entry point moved outside initialization";
}

/// The vault moves only through its own setter.
///
/// The vault is where every data bundle payment lands, and it is read here on each purchase rather
/// than cached anywhere, so this one write reaches every wallet. It used to sit on the device wallet
/// factory as well, where nothing on the payment path read it, which left the only rotatable copy
/// pointing somewhere the money never went.
rule theVaultMovesOnlyThroughItsSetter(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address vaultBefore = vault();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert vault() != vaultBefore => f.selector == sig:updateVaultAddress(address).selector,
        "the vault address moved through something other than its setter";
}

/// The vault is never set to the zero address.
///
/// A zero vault would send every subsequent data bundle payment to an address nobody holds. The
/// setter checks for it and this says the check has no way around it.
rule theVaultIsNeverSetToZero(address newVault) {
    require vault() != 0;

    env callEnv;
    updateVaultAddress@withrevert(callEnv, newVault);

    assert !lastReverted => vault() != 0, "the vault was set to the zero address";
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
