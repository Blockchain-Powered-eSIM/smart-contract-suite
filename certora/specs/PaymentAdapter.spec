/// PaymentAdapter: the currency table and the payment references.
///
/// Two properties carry this contract. A currency the table has withdrawn must never return a
/// price, because the withdrawal is the only thing stopping a purchase being recorded against a
/// currency the protocol no longer accepts. And a payment reference must never be spendable twice,
/// because a reference is one offchain payment and the backend retries the whole onchain step on
/// any failure, so a reference that could be spent again is a user charged once and billed twice.
///
/// Scope. This contract calls nothing out, so there is no cross-contract statement to make here.
/// The dispatch list is empty, which leaves the one delegate call, `upgradeToAndCall` reaching
/// `Address.functionDelegateCall`, on the NONDET default. Nothing below says anything about what a
/// new implementation does to this storage on the way through an upgrade. That is deliberate, since
/// the implementation is not known here, but it means the write-once rules cover every caller
/// except the one that replaces the code.
///
/// The reference rules are the release 1 form of the property section 9 states over `settle`. There
/// is no `settle` yet, so what is provable now is the half that does not depend on it: a reference
/// is marked by one entry point, only for the registry, and never goes back.
///
/// `renounceOwnership()` is overridden to revert unconditionally, so no rule body can complete on
/// it. It is filtered out of every parametric rule and pinned by `theRenouncePathAlwaysReverts`
/// instead.
///
/// Reading the result, which the headline count gets backwards. `rule_sanity` adds `assert false`
/// to each rule and reports the verdict of that modified rule rather than a verdict on the check. A
/// record reading `Violated: <rule>-<method>-rule_not_vacuous` means the body was reachable, which
/// is the outcome wanted. Count the records carrying no sanity suffix and ignore the fraction.
///
/// Verified 2026-08-28 at
/// `prover.certora.com/output/7200817/464cd89895e440c7845d7bb5e4cbd4f5`: 146 records verified, zero
/// assert failures, every violated record carrying a `-rule_not_vacuous` suffix.

methods {
    function assets(bytes32) external returns (bool, bool, uint8, address) envfree;
    function usedReferences(bytes32) external returns (bool) envfree;
    function quote(bytes32, uint64) external returns (uint256) envfree;
    function registry() external returns (address) envfree;
    function settlementToken() external returns (address) envfree;
    function owner() external returns (address) envfree;

    /// Nothing outside this contract is in the scene.
    unresolved external in _._ => DISPATCH [] default NONDET;
}

/// Whether the table currently accepts this currency.
function currencyIsAllowed(bytes32 symbol) returns bool {
    bool allowed;
    bool isDollarUnit;
    uint8 decimals;
    address token;
    allowed, isDollarUnit, decimals, token = assets(symbol);

    return allowed;
}

/// A currency is registered once its decimals are non-zero, which is what the two setters read.
function currencyIsRegistered(bytes32 symbol) returns bool {
    bool allowed;
    bool isDollarUnit;
    uint8 decimals;
    address token;
    allowed, isDollarUnit, decimals, token = assets(symbol);

    return decimals != 0;
}

/// The one method no rule body can complete on.
definition alwaysReverts(method f) returns bool =
    f.selector == sig:renounceOwnership().selector;

/// The renounce path is closed.
///
/// What the filter above gives up, stated directly. The owner is the only caller
/// `_authorizeUpgrade` accepts and the only one that can change the currency table, so renouncing
/// would freeze both for good.
rule theRenouncePathAlwaysReverts() {
    env callEnv;
    renounceOwnership@withrevert(callEnv);

    assert lastReverted, "the adapter owner was able to renounce ownership";
}

// ---------------------------------------------------------------------------------------------
// The currency table
// ---------------------------------------------------------------------------------------------

/// A withdrawn currency never returns a price.
///
/// The property section 9 asks for. Stated as a revert rather than as a zero answer, because zero
/// is a real answer for a zero price and a caller cannot tell the two apart.
rule aWithdrawnCurrencyNeverQuotes(bytes32 symbol, uint64 priceUSDCents) {
    require !currencyIsAllowed(symbol);

    quote@withrevert(symbol, priceUSDCents);

    assert lastReverted, "a currency the table does not allow returned a price";
}

/// And no call leaves the contract in a state where one would.
///
/// The rule above is about one state. This one says no method reaches a state it does not hold in,
/// which is what makes it a property of the contract rather than of a starting point.
rule noMethodLetsAWithdrawnCurrencyQuote(method f, bytes32 symbol, uint64 priceUSDCents)
    filtered { f -> !alwaysReverts(f) }
{
    env callEnv;
    calldataarg args;
    f(callEnv, args);

    require !currencyIsAllowed(symbol);
    quote@withrevert(symbol, priceUSDCents);

    assert lastReverted, "a call left a withdrawn currency able to return a price";
}

/// The currency table moves through its two setters and nothing else.
///
/// Parametric, so an entry point added later has to satisfy it without anyone remembering to
/// extend a test.
rule theCurrencyTableMovesOnlyThroughItsSetters(method f, bytes32 symbol)
    filtered { f -> !alwaysReverts(f) }
{
    bool allowedBefore = currencyIsAllowed(symbol);
    bool registeredBefore = currencyIsRegistered(symbol);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert (currencyIsAllowed(symbol) != allowedBefore
         || currencyIsRegistered(symbol) != registeredBefore) =>
        (f.selector == sig:registerAsset(bytes32, PaymentAdapter.Asset).selector
      || f.selector == sig:updateAsset(bytes32, PaymentAdapter.Asset).selector),
        "the currency table changed through something other than its two setters";
}

/// Only the owner changes the currency table.
///
/// The admin names the price on every purchase. One that could also add a currency would be naming
/// the token address it gets paid into.
rule onlyTheOwnerChangesTheCurrencyTable(method f, bytes32 symbol)
    filtered { f -> !alwaysReverts(f) }
{
    bool allowedBefore = currencyIsAllowed(symbol);
    bool registeredBefore = currencyIsRegistered(symbol);
    address ownerBefore = owner();

    env callEnv;
    calldataarg args;
    require callEnv.msg.sender != 0;
    f(callEnv, args);

    assert (currencyIsAllowed(symbol) != allowedBefore
         || currencyIsRegistered(symbol) != registeredBefore) =>
        callEnv.msg.sender == ownerBefore,
        "the currency table was changed by someone other than the owner";
}

/// A symbol once registered stays registered.
///
/// Withdrawing a currency sets `allowed` to false and leaves the entry in place. If the entry could
/// go back to unregistered, `registerAsset` would accept the symbol again and a withdrawn currency
/// could be brought back with different decimals and a different token address.
rule aRegisteredSymbolIsNeverUnregistered(method f, bytes32 symbol)
    filtered { f -> !alwaysReverts(f) }
{
    require currencyIsRegistered(symbol);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert currencyIsRegistered(symbol), "a registered currency went back to unregistered";
}

// ---------------------------------------------------------------------------------------------
// Payment references
// ---------------------------------------------------------------------------------------------

/// A spent reference is never unspent.
///
/// The half of the double-spend property that does not depend on the settlement path. If a
/// reference could go back, the retry the mapping exists to refuse would go through.
rule aSpentReferenceIsNeverUnspent(method f, bytes32 paymentReference)
    filtered { f -> !alwaysReverts(f) }
{
    require usedReferences(paymentReference);

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert usedReferences(paymentReference), "a spent payment reference went back to unspent";
}

/// A reference is spent by one entry point, and only for the registry.
///
/// Both payment paths reach this contract through the registry, so this is what makes one reference
/// unable to be spent once on each of them.
rule aReferenceIsSpentOnlyByTheRegistry(method f, bytes32 paymentReference)
    filtered { f -> !alwaysReverts(f) }
{
    require !usedReferences(paymentReference);
    address registryBefore = registry();

    env callEnv;
    calldataarg args;
    require callEnv.msg.sender != 0;
    f(callEnv, args);

    assert usedReferences(paymentReference) =>
        (f.selector == sig:consumePaymentReference(bytes32).selector
         && callEnv.msg.sender == registryBefore),
        "a payment reference was spent by something other than the registry";
}

/// Spending a reference refuses one already spent.
///
/// The check itself, stated on its own so a change to it fails here rather than only showing up as
/// a different rule going quiet.
rule spendingARefusesAReferenceAlreadySpent(bytes32 paymentReference) {
    require usedReferences(paymentReference);

    env callEnv;
    consumePaymentReference@withrevert(callEnv, paymentReference);

    assert lastReverted, "a payment reference was spent a second time";
}

/// Spending one reference leaves every other alone.
///
/// Without this the rules above would hold while a single call marked the whole mapping, which
/// would close every reference the protocol has yet to use.
rule spendingAReferenceTouchesNoOther(method f, bytes32 spent, bytes32 other)
    filtered { f -> !alwaysReverts(f) }
{
    require spent != other;
    require !usedReferences(other);

    env callEnv;
    consumePaymentReference(callEnv, spent);

    assert !usedReferences(other), "spending one payment reference marked another";
}

// ---------------------------------------------------------------------------------------------
// Write-once state
// ---------------------------------------------------------------------------------------------

/// The registry pointer is set once and never moves.
///
/// It is the whole of the authorisation on `consumePaymentReference`, so a second writer would be a
/// second way to spend references.
rule theRegistryPointerMovesOnlyAtInitialization(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address, address).selector
} {
    address registryBefore = registry();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert registry() == registryBefore, "the registry pointer moved outside initialization";
}

/// The settlement token is set once and never moves.
rule theSettlementTokenMovesOnlyAtInitialization(method f) filtered {
    f -> !alwaysReverts(f)
      && f.selector != sig:initialize(address, address, address).selector
} {
    address tokenBefore = settlementToken();

    env callEnv;
    calldataarg args;
    f(callEnv, args);

    assert settlementToken() == tokenBefore, "the settlement token moved outside initialization";
}
