/// DeviceWalletFactory: the addresses it is wired to, and the record of what it deployed.
///
/// This contract owns the beacon every device wallet runs on, so it is the single point from which
/// all of them can be moved at once. It also holds the vault that receives payment, the registry it
/// reports deployments to, and a per-wallet flag saying that report was made. Nothing here is a
/// balance, and the rules are about which of those may move and through what.
///
/// Two rules the milestone list asked for are not here, and the reason is that the contract moved
/// on. R-19 and R-20 are about `eSIMWalletAdmin` and `newRequestedAdmin`, and neither is storage
/// this contract has any more. The admin is read off the registry on every call, through the
/// `eSIMWalletAdmin()` view at the top of this file, so that the factory cannot fall behind the rest
/// of the protocol after a rotation. The two-step handover those rules describe now happens in the
/// registry and is proved there.
///
/// Scope. Calls out of this factory, into the registry, the eSIM wallet factory, the beacon and the
/// wallets it deploys, are summarised as NONDET. Same limit as the earlier milestones: NONDET
/// returns an arbitrary value and writes nothing, so nothing here is a statement about re-entrancy.
///
/// The consequence to keep in mind while reading any result below is that `eSIMWalletAdmin()` reads
/// through the registry and therefore answers arbitrarily, so `onlyAdmin` and `onlyAdminOrRegistry`
/// admit any caller as far as the prover is concerned. `onlyOwner` is the one guard that survives,
/// since it reads local storage. Read every rule with that in mind: a rule holding over an arbitrary
/// caller holds for a stronger reason than the code gives, and no rule here says who may call what.
///
/// The curve check on an owner key is summarised, the same as in the DeviceWallet spec, because it
/// is field arithmetic no rule below reads an answer from.
///
/// Loops unroll three times, so every statement about `deployDeviceWalletForUsers` covers batches of
/// at most three. Hashing of unbounded arguments is assumed within 224 bytes.
///
/// That hashing bound costs two methods outright, and it is worth knowing which. `createAccount` and
/// `getCounterFactualAddress` both hash `type(BeaconProxy).creationCode`, which is thousands of
/// bytes, so under the bound they always revert and no rule below says anything about them. They
/// show up as `rule_not_vacuous` records reading verified. Neither writes any of the storage these
/// rules are about, so what is lost is the confirmation rather than the property, but the honest
/// statement is that the counterfactual address derivation is not covered here at all. Raising the
/// bound to cover the creation code would make every other hash in the contract more expensive, and
/// the return on it is one confirmation, so it is left where it is.
///
/// `renounceOwnership` also reads unreachable, and correctly: it is overridden to revert.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` appends `assert false`
/// to each rule and the log carries the verdict of that modified rule, not a verdict on the check.
/// `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which is the outcome
/// wanted. A `rule_not_vacuous` record reading verified is the failure. Count the records carrying
/// no sanity suffix and ignore the fraction.

methods {
    function registry() external returns (address) envfree;
    function vault() external returns (address) envfree;
    function beacon() external returns (address) envfree;
    function eSIMWalletFactory() external returns (address) envfree;
    function entryPoint() external returns (address) envfree;
    function verifier() external returns (address) envfree;
    function deviceWalletInfoAdded(address) external returns (bool) envfree;
    function owner() external returns (address) envfree;

    unresolved external in _._ => DISPATCH [] default NONDET;

    function FCL_Elliptic_ZZ.ecAff_isOnCurve(uint256 x, uint256 y) internal returns (bool) => NONDET;
}

/// R-21. The registry is written once.
///
/// The registry answers who the admin is, so every admin-gated function here resolves through it. A
/// second write would let the whole admin surface be pointed at a contract that names a different
/// admin, and the guard on that write is `onlyOwner`, which is one key.
rule theRegistryIsWriteOnce(method f) {
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

/// R-22. A wallet's deployment record is never withdrawn.
///
/// `deviceWalletInfoAdded` says this factory has already told the registry about a wallet.
/// `postCreateAccount` refuses a wallet carrying the flag, so clearing it would let the same wallet
/// be reported twice under a different identifier or a different owner key.
rule aDeploymentRecordIsNeverWithdrawn(method f, address deviceWallet) {
    require deviceWalletInfoAdded(deviceWallet);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert deviceWalletInfoAdded(deviceWallet), "a device wallet's deployment record was withdrawn";
}

/// Reporting the same wallet twice always reverts.
///
/// The other half of R-22. The flag never comes down, and this says the flag being up is actually
/// checked, so the registry cannot be handed a second identifier or a second owner key for a wallet
/// it already has a record of.
rule reportingAWalletTwiceAlwaysReverts(address deviceWallet) {
    require deviceWalletInfoAdded(deviceWallet);

    env callEnv;
    string identifier;
    bytes32[2] ownerKey;
    postCreateAccount@withrevert(callEnv, deviceWallet, identifier, ownerKey);

    assert lastReverted, "a device wallet already reported to the registry was reported again";
}

/// The vault moves only through its own setter.
///
/// The vault is where every data bundle payment lands. Not in the milestone list, and the more
/// interesting rule of the two about it, because the setter is admin-gated rather than owner-gated
/// and the admin is a hot key.
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

/// The beacon and the rest of the wiring are written once.
///
/// The beacon is the one address that decides what every device wallet in the protocol executes.
/// `entryPoint`, `verifier` and `eSIMWalletFactory` are set beside it and read the same way. All four
/// are written in `initialize` and nothing is supposed to move them afterwards: moving the beacon
/// would leave every deployed wallet pointing at an object this factory no longer controls, and the
/// upgrade path that is supposed to be used goes through the beacon, not around it.
rule theBeaconAndTheWiringAreWriteOnce(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address beaconBefore = beacon();
    address entryPointBefore = entryPoint();
    address verifierBefore = verifier();
    address eSIMWalletFactoryBefore = eSIMWalletFactory();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert beacon() == beaconBefore, "the beacon was replaced";
    assert entryPoint() == entryPointBefore, "the entry point was replaced";
    assert verifier() == verifierBefore, "the signature verifier was replaced";
    assert eSIMWalletFactory() == eSIMWalletFactoryBefore, "the eSIM wallet factory was replaced";
}

/// Ownership is never given up.
///
/// The owner is the only caller `_authorizeUpgrade` accepts, and this contract owns the beacon, so
/// the owner is also the only route to a device wallet implementation change. Renouncing would leave
/// every device wallet frozen on its current logic with no way back, which is why the function is
/// overridden to revert. Stated parametrically so a method added later that clears the owner without
/// going through the two-step handover fails here.
rule ownershipIsNeverGivenUp(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    require owner() != 0;

    env callEnv;
    calldataarg args;

    /// The zero address cannot originate a call. Without this the prover hands back
    /// `acceptOwnership` called by zero against a pending owner of zero, which passes its own
    /// `pendingOwner() == msg.sender` check and lands the owner at zero. Nothing on chain reaches
    /// that state, so a zero-check on the accept path would defend against nothing. Note that the
    /// outgoing owner really can name zero as the pending owner, since `Ownable2Step` does not
    /// refuse it; what stops the handover completing is that no caller can answer to it.
    require callEnv.msg.sender != 0;

    f(callEnv, args);

    assert owner() != 0, "the factory lost its owner";
}

/// The owner moves only through the two-step handover.
///
/// `Ownable2Step` is used deliberately here: a one-step transfer to a wrong address would hand away
/// the only key that can move the beacon, with nobody able to accept it back.
rule theOwnerMovesOnlyThroughTheHandover(method f) filtered {
    f -> f.selector != sig:initialize(address, address, address, address, address, address).selector
} {
    address ownerBefore = owner();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert owner() != ownerBefore => f.selector == sig:acceptOwnership().selector,
        "the factory owner moved through something other than acceptOwnership";
}
