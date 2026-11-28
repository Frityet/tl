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

Teal supports optional diagnostic checks that you can enable in `tlconfig.lua`.
They run when you use `tl check` and in editors through the language server.

Diagnostics are grouped into four packs:

| Pack | What it checks |
| ---- | -------------- |
| `teal` | Risky casts, redundant or impossible type checks, and `typeof!` usage. |
| `lua` | Common Lua bugs such as truthiness pitfalls, bad loops, and legacy Lua 5.1 functions. |
| `luajit` | Loop and performance hints for LuaJIT. |
| `luajit-ffi` | Common mistakes and performance hints when using LuaJIT's FFI. |

Enable packs or individual rules in the `diagnostics` table of `tlconfig.lua`:

```lua
return {
   diagnostics = {
      teal = {
         ["cast-can-hide-nil"] = "error",
      },
      lua = {
         ["truthy-zero-or-empty"] = "warning",
      },
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

Each entry sets a rule's level:

* `true` - enable the rule with its default level.
* `false` or `"off"` - disable the rule.
* `"error"`, `"warning"`, `"info"`, or `"hint"` - enable the rule at that level.
* `all` - set a default for the whole pack (individual rules override it).

Diagnostics at the `"error"` level make `tl check` fail with a non-zero exit
code. Enabling any `luajit` or `luajit-ffi` rule automatically checks your code
for LuaJIT even if `gen_target` is `"5.1"`; you can also set `diagnostic_target`
explicitly.

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
