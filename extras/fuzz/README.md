# Teal compiler fuzzer

`fuzz.py` replaces the development-only, unbounded `extras/microfuzz.tl` workflow
with deterministic generated programs, malformed editor buffers, compiler
invariants, and replayable failures. It needs Python 3.10+ and Lua 5.1–5.5 or
LuaJIT on POSIX hosts (macOS/Linux). It uses only the Python and Lua standard libraries and the compiler in
this checkout. No Teal build or third-party Python package is needed.

From the repository root:

```sh
make fuzz-test
make fuzz-smoke
python3 extras/fuzz/fuzz.py --seed 20261105 --cases 10000 --jobs 4
python3 extras/fuzz/fuzz.py --lua luajit --targets 5.1 --seconds 300 --cases 100000
```

`--cases` counts source programs; the default `--targets 5.1,5.3` runs each
program twice. The campaign exits nonzero on **any** failure, records all failures
without suppressions, and continues unless `--stop-on-failure` is selected.
`--seconds` stops new submissions; already running cases finish within their
individual timeout. Source generation itself is bounded. Logs appear in
`_temp/fuzz/results.jsonl`, final counts in `summary.json`, and exact binary
failure inputs plus JSON metadata in `failures/`. Use different `--output`
directories for campaigns: logs/summary are replaced on each run, failure files
are retained. Existing corpus files are never modified.

## Inputs and checks

Each `(seed, index, profile, native target lane, corpus)` independently determines
one source file, regardless of job count or completion order. Native `luajit`
and standard Lua targets use different dialect feature sets. The eight
interleaved profiles are:

- **grammar:** bounded typed arithmetic, functions, generic functions, records,
  arrays/indexing, multiple returns, enum branches, union narrowing, numeric
  loops and repeat loops. A separate Python integer oracle predicts the return.
- **metamorphic:** alpha rename and insert comments into a generated program;
  the numeric oracle is unchanged.
- **editor:** delete, insert, duplicate, splice comments, truncate, or replace
  arbitrary bytes (including NUL and invalid UTF-8) in generated source.
- **tokens:** random grammar keywords, operators, literals, macro delimiters,
  pragmas and incomplete fragments.
- **deep:** nested parentheses/blocks/table types and alias chains at depths 8,
  16, 32 or `--max-depth` (default 128). These probe robustness, with normal
  resource-limit diagnostics permitted rather than guaranteed acceptance.
- **corpus-mutation:** mutate checked-in or user supplied seeds.
- **wide:** larger typed programs with up to 40 statement groups and the same
  independent semantics oracle.
- **corpus:** replay seed files unchanged, cycling deterministically through
  the corpus. Add more `.tl` files/directories with repeated `--corpus PATH`.

The isolated Lua worker lexes input and validates token position order, parses
it twice and compares diagnostics, checks it twice in fresh environments with
internal consistency assertions enabled, validates diagnostic locations, and
compares checker diagnostics. Rejected malformed inputs are normal outcomes.
Generated valid inputs must have no syntax/type errors. Every accepted input is
lowered twice with compatibility injection disabled to avoid nondeterministic
compatibility preambles; outputs must match. Generated Lua is reparsed in Lua
mode and loaded when the host supports that target. Only generated closed
programs execute, with a restricted environment containing `type` for union
checks. Their numeric returns must match the Python oracle. Corpus/mutated
programs are **never executed**. An optional `--reference-root OTHER_CHECKOUT`
compares acceptance with another compiler checkout; mismatches are reported,
even when caused by an intentional language change.

A Lua 5.1/LuaJIT host cannot load newer Lua targets; those cases still exercise
generation and Lua reparsing. Use a stock Lua 5.3+ interpreter to cover loading
and execution for the newer targets, and a separate LuaJIT run for native 5.1
behavior. `executed` in the per-case result records the actual execution check.
This is grammar/property fuzzing, not a coverage-guided fuzzer or a proof of
compiler correctness. No branch-coverage percentage is claimed. The arithmetic
oracle avoids division, overflow and floating point rounding to keep differences
meaningful across Lua implementations. Generated inputs currently avoid module
resolution, filesystem I/O and stdlib-heavy programs; add corpus seeds for
those compile-time paths.

## Isolation and bounds

Every check runs in its own interpreter process, with its own temporary working
directory and a clean Lua/TL search-path environment. The supervisor kills the
whole process group on `--timeout` (default 5 seconds). CPU time, output-file size
(4 MiB per file) and core-dump limits are set before starting Lua on POSIX.
`--memory-mb` optionally bounds virtual address space; the default leaves it
unlimited because LuaJIT reserves large virtual arenas. `--max-input` caps corpus
and generated source size (default 128 KiB). Oversize corpus seeds are skipped;
oversize generated inputs are truncated and lose their valid-program oracle.

This is availability isolation, **not an OS security sandbox**. Compilation can
itself evaluate language macros. Use trusted local corpus material and compiler
checkouts; do not treat the runner as a safe service for hostile uploads.

## Reproduce and reduce

Recreate a generated index without running earlier indices:

```sh
python3 extras/fuzz/fuzz.py --seed 20261105 --start 41 --cases 1 --targets 5.1
python3 extras/fuzz/fuzz.py --replay _temp/fuzz/failures/SEED-INDEX-TARGET-HASH.tl
python3 extras/fuzz/fuzz.py --replay path/to/crash.tl --minimize \
  --minimize-attempts 100 --minimize-seconds 60 --output _temp/reduced
```

Replay reads the adjacent JSON file to restore its numeric oracle and target;
`--root`, `--lua`, `--timeout` and other execution settings remain explicit CLI
choices, so the same saved bytes can test a fixed checkout. JSON metadata records
original settings, compiler Git revision, Python version and the SHA-256 digest.
The revision identifies HEAD; locally modified compiler files are not snapshotted. Keep the `.tl` and `.json` together.

Reduction uses bounded byte-level ddmin, preserving the failure stage and first
crash/invariant signature. Each attempt retains the regular per-case timeout;
the total reduction budget may overrun by one attempt. It may reach a local
minimum, not necessarily the shortest possible reproducer. **Reduction is refused
for generated-program failures with an expected numeric result**: deleting source
would invalidate both the validity promise and the semantics oracle and could
fabricate a bug. Preserve those original reports for analysis. For robustness
crashes, use an input without an oracle (a corpus failure or a `.tl` replay
without adjacent oracle JSON). Minimized files are saved separately and originals
are preserved. No compiler errors are automatically fixed or silently ignored.

## Optional tl-ng syntax

The core runner and default corpus work on official upstream Teal. The optional
profile is only intended for a compiler supporting tl-ng syntax:

```sh
python3 extras/fuzz/fuzz.py --root /path/to/tl-ng --profile tl-ng \
  --lua luajit --targets 5.1,luajit --seed 33 --cases 10000 --jobs 4
```

It interleaves the upstream grammar with 18 dialect generators: typed short
functions, ternaries, nil coalescing, safe navigation, compound assignments,
`continue`, macros, named/symbolic/Unicode custom operators, prefix/postfix
operators, precedence, associativity, lexical shadowing and generic callbacks.
These valid programs
have independent numeric oracles and execute after lowering. They also feed the
editor-mutation profile. Standard Lua targets use the 11 portable generators;
the native `luajit` target uses all 18, including features restricted to that
target. Native loading/execution requires LuaJIT with the full backported
extension set. The worker probes ternary support to identify that runtime; it
does not emulate missing runtime features. Native bit operations are not yet in
the closed arithmetic grammar.

Macro reader-error recovery, invalid-splice/scalar-result, and short-function
editor seeds from `profiles/tl-ng/` add robustness probes and incomplete byte
prefixes. Normal diagnostics are allowed for those seeds; compiler exceptions,
broken invariants and timeouts fail. Exact diagnostic text is covered by the
compiler's regression suite. Extend the directory or use `--corpus` for more
features; keep upstream-only campaigns on the default profile.

## Tests

```sh
python3 -m unittest discover -s extras/fuzz -p 'test_*.py' -v
```

The tests verify independent seed/index generation, the arithmetic oracle,
reduction budgets, binary repro preservation, rejection of invalid semantic
reduction, an actual compiler run across all profiles, LuaJIT execution when
installed, injected wrong-return detection, normal malformed-input rejection,
reference comparison, a nonterminating corpus program that must never execute,
and a fake hanging/crashing interpreter to prove parent timeouts and process
failure reporting. Lua compiler tests skip when no interpreter is installed.
