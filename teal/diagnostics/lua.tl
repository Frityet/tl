--#pragma strict_nil off
-- Opt-in checks for concrete Lua runtime and portability pitfalls.
local model = require("teal.diagnostics.model")
local types = require("teal.types")
local type Rule = model.Rule
local type State = model.State
local type Node = model.Node
local type Type = model.Type
local type TypeName = types.TypeName

local non_numeric_self_eq: {TypeName: boolean} = {
   ["string"] = true, ["enum"] = true, ["boolean"] = true,
   ["nil"] = true, ["function"] = true, ["thread"] = true,
}

local pure_op: {string: boolean} = {
   ["not"] = true, ["#"] = true, ["-"] = true, ["~"] = true,
   ["+"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
   [".."] = true, ["&"] = true, ["|"] = true, ["<<"] = true, [">>"] = true,
   ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true,
   ["and"] = true, ["or"] = true, ["??"] = true, ["."] = true, ["@index"] = true,
}

local function pure_expr_equal(a: Node, b: Node, depth: integer): boolean
   if depth > 16 then return false end
   a, b = model.unwrap(a), model.unwrap(b)
   if not a or not b or a.kind ~= b.kind then return false end
   local kind = a.kind
   if kind == "variable" or kind == "identifier" or kind == "boolean" then
      return a.tk == b.tk
   elseif kind == "nil" then
      return true
   elseif kind == "number" or kind == "integer" then
      return a.constnum ~= nil and a.constnum == b.constnum
   elseif kind == "string" then
      return a.conststr ~= nil and a.conststr == b.conststr
   elseif kind == "op" and a.op and b.op and a.op.op == b.op.op and a.op.arity == b.op.arity and pure_op[a.op.op] then
      if a.op.arity == 1 then
         return pure_expr_equal(a.e1, b.e1, depth + 1)
      end
      return pure_expr_equal(a.e1, b.e1, depth + 1) and pure_expr_equal(a.e2, b.e2, depth + 1)
   end
   return false
end

local function is_nan_literal(n: Node): boolean
   n = model.unwrap(n)
   return n ~= nil and n.op ~= nil and n.op.op == "/" and model.number(n.e1) == 0 and model.number(n.e2) == 0
end

local function string_call_parts(s: State, n: Node): string, Node, Node, Node
   local p = s:path(n.e1)
   if p == "string.find" or p == "string.match" or p == "string.gmatch" or p == "string.gsub" then
      return p:sub(8), n.e2[2], n.e2[3], n.e2[4]
   end
   local callee = n.e1
   if callee.op and callee.op.op == ":" then
      local recv = model.unwrap(callee.e1)
      local is_str = (callee.receiver and (callee.receiver.typename == "string" or callee.receiver.typename == "enum"))
         or (recv and recv.kind == "string")
      if is_str then
         local m = callee.e2.tk
         if m == "find" or m == "match" or m == "gmatch" or m == "gsub" then
            return m, n.e2[1], n.e2[2], n.e2[3]
         end
      end
   end
end

local function scan_pattern_captures(pat: string): string, integer
   local len = #pat
   local i = 1
   local total = 0
   local open: {integer} = {}
   local closed: {integer: boolean} = {}
   local backref_err: string
   while i <= len do
      local b = pat:byte(i)
      if b == 37 then -- '%'
         if i + 1 > len then return nil, nil end
         local nb = pat:byte(i + 1)
         if nb == 98 then -- 'b'
            if i + 3 > len then return nil, nil end
            i = i + 4
         elseif nb == 102 then -- 'f'
            if pat:byte(i + 2) ~= 91 then return nil, nil end
            i = i + 2
         elseif nb == 48 then -- '0'
            backref_err = backref_err or "This Lua pattern refers to capture %0. Pattern backreferences start at %1."
            i = i + 2
         elseif nb >= 49 and nb <= 57 then -- '1'..'9'
            if not closed[nb - 48] then
               backref_err = backref_err or "This Lua pattern refers to an unavailable capture index. Reference only an earlier closed capture."
            end
            i = i + 2
         else
            i = i + 2
         end
      elseif b == 91 then -- '['
         i = i + 1
         if i <= len and pat:byte(i) == 94 then i = i + 1 end
         if i <= len and pat:byte(i) == 93 then i = i + 1 end
         local found_close = false
         while i <= len do
            local cb = pat:byte(i)
            if cb == 93 then
               found_close = true
               i = i + 1
               break
            elseif cb == 37 then
               if i + 1 > len then return nil, nil end
               i = i + 2
            else
               i = i + 1
            end
         end
         if not found_close then return nil, nil end
      elseif b == 40 then -- '('
         total = total + 1
         open[#open + 1] = total
         i = i + 1
      elseif b == 41 then -- ')'
         local nopen = #open
         if nopen == 0 then return nil, nil end
         closed[open[nopen]] = true
         open[nopen] = nil
         i = i + 1
      else
         i = i + 1
      end
   end
   if #open > 0 then return nil, nil end
   return backref_err, total
end

local function call_is(s: State, n: Node, name: string): Node
   local args = model.call_args(n)
   if args and s:path(n.e1) == name then
      return args
   end
end

local function condition(s: State, n: Node)
   local e = model.unwrap(n.exp)
   if e and ((e.kind == "number" or e.kind == "integer") and model.number(e) == 0 or
      e.kind == "string" and e.conststr == "") then
      s:emit(e, "This value is truthy in Lua. Use an explicit comparison to test for zero or an empty string.")
   end
end

local rules: {Rule} = {
   {
      id = "lua/truthy-zero-or-empty",
      severity = "warning",
      description = "Flag zero or empty string used directly as a condition.",
      kinds = {"if_block", "while", "repeat"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         condition(s, n)
      end,
   },
   {
      id = "lua/falsey-ternary",
      severity = "warning",
      description = "Flag an and-or selection whose middle value is always falsey.",
      kinds = {"op"}, operators = {"or"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if n.op.op ~= "or" then return end
         local left = model.unwrap(n.e1)
         if not left or left.kind ~= "op" or left.op.op ~= "and" then return end
         local middle = model.unwrap(left.e2)
         if middle and (middle.kind == "nil" or (middle.kind == "boolean" and middle.tk == "false")) then
            s:emit(left.e2, "The middle value is falsey. This and-or expression always selects the fallback.")
         end
      end,
   },
   {
      id = "lua/zero-for-step",
      severity = "error",
      description = "Flag a numeric for loop with a literal zero step.",
      kinds = {"fornum"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if n.step and model.number(n.step) == 0 then
            s:emit(n.step, "A zero step can cause an error. It can also stop the loop counter from changing. Use a nonzero step.")
         end
      end,
   },
   {
      id = "lua/empty-numeric-for",
      severity = "warning",
      description = "Flag numeric for loops with literal bounds and a step pointing away from the limit.",
      kinds = {"fornum"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local first, last = model.number(n.from), model.number(n.to)
         local step = n.step and model.number(n.step) or (not n.step and 1 or nil)
         if first and last and step and ((step > 0 and first > last) or (step < 0 and first < last)) then
            s:emit(n, "This numeric for loop never runs. Its step points away from the limit.")
         end
      end,
   },
   {
      id = "lua/zero-divisor",
      severity = "warning",
      description = "Flag division, floor division, or modulo by a literal zero.",
      kinds = {"op"}, operators = {"/", "//", "%"},
      check = function(s: State, n: Node, _t: Type, children: {Type})
         local left = children[1] and types.untuple(children[1])
         if left is types.NumericType and not n.op.meta_on_operand and model.number(n.e2) == 0 then
            s:emit(n.e2, "Division or modulo by zero can raise an error or produce a non-finite value. The result depends on the operation and runtime.")
         end
      end,
   },
   {
      id = "lua/nil-table-key",
      severity = "error",
      description = "Flag a table constructor with a literal nil key.",
      kinds = {"literal_table_item"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local key = model.unwrap(n.key)
         if n.key_parsed == "long" and key and key.kind == "nil" then
            s:emit(key, "A table key must have a value other than nil.")
         end
      end,
   },
   {
      id = "lua/discarded-multiple-results",
      severity = "hint",
      description = "Find non-final expressions that return multiple values in an expression list.",
      kinds = {"expression_list"},
      check = function(s: State, n: Node, _t: Type, children: {Type})
         for i = 1, #n - 1 do
            local result = children[i]
            if result is types.TupleType and #result.tuple > 1 then
               s:emit(n[i], "Lua uses only the first result here. Add parentheses to show that you want one result.")
            end
         end
      end,
   },
   {
      id = "lua/constant-false-condition",
      severity = "warning",
      description = "Find if and while bodies guarded by literal false or nil.",
      kinds = {"if_block", "while"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local test = model.unwrap(n.exp)
         if test and (test.kind == "nil" or (test.kind == "boolean" and test.tk == "false")) then
            s:emit(n.exp, "This condition is always falsey. Its body is unreachable.")
         end
      end,
   },
   {
      id = "lua/random-empty-interval",
      severity = "error",
      description = "Flag math.random with literal bounds forming an empty interval.",
      kinds = {"op"}, calls = {"math.random"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "math.random")
         if not args then return end
         local a = model.number(args[1])
         local b = model.number(args[2])
         if a and a % 1 == 0 and ((#args == 1 and a < 0) or (#args == 2 and b and b % 1 == 0 and a > b)) then
            s:emit(n, "The arguments give math.random an empty interval. Use a lower bound that is less than or equal to the upper bound.")
         end
      end,
   },
   {
      id = "lua/random-zero-portability",
      severity = "warning",
      description = "Flag math.random(0), whose behavior differs across Lua versions.",
      kinds = {"op"}, calls = {"math.random"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "math.random")
         if args and #args == 1 and model.number(args[1]) == 0 then
            s:emit(args[1], "Lua versions handle math.random(0) differently. Use explicit bounds for the range you need.")
         end
      end,
   },
   {
      id = "lua/invalid-tonumber-base",
      severity = "warning",
      description = "Flag a literal tonumber base outside the supported range.",
      kinds = {"op"}, calls = {"tonumber"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "tonumber")
         local base = args and model.number(args[2])
         if base and (base < 2 or base > 36 or base % 1 ~= 0) then
            s:emit(args[2], "Use an integer base from 2 through 36. Lua versions handle fractional bases differently.")
         end
      end,
   },
   {
      id = "lua/invalid-select-index",
      severity = "error",
      description = "Flag select with a literal zero index.",
      kinds = {"op"}, calls = {"select"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
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
      kinds = {"op"}, calls = {"string.char"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "string.char")
         if not args then return end
         for _, argument in ipairs(args) do
            local value = model.number(argument)
            if value and (value < 0 or value > 255 or value % 1 ~= 0) then
               s:emit(argument, "Use integer byte values from 0 through 255. Lua versions handle fractional values differently.")
            end
         end
      end,
   },
   {
      id = "lua/negative-string-rep",
      severity = "hint",
      description = "Flag a negative literal repetition count in string.rep.",
      kinds = {"op"}, calls = {"string.rep"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "string.rep")
         local count = args and model.number(args[2])
         if count and count < 0 then
            s:emit(args[2], "A negative repetition count produces an empty string.")
         end
      end,
   },
   {
      id = "lua/reversed-string-sub",
      severity = "hint",
      description = "Flag positive literal string.sub bounds in reverse order.",
      kinds = {"op"}, calls = {"string.sub"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = call_is(s, n, "string.sub")
         local first = args and model.number(args[2])
         local last = args and model.number(args[3])
         if first and last and first > 0 and last > 0 and first % 1 == 0 and last % 1 == 0 and first > last then
            s:emit(args[2], "These string.sub bounds always produce an empty string.")
         end
      end,
   },
   {
      id = "lua/invalid-type-name",
      severity = "warning",
      description = "Flag comparisons between type() and a string that Lua's type function cannot return.",
      kinds = {"op"}, operators = {"==", "~="}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
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
      kinds = {"op"}, calls = {"getfenv", "setfenv"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Standard Lua 5.3 and later use lexical _ENV. For a loaded chunk, pass the environment to load.")
         end
      end,
   },
   {
      id = "lua/legacy-loadstring",
      severity = "warning",
      description = "Find loadstring calls on standard Lua 5.3 and later targets.",
      kinds = {"op"}, calls = {"loadstring"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Use load to compile a string on this Lua target.")
         end
      end,
   },
   {
      id = "lua/legacy-unpack",
      severity = "warning",
      description = "Find global unpack calls on standard Lua 5.3 and later targets.",
      kinds = {"op"}, calls = {"unpack"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.is_lua and s.target ~= "5.1" and s.target ~= "luajit" then
            s:emit(n, "Use table.unpack on this Lua target.")
         end
      end,
   },
   {
      id = "lua/nan-equality",
      severity = "warning",
      description = "Flag equality comparisons against a literal NaN expression.",
      kinds = {"op"}, operators = {"==", "~="},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if is_nan_literal(n.e1) then
            s:emit(n.e1, "NaN is never equal to any value, including itself. Test for NaN with x ~= x instead.")
         elseif is_nan_literal(n.e2) then
            s:emit(n.e2, "NaN is never equal to any value, including itself. Test for NaN with x ~= x instead.")
         end
      end,
   },
   {
      id = "lua/self-comparison",
      severity = "warning",
      description = "Flag comparisons between identical variables.",
      kinds = {"op"}, operators = {"<", "<=", ">", ">=", "==", "~="},
      check = function(s: State, n: Node, _t: Type, children: {Type})
         if n.op.meta_on_operand then return end
         local left, right = model.unwrap(n.e1), model.unwrap(n.e2)
         if not left or not right or left.kind ~= "variable" or right.kind ~= "variable" or left.tk ~= right.tk then
            return
         end
         if n.op.op == "==" or n.op.op == "~=" then
            local left_t = children[1] and types.untuple(children[1])
            if not left_t or not non_numeric_self_eq[left_t.typename] then return end
         end
         s:emit(n, "Both sides of this comparison use the same variable. Compare two different values or remove the test.")
      end,
   },
   {
      id = "lua/duplicate-branch-condition",
      severity = "warning",
      description = "Find repeated conditions in the same if-elseif chain.",
      kinds = {"if"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local blocks = n.if_blocks
         if not blocks or #blocks < 2 then return end
         for i = 2, #blocks do
            local cond = blocks[i].exp
            if cond then
               for j = 1, i - 1 do
                  if blocks[j].exp and pure_expr_equal(blocks[j].exp, cond, 0) then
                     s:emit(cond, "This condition repeats an earlier branch in the same if statement. This branch is unreachable.")
                     break
                  end
               end
            end
         end
      end,
   },
   {
      id = "lua/for-control-var-modified",
      severity = "warning",
      description = "Flag assignments to a numeric for loop control variable.",
      kinds = {"fornum"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if n.fornum_modifies_control_var then
            s:emit(n.var, "Assigning to a numeric for variable does not change the loop counter. Use a while loop if you need to change the index.")
         end
      end,
   },
   {
      id = "lua/invalid-pattern-backreference",
      severity = "error",
      description = "Flag invalid capture backreferences in literal Lua string patterns.",
      kinds = {"op"}, operators = {"@funcall"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local method, pat_node, _, plain_node = string_call_parts(s, n)
         if not method then return end
         if method == "find" and plain_node then
            local plain = model.unwrap(plain_node)
            if not plain or (plain.kind ~= "nil" and not (plain.kind == "boolean" and plain.tk == "false")) then
               return
            end
         end
         local pat = model.unwrap(pat_node)
         if pat and pat.kind == "string" and pat.conststr then
            local problem = scan_pattern_captures(pat.conststr)
            if problem then s:emit(pat, problem) end
         end
      end,
   },
   {
      id = "lua/invalid-gsub-replacement",
      severity = "warning",
      description = "Flag invalid % escapes or capture references in literal string.gsub replacements.",
      kinds = {"op"}, operators = {"@funcall"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local method, pat_node, repl_node = string_call_parts(s, n)
         if method ~= "gsub" then return end
         local repl = model.unwrap(repl_node)
         if not repl or repl.kind ~= "string" or not repl.conststr then return end
         local pat_captures: integer
         local pat = model.unwrap(pat_node)
         if pat and pat.kind == "string" and pat.conststr then
            local _, caps = scan_pattern_captures(pat.conststr)
            pat_captures = caps
         end
         local text = repl.conststr
         local len, i = #text, 1
         while i <= len do
            if text:byte(i) == 37 then
               local nb = text:byte(i + 1)
               if not nb or (nb ~= 37 and (nb < 48 or nb > 57)) then
                  s:emit(repl, "Only %% and %0 through %9 are valid in string.gsub replacements. Lua 5.3 and later raise an error for other % sequences.")
                  return
               end
               if nb >= 49 and nb <= 57 and pat_captures ~= nil then
                  local idx = nb - 48
                  local max_cap = pat_captures > 0 and pat_captures or 1
                  if idx > max_cap then
                     s:emit(repl, "This replacement string refers to a capture that the pattern does not define. Use %0 or a valid capture index.")
                     return
                  end
               end
               i = i + 2
            else
               i = i + 1
            end
         end
      end,
   },
}

return rules
