--#pragma strict_nil off
local type ast = require("teal.ast")
local type errors = require("teal.errors")
local type targets = require("teal.gen.targets")
local type types = require("teal.types")

local record model
   type Node = ast.Node
   type Type = types.Type
   type Severity = errors.Severity

   enum Level
      "off"
      "error"
      "warning"
      "info"
      "hint"
   end

   enum Pack
      "teal"
      "lua"
      "luajit"
      "luajit-ffi"
   end

   type Options = {string: boolean | Level}
   type Check = function(State, Node, Type, {Type})

   record Rule
      id: string
      severity: Severity
      description: string
      kinds: {ast.NodeKind}
      operators: {string}
      calls: {string}
      c_symbols: boolean
      bindings: boolean
      in_loop: boolean
      ffi_origins: boolean
      check: Check
   end

   record RuleInfo
      id: string
      pack: Pack
      description: string
      default_severity: Severity
      level: Level
      available: boolean
   end

   record EnabledRule
      id: string
      severity: Severity
      check: Check
      teal_only: boolean
      in_loop: boolean
   end

   record Plan
      by_kind: {ast.NodeKind: {EnabledRule}}
      by_operator: {string: {EnabledRule}}
      by_call: {string: {EnabledRule}}
      by_hot_call: {string: {EnabledRule}}
      c_symbols: {EnabledRule}
      hot_c_symbols: {EnabledRule}
      bindings: boolean
      ffi_origins: boolean
      teal_only: boolean
      track_loops: boolean
   end

   record State
      target: targets.GenTarget
      is_lua: boolean
      strict_nil: boolean
      loop_depth: integer
      function_depth: integer

      emit: function(self, Node, string)
      path: function(self, Node): string
      called_path: string
      ffi_aggregate_prototypes: {string: string}
      last_c_source: string
      last_c_text: string

      current_rule: EnabledRule
      results: {errors.Error}
      paths: {Node: string}
      modified_paths: {string: boolean}
      filename: string
      ffi_origins: boolean
   end
end

local type Node = model.Node

function model.unwrap(n: Node): Node
   while n and (n.kind == "paren" or (n.op and n.op.op == "as")) do
      n = n.e1
   end
   return n
end

function model.number(n: Node): number
   n = model.unwrap(n)
   if not n then return nil end
   if n.kind == "number" or n.kind == "integer" then
      return n.constnum
   end
   if n.op and n.op.op == "-" and n.op.arity == 1 then
      local value = model.number(n.e1)
      return value and -value
   end
end

function model.call_args(n: Node): Node
   n = model.unwrap(n)
   if n and n.op and n.op.op == "@funcall" then
      return n.e2
   end
end

local function end_of_c_quote(source: string, start: integer, quote: integer): integer
   local offset = start + 1
   while offset <= #source do
      local byte = source:byte(offset)
      if byte == quote then return offset end
      offset = offset + (byte == 92 and 2 or 1)
   end
   return #source
end

-- Keep line breaks for directive checks. Scan unmatched comments once so a
-- large unfinished C declaration stays cheap while a user edits it.
function model.c_declaration(state: model.State, node: Node): string
   node = model.unwrap(node)
   if not node or node.kind ~= "string" then return nil end
   local source = node.conststr
   if not source then return nil end
   if source == state.last_c_source then return state.last_c_text end
   local chunks: {string}
   local copy_from, cursor = 1, 1
   while true do
      local start = source:find("[/'\"]", cursor)
      if not start then break end
      local byte = source:byte(start)
      local finish: integer
      if byte == 47 then
         local next_byte = source:byte(start + 1)
         if next_byte == 42 then
            local close = source:find("*/", start + 2, true)
            finish = close and close + 1 or #source
         elseif next_byte == 47 then
            local newline = source:find("\n", start + 2, true)
            finish = newline and newline - 1 or #source
         end
      else
         finish = end_of_c_quote(source, start, byte)
      end
      cursor = (finish or start) + 1
      if finish then
         chunks = chunks or {}
         chunks[#chunks + 1] = source:sub(copy_from, start - 1)
         local newlines = source:sub(start, finish):gsub("[^\n]+", "")
         chunks[#chunks + 1] = " " .. newlines
         copy_from = cursor
      end
   end
   local text = source
   if chunks then
      chunks[#chunks + 1] = source:sub(copy_from)
      text = table.concat(chunks)
   end
   state.last_c_source, state.last_c_text = source, text
   return text
end

function model.ffi_namespace(path: string): boolean
   return path == "ffi.C" or path == "ffi.load()"
end

function model.ffi_temporary_symbol(path: string): boolean
   return path ~= nil and path:sub(1, 16) == "ffi.temporary()."
end

function model.ffi_symbol(path: string): boolean
   if not path then return false end
   local prefix: string
   if path:sub(1, 6) == "ffi.C." then
      prefix = "ffi.C."
   elseif path:sub(1, 11) == "ffi.load()." then
      prefix = "ffi.load()."
   elseif model.ffi_temporary_symbol(path) then
      prefix = "ffi.temporary()."
   end
   return prefix ~= nil and #path > #prefix and not path:find(".", #prefix + 1, true)
end

return model
