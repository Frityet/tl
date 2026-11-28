
Teal
====
[![Build Status](https://github.com/teal-language/tl/actions/workflows/ci.yml/badge.svg)](https://github.com/teal-language/tl/actions/workflows/ci.yml)
[![Join the chat at https://gitter.im/teal-language/community](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/teal-language/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

This is the repository of **tl**, the compiler for Teal, a typed dialect of Lua.

The compiler runs on LuaJIT 2.1 or later with FFI enabled. You can load the
standalone `tl.lua` file in a LuaJIT application. Call `tl.loader()` to load
and run `.tl` files with `require()`.

## Introduction

You can read the [tutorial chapter](https://teal-language.org/book/latest/tutorial.html)
of the Teal documentation to get started with an overview of the language.

## Installing

### Via LuaRocks

Install LuaJIT 2.1 or later. Configure LuaRocks for that installation. Run this
command from the repository root.

```
luarocks make tl-dev-2.rockspec
```

This should put a `tl` command in your `$PATH` (run `eval $(luarocks path)` if
the LuaRocks-installed binaries are not in your `$PATH`).

Use `--gen-target` to select the Lua version for the generated code. Use
`--gen-target=luajit` to use the LuaJIT 3.0 syntax extensions. See the
[syntax and lowering guide](docs/src/luajit_extensions.md).

### With Xmake

Put LuaJIT 2.1 or later on your path. Install the compiler's LuaRocks
dependencies for that LuaJIT installation with `luarocks make --only-deps`.

```sh
xmake build tl         # Build the compiler and its Lua API bundles
xmake run tl --version
xmake build tl.auxlib  # Build the auxlib Lua modules
```

To use the compiler in another Xmake project, include this repository and
apply the `tl` rule to the target with your Teal sources.

```lua
includes("vendor/tl")

target("app")
   set_kind("phony")
   add_rules("tl")
   add_deps("tl.auxlib")
   set_values("tl.root", "src")
   add_files("src/**.tl")
   on_run(function(target)
      os.execv("luajit", { path.join(target:data("tl.outputdir"), "main.lua") })
   end)
```

The rule reads your `tlconfig.lua` and generates Lua under the target's
Xmake-generated directory. It preserves paths relative to `tl.root`,
which defaults to the directory that defines the target. Use
`add_values("tl.includedirs", "types")` for additional Teal search directories.
With `add_deps("tl.auxlib")`, Teal can resolve imports such as
`require("auxlib.tables")` and macros from `auxlib.Object`. For `xmake run`,
the rule adds the compiled modules from the target and its dependencies to
`LUA_PATH`. The optional `auxlib.async.luv` and `auxlib.database.sqlite`
adapters require `luv` and `lsqlite3` respectively when loaded.

### Command-line arguments with `auxlib.argparse`

Decorate a record with `parser!` to generate `parse`, `help`, and `usage`
methods. The schema defines the command line, and the record fields give the
parsed values their Teal types. Match field names to option targets and field
types to the converters or defaults used in the schema.

```teal
local argparse = require("auxlib.argparse")
local record Options<argparse.parser!({
   name = "copy",
   arguments = {{ name = "path" }},
   options = {{ name = "-n --copies", default = "1", convert = argparse.integer }},
})>
   path: string
   copies: integer
end

local options, message, status = Options.parse(arg)
```

On success, `parse` returns the options and status `0`. Help returns no options,
help text, and status `0`. Invalid arguments return no options, an error message,
and status `2`. The schema also supports flags, repeated values, choices, and
nested subcommands. Use `argparse.new(schema)` to build a parser without a record,
or a schema's `configure` callback to use Lua argparse features such as mutually
exclusive options and custom actions. See [the CI job report](example/showcase.tl)
for a complete script.

### Test suites with `auxlib.testing`

Create a suite with `testing.suite(name)` and add tests with `suite:test` or
the `tests!` macro. The runner executes every selected case and reports
failures with source locations, expected and actual values, and any context
the tests attach. It returns a structured summary and supports Unicode,
plain text, and TAP output. See the [testing guide](docs/src/auxlib_testing.md)
for examples, hooks, and assertion helpers.

## Running

### Using the compiler directly

Once `tl` is in your path, there are a few subcommands:

* `tl run script.tl` will run a Teal script.
* `tl check module.tl` will type check a Teal module, report any errors and
  quit.
* `tl gen module.tl` will check for syntax errors and
  generate a `module.lua` file in plain Lua with all type annotations
  stripped.
* `tl warnings` will list all warnings the compiler can generate.
* `tl lsp [--stdio]` runs Teal's Language Server Protocol server over standard
  input and output. It provides compiler-backed push and pull diagnostics,
  macro-aware completion and hover, resolved definitions, references and rename,
  document/workspace symbols, semantic tokens, inlay hints, inline values,
  signature help, selection and folding ranges, linked editing, call and type
  hierarchy, document links and colors, code lenses/actions, TealDoc-enriched
  hover/completion/signature help, formatting and the
  `tl.check` / `tl.generate` editor commands. It reloads `tlconfig.lua` from the
  workspace root supplied by the editor and caches its workspace file manifest
  in `.cache/tl-lsp/workspace-index.paths`.

Put TealDoc comments next to declarations. Start with `---`. Continue with
`--` or `---`, or use a `--[[-- ... ]]--` block. Hover shows the original
Markdown and renders tags such as `@param` and `@return`. The server follows
macro aliases to their definitions. You can hover over each character of an
operator. The server reads open buffers before it reads files on disk.
[TealDoc comment syntax](https://github.com/teal-language/tealdoc#tealdoc-comments)

LSP features can be disabled per project in `tlconfig.lua`:

```lua
return {
   lsp = {
      inlay_hints = false,
      -- Coalesce edits for up to this many milliseconds per batch (default: 35).
      diagnostics_debounce_ms = 35,
      -- Enable workspace diagnostic requests (default: true).
      workspace_diagnostics = true,
      semantic_highlighting = false,
      workspace_index = false,
      cache = false,
   },
}
```

The available switches are `diagnostics`, `completion`, `hover`, `definitions`,
`references`, `rename`, `symbols`, `semantic_highlighting`, `inlay_hints`,
`inline_values`, `formatting`, `folding_ranges`, `selection_ranges`,
`document_links`, `linked_editing`, `document_colors`, `code_lens`,
`code_actions`, `call_hierarchy`, `type_hierarchy`, `monikers`,
`workspace_index`, and `cache`. All default to enabled.
Set `workspace_diagnostics = false` to disable advertising workspace diagnostic
requests. These requests cover documents currently known to the server.

`tl` also supports some [compiler options](https://teal-language.org/book/latest/compiler_options.html).
These can either be specified on the command line or inside a tlconfig.lua file at the root of your project.

### Building projects with Cyan

To build whole projects, you probably won't want to run `tl` on each
file individually. We recommend using [Cyan](https://github.com/teal-language/cyan),
the build tool designed for Teal.

## Loading Teal code from Lua

You can either pre-compile your `.tl` files into `.lua`, or you can add
the `tl.lua` module into your project and activate the Teal package loader:

```lua
local tl = require("tl")
tl.loader()
```

Once the package loader is activated, your `require()` calls can load and
compile `.tl` files on-the-fly.

## Documentation

You can read the [rendered documentation](https://teal-language.org/book/) online;
it can also be generated locally from the files in the [docs/](docs/) folder
of this repository.

See [compiler performance](docs/src/compiler_performance.md) for measurements
and steps to profile the compiler.
See [reader, parser, and macro performance](docs/src/frontend_performance.md)
for the frontend changes, compatibility checks, and stage benchmarks.

## Type definitions

`tl` supports [declaration files](https://teal-language.org/book/latest/declaration_files.html), which can be used to annotate the types
of third-party Lua libraries.

We have a collaborative repository for declaration files at
https://github.com/teal-language/teal-types — check it out and make your contribution!

## Text editor support

Teal language support is currently available for [Vim](https://github.com/teal-language/vim-teal), [Visual Studio Code](https://github.com/teal-language/vscode-teal), [lite](https://github.com/rxi/lite-plugins/blob/master/plugins/language_teal.lua) with [linter](https://github.com/drmargarido/linters/blob/master/linter_teal.lua) support and [Helix](https://docs.helix-editor.com/lang-support.html#:~:text=teal&text=teal-language-server) with LSP support.

## Community

* Join the chat on [Gitter](https://gitter.im/teal-language/community)!
  * You can also join via Matrix at [#teal-language_community:gitter.im](https://matrix.to/#/#teal-language_community:gitter.im)

Teal is a project started by [Hisham Muhammad](https://hisham.hm),
developed by a [growing number of contributors](https://github.com/teal-language/tl/graphs/contributors)
and is written using Teal itself!

## License

License is MIT, the same as Lua.
