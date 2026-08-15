#!/usr/bin/env python3
"""Write a storage layout baseline for every contract that can hold storage.

Two proxy layers sit under this protocol, four UUPS singletons and beacon-proxied wallets behind
two factories, so a slot that moves silently is the failure mode with the widest blast radius. The
baseline exists to make that visible in a diff rather than after a deploy.

Usage:
    python3 script/storage-layouts.py

Writes storage-layouts/<Contract>.json. CI regenerates and fails on `git diff --exit-code`, the
same shape the gas snapshots under snapshots/ already use.

`forge inspect` output is normalised before it is written. It carries an `astId` on every entry and
inside every contract, struct and enum type name, and those renumber whenever an unrelated source
line moves. Left in, the check would fail on edits that touch no storage at all. Array lengths look
similar and are kept: the 2 in `t_array(t_bytes32)2_storage` is the length, not an id.
"""

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "storage-layouts"

# Every contract under contracts/ that declares storage, plus P256Verifier, which declares none and
# is baselined anyway so that gaining a slot shows up as a new file rather than as nothing.
CONTRACTS = (
    "Registry",
    "RegistryHelper",
    "LazyWalletRegistry",
    "DeviceWalletFactory",
    "ESIMWalletFactory",
    "DeviceWallet",
    "ESIMWallet",
    "Account4337",
    "ProtocolAdmin",
    "P256Verifier",
)

# t_contract(Name)1234 and t_struct(Name)1234_storage carry an ast id. t_array(...)2_storage does
# not, so array is deliberately absent from this list.
AST_ID_IN_TYPE = re.compile(r"(t_(?:contract|struct|enum|userDefinedValueType)\([^()]*\))\d+")


def declared_contracts():
    """Every `contract X` declared under contracts/, mapped to its path.

    Scanning rather than trusting the list below is what stops a newly added contract from being
    baselined by nobody. It also supplies the source path for a contract with no storage, where
    forge omits it.
    """
    found = {}
    for path in sorted((ROOT / "contracts").rglob("*.sol")):
        for match in re.finditer(r"^contract\s+(\w+)", path.read_text(), re.MULTILINE):
            found[match.group(1)] = path.relative_to(ROOT).as_posix()
    return found


def normalise(type_name):
    return AST_ID_IN_TYPE.sub(r"\1", type_name)


def layout(contract, source):
    result = subprocess.run(
        ["forge", "inspect", contract, "storage-layout", "--json"],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if result.returncode != 0:
        raise SystemExit(f"forge inspect failed for {contract}:\n{result.stderr}")

    raw = json.loads(result.stdout)
    types = raw.get("types") or {}

    entries = []
    for entry in raw.get("storage", []):
        type_name = entry["type"]
        entries.append(
            {
                "slot": entry["slot"],
                "offset": entry["offset"],
                "bytes": types.get(type_name, {}).get("numberOfBytes"),
                "label": entry["label"],
                "type": normalise(type_name),
            }
        )

    return {"contract": f"{source}:{contract}", "storage": entries}


def main():
    declared = declared_contracts()
    missing = set(declared) - set(CONTRACTS)
    if missing:
        raise SystemExit(
            "contracts/ declares a contract with no baseline: "
            + ", ".join(sorted(missing))
            + "\nAdd it to CONTRACTS in this file and regenerate."
        )

    OUT.mkdir(exist_ok=True)
    for contract in CONTRACTS:
        body = layout(contract, declared[contract])
        (OUT / f"{contract}.json").write_text(json.dumps(body, indent=2) + "\n")
        print(f"{contract:<22}{len(body['storage']):>3} entries")

    return 0


if __name__ == "__main__":
    sys.exit(main())
