# Compiler performance

## Measurements

The baseline is commit `28ec7e4`. Both compilers used LuaJIT `2.1.1795119671`
on Linux x86-64 with an AMD EPYC 9V74. Each result is the median of five runs.
The tests used one logical CPU and read the same 51 files from the baseline
checkout. The files contain 974,691 bytes of compiler and CLI source.

| Workload | Rounds | Baseline | LuaJIT build | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Lexer API | 12 | 0.862 s | 0.665 s | 1.30× |
| Parse API | 2 | 2.310 s | 0.650 s | 3.55× |
| Check API | 2 | 8.195 s | 2.784 s | 2.94× |
| Generation API | 2 | 9.804 s | 3.495 s | 2.81× |
| `tl check` | 1 | 1.898 s | 1.483 s | 1.28× |
| `tl gen` | 1 | 2.183 s | 1.726 s | 1.27× |
| `tl check`, 750 small files | 1 | 1.083 s | 0.157 s | 6.89× |

The API times are CPU seconds and exclude compiler startup and input reads.
The CLI times are elapsed seconds and include process startup and file I/O.
The small files each define and call a function that adds a constant.

| CLI workload | Baseline peak RSS | LuaJIT build peak RSS |
| --- | ---: | ---: |
| `tl check`, 51 files | 450 MiB | 161 MiB |
| `tl gen`, 51 files | 450 MiB | 186 MiB |

## Profile

LuaJIT spent 49% of the baseline generation samples compiling traces. A trace
log recorded 81 cache flushes in two rounds. After the changes, trace compilation
took about 1% of generation samples.

The parser and type checker use the interpreter to reduce trace compilation.
The lexer and application code can use the trace compiler. The CLI uses the
normal garbage collector.

The reader skips macro and `continue` passes when the input does not use them.
The lexer scans identifier bytes and validates numeric tokens in a separate list.
The generator collects output fragments and joins them once. The CLI indexes
loaded paths as the compiler finds them.

## Reproduce the measurements

Run these commands from the optimized checkout. Install `argparse` and
`luafilesystem` for the CLI. Install `compat53` for both checkouts.

```bash
compiler="$PWD"
git worktree add --detach ../tl-base 28ec7e4
cd ../tl-base
sources=$(mktemp)
git ls-files 'teal/*.tl' 'tlcli/*.tl' | awk '!/\.d\.tl$/' > "$sources"
export TL_PATH='?.tl;?/init.tl;?.d.tl;extras/?.tl;extras/?/init.tl;extras/?.d.tl'

luajit "$compiler/extras/bench-compiler.lua" gen 2 "$sources" "$PWD"
luajit "$compiler/extras/bench-compiler.lua" gen 2 "$sources" "$compiler"
```

Use `lex`, `parse`, `check`, or `gen` to select a stage. Each stage includes
the earlier stages it needs. For CLI measurements, use the same source list
with each checkout's `tl` script. Set the generation target to `5.1`.

```bash
mapfile -t files < "$sources"
time luajit "$compiler/tl" check --quiet --gen-target=5.1 "${files[@]}"
time luajit "$compiler/tl" gen --quiet --gen-target=5.1 \
   --root . --output-dir "$(mktemp -d)" "${files[@]}"
```

Run LuaJIT with `-jp=vFm1i1` to measure where the compiler spends time.

```bash
luajit -jp=vFm1i1 "$compiler/extras/bench-compiler.lua" gen 4 "$sources" "$compiler"
```
