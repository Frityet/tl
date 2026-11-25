

local backend = require("argparse")


local Argparse = { Argument = {}, Option = {}, Flag = {}, Schema = {}, CommandLine = {} }































































local MAX_SAFE_INTEGER = 9007199254740991


function Argparse.integer(text)
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





local function configure(parser, spec, context)
   local epilog = spec.epilog
   if epilog then parser:epilog(epilog) end

   parser:add_help(false)
   parser:flag("-h --help"):
   description("Show this help."):
   action(function()
      context.help = parser:get_help()


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

      local child = parser:command(subcommand.name, subcommand.description or "")
      configure(child, subcommand, context)
   end
   local configure_extra = spec.configure
   if configure_extra then configure_extra(parser) end
end

local function build(spec, context)
   local parser = backend(spec.name, spec.description or "")
   configure(parser, spec, context)
   return parser
end



function Argparse.CommandLine:parse(argv)
   local context = {}
   local parser = build(self._spec, context)
   local ok, parsed, result = pcall(parser.pparse, parser, argv)
   if context.help then return nil, context.help, 0 end
   if not ok then error(parsed, 0) end
   if not parsed then return nil, result, 2 end
   return result, nil, 0
end


function Argparse.CommandLine:help()
   return build(self._spec, {}):get_help()
end


function Argparse.CommandLine:usage()
   return build(self._spec, {}):get_usage()
end


function Argparse.new(schema)
   local command_line = { _spec = schema }
   return setmetatable(command_line, { __index = Argparse.CommandLine })
end



















































return Argparse
