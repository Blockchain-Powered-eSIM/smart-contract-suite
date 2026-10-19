#!/usr/bin/env bash
#
# Deployment rehearsal against a local fork of Base Sepolia or Base mainnet.
#
# Runs the three real deploy scripts, in order, against an anvil fork, then exercises the protocol
# they left behind. Nothing here reimplements a deploy step: a rehearsal of different code
# rehearses nothing.
#
#   ./scripts/fork/rehearse.sh                        # Base Sepolia, anvil keys for every role
#   NETWORK=base-mainnet ./scripts/fork/rehearse.sh   # Base mainnet, real role addresses
#
# Base Sepolia mode reports chain id 31337 rather than 84532, so the run is never mistaken for the
# live testnet deployment. Base mainnet mode keeps 8453, because the mainnet-only checks in
# DeployConfig (USDC pin, Safes for proposers and guardians, USDT and DAI) only run on that id.
#
# Base mainnet mode takes ESIM_WALLET_ADMIN, VAULT and the three TIMELOCK_* lists from .env. It
# never needs their keys: the fork impersonates the admin, and the deployer is still anvil's
# public key. Point BASE_MAINNET_RPC at a private endpoint if the public one rate limits.
#
# The whole run writes to its own record and its own address book rather than the real ones, so
# nothing here can reach the files that track live deployments. Both are deleted on exit, as are
# forge's broadcast and cache logs for chain 8453 in mainnet mode.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

NETWORK="${NETWORK:-base-sepolia}"
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
FORGE_LOGS_TO_DROP=()
ANVIL_NETWORK_ARGS=()

log()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mRehearsal failed: %s\033[0m\n' "$1" >&2; exit 1; }

cleanup() {
    local status=$?
    [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true

    # Drop the rehearsal's record and address book however the run ended. Leaving either behind is
    # how a fork address gets mistaken for a deployed one later.
    rm -f "$RECORD" "$ADDRESS_BOOK"
    for dir in ${FORGE_LOGS_TO_DROP[@]+"${FORGE_LOGS_TO_DROP[@]}"}; do rm -rf "$dir"; done

    echo "Logs kept in $LOG_DIR"
    exit $status
}
trap cleanup EXIT

[[ -f .env ]] || fail ".env not found."
set -a; . ./.env; set +a

# Anvil's first account, so the deployer key is public and worthless by construction. A rehearsal
# must never be able to reach for a key that controls anything.
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export PRICE_CAP_USD_CENTS=100000
export ADMIN_ALLOWANCE_USD_CENTS=10000

case "$NETWORK" in
    base-sepolia)
        [[ -n "${ALCHEMY_BASE_SEPOLIA_HTTPS:-}" ]] || fail "ALCHEMY_BASE_SEPOLIA_HTTPS is unset."
        FORK_RPC="$ALCHEMY_BASE_SEPOLIA_HTTPS"
        FORK_BLOCK="${FORK_BLOCK:-45600000}"
        CHAIN_ID=31337

        # The three timelock lists have to stay disjoint: ProtocolAdmin's constructor rejects an
        # overlap and DeployConfig checks the same thing before broadcasting.
        export ESIM_WALLET_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        export VAULT=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
        export TIMELOCK_PROPOSERS=0x90F79bf6EB2c4f870365E785982E1f101E93b906
        export TIMELOCK_CANCELLERS=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
        export TIMELOCK_GUARDIANS=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc

        # Base Sepolia USDC. Checked with cast on 2026-08-29: has code, symbol USDC, 6 decimals.
        export SETTLEMENT_TOKEN=0x036CbD53842c5426634e7929541eC2318f3dCF7e
        ;;
    base-mainnet)
        FORK_RPC="${BASE_MAINNET_RPC:-https://mainnet.base.org}"
        FORK_BLOCK="${FORK_BLOCK:-}"
        CHAIN_ID=8453
        # Without it anvil runs chain 8453 on Ethereum rules and drops the P256 precompile Base has
        ANVIL_NETWORK_ARGS=(--network optimism)

        for var in ESIM_WALLET_ADMIN VAULT TIMELOCK_PROPOSERS TIMELOCK_GUARDIANS; do
            [[ -n "${!var:-}" ]] || fail "$var is unset in .env."
        done

        # DeployConfig.BASE_USDC. DeployConfig refuses anything else on 8453.
        export SETTLEMENT_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

        # Forge logs runs under broadcast/ and forge-cache/ by chain id. Refuse to start over a
        # real mainnet log, and drop the rehearsal's own on exit so it is never mistaken for one.
        for script in Deploy Configure TransferOwnership ForkRehearsal; do
            for dir in "broadcast/$script.s.sol/$CHAIN_ID" "forge-cache/$script.s.sol/$CHAIN_ID"; do
                [[ -e "$dir" ]] && fail "$dir already exists. Move it aside if it is a real deployment log."
                FORGE_LOGS_TO_DROP+=("$dir")
            done
        done
        ;;
    *)
        fail "NETWORK must be base-sepolia or base-mainnet, got '$NETWORK'."
        ;;
esac

# ------------------------------------------------------------------------------------------------

log "Starting anvil, forking $NETWORK at block ${FORK_BLOCK:-latest}"

FORK_BLOCK_ARGS=()
[[ -n "$FORK_BLOCK" ]] && FORK_BLOCK_ARGS=(--fork-block-number "$FORK_BLOCK")

# Auto impersonation lets the admin step send as whatever address ESIM_WALLET_ADMIN names
anvil \
    --fork-url "$FORK_RPC" \
    ${FORK_BLOCK_ARGS[@]+"${FORK_BLOCK_ARGS[@]}"} \
    ${ANVIL_NETWORK_ARGS[@]+"${ANVIL_NETWORK_ARGS[@]}"} \
    --chain-id "$CHAIN_ID" \
    --auto-impersonate \
    --silent \
    > "$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!

for _ in $(seq 1 30); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil did not come up. See $LOG_DIR/anvil.log"

echo "anvil up, chain id $(cast chain-id --rpc-url "$RPC"), forked at block $(cast block-number --rpc-url "$RPC")"

# The admin pays for postCreateAccount, and a real address may hold nothing on the fork
cast rpc anvil_setBalance "$ESIM_WALLET_ADMIN" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null

if [[ "$NETWORK" == base-mainnet ]]; then
    # DeployConfig requires code at every proposer and guardian on 8453. Checked here too, so a
    # testnet Safe missing on mainnet is named before forge starts. Printed by position only.
    missing=0
    for var in TIMELOCK_PROPOSERS TIMELOCK_GUARDIANS; do
        IFS=',' read -ra accounts <<< "${!var}"
        for i in "${!accounts[@]}"; do
            if [[ "$(cast code "${accounts[$i]}" --rpc-url "$RPC")" == "0x" ]]; then
                echo "$var entry $i has no code on Base mainnet"
                missing=1
                # Rehearsal only: lets the rest run with these addresses. A real deploy still refuses.
                [[ "${STUB_MISSING_SAFES:-0}" == 1 ]] \
                    && cast rpc anvil_setCode "${accounts[$i]}" 0x00 --rpc-url "$RPC" >/dev/null
            fi
        done
    done
    if [[ "$missing" == 1 && "${STUB_MISSING_SAFES:-0}" == 1 ]]; then
        printf '\033[33mSTUB_MISSING_SAFES=1: placeholder code put on the fork. Not deployable as is.\033[0m\n'
    elif [[ "$missing" == 1 ]]; then
        fail "Deploy the Safes on Base mainnet first, or rerun with STUB_MISSING_SAFES=1 to rehearse the rest."
    else
        echo "Every proposer and guardian carries code on Base mainnet"
    fi
fi

# The whole reason for forking rather than using a bare anvil.
ENTRY_POINT=0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108
[[ "$(cast code "$ENTRY_POINT" --rpc-url "$RPC" | wc -c)" -gt 2 ]] \
    || fail "EntryPoint v0.8 carries no code on the fork. Wrong block, or the fork did not take."
echo "EntryPoint v0.8 present at $ENTRY_POINT"

# RIP-7212, asked over RPC and not from inside a forge script.
#
# Forge's own EVM is osaka and carries the precompile whatever the chain does, and a precompile
# holds no bytecode, so only a call with a known-good vector over the wire tells them apart.
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
probe_p256 "$FORK_RPC" "$NETWORK itself"

# Start with neither file present. DeploymentRecord.isRecorded() reads file existence as "already
# deployed", so an empty {} here would make Deploy.s.sol refuse to start on its own rehearsal.
rm -f "$RECORD" "$ADDRESS_BOOK"

# Forge sizes a broadcast transaction from what the simulation consumed. That is wrong for
# handleOps: the EntryPoint checks the transaction carries the operation's whole declared gas
# before it starts and reverts AA95 out of gas when it does not, however little the operation goes
# on to use. The multiplier covers the gap. Unused gas is refunded.
GAS_MULTIPLIER=600

run_script() {
    local name="$1" path="$2"
    log "$name"
    # --unlocked sends every transaction through anvil, which holds the deployer and impersonates
    # the admin
    if ! forge script "$path" --rpc-url "$RPC" --broadcast --via-ir -vv \
        --unlocked --sender "$DEPLOYER" \
        --gas-estimate-multiplier "$GAS_MULTIPLIER" \
        > "$LOG_DIR/$name.log" 2>&1; then
        tail -40 "$LOG_DIR/$name.log" >&2
        fail "$name failed. Full log at $LOG_DIR/$name.log"
    fi
    grep -E '^\s+(Registry|DeviceWalletFactory|ESIMWalletFactory|PaymentAdapter|ProtocolAdmin|Wallet|initCode|Counterfactual|Ownership|UserOperation|Offchain|Extra)' \
        "$LOG_DIR/$name.log" || true
    echo "ok"
}

run_script deploy   scripts/deploy/Deploy.s.sol:Deploy
run_script configure scripts/deploy/Configure.s.sol:Configure
run_script handover scripts/deploy/TransferOwnership.s.sol:TransferOwnership
run_script rehearsal scripts/fork/ForkRehearsal.s.sol:ForkRehearsal

case "$CHAIN_ID" in
    31337) RECORD_KEY="anvil-31337-entrypoint-v8" ;;
    8453)  RECORD_KEY="base-8453-entrypoint-v8" ;;
esac

log "Contract addresses written by the rehearsal"
python3 -c "
import json
print(json.dumps(json.load(open('$ADDRESS_BOOK'))['$RECORD_KEY'], indent=2))
"

log "Deployment record written by the rehearsal"
python3 -c "
import json
r = json.load(open('$RECORD'))
print(json.dumps({k: r[k] for k in ('chain', 'status') if k in r}, indent=2))
print('contracts:', ', '.join(r.get('contracts', {})))
"

log "Rehearsal passed"
echo "Full suite deployed to the $NETWORK fork, all four scripts clean, representative transactions executed."
