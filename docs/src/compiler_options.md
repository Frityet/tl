# Compiler options

`tl` supports some compiler options. These can either be specified on the command line or inside a `tlconfig.lua` file.

## Project configuration

When running `tl`, the compiler will try to read the compilation options from a file called `tlconfig.lua` inside the current working directory.

Here is an example of a `tlconfig.lua` file:
```lua
return {
    include_dir = {
        "folder1/",
        "folder2/"
    },
}
```

## List of compiler options

| Command line option  | Config key                 | Type       | Relevant Commands    | Description |
| -------------------- | -------------------------- | ---------- | -------------------- | ----------- |
| `-l --require`       |                            | `{string}` | `run`                | Require a module prior to executing the script. This is similar in behavior to the `-l` flag in the Lua interpreter. |
| `-I --include-dir`   | `include_dir`              | `{string}` | `check` `gen` `run`  | Prepend this directory to the module search path.
|                      | `source_dir`               | `string`   | `check` `gen` `run`  | Set the project source directory and add it to the module search path.
| `--gen-compat`       | `gen_compat`               | `string`   | `gen` `run`          | Generate compatibility code for targeting different Lua VM versions. See [below](#generated-code) for details.
| `--gen-target`       | `gen_target`               | `string`   | `gen` `run`          | Minimum targeted Lua version for generated code. Options are `5.1`, `5.3`, `5.4`, `5.5`, and `luajit`. See [below](#generated-code) for details.
| `--keep-hashbang`    |                            |            | `gen`                | Preserve hashbang line (`#!`) at the top of file if present.
| `-p --pretend`       |                            |            | `gen`                | Don't compile/write to any files, but type check and log what files would be written to.
| `--wdisable`         | `disable_warnings`         | `{string}` | `check` `run`        | Disable the given warnings.
| `--werror`           | `warning_error`            | `{string}` | `check` `run`        | Promote the given warnings to errors.
|                      | `diagnostics`              | map        | `check` `lsp` | Configure diagnostic rules by pack. |
|                      | `diagnostic_target`        | `string`   | `check` `lsp` | Set the analysis target independently of code generation. |
| `--global-env-def`   | `global_env_def`           | `string`   | `check` `gen` `run`  | Specify a definition module declaring any custom globals predefined in your Lua environment. See the [declaration files](declaration_files.md#global-environment-definition) page for details. |
| `--no-stdlib`        | `no_stdlib`                | `boolean`  | `check` `gen` `run`  | Don't include the standard library definitions in the type checker. This is useful when using a custom environment that differs from the PUC-Rio Lua standard library. |

When `source_dir` is set in `tlconfig.lua`, Teal also uses it when resolving
required modules. This lets a project keep its modules under a source directory
such as `src` without repeating that directory in `include_dir`; any explicit
`include_dir` entries are preserved.

### Diagnostics

Configure opt-in diagnostic packs in the `diagnostics` table in `tlconfig.lua`.
Run `tl check main.tl` to see findings. Editors use the same project settings
and show the rule ID and severity. Standard type errors and warnings use their
usual settings.

| Pack | Examples |
| ---- | -------- |
| `teal` | Casts that hide nil or erase type information, redundant type tests and nil fallbacks, optional receiver types |
| `lua` | Truthiness, discarded multiple results, numeric loop bounds, invalid library arguments, and removed Lua 5.1 APIs |
| `luajit` | Trace-sensitive work in loops, repeated allocations and compilation, string accumulation, and JIT controls |
| `luajit-ffi` | C declaration and type reuse, buffer lengths, pointer lifetimes, callback types, and C varargs |

The Lua pack checks `.lua` and `.tl` files. The Teal pack checks Teal source.
Enabling a LuaJIT or FFI rule in project config selects the LuaJIT analysis
target by default, even if `gen_target` is `"5.1"`. Use `diagnostic_target` to
set it explicitly. The optional rules analyze the checked AST in-process, so
editor diagnostics require no separate LuaJIT process or program execution.

```lua
-- tlconfig.lua
return {
   gen_target = "5.1",
   diagnostics = {
      teal = { ["cast-can-hide-nil"] = "error" },
      lua = { ["truthy-zero-or-empty"] = "warning" },
      luajit = {
         all = "hint",
         ["hot-print"] = "off",
      },
      ["luajit-ffi"] = {
         ["negative-length"] = "error",
      },
   },
}
```

Use the name after the slash in a diagnostic ID as the key in its pack
table. `all` sets a default for that pack. An explicit rule setting takes
precedence. `true` uses a rule's default severity. `false` and `"off"`
disable it. Other levels are `"error"`, `"warning"`, `"info"`, and `"hint"`.
An `"error"` finding makes `tl check` exit with status 1.

API callers can pass qualified IDs such as `diagnostics = { ["teal/cast-can-hide-nil"] = "error" }`
and an analysis target to `teal.compiler`.
`Input:check()` returns findings in `CheckError.diagnostics`, with `code`,
`severity`, `msg`, `filename`, `y`, `x`, and an exclusive `end_y` and `end_x`
when available. `teal.diagnostic_catalog(opts)` returns the catalog as data.
The optional suite skips declaration files and files with syntax errors.

Rule messages use ASD-STE100 style. A short sentence gives the cause or
effect. If the rule can suggest a change, a separate sentence gives one
action. Code terms such as `ctype` and `side exit` keep their LuaJIT meanings.
[ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)

#### LuaJIT traces and hot loops

* `luajit/loop-closure`, `luajit-ffi/vla-initializer-in-loop`, and
  `luajit-ffi/aggregate-by-value-call` point to recorder limitations in
  upstream LuaJIT 2.1. Hoist a closure that can take iteration state as
  arguments, separate C buffer allocation from initialization, or use a
  pointer-based C API for an aggregate. The aggregate rule checks simple
  prototypes in literal `ffi.cdef` declarations earlier in the same file.
  [Bytecode recorder](https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_record.c) · [FFI recorder](https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_crecord.c)
* `luajit/string-find-pattern` and `luajit/unrecorded-library-call` identify
  interpreter work. LuaJIT can stitch a trace across some calls. Use literal
  search with `string.find(..., 1, true)` when a pattern is unnecessary, or
  move invariant work outside the loop. [Fast-function recorder](https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_ffrecord.c)
* `luajit/unpack-bounds`, `luajit/loop-type-dispatch`, and
  `luajit-ffi/ctype-choice-in-loop` point to guards that can exit a trace as
  inputs change. Keep result counts, value types, and C types stable within a
  batch. For C functions, cache the library namespace and use its named
  member. `luajit-ffi/dynamic-symbol-call` flags lookups that can change the
  recorded symbol. [LuaJIT runtime options](https://luajit.org/running.html) · [FFI namespaces](https://luajit.org/ext_ffi_semantics.html#clib)
* `luajit-ffi/callback-call-in-loop` identifies calls that pass an explicitly
  cast Lua callback to C. If C invokes it synchronously, keep that call out
  of compiled Lua or use a batched or pull-style interface. A native function
  that merely saves a callback has different runtime behavior. [FFI callbacks](https://luajit.org/ext_ffi_semantics.html#callback)

These are source-based findings. Whether a path runs hot, how often a guard
fails, and whether LuaJIT compiles a side trace depend on the actual workload
and runtime build. [LuaJIT runtime options](https://luajit.org/running.html)

### Generated code

Teal is a Lua dialect that most closely resembles Lua 5.3–5.5, but it is able
to target Lua 5.1 (including LuaJIT) and Lua 5.2 as well. The compiler attempts
to produce code that, given an input `.tl` file, generates the same behavior
on various Lua versions.

However, there are limitations in the portability across Lua versions, and the
options `--gen-target` and `--gen-compat` give you some control over the generated
code.

#### Target version

The configuration option `gen_target` (`--gen-target` in the CLI) allow you to
choose what is the minimum Lua version you want to target. Valid options are
`5.1` (for Lua 5.1 and above, including LuaJIT) and `5.3` for Lua 5.3 and above.

Using `5.1`, Teal will generate compatibility code for the integer division operator,
a compatibility forward declaration for `table.unpack` and will use the `bit32`
library for bitwise operators.

Using `5.3`, Teal will generate code using the native `//` and bitwise operators.

The options `5.4` and `5.5` are equivalent to `5.3`, but also allow using the `<close>`
variable annotation. Since that is incompatible with other Lua versions, using
this option requires using `--gen-compat=off`.

Code generated with `--gen-target=5.1` will still run on Lua 5.3+, but not
optimally: the native Lua 5.3+ operators have better performance and better
precision. For example, if you are targeting Lua 5.1, the Teal code `x // y`
will generate `math.floor(x / y)` instead.

If you do not use these options, the Teal compiler will infer a default
target implicitly.

#### Which Lua version does the Teal compiler target by default?

If set explicitly via the `--gen-target` flag of the `tl` CLI (or the equivalent
options in the programmatic API), the generated code will target the Lua
version requested: 5.1, 5.3, 5.4, 5.5, or LuaJIT.

The compiler runs on LuaJIT. By default, `tl gen` generates Lua 5.3 code.
`tl run` and `tl.loader()` generate Lua 5.1-compatible code and execute it
with LuaJIT.

#### Compatibility wrappers

Another source of incompatibility across Lua versions is the standard library.
This is mostly fixable via compatibility wrappers, implemented by the
[compat53](https://github.com/keplerproject/lua-compat-5.3) Lua library.

Teal's own standard library definition as used by its type checker most
closely resembles that of Lua 5.3+, and the compiler's code generator can
generate code that uses compat53 in order to produce consistent behavior
across Lua versions, at the cost of adding a dependency when running on older
Lua versions. For Lua 5.3 and above, compat53 is never needed.

To avoid forcing a dependency on Teal users running Lua 5.1, 5.2 or LuaJIT,
especially those who take care to avoid incompatibilities in the Lua standard
library and hence wouldn't need compat53 in their code, Teal offers three
modes of operation for compatibility wrapper generation via the `gen_compat`
flag (and `--gen-compat` CLI option):

* `off` - Teal generates code without compatibility wrappers. The compiler type
  checks against the Lua 5.3 standard library. If the generated code calls a
  function that the target does not supply, it can cause a runtime error.
* `optional` (*default*) - Teal will generate compatibility code which
  initializes the the compat53 library wrapping `require` with a `pcall`,
  so that it doesn't produce a failure if the library is missing. This means
  that, if compat53 is installed, you'll get the compliant standard library
  behavior when running on Lua 5.2 and below, but if compat53 is missing,
  you'll get the same behavior as described for `off` above.
* `required` - Teal will generate compatibility code which initializes compat53
  with a plain `require`, meaning that you'll get a runtime error when loading
  the generated module from Lua if compat53 is missing. You can use this option
  if you are distributing the generated Lua code for users running different
  Lua versions and you want to ensure that your Teal code behaves the same
  way on all Lua versions, even if at the cost of an additional dependency.

### Global environment definition

To make the Teal compiler aware of global variables in your execution environment,
you may pass a declaration module to the compiler using the `--global-env-def` flag
in the CLI or the `global_env_def` string in `tlconfig.lua`.

For more information, see the [declaration files](declaration_files.md#global-environment-definition) page.

### LuaJIT 2.1 with the 3.0 syntax backport

Use `--gen-target=luajit` (or `gen_target = "luajit"` in `tlconfig.lua`)
for LuaJIT 2.1 builds with the LuaJIT 3.0 syntax extensions. Select this target
explicitly.

See [LuaJIT syntax extensions](luajit_extensions.md) for supported syntax,
type checking, and generated code.
