#!/usr/bin/env python3
"""Report branch coverage over the branches forge can actually see.

`forge coverage --ir-minimum` does not count `require(cond, "string")` as a branch. Those sites
report zero hits on both arms even where the line itself runs hundreds of times, and they are the
majority of the branch denominator in this repo, so the percentage forge prints tracks how much of
a contract is written with custom errors rather than how much of it is tested.

`if (cond) revert CustomError()` is counted correctly, reverting arm included. This script drops
the require sites and reports what is left, plus the arms that are genuinely uncovered.

Usage:
    forge coverage --ir-minimum --report lcov --report-file lcov.info \
        --no-match-path "test/foundry/{fork,invariant-testing}/*"
    python3 script/branch-coverage.py lcov.info

Fork tests are excluded because they skip when the RPC variables are unset, so including them
makes the number depend on the environment. Invariant runs are excluded for runtime: a campaign
under `--ir-minimum` costs more than the rest of the suite put together. They do reach branches,
so this is a deliberate choice about what the number means. A branch that only a random walk
reaches counts as uncovered here, which is the intent: it should be pinned by a named test.

Fuzz tests stay in. They run in seconds and reach revert arms that fixed inputs do not.
"""

import collections
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def parse(lcov_path):
    """Read an lcov file into per-file branch arms and per-line hit counts."""
    branches = collections.defaultdict(lambda: collections.defaultdict(list))
    line_hits = collections.defaultdict(dict)
    current = None

    for raw in pathlib.Path(lcov_path).read_text().splitlines():
        record = raw.strip()
        if record.startswith("SF:"):
            current = record[3:]
        elif record.startswith("BRDA:"):
            line, _block, _arm, hits = record[5:].split(",")
            branches[current][int(line)].append(0 if hits == "-" else int(hits))
        elif record.startswith("DA:"):
            line, hits = record[3:].split(",")
            line_hits[current][int(line)] = int(hits)

    return branches, line_hits


def source_line(sources, path, number):
    if path not in sources:
        sources[path] = (ROOT / path).read_text().splitlines()
    return sources[path][number - 1].strip()


def main():
    lcov = sys.argv[1] if len(sys.argv) > 1 else "lcov.info"
    branches, line_hits = parse(lcov)
    sources = {}

    total_arms = measurable_arms = covered_arms = 0
    gaps = []

    print(f"{'contract':<26}{'raw':>12}{'measurable':>16}")
    for path in sorted(branches):
        if "contracts/" not in path:
            continue

        arms_here = skipped_here = covered_here = 0
        for number, arms in sorted(branches[path].items()):
            arms_here += len(arms)
            if source_line(sources, path, number).startswith("require"):
                skipped_here += len(arms)
                continue
            for hits in arms:
                if hits:
                    covered_here += 1
                else:
                    gaps.append((path, number, line_hits[path].get(number, 0)))

        measurable_here = arms_here - skipped_here
        total_arms += arms_here
        measurable_arms += measurable_here
        covered_arms += covered_here

        raw_covered = sum(1 for arms in branches[path].values() for h in arms if h)
        share = 100 * covered_here / measurable_here if measurable_here else 0
        print(
            f"{path.split('/')[-1]:<26}{raw_covered:>4}/{arms_here:<7}"
            f"{covered_here:>7}/{measurable_here:<5} = {share:5.1f}%"
        )

    raw_total = sum(
        1 for p in branches if "contracts/" in p for arms in branches[p].values() for h in arms if h
    )
    print(f"\nraw        {raw_total}/{total_arms} = {100 * raw_total / total_arms:.2f}%  (do not quote this)")
    print(
        f"measurable {covered_arms}/{measurable_arms} = "
        f"{100 * covered_arms / measurable_arms:.2f}%  "
        f"({total_arms - measurable_arms} require arms excluded)"
    )

    print(f"\nuncovered measurable arms: {len(gaps)}")
    for path, number, executions in gaps:
        # A line that never ran at all is a function no test calls, rather than an untaken branch
        note = "function never called" if executions == 0 else f"line ran {executions}x"
        print(f"  {path}:{number}  ({note})")
        print(f"      {source_line(sources, path, number)[:96]}")

    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
