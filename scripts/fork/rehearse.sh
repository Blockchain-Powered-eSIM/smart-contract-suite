#!/usr/bin/env bash
#
# Deployment rehearsal against a local fork of Base Sepolia.
#
# Runs the three real deploy scripts, in order, against an anvil fork, then exercises the protocol
# they left behind. Nothing here reimplements a deploy step: a rehearsal of different code
# rehearses nothing.
#
#   ./scripts/fork/rehearse.sh
#
# The fork reports chain id 31337 rather than 84532. That is deliberate. The record key is built
# from the chain id, so a fork answering 84532 would write the production
# base-sepolia-84532-entrypoint-v8 entry from a run that deployed nothing real. The forked state
# still carries the real EntryPoint v0.8 and the real RIP-7212 precompile, which is the reason to
# fork at all. What it does not carry is the production EIP-712 domain, since v0.8 folds the chain
# id into userOpHash; EntryPointValidation.t.sol covers that at the real chain id and this does not
# try to.
#
# The whole run writes to its own record and its own address book rather than the real ones, so
# nothing here can reach the files that track live deployments. Both are deleted on exit.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

FORK_BLOCK="${FORK_BLOCK:-45600000}"
CHAIN_ID=31337
RPC="http://127.0.0.1:8545"

# The scripts read these and write nowhere else. fs_permissions only grants them deployments/, so
# the rehearsal's record and address book sit beside the real ones rather than in a temporary
# directory.
RECORD="deployments/.test-rehearsal.json"
ADDRESS_BOOK="deployments/.test-rehearsal-addresses.json"
export DEPLOYMENT_RECORD_PATH="$RECORD"
export ADDRESS_BOOK_PATH="$ADDRESS_BOOK"
LOG_DIR="$(mktemp -d)"
ANVIL_PID=""

log()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mRehearsal failed: %s\033[0m\n' "$1" >&2; exit 1; }

cleanup() {
    local status=$?
    [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true

    # Drop the rehearsal's record and address book however the run ended. Leaving either behind is
    # how a fork address gets mistaken for a deployed one later.
    rm -f "$RECORD" "$ADDRESS_BOOK"

    echo "Logs kept in $LOG_DIR"
    exit $status
}
trap cleanup EXIT

# ------------------------------------------------------------------------------------------------
# Fork parameters, read out of the existing .env rather than asked for again
# ------------------------------------------------------------------------------------------------

[[ -f .env ]] || fail ".env not found. ALCHEMY_BASE_SEPOLIA_HTTPS has to come from somewhere."
set -a; . ./.env; set +a

[[ -n "${ALCHEMY_BASE_SEPOLIA_HTTPS:-}" ]] || fail "ALCHEMY_BASE_SEPOLIA_HTTPS is unset."

# Anvil's default mnemonic, so every key here is public and worthless by construction. A rehearsal
# must never be able to reach for a key that controls anything.
#
# The three timelock lists have to stay disjoint: ProtocolAdmin's constructor rejects an overlap
# and DeployConfig checks the same thing before broadcasting.
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ESIM_WALLET_ADMIN_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export ESIM_WALLET_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export VAULT=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export PRICE_CAP_USD_CENTS=100000

# Base Sepolia USDC, which is the chain this forks. Checked with cast on 2026-08-29: has code,
# symbol USDC, 6 decimals.
export SETTLEMENT_TOKEN=0x036CbD53842c5426634e7929541eC2318f3dCF7e

export TIMELOCK_PROPOSERS=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export TIMELOCK_CANCELLERS=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
export TIMELOCK_GUARDIANS=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc

# ------------------------------------------------------------------------------------------------

log "Starting anvil, forking Base Sepolia at block $FORK_BLOCK"

anvil \
    --fork-url "$ALCHEMY_BASE_SEPOLIA_HTTPS" \
    --fork-block-number "$FORK_BLOCK" \
    --chain-id "$CHAIN_ID" \
    --silent \
    > "$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!

for _ in $(seq 1 30); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil did not come up. See $LOG_DIR/anvil.log"

echo "anvil up, chain id $(cast chain-id --rpc-url "$RPC"), forked at block $(cast block-number --rpc-url "$RPC")"

# The whole reason for forking rather than using a bare anvil.
ENTRY_POINT=0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108
[[ "$(cast code "$ENTRY_POINT" --rpc-url "$RPC" | wc -c)" -gt 2 ]] \
    || fail "EntryPoint v0.8 carries no code on the fork. Wrong block, or the fork did not take."
echo "EntryPoint v0.8 present at $ENTRY_POINT"

# RIP-7212, asked over RPC and not from inside a forge script.
#
# This cannot be checked in solidity here. foundry.toml sets evm_version = "osaka", so forge's own
# EVM carries the precompile whether or not the target chain does, and a staticcall to 0x100 inside
# a script answers out of that EVM rather than out of the chain. `cast code 0x100` is no good
# either: a precompile holds no bytecode and returns empty on every chain. A call with a known-good
# vector is the only thing that distinguishes the two, and it has to go over the wire.
#
# It decides the cost of verification: 7,270 gas through the precompile against 227,256 through
# FreshCryptoLib, a factor of 31, which is what verificationGasLimit has to respect.
#
# First entry of lib/p256-verifier/test-vectors/vectors_random_valid.jsonl, the same vector
# test/foundry/unit-testing/signature/P256Verification.t.sol uses.
P256_VECTOR=0x3fec5769b5cf4e310a7d150508e82fb8e3eda1c2c94c61492d3bd8aea99e06c9e22466e928fdccef0de49e3503d2657d00494a00e764fd437bdafa05f5922b1fbbb77c6817ccf50748419477e843d5bac67e6a70e97dde5a57e0c983b777e1ad31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5

probe_p256() {
    local url="$1" label="$2" answer
    answer="$(cast call 0x0000000000000000000000000000000000000100 "$P256_VECTOR" --rpc-url "$url" 2>/dev/null || true)"
    case "$answer" in
        0x0000000000000000000000000000000000000000000000000000000000000001)
            echo "RIP-7212 present on $label, verification takes the precompile branch" ;;
        "")
            echo "RIP-7212 ABSENT on $label, verification falls back to FreshCryptoLib at 227,256 gas" ;;
        *)
            fail "$label rejected a known-good P256 vector, returned '$answer'" ;;
    esac
}

probe_p256 "$RPC" "the fork"
probe_p256 "$ALCHEMY_BASE_SEPOLIA_HTTPS" "Base Sepolia itself"

# Start with neither file present. DeploymentRecord.isRecorded() reads file existence as "already
# deployed", the same as it does for a live chain, so writing an empty {} here would make
# Deploy.s.sol refuse to start on its own rehearsal. A leftover from an interrupted run would cause
# the exact same false positive, which is why cleanup below always removes both on exit.
rm -f "$RECORD" "$ADDRESS_BOOK"

# Forge sizes a broadcast transaction from what the simulation consumed. That is wrong for
# handleOps: the EntryPoint checks the transaction carries the operation's whole declared gas
# before it starts and reverts AA95 out of gas when it does not, however little the operation goes
# on to use. A UserOp declaring 410k while consuming 100k therefore ships in a 130k transaction and
# fails. The multiplier covers the gap. Unused gas is refunded, so the only cost is a larger
# balance reserved during the run.
GAS_MULTIPLIER=600

run_script() {
    local name="$1" path="$2"
    log "$name"
    if ! forge script "$path" --rpc-url "$RPC" --broadcast --via-ir -vv \
        --gas-estimate-multiplier "$GAS_MULTIPLIER" \
        > "$LOG_DIR/$name.log" 2>&1; then
        tail -40 "$LOG_DIR/$name.log" >&2
        fail "$name failed. Full log at $LOG_DIR/$name.log"
    fi
    grep -E '^\s+(Registry|DeviceWalletFactory|ESIMWalletFactory|ProtocolAdmin|Wallet|initCode|Counterfactual|Ownership|UserOperation|Offchain)' \
        "$LOG_DIR/$name.log" || true
    echo "ok"
}

run_script deploy   scripts/deploy/Deploy.s.sol:Deploy
run_script configure scripts/deploy/Configure.s.sol:Configure
run_script handover scripts/deploy/TransferOwnership.s.sol:TransferOwnership
run_script rehearsal scripts/fork/ForkRehearsal.s.sol:ForkRehearsal

RECORD_KEY="anvil-${CHAIN_ID}-entrypoint-v8"

log "Addresses written by the rehearsal"
python3 -c "
import json
print(json.dumps(json.load(open('$ADDRESS_BOOK'))['$RECORD_KEY'], indent=2))
"

log "Deployment record written by the rehearsal"
python3 -c "
import json
r = json.load(open('$RECORD'))
print(json.dumps({k: r[k] for k in ('chain', 'external', 'admin', 'status') if k in r}, indent=2))
print('contracts:', ', '.join(r.get('contracts', {})))
"

log "Rehearsal passed"
echo "Full suite deployed to the fork, all four scripts clean, representative transactions executed."
