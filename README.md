# eSIM Wallet Smart Contract Suite

![](./resources/KokioSCWithBG.png)

Onchain wallets for eSIM data plans. A phone gets one smart wallet controlled by a passkey, and
every eSIM on that phone gets its own wallet that buys data bundles and keeps the record of what it bought.

The wallets are ERC-4337 accounts. Signatures are WebAuthn assertions over a P256 key held in the
device's secure enclave, so no seed phrase appears anywhere in the flow.

## Architecture

Two proxy layers, and most of the risk sits in them. Four UUPS singletons hold protocol state and
upgrade one at a time. Every wallet is a beacon proxy, so one beacon call moves every wallet of that kind at once. There is no per-wallet opt-out, which makes any beacon change a protocol-wide upgrade.

| Contract | What it does | Pattern |
|---|---|---|
| `Registry` | Central record of every device and eSIM wallet. Also holds the protocol admin, the vault, the pause switch and the data bundle price ceiling | UUPS proxy |
| `RegistryHelper` | The registry's storage and lazy deployment half | Inherited by `Registry` |
| `LazyWalletRegistry` | Holds data bundle history for users paying in fiat, keyed by device and eSIM identifier strings, until they ask for a wallet | UUPS proxy |
| `DeviceWalletFactory` | Deploys device wallets at deterministic CREATE2 addresses and owns their beacon | UUPS proxy |
| `DeviceWallet` | One per phone. Holds ETH and tokens, owns the eSIM wallets on that device, verifies the passkey | Beacon proxy |
| `ESIMWalletFactory` | Deploys eSIM wallets and owns their beacon | UUPS proxy |
| `ESIMWallet` | One per eSIM. Buys data bundles, keeps purchase history, pulls tokens from its device wallet | Beacon proxy |
| `PaymentAdapter` | The currencies the protocol accepts, the one conversion from USD cents into a token amount, and the payment references each spendable once. Moves tokens to the vault | UUPS proxy |
| `Account4337` | The ERC-4337 `IAccount` and `IERC1271` base that `DeviceWallet` builds on | Inherited by `DeviceWallet` |
| `WebAuthn` | Verifies WebAuthn authentication assertions. Tries the RIP-7212 precompile first and falls back to FreshCryptoLib | Library |
| `P256Verifier` | One immutable address for accounts to verify through, wrapping the WebAuthn library | Plain contract |
| `ProtocolAdmin` | Timelock meant to own the five singletons. Adds a delay floor that `updateDelay` cannot go under, and a guardian role with exactly two powers | Plain contract |
| `Errors` | Every custom error in the suite | Library |
| `CustomStructs` | Structs shared across contracts | Types |
| `interfaces/` | `IPausable`, `IOwnable2Step` and `IRegistryAdmin` for the calls `ProtocolAdmin` makes back into the protocol; `IPaymentRegistry` for what `PaymentAdapter` reads from the registry | Interfaces |

A backend server generates the device and eSIM identifiers and writes them into the wallets. That is what ties an onchain wallet to a provisioned eSIM.

## Quickstart

Foundry 1.7.1, solc 0.8.36, `evm_version = "osaka"`.

```bash
git clone --recurse-submodules https://github.com/Blockchain-Powered-eSIM/smart-contract-suite.git
cd smart-contract-suite
forge build --sizes
forge test
```

This repo does not compile without via-IR. `via_ir = true` is already in `foundry.toml`, so plain
`forge` commands pick it up. A cold build takes about 30 seconds.

Dependencies are git submodules under `lib/`.
Hardhat is wired up through `@nomicfoundation/hardhat-foundry` and compiles the same sources, so `npx hardhat compile` produces byte-identical bytecode.
That parity depends on `bytecode_hash = "none"` in `foundry.toml` and `metadata.bytecodeHash: "none"` in `hardhat.config.js`. Removing either breaks it.

## Testing

804 tests across 73 suites, about eight minutes for a full run.

| Suite | Files | What it covers |
|---|---|---|
| `test/foundry/unit-testing/` | 44 | Per-contract behaviour, access control, revert paths, storage layout and initialiser locks |
| `test/foundry/fuzz-testing/` | 10 | Identifier and array shapes, price ceilings, token settlement, signature shapes, a P256 differential against the precompile |
| `test/foundry/invariant-testing/` | 9 | Registry consistency, wallet ownership, payment accounting, purchase history, timelock behaviour |
| `test/foundry/gas/` | 8 | Per-operation gas with every input pinned, offchain signatures included |
| `test/foundry/fork/` | 1 | A user operation through the deployed EntryPoint on both chains |

Branch coverage is 92.58%, or 237 of 256 arms, with `WebAuthn` at 80% the lowest and
`Account4337`, `ProtocolAdmin`, `DeviceWallet` and `PaymentAdapter` at 100%.
Measure it with `scripts/checks/branch-coverage.py` rather than reading forge's own percentage:
`forge coverage --ir-minimum` does not count `require(cond, "string")` as a branch, so those sites
report zero hits on both arms however often they run. The contracts use custom errors throughout, so nothing is currently excluded, but the raw number stops meaning anything the moment a `require`
string is added.

```bash
forge coverage --ir-minimum --report lcov --report-file lcov.info \
    --no-match-path "test/foundry/{fork,invariant-testing}/*"
python3 scripts/checks/branch-coverage.py lcov.info
```

The fork tests read `ALCHEMY_OP_SEPOLIA_HTTPS` and `ALCHEMY_BASE_SEPOLIA_HTTPS`. They skip rather
than fail when those are unset, so the suite runs without credentials.

The long invariant campaign is a separate profile, run before a release rather than on every change:

```bash
FOUNDRY_PROFILE=campaign forge test --match-path "test/foundry/invariant-testing/*"
```

The deployment scripts have their own suite, kept out of the default run:

```bash
FOUNDRY_PROFILE=scripts forge test --threads 1
```

50 tests in `test/scripts/`, exercising `Deploy.s.sol`, `Configure.s.sol` and `TransferOwnership.s.sol`
against a scratch record. `scripts/fork/rehearse.sh` runs the same three against a Base Sepolia fork
and checks the happy path better than any test can, but it needs an RPC key and a live anvil, so CI
never runs it. These reach what it cannot: the resume branches and the mismatch guards, which only
fire on a deployment that has already gone wrong.

`--threads 1` is not optional. The scripts read their parameters from the process environment and
their record from one file, and forge runs every `setUp` before any test and then runs the tests in
parallel. Without the flag, somewhere between 2 and 12 of the 50 fail on each run, and which ones
changes every time.

Two gas baselines, measuring different things. `.gas-snapshot` is the whole-test-body figure, useful as a regression tripwire and not as a protocol gas number, since a row can include whatever that test deployed.
`snapshots/*.json` is per operation, written by the tests under `test/foundry/gas/` and rewritten by any ordinary `forge test`.

## Security

**Audit.** Reviewed by CD Security in March 2025. The report is in [audits/2025-03-CDSecurity.pdf](./audits/2025-03-CDSecurity.pdf).

**Formal verification.** Eight Certora specs, 83 rules.

| Spec | Rules | Subject |
|---|---|---|
| `Registry.spec` | 18 | Wallet registration and association records |
| `PaymentAdapter.spec` | 15 | The currency table, the payment references, and what a settlement moves |
| `ProtocolAdmin.spec` | 11 | The delay nothing gets around, and the two things a guardian can say |
| `ESIMWallet.spec` | 10 | Ownership state machine, price ceiling, deploying factory |
| `ESIMWalletFactory.spec` | 10 | Registry wiring, beacon control, the record of what it deployed |
| `DeviceWalletFactory.spec` | 8 | Deterministic deployment and beacon control |
| `DeviceWallet.spec` | 7 | Owner key, eSIM wallet set, funds access flags |
| `RegistryCrossContract.spec` | 4 | `Registry`, `DeviceWallet` and `ESIMWallet` agreeing on who holds an eSIM wallet |

Three caveats attach to every proof. Loops unroll three times, so a result covers batches of at most three rather than all batches. Hashing of unbounded arguments is assumed within 224 bytes, raised to 1600 in `ESIMWalletFactory.spec` so its CREATE2 address prediction stays reachable. External calls are summarised one signature at a time.

`LazyWalletRegistry` has no spec, and the reason is every mapping in it is string-keyed, and Certora's storage analysis fails on any method taking a `string`.
Its properties are carried by Foundry invariants instead.

**Static analysis.** Slither and Aderyn run before anything substantial is committed:

```bash
slither . --filter-paths "test/,script/,lib/,node_modules/"
aderyn .
```

**Trust model, as it stands.** On the v0.8 Base Sepolia deployment, `ProtocolAdmin` owns all four
UUPS proxies and both factories that own the beacons. Every owner gated call now waits out a two day
delay, proposing is 2-of-3 or a cold key, and a 3-of-3 guardian executes. The older deployments are
not on that footing: one EOA still owns everything on the v0.7 Base Sepolia and OP Sepolia
deployments, so a single key compromise reaches every wallet there in one transaction. Admin
transactions go into the public mempool on all three, with no private relay in front of them.

That v0.8 deployment predates `PaymentAdapter`, so none of the three live deployments carry it or the
fifth singleton it adds. This branch's own protocol has not been deployed under any handover yet:
`ProtocolAdmin` exists in the contracts and in the deploy scripts, but no `TransferOwnership.s.sol`
run has pointed it at a `PaymentAdapter`-carrying deployment.

## Deployments

Testnet only. The v0.8 column is the current deployment, from commit [`8e49dd9`](https://github.com/Blockchain-Powered-eSIM/smart-contract-suite/tree/8e49dd96eb8dfd09b95d584079e423b5ed350a7b), tagged
`deploy/base-sepolia-entrypoint-v8`. The two older columns bind the v0.7 EntryPoint and were built
from an earlier commit. They were redeployed rather than upgraded, because the EntryPoint address is
immutable in the wallets.

| Contract | Base Sepolia (EP v0.8) | Base Sepolia (EP v0.7) | OP Sepolia |
|---|---|---|---|
| `RegistryProxy` | [`0x89e386E3251692F21a2E9048A46518AdC2A5Cb4A`](https://sepolia.basescan.org/address/0x89e386E3251692F21a2E9048A46518AdC2A5Cb4A) | `0xCa447f5C75C57f6C59027304A5Fb5A09F0E005c9` | `0x96dA9cE92D2C09f7b3ADE01260608e9079f16d12` |
| `LazyWalletRegistryProxy` | [`0x394177c5cc4762b897c37de1820259B75993e033`](https://sepolia.basescan.org/address/0x394177c5cc4762b897c37de1820259B75993e033) | `0x8a1E53b903efcc6b252CE4bD3b255202318505Ef` | `0x3F14D060074B174B0784056bDe5e0f8970D25ff1` |
| `DeviceWalletFactoryProxy` | [`0xB006c7066C89a5d7Bfc229e9fb0bADf96c8F979f`](https://sepolia.basescan.org/address/0xB006c7066C89a5d7Bfc229e9fb0bADf96c8F979f) | `0xB4473979ff8cE4e09161B08f74EEb66BD7718076` | `0x243cCdE6a56b0Ba740E067f39896772748E20fFD` |
| `ESIMWalletFactoryProxy` | [`0x13998C0bb7433c51cE5101922B12EE69F459699A`](https://sepolia.basescan.org/address/0x13998C0bb7433c51cE5101922B12EE69F459699A) | `0x63005d8214533fC7209678Aa39F7b9b0b51a7bcB` | `0x8444bF9C39F01e4B092e42DC11695C61f8B93957` |
| `DeviceWalletImpl` | [`0x8076aD3AdaeFb5A35a1ADFdE850F44A06C379DC8`](https://sepolia.basescan.org/address/0x8076aD3AdaeFb5A35a1ADFdE850F44A06C379DC8) | `0xde0dC03eF67317D4702e1d6Ef3f8cE246517e84e` | `0x22FCFa80868dc9F423873F9332817eDAe4483974` |
| `ESIMWalletImpl` | [`0xF77FE1da39501Bb1963f08e8778242F25Bc668C2`](https://sepolia.basescan.org/address/0xF77FE1da39501Bb1963f08e8778242F25Bc668C2) | `0x59A78Cbb73e94a3fD6ada0136C89AE658BA16Dd9` | `0xf86FE9253b6ea9454abda657f47aE508B00c15C1` |
| `DeviceWalletBeacon` | [`0x985519b60b39C630d9575911d62635A993383900`](https://sepolia.basescan.org/address/0x985519b60b39C630d9575911d62635A993383900) | not recorded | not recorded |
| `ESIMWalletBeacon` | [`0x7D0515286Ad92953665B6ED02D4e3b3901479c19`](https://sepolia.basescan.org/address/0x7D0515286Ad92953665B6ED02D4e3b3901479c19) | not recorded | not recorded |
| `P256Verifier` | [`0x625561429bD99d647956ccBCA4eBf762aaA142c5`](https://sepolia.basescan.org/address/0x625561429bD99d647956ccBCA4eBf762aaA142c5) | `0xF04f3b3935aD461D17d4a8a78E7ea21d4a61AEb1` | `0x3c15a78046838481788613A9F111F972B562623C` |
| `ProtocolAdmin` | [`0x77A1D6f27462c34BF038832d9Cff6b3E94a9Fe6F`](https://sepolia.basescan.org/address/0x77A1D6f27462c34BF038832d9Cff6b3E94a9Fe6F) | not deployed | not deployed |
| `EntryPoint` | [`0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`](https://sepolia.basescan.org/address/0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108) | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

The full list, including the Ethereum Sepolia deployment, is in
[deployments/address.json](./deployments/address.json). That file is addresses only. What the v0.8
deploy captured beyond them, build provenance, every transaction, gas, constructor arguments and
verification status, is in
[deployments/base-sepolia-84532-entrypoint-v8.json](./deployments/base-sepolia-84532-entrypoint-v8.json).

The two chains are not symmetric in one way that file does not record. The owner EOA carries an
EIP-7702 delegation on Base Sepolia and none on OP Sepolia, so the same address is a smart account
on one chain and a plain EOA on the other.

## Specifications

- [Registry](./docs/Registry.md)
- [Registry Helper](./docs/RegistryHelper.md)
- [Lazy Wallet Registry](./docs/LazyWalletRegistry.md)
- [Protocol Admin](./docs/admin/ProtocolAdmin.md)
- [Device Wallet Factory](./docs/device-wallet/DeviceWalletFactory.md)
- [Device Wallet](./docs/device-wallet/DeviceWallet.md)
- [eSIM Wallet Factory](./docs/esim-wallet/ESIMWalletFactory.md)
- [eSIM Wallet](./docs/esim-wallet/ESIMWallet.md)
- [Payment Adapter](./docs/payments/PaymentAdapter.md)
- [Account4337](./docs/aa-helper/Account4337.md)
- [Upgradeable Beacon](./docs/UpgradableBeacon.md)
- [Custom Structs](./docs/CustomStructs.md)
- [Errors](./docs/Errors.md)
- [Ownable Two-Step Interface](./docs/interfaces/IOwnable2Step.md)
- [Pausable Interface](./docs/interfaces/IPausable.md)
- [Registry Admin Interface](./docs/interfaces/IRegistryAdmin.md)
- [Payment Registry Interface](./docs/interfaces/IPaymentRegistry.md)
- [P256 Verifier](./docs/P256Verifier.md)
- [WebAuthn](./docs/WebAuthn.md)

## User flow

1. **Install the app and register a passkey.** The P256 key lives in the device's secure enclave and
   never leaves it.
2. **Deploy the wallets.** For a new device, the app asks the registry for a device wallet and one
   eSIM wallet, linked at deployment.
3. **Pick and buy a data bundle.** Paying in crypto deploys both wallets immediately, in an ERC-20
   the payment adapter has been given a price for. Paying in fiat records the purchase in the lazy
   wallet registry, and the wallets are deployed later if the user asks for them.

   Paying in ETH is not currently supported. The adapter works the amount out from the price, and
   nothing onchain prices ETH, so it comes back when the adapter can swap into the settlement token.
4. **Provision the eSIM.** The server generates the eSIM identifier, writes it into the eSIM wallet
   through the device wallet, and returns a QR code for activation.
5. **Use the device wallet.** It holds ETH and ERC-20 tokens and can be used as an ordinary wallet.
   Funds can be withdrawn at any time.
