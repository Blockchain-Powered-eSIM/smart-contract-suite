#!/usr/bin/env python3
"""Emit a JSON object describing the tree a deployment was built from.

The deploy script calls this through `vm.ffi` and nests the result under `build` in
`deployments/address.json`. Everything here answers the same question: given only that file,
can somebody rebuild byte-identical bytecode and check it against what is onchain?

That needs three things, and a commit hash alone is none of them. It needs the commit, the
seven submodule commits (a `lib/` bump changes the output without changing this repo's
history), and the compiler settings, because `bytecode_hash`, the optimizer run count and the
evm version all move the bytes.

The storage layout hashes come last. They are what an upgrade is checked against later, and
this is the only moment the layout and the deployed address are known together.
"""

import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def git(*args):
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.strip()


def submodule_pins():
    """Map each `lib/` path to the commit it is checked out at.

    `git submodule status` puts a flag character in column one: a space when the checkout sits
    at the commit this repo records, `+` when it has moved, `-` when it is not initialised.
    Read with a regex rather than by slicing, because the flag is a space on the common case
    and stripping whitespace anywhere would eat the first digit of the hash instead.

    `atPin` false is a reason to stop and look. It means the deployed bytecode was built from a
    dependency this repo does not record, so nobody can reproduce it from the commit alone.
    """
    raw = subprocess.run(
        ["git", "submodule", "status"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout

    pins = {}
    for line in raw.splitlines():
        match = re.match(r"^([ +\-U])([0-9a-f]{40})\s+(\S+)", line)
        if not match:
            continue
        flag, commit, path = match.groups()
        pins[path] = {"commit": commit, "atPin": flag == " "}
    return pins


def compiler_settings():
    """Read the settings that move bytecode straight out of foundry.toml.

    Parsed rather than hardcoded so this file cannot drift away from the build. Only the
    `[profile.default]` block is read, since that is what a deploy runs under.
    """
    text = (ROOT / "foundry.toml").read_text()
    default = text.split("[profile.default]", 1)[1].split("\n[", 1)[0]

    def value(key):
        match = re.search(rf"^{key}\s*=\s*(.+)$", default, re.MULTILINE)
        if not match:
            return None
        return match.group(1).strip().strip("'\"").replace("_", "")

    return {
        "solc": value("solc"),
        "evmVersion": value("evm_version"),
        "optimizer": value("optimizer") == "true",
        "optimizerRuns": int(value("optimizer-runs")),
        "viaIR": value("via_ir") == "true",
        "bytecodeHash": value("bytecode_hash"),
    }


def storage_layout_hashes():
    """Hash each committed storage layout so an upgrade can be diffed against the deployment.

    Absent rather than empty when the directory has not been generated, so a missing entry
    reads as "not recorded" instead of "no storage".
    """
    layouts = {}
    directory = ROOT / "storage-layouts"
    if not directory.is_dir():
        return layouts
    for path in sorted(directory.glob("*.json")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        layouts[path.stem] = f"0x{digest}"
    return layouts


def main():
    # Scoped to `contracts/` on purpose. Third party submodules accumulate stray lockfiles, so
    # `lib/` reads as modified almost always without a single source line having changed, and
    # folding that in here would make every deployment record read dirty and mean nothing.
    # Whether a dependency actually moved is the `atPin` flag, recorded per submodule.
    dirty = git("status", "--porcelain", "--", "contracts") != ""

    provenance = {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "dirty": dirty,
        "submodules": submodule_pins(),
        "compiler": compiler_settings(),
        "storageLayoutHashes": storage_layout_hashes(),
    }

    # Compact, because forge reads this back through ffi as one value.
    json.dump(provenance, sys.stdout, separators=(",", ":"), sort_keys=True)


if __name__ == "__main__":
    main()
