#!/usr/bin/env python3
"""Compare two compiler builds on real sources and test snippets.

Usage (LuaJIT and the compiler's Lua test dependencies must be on the path):
    python3 extras/compare-frontends.py /path/to/baseline /path/to/candidate
    python3 extras/compare-frontends.py ../baseline . \
        --extra-spec spec/lang/parser/frontend_reader_spec.lua

The source corpus defaults to the baseline checkout. Neither checkout is
modified. Generated input and snapshots live in a temporary directory; use
--output-dir if you want to retain them for investigating a mismatch.
"""

import argparse
import contextlib
import itertools
import json
import os
import pathlib
import re
import subprocess
import tempfile


LONG_STRING = re.compile(r"\[(=*)\[(.*?)\]\1\]", re.DOTALL)
SOURCE_WORD = re.compile(r"\b(local|function|return|global|macro|while|repeat|if|for)\b")


def snippets(path, name):
    for index, match in enumerate(LONG_STRING.finditer(path.read_text())):
        source = match[2]
        if SOURCE_WORD.search(source):
            yield {"name": f"{name}-{index}.tl", "source": source}


def corpus(root, extras):
    cases = [
        {"name": str(path.relative_to(root)), "source": path.read_text()}
        for path in sorted(root.glob("teal/**/*.tl"))
    ]
    for path in sorted(root.glob("spec/**/*.lua")):
        cases.extend(snippets(path, str(path.relative_to(root))))
    for index, path in enumerate(extras):
        cases.extend(snippets(path, f"extra-{index}/{path.name}"))
    if not cases:
        raise ValueError(f"no compiler sources or test snippets found in {root}")
    return cases


def snapshot(lua, runtime, source_root, manifest, destination):
    worker = pathlib.Path(__file__).with_name("frontend-snapshot.lua").resolve()
    env = os.environ.copy()
    # Both runtimes see exactly the same imported source modules.
    paths = ["./extras/?.tl", "./extras/?/init.tl", "./?.tl", "./?/init.tl", "./?.d.tl"]
    env["TL_PATH"] = ";".join(paths)
    with destination.open("w") as output:
        subprocess.run(
            [lua, str(worker), str(runtime), str(manifest)],
            cwd=source_root,
            env=env,
            stdout=output,
            check=True,
        )


def compare(before, after):
    mismatches, count = [], 0
    with before.open() as left, after.open() as right:
        for a_line, b_line in itertools.zip_longest(left, right):
            if a_line is None or b_line is None:
                raise ValueError("snapshot case counts differ")
            a, b = json.loads(a_line), json.loads(b_line)
            if a["name"] != b["name"]:
                raise ValueError("snapshot cases are not in the same order")
            count += 1
            for stage in ("lex", "raw", "read", "program", "parse", "ast", "blocks_unchanged"):
                if a.get(stage) != b.get(stage):
                    mismatches.append((a["name"], stage, a.get(stage), b.get(stage)))
            if b.get("blocks_unchanged") is False:
                mismatches.append((a["name"], "input Block mutation", True, False))
    return count, mismatches


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("baseline", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("--source-root", type=pathlib.Path, help="default: baseline checkout")
    parser.add_argument("--extra-spec", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--lua", default="luajit")
    parser.add_argument("--output-dir", type=pathlib.Path)
    args = parser.parse_args()
    baseline, candidate = args.baseline.resolve(), args.candidate.resolve()
    source_root = (args.source_root or baseline).resolve()
    cases = corpus(source_root, args.extra_spec)
    print(f"Comparing {len(cases)} source cases across tokens, Blocks, ASTs, diagnostics, and sparse lengths.", flush=True)
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        directory = contextlib.nullcontext(str(args.output_dir.resolve()))
    else:
        directory = tempfile.TemporaryDirectory(prefix="tl-frontend-")
    with directory as path:
        output = pathlib.Path(path)
        manifest = output / "cases.json"
        manifest.write_text(json.dumps(cases))
        left, right = output / "baseline.jsonl", output / "candidate.jsonl"
        snapshot(args.lua, baseline, source_root, manifest, left)
        snapshot(args.lua, candidate, source_root, manifest, right)
        count, mismatches = compare(left, right)
        for name, stage, before, after in mismatches[:20]:
            print(f"MISMATCH {name}: {stage}")
            if isinstance(before, str) and isinstance(after, str):
                at = next((i for i, (a, b) in enumerate(zip(before, after)) if a != b), min(len(before), len(after)))
                print(f"  baseline:  {before[max(0, at - 60):at + 120]}")
                print(f"  candidate: {after[max(0, at - 60):at + 120]}")
        print(f"{count} cases compared; {len(mismatches)} mismatches.")
        if args.output_dir:
            print(f"Snapshots: {output}")
        return 1 if mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
