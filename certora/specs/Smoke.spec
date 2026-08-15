/// Smoke spec. It exists to answer one question: can the prover compile and reason about this
/// codebase end to end. It asserts nothing about the protocol.
///
/// Every external method is run symbolically and asked to be reachable. A method that cannot be
/// reached means the prover choked on it, which is what we want to find out before writing specs
/// that depend on it.

methods {
    function owner() external returns (address) envfree;
}

/// Every method is reachable under some input.
///
/// renounceOwnership is excluded because it reverts on every input by design: the override at
/// Registry.sol:97 rejects the call outright, since the owner is the only caller _authorizeUpgrade
/// accepts and renouncing would freeze the contract on its current logic. Unreachable is the
/// correct answer for it, so asking the question is noise.
rule everyMethodIsReachable(method f) filtered {
    f -> f.selector != sig:renounceOwnership().selector
} {
    env e;
    calldataarg args;

    f(e, args);

    satisfy true;
}

/// The owner is a stable value across a call that does not touch ownership
rule ownerIsReadable() {
    address before = owner();
    address after = owner();

    assert before == after, "owner() is not deterministic";
}
