# Properties

What the Echidna and Medusa campaign in `test/fizz/` asserts about the protocol.

Each entry carries a **Guarantee**: `SHOULD-HOLD` means docs, a single-writer guard or an exact
identity say it must be true, and a violation is a bug. `EXPLORATORY` means it was inferred, and a
violation is a lead for a person to judge rather than a confirmed defect.

Run them with `medusa fuzz` or `echidna . --contract FuzzTester --config echidna.yaml`.

## Global

Checked after every call in a sequence. These iterate the wallets the campaign has built, so they
stay O(n) in the population and never O(n squared).

- [x] **GL-01 — an eSIM wallet's purchase history is append-only, entry for entry.**
  Once an entry is seen at index `i`, its id, price and settlement never change again, and the list
  never shortens. SHOULD-HOLD: all three writers push and nothing indexes or deletes. This one is
  here because the repo's own notes record a mutation that made a purchase overwrite entry zero and
  nothing in the suite caught it, unit tests included.

- [x] **GL-02 — the history copy cursor never runs backwards or past the end.**
  `historyEntriesCopied[id]` never decreases, and never exceeds the stored history length reached
  through the live device redirect. SHOULD-HOLD: I-8, single writer bounded by `outstanding`.

- [x] **GL-03 — the deployment cursor never runs backwards or past the end.**
  `eSIMWalletsDeployed[deviceId]` never decreases and never exceeds that device's associated
  identifier count. SHOULD-HOLD: I-9, both writers clamped by `_boundedBatchSize`.

- [x] **GL-04 — a device's identifier list freezes once it has a wallet.**
  After `isDeviceIdentifierAlreadyUsed` first reads true, the associated identifier list never
  changes length again. SHOULD-HOLD: the only two writers refuse a deployed device. This is the
  mechanism GL-03 depends on, checked separately so a break localises.

- [x] **GL-05 — an eSIM wallet's registration is never revoked.**
  Once `isESIMWalletValid[w]` is non-zero it never returns to zero; only the named holder changes.
  SHOULD-HOLD: I-6, `bindESIMWallet` is the sole writer and no path zeroes it.

- [x] **GL-06 — a spent payment reference never un-spends.**
  For any `(wallet, reference)` the campaign has spent, `usedPaymentReferences` stays true, across
  an adapter rotation. SHOULD-HOLD: I-4 as corrected, one guarded writer on `Registry`.

- [x] **GL-07 — one P256 key names at most one device wallet.**
  For every device wallet, the key index resolves its current key back to that same wallet.
  SHOULD-HOLD: I-5, rotation deletes the old hash before writing the new one.

- [x] **GL-08 — the registry's copy of a wallet's owner key matches the wallet's own.**
  SHOULD-HOLD: rotation writes both in one transaction, so they cannot split.

- [x] **GL-09 — a device identifier names one wallet, and that wallet agrees.**
  SHOULD-HOLD: `_updateDeviceWalletInfo` is the sole writer and refuses an identifier already taken.
  Reachable because both deploy routes draw from a shared pool of contested identifiers.

- [x] **GL-10 — an eSIM identifier is claimed once and never reassigned.**
  SHOULD-HOLD: `_claimESIMIdentifier` refuses a second claim.

- [x] **GL-11 — the ceiling always binds, and nothing was ever written over it.**
  The registry default is never zero, since zero reads as "no ceiling" everywhere a cap is consumed.
  No purchase was ever accepted priced above the ceiling in force at the moment it was written.
  SHOULD-HOLD: I-1, I-11, E-1. The per-entry half is checked at write time rather than against
  today's cap, because the owner may lower the cap afterwards and that does not make an earlier
  purchase illegal.

- [x] **GL-12 — settlement token is never created or destroyed.**
  `totalSupply` equals the sum of every balance the harness can hold it in: the fuzzer itself, the
  actors, every device wallet, every eSIM wallet, both adapters and both vaults. SHOULD-HOLD: the
  mock is a plain ERC-20 with no fee or rebase, so this is an accounting identity as long as no
  value escapes the accounted set.

- [x] **GL-13 — only the path that moved the money may say it did.**
  The count of `Settlement.DeviceWallet` entries in a wallet's history equals the number of
  successful `buyDataBundleWithToken` calls against it. SHOULD-HOLD: G-31, G-43, E-1. Every other
  writer refuses that tag.

- [x] **GL-14 — the currency table stays inside its own bounds.**
  Every registered asset has decimals in `[2, 36]`, and a symbol once registered never returns to
  unregistered. SHOULD-HOLD: I-2, I-3, `_writeAsset` is the sole writer.

## Specific

Asserted inside the handler that makes the call, where a before-and-after comparison is the point.

- [x] **SP-01 — a purchase moves value between four addresses and creates none.**
  Across one `buyDataBundleWithToken`, the combined balance of the device wallet, the eSIM wallet,
  the adapter and the vault is unchanged, and the adapter's own balance ends exactly where it
  started. SHOULD-HOLD: `spent + refunded == amountIn` by construction, so nothing rests on the
  adapter.

- [x] **SP-02 — what the adapter spends matches an independently written formula.**
  The settled amount equals `price * 10**decimals / 100` computed in the harness rather than read
  back from the adapter. SHOULD-HOLD: catches a reordering of the multiply and divide that a
  self-consistency check cannot.

- [x] **SP-03 — the quote is exact, monotonic, and agrees with settlement.**
  `amount * 100 == price * 10**decimals` with no remainder, a higher price never quotes lower, and
  `settle` spends exactly what `quote` returned for the same inputs. SHOULD-HOLD: decimals are
  bounded at or above 2, so the division by 100 never truncates. X-1 covers the third part.

- [x] **SP-04 — a wallet lands where the factory said it would.**
  Both factories' counterfactual address equals the address actually deployed for the same inputs.
  SHOULD-HOLD: the prediction and the deployment encode the same salt and init code.

- [x] **SP-05 — a handover does not carry the old owner's ceiling.**
  After `acceptOwnershipTransfer`, `priceCapUSDCents` reads zero, so the incoming owner starts on
  the registry default. SHOULD-HOLD: `_secureTransferOwnership` resets it. Worth asserting because
  the outgoing owner controls that cap right up to the moment it hands the wallet over.

- [x] **SP-06 — accepting ownership does not rewrite the registry association.**
  `acceptOwnershipTransfer` leaves `isESIMWalletValid` naming whoever last bound the wallet.
  SHOULD-HOLD: X-2. The divergence is deliberate, which is why authorization reads live `owner()`.

- [x] **SP-07 — raising or clearing standby never touches the registration.**
  A call that changes `isESIMWalletOnStandby` leaves `isESIMWalletValid` alone. SHOULD-HOLD: the
  two mappings are independent. This is a direct regression net for a defect this repo already
  shipped once, where the flag was derived from the association. The inverse property, that one
  implies the other, would be wrong.

- [x] **SP-08 — releasing and re-adding a wallet never hands back spend rights.**
  A removal clears both the validity flag and funds access; a later re-add restores validity and
  clears standby but leaves funds access false. SHOULD-HOLD: G-21 refuses a grant at bind time, so
  access can only come from a separate owner-signed call.

- [x] **SP-09 — a deployed but unregistered device wallet can do nothing.**
  Between `createAccount` and `postCreateAccount` the wallet holds code, is not valid, does not
  claim its identifier, and cannot deploy an eSIM wallet. SHOULD-HOLD: `createAccount` writes no
  external storage.

- [x] **SP-10 — a pause stops every path that moves value.**
  While paused, `pullToken`, `buyDataBundleWithToken`, `recordSettledPurchase` and the lazy funded
  deployment all revert. SHOULD-HOLD: each carries the check. The last one only recently gained it.
  The two lazy siblings that move no ETH are deliberately not in this list.

## Not asserted, and why

- **Anything needing a WebAuthn signature.** `validateUserOp`, `isValidSignature` and the challenge
  binding need a P256 assertion produced through `vm.ffi`, which the fuzzers cannot call. Owner-gated
  calls are reached by impersonating the wallet instead. The signature path is covered by the
  Foundry differential and shape suites and by a fork test through the deployed EntryPoint.
- **Native ETH conservation.** Several handlers top up a caller with `vm.deal` before a payable
  call, because a pranked call is debited from the pranked account. That manufactures ETH by
  cheatcode, so a sum-conservation property over ETH would be false by construction and would say
  nothing about the protocol.
- **Round trips over the conversion.** There is no units-back-to-cents function, so there is no
  inverse to compose with.
- **Anything about shares, liquidity, liquidation or TVL.** None of it exists here.
