# Reader, parser, and macro performance

The frontend uses the existing LuaJIT runtime and is enabled by default. There
is no native extension to build and no alternate grammar to select. Its public
token, Block, AST, diagnostic, and source-position formats are retained.

## Measurements

Measured on 2026-11-26 against commit `84d1921`, using LuaJIT
`2.1.1795119671` on Linux x86-64, Intel Xeon Platinum 8573C. Both implementations
read the same pristine baseline sources. The compiler corpus contains 432,666
bytes in 12 source files. The application corpus contains `example/showcase.tl`
and `example/triage/main.tl`, including the imports needed during compilation.

Warm results are medians of five samples, with three rounds per sample and two
warmup rounds. Garbage collection is enabled. Times are milliseconds per round.

| Workload | Baseline | Updated | Speedup |
| --- | ---: | ---: | ---: |
| Full parse, compiler sources | 131.972 ms | 123.681 ms | 1.07x |
| AST lowering, prebuilt compiler Blocks | 46.396 ms | 37.020 ms | 1.25x |
| Decorators and `Statement \| Expression` macros | 82.671 ms | 41.448 ms | 1.99x |
| 512 macro declarations, repeated file | 142.125 ms | 32.634 ms | 4.36x |
| 2,048 distinct macro declarations, cache exceeded | 994.303 ms | 581.534 ms | 1.71x |
| 512 macro calls expanding to eight statements each | 1,192.193 ms | 29.782 ms | 40.03x |
| Application parse | 40.742 ms | 25.461 ms | 1.60x |
| Application check | 92.737 ms | 75.918 ms | 1.22x |
| Application check and generation | 100.248 ms | 81.697 ms | 1.23x |

Cold results are medians of five fresh LuaJIT processes with no warmups. The
timer starts after initial frontend imports and primary source reads, so these
are first frontend invocations, not whole-process startup measurements. Lazy
module loading and source imports during the measured stage are included.

| Cold full-parse workload | Baseline | Updated | Speedup |
| --- | ---: | ---: | ---: |
| Compiler sources | 171.382 ms | 149.839 ms | 1.14x |
| Decorators and mixed macro arguments | 94.255 ms | 38.007 ms | 2.48x |
| 512 macro declarations | 148.852 ms | 91.726 ms | 1.62x |
| 2,048 macro declarations | 944.651 ms | 483.908 ms | 1.95x |
| 512 expanding statement macros | 1,179.296 ms | 42.580 ms | 27.70x |
| Applications | 59.878 ms | 48.674 ms | 1.23x |

The largest gain addresses a quadratic macro-expansion workload. Ordinary
compiler-source parsing improves much less. AST-only and full-parse timings
are separate experiments with different live heaps and are not additive.
The cache-exceeding and cold cases show improvements that do not depend on
reusing all compiled macros.

Absolute times vary by machine and workload.

## Validation

- Two-stage self-build passed with identical generated output, and both shipped
  bundles (`tl.lua` and `teal.lua`) were regenerated.
- The differential harness compared **2,086 source cases with zero mismatches**,
  including sparse Lua lengths, graph sharing, errors and source positions,
  token rewrites, and the public AST input-mutation check.
- **23 new regressions pass**: 11 reader-state cases, 9 macro-evaluation cases,
  and 3 compact-quote equivalence cases.
- Final bundled language/auxlib suite: **2,164 successes, 5 failures, 0 errors**.
  API suite: **110 successes**. CLI suite: **168 successes**. Total: **2,442
  successes**, with the same five failures present on the pristine baseline.

The unchanged baseline failures concern the expected nullable `setmetatable`
signature in `to_const_spec.lua`, generic metatable inference in
`local_type_spec.lua`, two nullable `FILE`/`<close>` cases in `local_spec.lua`,
and the attached-interface macro import in `invocation_spec.lua`. This change
does not suppress or rewrite those test expectations.

## What changed

### Reader

Speculative expression parsing records token edits in a rollback journal.
Previously, each `Statement | Expression` argument and ambiguous nullable-type
suffix copied the entire token array and scanned the unconsumed file for generic
closers. A successful probe now keeps its edits; a failed probe reverses only
its edits. Nested probes retain the enclosing journal. Reentrant statement
parsing isolates mutable generic closers while keeping the work proportional to
the argument being parsed.

Custom operators use a byte-prefix trie, preserving longest contiguous matches
across token boundaries. The previous matcher tried every registered operator
and concatenated candidate token strings. The byte trie also accepts equivalent
token segmentations supplied through `read_program`. Nested scopes share operator and macro-signature maps
until a declaration writes to them. Trie state is discarded between top-level
reads, including when callers reuse and edit an operator context.

Comment blocks are appended directly to their destination. Structural walks
use the fixed child layout where appropriate. Continue validation also visits
arbitrary sparse numeric children supplied by macros, reusing one sorted-key
buffer per recursion depth. Block array allocation retains the original layout,
including observable Lua length behavior on sparse blocks.

### AST lowering

Operator nodes are allocated with their final fields. Ordinary node positions
and type metadata are initialized in their first table constructor, avoiding
extra calls and table growth. Numeric spelling is normalized once. Comment
buffers and recovery types are allocated only when needed.

Public `ast.parse_blocks` still produces ordinary AST nodes and does not mutate
its input Block graph. The macro compiler uses a separate internal
`ast.parse_macro` entry point, which represents quoted syntax as one compact Lua
constructor. This avoids creating and traversing multiple temporary AST nodes
for each quote metadata field. Quotes preserve sparse children, byte strings,
source positions, and independent splice clones.

### Macro evaluation

Macro statement expansion and declaration removal compact statement arrays
linearly. Expanding one macro no longer repeatedly shifts all following
statements. Imported-name references are collected once, with removal accounting
that preserves the previous reverse-order behavior. Visitation state belongs to
an expansion environment, so reentrant expression parsing cannot replace it.

A bounded FIFO cache reuses compiled macro bytecode after exact structural
validation of an immutable declaration snapshot. The comparison includes sparse
numeric children, token spelling, locations, and the language/filename context.
Each parse loads a fresh function into a fresh sandbox: mutable macro globals,
callbacks, argument Blocks, and expansion results are not cached. The cache has
at most 1,024 entries and an approximately 8 MiB accounted-size budget; that
budget is not a process-RSS limit. See [macro execution and reuse](macros.md).

The ordinary invocation path calls the macro under `pcall` without allocating
an extra wrapper closure. Very large argument lists retain a protected unpack
path, so a LuaJIT stack limit becomes a macro diagnostic rather than an escaped
compiler error.

## Runtime choice

The recursive reader and AST lowerer retain their existing JIT opt-out. Simply
enabling tracing was slower on the measured compiler corpus; tracing a large
polymorphic recursive frontend consumed time compiling and discarding traces.
The lexer and user code continue to use normal LuaJIT behavior. Generic
`table.new` substitutions were also measured and rejected where they did not
improve the real workload. Reserving extra Block array slots was rejected
because it changed Lua's observable sparse-array length.

These changes address measured algorithms and allocation costs. They do not
establish that no possible native implementation could be faster.

## Reproduce

Install the compiler's LuaJIT dependencies and `dkjson` for the JSON benchmark
output. Keep both runs on the same source corpus:

```sh
git worktree add --detach ../tl-frontend-baseline 84d1921

TL_FRONTEND_RUNTIME=../tl-frontend-baseline \
  luajit extras/bench-frontend.lua parse compiler ../tl-frontend-baseline 3 5 2
luajit extras/bench-frontend.lua parse compiler ../tl-frontend-baseline 3 5 2
```

Arguments are stage, corpus, source root, rounds per sample, samples, and warmup
rounds. `TL_FRONTEND_RUNTIME` selects the implementation without changing the
source inputs. The harness loads the individual source modules directly, so an
older bundled `tl.lua` cannot silently replace the implementation being timed.

Stages are `lex`, `read` (including macros), `ast` (prebuilt Blocks), `parse`,
`check`, and `gen`. Corpora include `compiler`, `applications`, `macros`,
`macro-definitions`, `macro-uncached`, and `macro-statements`. A file containing
one source path per line is also accepted. The 2,048 distinct declarations in
`macro-uncached` exceed the prototype cache capacity; `macro-definitions`
intentionally measures repeated compilation of a reusable 512-declaration file.

Use `1 1 0` for a first invocation in a fresh process, and repeat in separate
processes to calculate a cold median. Warm and cold results are different
workloads and should be reported separately.

The timer uses process CPU time. Module loading and explicit source reads are
outside the timer; garbage collection is enabled during it. Fresh-process
frontend timings therefore exclude process startup. Check/generation stages
include the imports required by those stages. The reported checksum catches
empty-work benchmarks, while the regression and differential tests verify
semantic equivalence.

## Compare frontend behavior

The differential harness runs each implementation in a separate LuaJIT process
on the baseline compiler sources and source snippets extracted from its tests:

```sh
python3 extras/compare-frontends.py ../tl-frontend-baseline . \
  --extra-spec spec/lang/parser/frontend_reader_spec.lua \
  --extra-spec spec/lang/macro/frontend_eval_spec.lua \
  --extra-spec spec/lang/macro/compact_quote_spec.lua
```

It compares lexer output; raw and expanded Blocks; parser ASTs and required
modules; diagnostics and positions; `read_program` output and its token edits;
graph sharing; sparse numeric keys; and the Lua length of each table. It also
checks that `ast.parse_blocks` does not mutate its input. Only process-global
type IDs and source line numbers inside thrown host errors are normalized.
Use `--output-dir PATH` to retain snapshots for investigating a mismatch.
