# The Echidna and Medusa harness

A second fuzzing engine over the same protocol the Foundry invariant campaigns already cover. It is
independent of `test/foundry/`: its own deployment, its own handlers, its own properties. Nothing
here runs during an ordinary `forge test`.

## Running it

Everything needs the `fuzz` profile, which is what puts `test/fizz` on the test path.

```bash
FOUNDRY_PROFILE=fuzz forge build

# The campaigns. Run one at a time; both at once will thrash the machine.
medusa fuzz
echidna . --contract FuzzTester --config echidna.yaml

# Debugging a handler or replaying a violation
FOUNDRY_PROFILE=fuzz forge test --match-contract FoundryTester -vvv
```

`PROPERTIES.md` at the repo root is the English spec: what each property claims and whether a
violation is a confirmed bug or a lead. `fizz_data/coverage-targets.md` records per-contract
coverage and the deliberate gaps.

## Why the fuzz profile exists

Three settings differ from the default, and each is here for a measured reason.

**`optimizer = false`.** The Yul optimizer merges branches, so a campaign against optimized bytecode
reports roughly ten percent less coverage than the source actually reaches. Turning via-IR off would
recover all of it and does not compile: the suite is stack-too-deep without it.

**`bytecode_hash = 'ipfs'`.** The fuzzers match deployed runtime bytecode back to a source file to
attribute coverage, and the metadata trailer is what makes that match unambiguous. The default
profile drops it, which is what holds the byte-for-byte agreement with hardhat, and which also made
the first two campaigns report `Registry` at 0.7% and `DeviceWallet` at 0.0% while a smoke test
proved purchases were running through both.

**Its own `out` and `test` paths.** The two profiles disagree on optimizer settings, so sharing one
artifact directory turns every profile switch into a full rebuild. The separate test path keeps a
plain `forge test` from picking the harness up, the same way `[profile.scripts]` does.

## Layout

| File | What it holds |
|---|---|
| `Base.sol` | The deployment, the actor and wallet registries, ghost state, and the identifier namespaces |
| `Snapshots.sol` | Before and after balances for the purchase path, the only property that needs them |
| `Properties.sol` | The properties, global and specific |
| `handlers/` | One file per contract, clamped and unclamped |
| `FuzzTester.sol` | What Echidna and Medusa target |
| `FoundryTester.sol` | Smoke tests, and where a violation gets replayed |

## How the harness drives a gated protocol

Almost every entry point here is gated, so the handlers resolve the caller out of live state rather
than taking one from the fuzzer. Four things make that work, and each was needed before coverage
moved at all.

**Owner keys have to be on the curve.** Every deploy path rejects a key that could never verify a
signature, so a random pair spends the whole run being refused. `_ownerKey` walks x upward until the
curve equation has a square root, which finds one in about two tries.

**The admin is read live, never cached.** Every admin check in the protocol resolves through
`Registry.eSIMWalletAdmin()`, and the config handlers rotate it. A handler holding its own copy would
go on impersonating an address the protocol already demoted, and every admin path would sit dead for
the rest of the run.

**Ownership is re-read on every use.** An eSIM wallet changes hands during a run, so a handler
pranking the device wallet that used to hold one is refused on every call. `_pickOwnedPair` resolves
the current pair instead of remembering one.

**Config handlers swap between valid targets.** A fuzzed address in `setPaymentAdapter` or either
beacon would leave the rest of the run reverting against something that was never deployed. A second
adapter, a second vault and spare implementations exist so the rotation is real without being fatal.
Rotating the adapter is also the one shape that shows whether spent payment references survive a
swap, which they only do because the store moved to the registry.

## What it deliberately does not reach

**Anything needing a WebAuthn signature.** The assertion has to be signed by a P256 key with the
challenge bound to the operation, which the repo produces through `vm.ffi` and a Node signer. The
fuzzers cannot call it. Owner-gated functions are reached by impersonating the wallet, which is what
a signed `execute` amounts to onchain. The signature path itself is covered by the Foundry
differential and shape suites and by a fork test through the deployed EntryPoint.

**`ProtocolAdmin`.** It owns none of the singletons in this deployment, so nothing it does is
visible in the state the properties read, and reaching it needs schedule, delay, execute in order.
It carries ten Certora rules and its own Foundry campaign.

**UUPS upgrades and singleton ownership transfer.** Either would leave the rest of a sequence running
against something the harness never deployed. Storage-layout safety across an upgrade is pinned by
`test/foundry/unit-testing/upgrade/StorageLayout.t.sol`, which is the check that matters there. Both
beacon swaps are exercised, between real implementations.

## Two things worth knowing before changing it

**A prank only survives to the next call.** Resolving the adapter with `_activeAdapter()` inside a
pranked call expression spends the prank on `registry.paymentAdapter()`, and the call that was meant
to be pranked runs as the harness. Hoist the lookup above the prank.

**A pranked call is debited from the pranked account, not from the harness.** Any handler sending
value has to fund the account it is impersonating first, and has to do it before clamping the amount
rather than after, or the ceiling reads zero and the payable branch never runs.
