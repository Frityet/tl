# Teal compiler fuzzer

The fuzzer is authored in typed Teal, with checked-in generated Lua for immediate
use. The supervisor requires **LuaJIT on macOS or Linux**, using its bundled FFI
and bit libraries plus POSIX libc. Compiler workers independently support Lua
5.1–5.5 or LuaJIT. There are no Python or third-party package dependencies.

From the repository root:

```sh
make fuzz-test
make fuzz-smoke
luajit extras/fuzz/fuzz.lua --seed 20261105 --cases 10000 --jobs 4
luajit extras/fuzz/fuzz.lua --lua luajit --targets 5.1 --seconds 300 --cases 100000
```

`FUZZ_LUA` selects the LuaJIT supervisor for Makefile targets; `LUA`/`--lua`
selects the compiler worker. For example, `make fuzz-smoke LUA=lua` checks the
compiler under stock Lua while its supervisor still runs under LuaJIT.
`--cases` counts source programs; default `--targets 5.1,5.3` checks each source
against both targets. Campaigns exit nonzero on **any** failure, retain all
failures without suppressions, and continue unless `--stop-on-failure` is set.
`--seconds` stops new submissions; active workers drain within their individual
timeouts (an optional reference comparison can require a second timeout).

Logs are `_temp/fuzz/results.jsonl`; counts/configuration are in `summary.json`.
Exact binary failure inputs plus adjacent JSON metadata go in `failures/`.
Use separate `--output` directories: logs/summary are replaced on each run,
while failure files remain. Corpus files are never modified.

## Teal sources and rebuilding

- `model.tl`: typed case, configuration and worker-result records.
- `generator.tl`: deterministic PRNG, grammar, dialect and mutation generators.
- `system.tl`: the typed POSIX FFI boundary, filesystem and child lifecycle.
- `json.tl` and `hash.tl`: JSON and SHA-256, without external packages.
- `runner.tl`: scheduling, pipeline results, artifacts, replay, reduction and CLI.
- `fuzz.tl`: executable entrypoint and cleanup on errors.
- `worker.tl`: compiler pipeline invariants and closed-program execution.
- `test_fuzz.tl`: plain Teal integration tests, generated alongside the runtime.

`.lua` files are generated artifacts. Edit `.tl`, then check and regenerate only
the fuzzer files, using this checkout's compiler and its normal dependencies:

```sh
make fuzz-build LUA=./lua
make fuzz-test
```

`fuzz-check` type-checks without regenerating. Both targets use `STABLE_TL`, so a
working compiler command can be supplied explicitly. Running the checked-in Lua
fuzzer/tests does not require compiler CLI dependencies such as argparse/Busted.
The sources use upstream Teal syntax; optional tl-ng programs are string
fixtures, rather than language features needed to run the supervisor itself.

## Inputs and checks

Generator **version 2** uses a local Park–Miller PRNG with explicit integer state;
it never reads or changes Lua's global random state. Each
`(seed, index, profile, native target lane, corpus, max-depth)` determines a case
independently of jobs/order. Version 2 intentionally changes the old Python
version 1 seed stream. Existing saved binary `.tl`/`.json` repros still replay
with their original expected return/target; original Python seed indices cannot
regenerate identical version 2 bytes. Keep original repro files for old bugs.

The eight interleaved profiles are:

- **grammar:** bounded typed arithmetic, functions, generics, records, arrays,
  multiple returns, enum branches, union narrowing, numeric and repeat loops.
  An independent arithmetic calculation predicts each closed program's return.
- **metamorphic:** alpha rename and insert comments into grammar programs,
  retaining their expected numeric return.
- **editor:** delete, insert, duplicate, splice comments, truncate, or replace
  arbitrary bytes, including NUL/invalid UTF-8, in generated source.
- **tokens:** keywords, operators, literals, macro delimiters and incomplete forms.
- **deep:** nested parentheses, blocks, table types and alias chains at depths
  up to `--max-depth` (128 by default). Normal rejection diagnostics are allowed.
- **corpus-mutation:** mutate checked-in seeds or user-provided seeds.
- **wide:** larger typed programs with up to 40 statement groups and an oracle.
- **corpus:** cycle deterministically through unchanged seeds. Add files or
  directories with repeated `--corpus PATH`; empty files are supported.

Workers validate token position ordering, parse twice and compare diagnostics,
check twice in fresh environments with internal consistency assertions enabled,
validate diagnostic locations and compare checker diagnostics. Malformed-input
rejection is expected; generated valid programs must have no syntax/type errors.
Accepted input is lowered twice with compatibility injection disabled, avoiding
nondeterministic compatibility preambles. Generated Lua must match and reparse
in Lua mode. It must load when the host supports that target. Only grammar
programs with numeric oracles execute, under an environment exposing only `type`
for union checks; their return must equal the independently calculated result.
Corpus/mutated input never executes.

Lua 5.1/LuaJIT cannot load newer standard Lua targets: those cases still check
generation/reparsing. Stock Lua 5.3+ covers loading and execution for newer
standard targets. Native `luajit` execution requires the patched extension set.
The `executed` field reports the actual check, avoiding claims of runtime
coverage for targets the worker cannot execute.

`--reference-root OTHER_CHECKOUT` also compares acceptance with another compiler
checkout. Differences fail, including intentional language changes; a reference
compiler exception is reported separately. This is grammar/property fuzzing,
not coverage-guided fuzzing or proof of correctness. No branch coverage
percentage is claimed. Arithmetic avoids division, overflow and rounding;
closed grammar currently avoids module resolution and stdlib-heavy programs.
Add corpus seeds to reach those compile-time paths.

## Isolation and bounds

Each case gets a separate interpreter process and temporary working directory.
The supervisor disables JIT globally before its single-threaded fork/configure/
exec path. It sets a separate process group, redirects stdin from `/dev/null`,
clears Lua/TL initialization/search-path overrides, and applies CPU, output-file
size (4 MiB per file), and zero-core-dump limits before exec. The whole process
group is killed on `--timeout` (default 5 seconds), including descendants.
Workers run concurrently using nonblocking `waitpid` polling, without threads.
Interpreter paths resolve before changing directories, including `./lua` wrappers.
Invalid interpreter/compiler roots fail before launching a campaign.

`--memory-mb` optionally caps virtual address space; default 0 leaves it unlimited
because LuaJIT reserves large virtual arenas. `--max-input` caps input bytes
(default 128 KiB): oversize seeds are skipped; generated inputs are truncated
and lose their validity oracle. Corpus walks do not follow directory symlinks.
Temporary cleanup removes the three supervisor-created input/output files and
tries to remove the directory; it does not recursively erase worker-created
content. Unexpected errors/interrupts unwind through the entrypoint cleanup and
terminate active process groups. SIGKILL of the supervisor cannot run cleanup.

This is availability isolation, **not an OS security sandbox**. Compilation can
evaluate language macros. Use trusted local corpus/checkouts and do not expose
the runner as a service for hostile uploads.

## Replay and reduction

```sh
luajit extras/fuzz/fuzz.lua --seed 33 --start 41 --cases 1 --targets 5.1
luajit extras/fuzz/fuzz.lua --replay _temp/fuzz/failures/SEED-INDEX-TARGET-HASH.tl
luajit extras/fuzz/fuzz.lua --replay path/to/crash.tl --minimize \
  --minimize-attempts 100 --minimize-seconds 60 --output _temp/reduced
```

Replay reads the adjacent JSON's oracle and target. Execution settings such as
`--root`, `--lua`, `--timeout` remain explicit choices so the same bytes can test
a fixed compiler. Metadata records generator version, original configuration,
compiler Git revision and SHA-256. Git HEAD works for main/linked worktrees;
locally modified compiler files are not snapshotted. Keep `.tl`/`.json` together.

Reduction is bounded byte-level ddmin and retains the failure stage and first
crash/invariant signature. A local minimum need not be shortest. The total
reduction budget can overrun by one regular per-case timeout (two with a
reference). Minimized files are separate and originals remain untouched.
**Reduction is refused when an expected numeric result is saved**: deleting
source invalidates both the validity promise and semantics oracle, potentially
fabricating a bug. Preserve those original reports. Robustness crashes can use
corpus failures, or a `.tl` without adjacent oracle JSON. No compiler errors are
automatically fixed or silently ignored.

## Optional tl-ng syntax

```sh
luajit extras/fuzz/fuzz.lua --root /path/to/tl-ng --profile tl-ng \
  --lua luajit --targets 5.1,luajit --seed 33 --cases 10000 --jobs 4
```

The profile interleaves 18 dialect generators: typed short functions, ternaries,
nil coalescing, safe navigation, compound assignments, `continue`, macros,
named/symbolic/Unicode operators, prefix/postfix operators, precedence,
associativity, lexical shadowing and generic callbacks. Standard targets use
11 portable generators; native `luajit` uses all 18. Their independent numeric
oracles execute after lowering and also seed editor mutations. Native loading
requires LuaJIT with the full backported extension set; the worker probes
ternary support and does not emulate missing features. Native bit operations
are not in the closed grammar yet.

`profiles/tl-ng/` additionally holds macro reader-error recovery, invalid-splice/
scalar-result and short-function robustness seeds, including incomplete byte
prefixes. Normal diagnostics are allowed; exceptions, broken invariants and
timeouts fail. Exact diagnostic wording belongs in compiler regression tests.
Extend the directory or `--corpus` for additional features; use the default
profile for official upstream Teal.

## Tests

`make fuzz-test` runs the generated plain Lua test harness under LuaJIT. Tests
cover addressable generation and arithmetic semantics, SHA-256 vectors, JSON,
bounded reduction, empty corpus/file/directory reads, actual pipeline checks,
all portable/native dialect templates when available, intentionally wrong
numeric returns, non-execution of infinite corpus programs, a distinct
controlled reference compiler that deliberately disagrees, actual process-group
timeouts with descendant heartbeats, process crashes, legacy Python metadata,
semantic-reduction refusal, binary repro preservation, relative/missing
interpreters, bad compiler roots and both Git metadata layouts.
