--#pragma strict_nil on

local backend = require("argparse")

--- Build a command line from a schema using Lua argparse.
local record Argparse
   type RawParser = backend.Parser
   type Values = {string: any}
   type Arity = integer | string
   type Converter = function(string): any, string?

   record Argument
      name: string
      description: string?
      target: string?
      metavar: string?
      args: Arity?
      choices: {string}?
      default: string?
      defmode: string?
      convert: Converter?
   end

   record Option
      name: string
      description: string?
      target: string?
      metavar: string?
      args: Arity?
      count: Arity?
      choices: {string}?
      default: string?
      defmode: string?
      convert: Converter?
   end

   record Flag
      name: string
      description: string?
      target: string?
      count: Arity?
      default: boolean?
   end

   record Schema
      name: string
      description: string?
      epilog: string?
      arguments: {Argument}?
      options: {Option}?
      flags: {Flag}?
      commands: {Schema}?
      command_target: string?
      require_command: boolean?

      --- Configure grouping, mutually exclusive options, or custom actions.
      configure: function(RawParser)?
   end

   record CommandLine
      _spec: Schema
   end
end

local type Schema = Argparse.Schema
local type RawParser = Argparse.RawParser
local type CommandLine = Argparse.CommandLine
local type Values = Argparse.Values

const MAX_SAFE_INTEGER = 9007199254740991

--- Convert an option or argument to a base-ten integer.
function Argparse.integer(text: string): integer?, string?
   if not text:match("^[+-]?%d+$") then return nil, "expected a whole number" end
   local value = tonumber(text)
   if value then
      if math.tointeger then
         local integer = math.tointeger(value)
         if integer then return integer end
      elseif math.abs(value) <= MAX_SAFE_INTEGER then
         return math.floor(value)
      end
   end
   return nil, "whole number is out of range"
end

local record ParseContext
   help: string?
end

local function configure(parser: RawParser, spec: Schema, context: ParseContext)
   local epilog = spec.epilog
   if epilog then parser:epilog(epilog) end

   parser:add_help(false)
   parser:flag("-h --help")
      :description("Show this help.")
      :action(function()
         context.help = parser:get_help()
         -- Stop before the backend checks required arguments;
         -- the caller will return this help text with status zero.
         error("help requested", 0)
      end)

   for _, spec_arg in ipairs(spec.arguments or {}) do
      local argument = parser:argument(spec_arg.name, spec_arg.description or "")
      local target, metavar, args = spec_arg.target, spec_arg.metavar, spec_arg.args
      local choices, default, defmode, convert = spec_arg.choices, spec_arg.default, spec_arg.defmode, spec_arg.convert
      if target then argument:target(target) end
      if metavar then argument:argname(metavar) end
      if args then argument:args(args) end
      if choices then argument:choices(choices) end
      if default then argument:default(default) end
      if defmode then argument:defmode(defmode) end
      if convert then argument:convert(convert) end
   end

   for _, spec_opt in ipairs(spec.options or {}) do
      local option = parser:option(spec_opt.name, spec_opt.description or "")
      local target, metavar, args, count = spec_opt.target, spec_opt.metavar, spec_opt.args, spec_opt.count
      local choices, default, defmode, convert = spec_opt.choices, spec_opt.default, spec_opt.defmode, spec_opt.convert
      if target then option:target(target) end
      if metavar then option:argname(metavar) end
      if args then option:args(args) end
      if count then option:count(count) end
      if choices then option:choices(choices) end
      if default then option:default(default) end
      if defmode then option:defmode(defmode) end
      if convert then option:convert(convert) end
   end

   for _, spec_flag in ipairs(spec.flags or {}) do
      local flag = parser:flag(spec_flag.name)
      local description, target, count, default = spec_flag.description, spec_flag.target, spec_flag.count, spec_flag.default
      if description then flag:description(description) end
      if target then flag:target(target) end
      if count then flag:count(count) end
      if default ~= nil then flag:default(default) end
   end

   local command_target, require_command = spec.command_target, spec.require_command
   if command_target then parser:command_target(command_target) end
   if require_command ~= nil then parser:require_command(require_command) end
   for _, subcommand in ipairs(spec.commands or {}) do
      -- The backend's Command class inherits the Parser configuration methods.
      local child = parser:command(subcommand.name, subcommand.description or "")
      configure(child as RawParser, subcommand, context)
   end
   local configure_extra = spec.configure
   if configure_extra then configure_extra(parser) end
end

local function build(spec: Schema, context: ParseContext): RawParser
   local parser = backend(spec.name, spec.description or "")
   configure(parser, spec, context)
   return parser
end

--- Parse argument strings without exiting the process.
--- @return Parsed values on success. Help returns text and status 0. Invalid arguments return a diagnostic and status 2.
function Argparse.CommandLine:parse(argv: {string}): Values?, string?, integer
   local context: ParseContext = {}
   local parser = build(self._spec, context)
   local ok, parsed, result = pcall(parser.pparse, parser, argv)
   if context.help then return nil, context.help, 0 end
   if not ok then error(parsed, 0) end
   if not parsed then return nil, result as string, 2 end
   return result as Values, nil, 0
end

--- Render the command's help text.
function Argparse.CommandLine:help(): string
   return build(self._spec, {}):get_help()
end

--- Render the command's usage line.
function Argparse.CommandLine:usage(): string
   return build(self._spec, {}):get_usage()
end

--- Keep the declaration for later parsing and help generation.
function Argparse.new(schema: Schema): CommandLine
   local command_line: CommandLine = { _spec = schema }
   return setmetatable(command_line, { __index = Argparse.CommandLine } as metatable<CommandLine>)
end

--- Generate typed parse, help, and usage functions for a record.
--- Fields on the record describe the parser values. Match field names to targets and types to conversions.
---
--- ```teal
--- local argparse = require("auxlib.argparse")
--- local macro parser! = argparse.parser!
--- local record Options<parser!({
---    name = "copy",
---    arguments = {{ name = "path" }},
---    options = {{
---       name = "-n --copies", target = "copies", default = "1", convert = argparse.integer,
---    }},
--- })>
---    path: string
---    copies: integer
--- end
--- local options, message, status = Options.parse(arg)
--- ```
macro Argparse.parser!(declaration: Statement, schema: Expression): Statement
   local B = BLOCK_INDEXES
   local record_block = declaration[1]
   assert(#declaration == 1 and record_block.kind == "local_type", "parser! expects one local record")
   local name = record_block[B.LOCAL_TYPE.VAR]
   local value = record_block[B.LOCAL_TYPE.VALUE]
   local definition = value and value[B.NEWTYPE.TYPEDECL]
   local layout = definition and definition[B.TYPEDECL.TYPE]
   assert(layout and layout.kind == "record", "parser! expects a non-generic record")
   local command_line = block("identifier")
   command_line.tk = "__auxlib_argparse_" .. name.tk
   local options_type = block("identifier")
   options_type.tk = "@auxlib_argparse_type_" .. name.tk
   return ```
      $declaration
      do
         local type $options_type = $name
         local $command_line = require("auxlib.argparse").new($schema)
         function $name.parse(argv: {string}): $options_type?, string?, integer
            local options, message, status = ($command_line):parse(argv)
            return options as $options_type?, message, status
         end
         function $name.help(): string
            return ($command_line):help()
         end
         function $name.usage(): string
            return ($command_line):usage()
         end
      end
   ```
end

return Argparse
