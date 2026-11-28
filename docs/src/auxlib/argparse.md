# Command-line arguments with `auxlib.argparse`

Decorate a record with `parser!` to generate `parse`, `help`, and `usage`
functions. The schema defines the command line. The record gives the parsed
values their Teal types. Match field names to option targets and field types
to the converters or defaults.

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

local options, message, status = Options.parse({"report.txt", "--copies", "3"})
assert(status == 0)
local parsed = assert(options, message)
print(parsed.path, parsed.copies) -- report.txt  3
```

Pass `arg` to parse a script's command line. The parser returns values and
status `0` on success. Help returns `nil`, help text, and `0`. Invalid input
returns `nil`, an error message, and `2`. The caller decides what to print and
which exit status to use.

## Schema

| Field | Use |
| --- | --- |
| `name`, `description`, `epilog` | Set the command name and help text. Only `name` is required. |
| `arguments` | Declare positional arguments. |
| `options` | Declare options that take values. Separate aliases with spaces in `name`. |
| `flags` | Declare switches with an optional boolean default. |
| `commands` | Declare subcommands using the same schema. |
| `command_target`, `require_command` | Name the field that receives the selected subcommand and control whether a subcommand is required. |
| `configure` | Customize the Lua argparse parser, for example to make options mutually exclusive. |

Arguments and options support `target`, `metavar`, `args`, `choices`,
`default`, `defmode`, and `convert`. Options and flags support `count` to
control how often they can appear. Defaults for arguments and options are
strings. `argparse.integer` converts a base-ten whole number and returns
`nil` with a message if conversion fails.

Use `argparse.new(schema)` to get a `CommandLine` with `:parse(argv)`,
`:help()`, and `:usage()`. Its parse result is a table keyed by target name.
The module uses the Lua `argparse` package at run time.
