local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs

local model = require("teal.diagnostics.model")
local types = require("teal.types")





local function call_is(s, n, name)
   local args = model.call_args(n)
   if args and s:path(n.e1) == name then
      return args
   end
end

local function condition(s, n)
   local e = model.unwrap(n.exp)
   if e and ((e.kind == "number" or e.kind == "integer") and model.number(e) == 0 or
      e.kind == "string" and e.conststr == "") then
      s:emit(e, "This value is truthy in Lua. Use an explicit comparison if you meant to test for zero or an empty string.")
   end
end

local rules = {
   {
      id = "lua/truthy-zero-or-empty",
      severity = "warning",
      description = "Flag zero or empty string used directly as a condition.",
      kinds = { "if_block", "while", "repeat" },
      check = function(s, n, _t, _children)
         condition(s, n)
      end,
   },
   {
      id = "lua/falsey-ternary",
      severity = "warning",
      description = "Flag an and-or selection whose middle value is always falsey.",
      kinds = { "op" }, operators = { "or" },
      check = function(s, n, _t, _children)
         if n.op.op ~= "or" then return end
         local left = model.unwrap(n.e1)
         if not left or left.kind ~= "op" or left.op.op ~= "and" then return end
         local middle = model.unwrap(left.e2)
         if middle and (middle.kind == "nil" or (middle.kind == "boolean" and middle.tk == "false")) then
            s:emit(left.e2, "The middle value is falsey, so this and-or expression always selects the fallback.")
         end
      end,
   },
   {
      id = "lua/zero-for-step",
      severity = "error",
      description = "Flag a numeric for loop with a literal zero step.",
      kinds = { "fornum" },
      check = function(s, n, _t, _children)
         if n.step and model.number(n.step) == 0 then
            s:emit(n.step, "A zero numeric-for step can error or prevent the loop from progressing")
         end
      end,
   },
   {
      id = "lua/empty-numeric-for",
      severity = "warning",
      description = "Flag numeric for loops with literal bounds and a step pointing away from the limit.",
      kinds = { "fornum" },
      check = function(s, n, _t, _children)
         local first, last = model.number(n.from), model.number(n.to)
         local step = n.step and model.number(n.step) or (not n.step and 1 or nil)
         if first and last and step and ((step > 0 and first > last) or (step < 0 and first < last)) then
            s:emit(n, "This numeric for loop never runs: its step points away from the limit")
         end
      end,
   },
   {
      id = "lua/zero-divisor",
      severity = "warning",
      description = "Flag division, floor division, or modulo by a literal zero.",
      kinds = { "op" }, operators = { "/", "//", "%" },
      check = function(s, n, _t, children)
         local left = children[1] and types.untuple(children[1])
         if is_numeric_type(left) and not n.op.meta_on_operand and model.number(n.e2) == 0 then
            s:emit(n.e2, "Division or modulo by zero can raise an error or produce a non-finite value depending on the operation and runtime")
         end
      end,
   },
   {
      id = "lua/nil-table-key",
      severity = "error",
      description = "Flag a table constructor with a literal nil key.",
      kinds = { "literal_table_item" },
      check = function(s, n, _t, _children)
         local key = model.unwrap(n.key)
         if n.key_parsed == "long" and key and key.kind == "nil" then
            s:emit(key, "A table key cannot be nil")
         end
      end,
   },
   {
      id = "lua/discarded-multiple-results",
      severity = "hint",
      description = "Find non-final expressions that return multiple values in an expression list.",
      kinds = { "expression_list" },
      check = function(s, n, _t, children)
         for i = 1, #n - 1 do
            local result = children[i]
            if result.typename == "tuple" and #result.tuple > 1 then
               s:emit(n[i], "Only the first result is used in this position. Use parentheses to make the truncation explicit.")
            end
         end
      end,
   },
   {
      id = "lua/constant-false-condition",
      severity = "warning",
      description = "Find if and while bodies guarded by literal false or nil.",
      kinds = { "if_block", "while" },
      check = function(s, n, _t, _children)
         local test = model.unwrap(n.exp)
         if test and (test.kind == "nil" or (test.kind == "boolean" and test.tk == "false")) then
            s:emit(n.exp, "This condition is always falsey, so its body is unreachable.")
         end
      end,
   },
   {
      id = "lua/random-empty-interval",
      severity = "error",
      description = "Flag math.random with literal bounds forming an empty interval.",
      kinds = { "op" }, calls = { "math.random" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "math.random")
         if not args then return end
         local a = model.number(args[1])
         local b = model.number(args[2])
         if a and a % 1 == 0 and ((#args == 1 and a < 0) or (#args == 2 and b and b % 1 == 0 and a > b)) then
            s:emit(n, "math.random receives an empty interval")
         end
      end,
   },
   {
      id = "lua/random-zero-portability",
      severity = "warning",
      description = "Flag math.random(0), whose behavior differs across Lua versions.",
      kinds = { "op" }, calls = { "math.random" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "math.random")
         if args and #args == 1 and model.number(args[1]) == 0 then
            s:emit(args[1], "math.random(0) has different behavior across Lua versions")
         end
      end,
   },
   {
      id = "lua/invalid-tonumber-base",
      severity = "warning",
      description = "Flag a literal tonumber base outside the supported range.",
      kinds = { "op" }, calls = { "tonumber" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "tonumber")
         local base = args and model.number(args[2])
         if base and (base < 2 or base > 36 or base % 1 ~= 0) then
            s:emit(args[2], "Use an integer base from 2 through 36. Fractional bases are handled differently across Lua versions.")
         end
      end,
   },
   {
      id = "lua/invalid-select-index",
      severity = "error",
      description = "Flag select with a literal zero index.",
      kinds = { "op" }, calls = { "select" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "select")
         if args and model.number(args[1]) == 0 then
            s:emit(args[1], "select accepts a nonzero index or '#'. Zero is invalid.")
         end
      end,
   },
   {
      id = "lua/invalid-string-char",
      severity = "warning",
      description = "Flag literal byte values outside the range accepted by string.char.",
      kinds = { "op" }, calls = { "string.char" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "string.char")
         if not args then return end
         for _, argument in ipairs(args) do
            local value = model.number(argument)
            if value and (value < 0 or value > 255 or value % 1 ~= 0) then
               s:emit(argument, "Use integer byte values from 0 through 255. Fractional values are handled differently across Lua versions.")
            end
         end
      end,
   },
   {
      id = "lua/negative-string-rep",
      severity = "hint",
      description = "Flag a negative literal repetition count in string.rep.",
      kinds = { "op" }, calls = { "string.rep" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "string.rep")
         local count = args and model.number(args[2])
         if count and count < 0 then
            s:emit(args[2], "A negative repetition count produces an empty string")
         end
      end,
   },
   {
      id = "lua/reversed-string-sub",
      severity = "hint",
      description = "Flag positive literal string.sub bounds in reverse order.",
      kinds = { "op" }, calls = { "string.sub" }, bindings = true,
      check = function(s, n, _t, _children)
         local args = call_is(s, n, "string.sub")
         local first = args and model.number(args[2])
         local last = args and model.number(args[3])
         if first and last and first > 0 and last > 0 and first % 1 == 0 and last % 1 == 0 and first > last then
            s:emit(args[2], "These string.sub bounds always produce an empty string")
         end
      end,
   },
   {
      id = "lua/invalid-type-name",
      severity = "warning",
      description = "Flag comparisons between type() and a string that Lua's type function cannot return.",
      kinds = { "op" }, operators = { "==", "~=" }, bindings = true,
      check = function(s, n, _t, _children)
         if n.op.op ~= "==" and n.op.op ~= "~=" then return end
         local call, literal = model.unwrap(n.e1), model.unwrap(n.e2)
         if call and literal and literal.kind ~= "string" then call, literal = literal, call end
         if not call or not literal or literal.kind ~= "string" or not call_is(s, call, "type") then return end
         local name = literal.conststr
         if name == "cdata" and s.target == "luajit" then return end
         if name ~= "nil" and name ~= "boolean" and name ~= "number" and name ~= "string" and
            name ~= "function" and name ~= "userdata" and name ~= "thread" and name ~= "table" then
            local message = "This runtime's type() never returns this name."
            if name == "integer" and s.target ~= "5.1" and s.target ~= "luajit" then
               message = message .. " Use math.type to distinguish integers from floats."
            end
            s:emit(literal, message)
         end
      end,
   },
   {
      id = "lua/legacy-environment-api",
      severity = "warning",
      description = "Find Lua 5.1 environment APIs on standard Lua 5.3 and later targets.",
      kinds = { "op" }, calls = { "getfenv", "setfenv" },
      check = function(s, n, _t, _children)
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Standard Lua 5.3 and later use lexical _ENV. For a loaded chunk, pass the environment to load.")
         end
      end,
   },
   {
      id = "lua/legacy-loadstring",
      severity = "warning",
      description = "Find loadstring calls on standard Lua 5.3 and later targets.",
      kinds = { "op" }, calls = { "loadstring" },
      check = function(s, n, _t, _children)
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Use load to compile a string on this Lua target.")
         end
      end,
   },
   {
      id = "lua/legacy-unpack",
      severity = "warning",
      description = "Find global unpack calls on standard Lua 5.3 and later targets.",
      kinds = { "op" }, calls = { "unpack" },
      check = function(s, n, _t, _children)
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Use table.unpack on this Lua target.")
         end
      end,
   },
}

return rules
