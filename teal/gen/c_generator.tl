--#pragma strict_nil off
local type Node = require("teal.parser").Node
local ffi = require("teal.gen.c_ffi")
local type CType = ffi.CType
local type Symbol = ffi.Symbol
local c_types = require("teal.gen.c_types")
local c_runtime = require("teal.gen.c_runtime")
local traversal = require("teal.traversal")
local sorted_keys = require("teal.util").sorted_keys
local type Repr = c_types.Repr
local type Field = c_types.Field
local types = require("teal.types")
local type Type = types.Type

local record generator
   record CUnit
      source: string
      filename: string
      code: string
   end

   record COutput
      entry: string
      directory: string
      header: string
      modules: {CUnit}
   end
end

local record Binding
   name: string
   value: Repr
   direct_function: boolean
   builtin: string
   virtual: boolean
end

local record Value
   code: string
   repr: Repr
end

local record Module
   init: string
   value: Repr
end

local record State
   ffi: ffi.State
   registry: c_types.Registry
   modules: {Node:Module}
   scopes: {{string:Binding}}
   globals: {string}
   functions: {string}
   out: {string}
   indent: integer
   next_id: integer
   helpers: {string:boolean}
   return_type: Repr -- nil while emitting main
   module_cache: string
end

local integer = c_types.integer

local failure_tag = {}
local function fail(node: Node, message: string)
   local position = ("%s:%d:%d"):format(node.f or "<input>", node.y or 1, node.x or 1)
   error({ failure_tag, position .. ": C target: " .. message }, 0)
end

local function repr(s: State, node: Node, t?: Type): Repr
   t = t or node.native_type
   local r = c_types.representation(s.registry, t)
   if not r then fail(node, "unsupported value type " .. (t and types.show_type(t) or node.kind)) end
   return r
end

local function zero(r: Repr): string
   if r.payload then return "(" .. r.ctype .. "){0}" end
   return "NULL"
end

local function wrapped(lines: {string}, value: string): string
   if #lines == 0 then return value end
   return "__extension__ ({ " .. table.concat(lines, " ") .. " " .. value .. "; })"
end

local function emit(s: State, line: string)
   table.insert(s.out, ("   "):rep(s.indent) .. line)
end

local function fresh(s: State): string
   s.next_id = s.next_id + 1
   return "tl_native_" .. tostring(s.next_id)
end

local function coerce(s: State, node: Node, value: string, from: Repr, to: Repr): string
   if from.key == to.key then return value end
   if from.kind == "nil" and to.nullable then
      return "((void)(" .. value .. "), " .. zero(to) .. ")"
   end
   if to.payload then
      if from.payload then
         local tmp = fresh(s)
         local payload = coerce(s, node, tmp .. ".value", from.payload, to.payload)
         return wrapped({ from.ctype .. " " .. tmp .. " = " .. value .. ";" },
            "(" .. to.ctype .. "){ " .. tmp .. ".present, " .. payload .. " }")
      end
      return "(" .. to.ctype .. "){1, " .. coerce(s, node, value, from, to.payload) .. "}"
   end
   if from.payload then
      return coerce(s, node, "(" .. value .. ").value", from.payload, to)
   end
   if from.kind == "integer" and to.kind == "number" then return "(double)(" .. value .. ")" end
   fail(node, "incompatible native representations for " .. from.key .. " and " .. to.key)
end

local function stage(s: State, lines: {string}, code: string, r: Repr): Value
   local tmp = fresh(s)
   table.insert(lines, r.ctype .. " " .. tmp .. " __attribute__((unused)) = " .. code .. ";")
   return { code = tmp, repr = r }
end

local function lookup(s: State, name: string): Binding
   for i = #s.scopes, 1, -1 do
      local binding = s.scopes[i][name]
      if binding then return binding end
   end
end

local function c_string(node: Node): string
   local value, err = ffi.decode_string(node.tk)
   if not value then fail(node, err) end
   if value:find("\0", 1, true) then
      fail(node, "strings containing NUL bytes are unsupported")
   end
   local parts: {string} = { '"' }
   for i = 1, #value do
      local byte = value:byte(i)
      if byte >= 32 and byte <= 126 and byte ~= 34 and byte ~= 92 and byte ~= 63 then
         table.insert(parts, string.char(byte))
      else
         table.insert(parts, ("\\%03o"):format(byte))
      end
   end
   table.insert(parts, '"')
   return table.concat(parts)
end

local helpers: {string:string} = {
   int = [[
#define tl_native_int(type, value) __extension__ ({ \
   type tl_native_converted; \
   if (__builtin_add_overflow((value), 0, &tl_native_converted)) __builtin_trap(); \
   tl_native_converted; \
})
]],
   idiv = [[
static int64_t tl_native_idiv(int64_t a, int64_t b) {
   if (b == 0) __builtin_trap();
   if (b == -1) return (int64_t)(0 - (uint64_t)a);
   int64_t quotient = a / b;
   if (a % b != 0 && (a < 0) != (b < 0)) --quotient;
   return quotient;
}
]],
   imod = [[
static int64_t tl_native_imod(int64_t a, int64_t b) {
   if (b == 0) __builtin_trap();
   if (b == -1) return 0;
   int64_t remainder = a % b;
   if (remainder != 0 && (remainder < 0) != (b < 0)) remainder += b;
   return remainder;
}
]],
   fmod = [[
static double tl_native_fmod(double a, double b) {
   double remainder = __builtin_fmod(a, b);
   if ((remainder > 0 && b < 0) || (remainder < 0 && b > 0)) remainder += b;
   return remainder;
}
]],
   shift = [[
static int64_t tl_native_shift(uint64_t value, int64_t amount, _Bool left) {
   uint64_t count = (uint64_t)amount;
   if (amount < 0) {
      count = 0 - count;
      left = !left;
   }
   if (count >= 64) return 0;
   return (int64_t)(left ? value << count : value >> count);
}
]],
   compare = [[
/* 2 denotes an unordered comparison with NaN. */
static int tl_native_compare(int64_t a, double b) {
   if (__builtin_isnan(b)) return 2;
   if (b >= 0x1p63) return -1;
   if (b < -0x1p63) return 1;
   int64_t integral = (int64_t)b;
   if (a != integral) return a < integral ? -1 : 1;
   return ((double)integral > b) - ((double)integral < b);
}
]],
}

local function int_conversion(s: State, ctype: string, value: string): string
   s.helpers.int = true
   return "tl_native_int(" .. ctype .. ", " .. value .. ")"
end

local function ffi_result(s: State, typ: CType, value: string): string
   if typ.kind == "void" then return "((void)(" .. value .. "), (void *)0)" end
   if typ.kind == "integer" then return int_conversion(s, integer.ctype, value) end
   if typ.kind == "number" then return "(double)(" .. value .. ")" end
   if typ.mutable_char then return "(const char *)(" .. value .. ")" end
   return value
end

local function is_ffi_reference(s: State, node: Node): boolean
   if not node.native_type then return false end
   local t = types.untuple(node.native_type)
   if t.typeid ~= s.ffi.ffi.typeid and t.typeid ~= s.ffi.namespace.typeid then return false end
   if node.kind == "variable" then
      local b = lookup(s, node.tk)
      return (b and b.virtual) or (not b and node.tk == "C" and t.typeid == s.ffi.namespace.typeid)
   elseif node.kind == "paren" then
      return is_ffi_reference(s, node.e1)
   elseif node.kind == "op" then
      if node.op.op == "." then return is_ffi_reference(s, node.e1) end
      return t.typeid == s.ffi.ffi.typeid and node.native_builtin == "ffi"
   end
   return false
end

local function foreign_symbol(s: State, node: Node): Symbol
   if node.kind == "op" and node.op.op == "." and node.e1.native_type
      and types.untuple(node.e1.native_type).typeid == s.ffi.namespace.typeid and is_ffi_reference(s, node.e1) then
      return s.ffi.symbols[node.e2.tk]
   end
end

local expression: function(State, Node): string
local emit_function: function(State, Node, string, Repr)

local function returns_no_values(node: Node): boolean
   local t = node.native_type
   return t is types.TupleType and #t.tuple == 0 and not t.is_va
end

local function intrinsic(s: State, node: Node): string
   if node.native_builtin and node.native_builtin ~= "ffi" then return node.native_builtin end
   if node.kind == "variable" then
      local binding = lookup(s, node.tk)
      return binding and binding.builtin
   elseif node.kind == "paren" then
      return intrinsic(s, node.e1)
   elseif node.kind == "op" then
      if node.op.op == "." then
         local namespace = intrinsic(s, node.e1)
         if namespace and c_runtime.namespaces[namespace] then return namespace .. "." .. node.e2.tk end
      elseif node.op.op == ":" then
         local r = c_types.representation(s.registry, node.e1.native_type)
         if r and r.kind == "string" and not r.nullable then return "string." .. node.e2.tk end
      end
   end
end

local function vararg(s: State, node: Node, value: string, r: Repr): string, Repr
   if r.payload then fail(node, "nullable scalars cannot be passed to a C variadic function") end
   if r.kind == "integer" or r.kind == "boolean" then
      local cint: Repr = { kind = "integer", ctype = "int", key = "C int" }
      local code = r.kind == "integer" and int_conversion(s, "int", value) or "(int)(" .. value .. ")"
      return code, cint
   end
   return value, r
end

local library_call: function(State, Node, string, Node): string

local function call(s: State, node: Node): string
   if node.native_module then return s.modules[node.native_module].init .. "()" end
   local callee = node.e1
   while callee.kind == "paren" do callee = callee.e1 end
   local builtin = intrinsic(s, callee)
   if builtin then return library_call(s, node, builtin, callee) end

   local foreign = foreign_symbol(s, callee)
   local binding = callee.kind == "variable" and lookup(s, callee.tk)
   local sig: Repr
   local name: string
   local temps: {string} = {}
   if foreign and foreign.params then
      name = foreign.name
   else
      sig = repr(s, callee)
      if sig.kind ~= "function" then fail(node, "callee is not a supported native function") end
      if binding and binding.direct_function then
         name = binding.name
      else
         name = stage(s, temps, expression(s, callee), sig).code
         s.helpers.panic = true
         table.insert(temps, 'if (!' .. name .. ') tl_native_panic("attempt to call a missing function");')
      end
   end

   local params: {string} = {}
   for i, argument in ipairs(node.e2) do
      local value = expression(s, argument)
      if i == #node.e2 and returns_no_values(argument) then
         table.insert(temps, "(void)(" .. value .. ");")
         break
      end
      local fixed = foreign and foreign.params[i]
      local r = repr(s, argument)
      if fixed and fixed.kind == "integer" then
         value = int_conversion(s, fixed.spelling:gsub("^const ", ""), value)
         r = { kind = "integer", ctype = fixed.spelling, key = fixed.spelling }
      elseif foreign and not fixed then
         value, r = vararg(s, argument, value, r)
      elseif sig and sig.params[i] then
         local expected = sig.params[i]
         value = coerce(s, argument, value, r, expected)
         r = expected
      end

      -- Keep literal format strings visible to Clang.
      if argument.kind ~= "string" and argument.kind ~= "integer" and argument.kind ~= "number"
         and argument.kind ~= "boolean" and argument.kind ~= "nil" then
         value = stage(s, temps, value, r).code
      end
      table.insert(params, value)
   end

   if sig then
      for i = #params + 1, #sig.params do
         if not sig.params[i].nullable then fail(node, "missing argument " .. tostring(i)) end
         params[i] = zero(sig.params[i])
      end
   end
   local value = name .. "(" .. table.concat(params, ", ") .. ")"
   if foreign then
      value = ffi_result(s, foreign.result, value)
   elseif sig.result.kind == "void" then
      value = "((void)(" .. value .. "), (void *)0)"
   else
      value = coerce(s, node, value, sig.result, repr(s, node))
   end
   return wrapped(temps, value)
end

local function truth(s: State, r: Repr, value: string): string
   if r.payload then
      if r.kind ~= "boolean" then return "(" .. value .. ").present" end
      local tmp = fresh(s)
      return wrapped({ r.ctype .. " " .. tmp .. " = " .. value .. ";" }, tmp .. ".present && " .. tmp .. ".value")
   end
   if r.kind == "boolean" then return value end
   if r.kind == "nil" then return "((void)(" .. value .. "), 0)" end
   if r.nullable then return value .. " != NULL" end
   return "((void)(" .. value .. "), 1)"
end

local function condition(s: State, node: Node): string
   if node.kind == "paren" then return condition(s, node.e1) end
   if node.kind == "op" and (node.op.op == "and" or node.op.op == "or") then
      local op = node.op.op == "and" and " && " or " || "
      return "(" .. condition(s, node.e1) .. ")" .. op .. "(" .. condition(s, node.e2) .. ")"
   end
   return truth(s, repr(s, node), expression(s, node))
end

local function numeric(r: Repr): boolean
   return not r.nullable and (r.kind == "integer" or r.kind == "number")
end

local function scalar_string(s: State, node: Node, value: Value): string
   local r, v = value.repr, value.code
   if r.payload then
      local present = scalar_string(s, node, { repr = r.payload, code = v .. ".value" })
      return "(" .. v .. '.present ? ' .. present .. ' : "nil")'
   elseif r.kind == "string" then
      return r.nullable and "(" .. v .. " ? " .. v .. ' : "nil")' or v
   elseif r.kind == "boolean" then
      return "(" .. v .. ' ? "true" : "false")'
   elseif r.kind == "nil" then
      return '"nil"'
   elseif numeric(r) then
      s.helpers.strings = true
      return "tl_native_" .. r.kind .. "_string(" .. v .. ")"
   end
   fail(node, "tostring supports scalar values")
end

local function print_value(s: State, node: Node, value: Value): string
   local r, v = value.repr, value.code
   if r.payload then
      local printed = print_value(s, node, { repr = r.payload, code = v .. ".value" })
      return "if (" .. v .. '.present) { ' .. printed .. ' } else fputs("nil", stdout);'
   elseif r.kind == "integer" then
      return 'printf("%lld", (long long)' .. v .. ");"
   elseif r.kind == "number" then
      s.helpers.print_number = true
      return "tl_native_print_number(" .. v .. ");"
   end
   return "fputs(" .. scalar_string(s, node, value) .. ", stdout);"
end

local type_names: {c_types.Kind:string} = {
   integer = "number", number = "number", boolean = "boolean", string = "string",
   array = "table", record = "table", ["function"] = "function", pointer = "userdata", ["nil"] = "nil",
}
local function type_string(value: Value): string
   local r, v = value.repr, value.code
   local name = string.format("%q", type_names[r.kind])
   if r.payload then return "(" .. v .. '.present ? ' .. name .. ' : "nil")' end
   if r.nullable and r.kind ~= "nil" then return "(" .. v .. " ? " .. name .. ' : "nil")' end
   return name
end

local function optional_argument(value: Value, default: string): string
   if not value or value.repr.kind == "nil" then return default end
   if value.repr.payload then
      local v = value.code
      return "(" .. v .. ".present ? " .. v .. ".value : " .. default .. ")"
   end
   return value.code
end

local math_constants: {string:string} = {
   ["math.pi"] = "0x1.921fb54442d18p1",
   ["math.huge"] = "__builtin_huge_val()",
   ["math.maxinteger"] = "INT64_MAX",
   ["math.mininteger"] = "INT64_MIN",
}

local math_unary: {string:string} = {
   acos = "__builtin_acos", asin = "__builtin_asin", cos = "__builtin_cos",
   cosh = "__builtin_cosh", exp = "__builtin_exp", log10 = "__builtin_log10",
   sin = "__builtin_sin", sinh = "__builtin_sinh", sqrt = "__builtin_sqrt",
   tan = "__builtin_tan", tanh = "__builtin_tanh",
}

local function math_call(s: State, node: Node, op: string, args: {Value}, lines: {string}): string
   local first = args[1]
   if not first or not numeric(first.repr) then fail(node, "math." .. op .. " expects numbers") end
   local a = first.code
   if math_unary[op] then return math_unary[op] .. "(" .. a .. ")" end
   if op == "abs" then
      if first.repr.kind == "integer" then
         return "(" .. a .. " < 0 ? (int64_t)(0 - (uint64_t)" .. a .. ") : " .. a .. ")"
      end
      return "__builtin_fabs(" .. a .. ")"
   elseif op == "floor" or op == "ceil" then
      if first.repr.kind == "integer" then return a end
      s.helpers.math_integer = true
      return "tl_native_math_integer(__builtin_" .. op .. "(" .. a .. "))"
   elseif op == "min" or op == "max" then
      local r = repr(s, node)
      if not numeric(r) then fail(node, "math." .. op .. " expects numeric arguments on the C target") end
      local best = stage(s, lines, coerce(s, node, a, first.repr, r), r).code
      for i = 2, #args do
         local candidate = args[i]
         if not numeric(candidate.repr) then fail(node, "math." .. op .. " expects numbers") end
         local value = coerce(s, node, candidate.code, candidate.repr, r)
         table.insert(lines, "if (" .. value .. (op == "min" and " < " or " > ") .. best ..
            ") " .. best .. " = " .. value .. ";")
      end
      return best
   elseif op == "deg" then
      return "((double)" .. a .. " * (180.0 / " .. math_constants["math.pi"] .. "))"
   elseif op == "rad" then
      return "((double)" .. a .. " * (" .. math_constants["math.pi"] .. " / 180.0))"
   elseif op == "pow" or op == "atan2" or op == "fmod" then
      local second = args[2]
      if not second or not numeric(second.repr) then fail(node, "math." .. op .. " expects two numbers") end
      local b = second.code
      if op == "fmod" and repr(s, node).kind == "integer" then
         s.helpers.panic = true
         table.insert(lines, 'if (' .. b .. ' == 0) tl_native_panic("math.fmod divisor is zero");')
         return "(" .. b .. " == -1 ? INT64_C(0) : " .. a .. " % " .. b .. ")"
      end
      return "__builtin_" .. op .. "(" .. a .. ", " .. b .. ")"
   elseif op == "log" or op == "atan" then
      local default = "__builtin_" .. op .. "(" .. a .. ")"
      local second = args[2]
      if not second or second.repr.kind == "nil" then return default end
      local b = optional_argument(second, "0")
      local provided = op == "log" and "(" .. default .. " / __builtin_log(" .. b .. "))"
         or "__builtin_atan2(" .. a .. ", " .. b .. ")"
      return second.repr.payload and "(" .. second.code .. ".present ? " .. provided .. " : " .. default .. ")" or provided
   end
   fail(node, "unsupported standard library function math." .. op)
end

local string_transforms: {string:string} = { lower = "0", upper = "1", reverse = "2" }

local function string_call(s: State, node: Node, op: string, args: {Value}): string
   local first = args[1]
   if not first or first.repr.kind ~= "string" or first.repr.nullable then
      fail(node, "string." .. op .. " expects a non-nil string")
   end
   local text = first.code
   if op == "len" then return "(int64_t)__builtin_strlen(" .. text .. ")" end
   if op == "sub" then
      s.helpers.strings = true
      return "tl_native_sub(" .. text .. ", " .. args[2].code .. ", " .. optional_argument(args[3], "INT64_MAX") .. ")"
   elseif op == "rep" then
      s.helpers.strings = true
      return "tl_native_rep(" .. text .. ", " .. args[2].code .. ", " .. optional_argument(args[3], "NULL") .. ")"
   elseif string_transforms[op] then
      s.helpers.strings = true
      return "tl_native_string_transform(" .. text .. ", " .. string_transforms[op] .. ")"
   end
   fail(node, "unsupported standard library function string." .. op)
end

local function table_call(s: State, node: Node, op: string, args: {Value}, lines: {string}): string
   local first = args[1]
   if not first or first.repr.kind ~= "array" or first.repr.nullable then
      fail(node, "table." .. op .. " expects a dense array")
   end
   s.helpers.array = true
   local a, element = first.code, first.repr.element
   local length = "(int64_t)" .. a .. "->length"
   if op == "insert" then
      local value = args[#args]
      local index = #args == 3 and args[2].code or "tl_native_array_append_index(" .. a .. ")"
      local stored = stage(s, lines, coerce(s, node, value.code, value.repr, element), element)
      table.insert(lines, "tl_native_array_insert(" .. a .. ", " .. index .. ", &" .. stored.code .. ");")
      return "(void *)0"
   elseif op == "remove" then
      local r = c_types.optional(s.registry, element)
      local result = stage(s, lines, zero(r), r).code
      local index = optional_argument(args[2], length)
      local out = r.payload and result .. ".value" or result
      local remove = "tl_native_array_remove(" .. a .. ", " .. index .. ", &" .. out .. ")"
      table.insert(lines, r.payload and result .. ".present = " .. remove .. ";" or "(void)" .. remove .. ";")
      return coerce(s, node, result, r, repr(s, node))
   elseif op == "concat" then
      if element.kind ~= "string" then fail(node, "table.concat supports arrays of strings") end
      s.helpers.table_concat = true
      return "tl_native_table_concat(" .. a .. ", " .. optional_argument(args[2], "NULL") .. ", " ..
         optional_argument(args[3], "1") .. ", " .. optional_argument(args[4], length) .. ")"
   end
   fail(node, "unsupported standard library function table." .. op)
end

library_call = function(s: State, node: Node, name: string, callee: Node): string
   local lines: {string} = {}
   local args: {Value} = {}
   if callee.op and callee.op.op == ":" then
      local receiver = callee.e1
      table.insert(args, stage(s, lines, expression(s, receiver), repr(s, receiver)))
   end
   for i, argument in ipairs(node.e2) do
      local code = expression(s, argument)
      if i == #node.e2 and returns_no_values(argument) then
         table.insert(lines, "(void)(" .. code .. ");")
      else
         table.insert(args, stage(s, lines, code, repr(s, argument)))
      end
   end

   local result: string
   if name == "print" then
      s.helpers.print = true
      for i, value in ipairs(args) do
         if i > 1 then table.insert(lines, [[fputc('\t', stdout);]]) end
         table.insert(lines, print_value(s, node, value))
      end
      table.insert(lines, [[fputc('\n', stdout);]])
      result = "(void *)0"
   elseif name == "tostring" then
      result = scalar_string(s, node, args[1])
   elseif name == "type" then
      result = type_string(args[1])
   elseif name == "tonumber" then
      if #args ~= 1 then fail(node, "tonumber supports a single argument on the C target") end
      local value, r = args[1], repr(s, node)
      if value.repr.kind == "integer" or value.repr.kind == "number" then
         result = coerce(s, node, value.code, value.repr, r)
      elseif value.repr.kind == "string" then
         s.helpers.parse_number = true
         local out = stage(s, lines, zero(r), r).code
         table.insert(lines, out .. ".present = tl_native_parse_number(" .. value.code .. ", &" .. out .. ".value);")
         result = out
      else
         result = zero(r)
      end
   elseif name == "assert" or name == "error" then
      s.helpers.panic = true
      local msg = args[name == "assert" and 2 or 1]
      local fallback = name == "assert" and '"assertion failed!"' or '"error"'
      local text = fallback
      if msg and msg.repr.kind ~= "nil" then
         text = scalar_string(s, node, msg)
         if msg.repr.nullable then
            local present = msg.repr.payload and msg.code .. ".present" or msg.code .. " != NULL"
            text = "(" .. present .. " ? " .. text .. " : " .. fallback .. ")"
         end
      end
      if name == "assert" then
         local first = args[1]
         table.insert(lines, "if (!(" .. truth(s, first.repr, first.code) .. ")) tl_native_panic(" .. text .. ");")
         result = coerce(s, node, first.code, first.repr, repr(s, node))
      else
         table.insert(lines, "tl_native_panic(" .. text .. ");")
         result = "(void *)0"
      end
   else
      local lib, op = name:match("^([^.]+)%.(.+)$")
      if lib == "math" then result = math_call(s, node, op, args, lines)
      elseif lib == "string" then result = string_call(s, node, op, args)
      elseif lib == "table" then result = table_call(s, node, op, args, lines)
      else fail(node, "unsupported standard library function " .. name) end
   end
   return wrapped(lines, result)
end

local function record_field(s: State, node: Node, receiver: Node, key: string): Field
   local r = repr(s, receiver)
   local field = r.fields and r.fields[key]
   if not field or r.nullable then fail(node, "unsupported native record field '" .. tostring(key) .. "'") end
   return field
end

local function array_slot(s: State, node: Node, receiver: Value, index: Value, write: boolean): string
   local r = receiver.repr
   if r.kind ~= "array" or r.nullable or index.repr.key ~= integer.key then
      fail(node, "native indexing expects an array and an integer index")
   end
   s.helpers.array = true
   return "*(" .. r.element.ctype .. " *)tl_native_array_slot(" .. receiver.code .. ", " ..
      index.code .. ", " .. (write and "1" or "0") .. ")"
end

local comparison_ops: {string:string} = {
   ["=="] = "==", ["~="] = "!=", ["<"] = "<", [">"] = ">", ["<="] = "<=", [">="] = ">=",
}
local reversed_comparison: {string:string} = { ["<"] = ">", [">"] = "<", ["<="] = ">=", [">="] = "<=" }
local function compare(s: State, node: Node, op: string, a: Repr, b: Repr, left: string, right: string): string
   local equality = op == "==" or op == "!="
   if a.payload or b.payload then
      if not equality then fail(node, "ordered comparison requires non-nil operands") end
      local left_present = a.payload and left .. ".present" or (a.kind == "nil" and "0" or "1")
      local right_present = b.payload and right .. ".present" or (b.kind == "nil" and "0" or "1")
      local same = "(" .. left_present .. " == " .. right_present
      if a.kind ~= "nil" and b.kind ~= "nil" then
         local av = a.payload and left .. ".value" or left
         local bv = b.payload and right .. ".value" or right
         same = same .. " && (!(" .. left_present .. ") || (" ..
            compare(s, node, "==", a.payload or a, b.payload or b, av, bv) .. "))"
      end
      return (op == "!=" and "!" or "") .. same .. ")"
   end
   if a.kind == "string" and b.kind == "string" then
      local compare_strings = "__builtin_strcmp(" .. left .. ", " .. right .. ")"
      if equality then
         local same = "(" .. left .. " == " .. right .. " || (" .. left .. " && " .. right .. " && " .. compare_strings .. " == 0))"
         return op == "!=" and "!" .. same or same
      end
      return compare_strings .. " " .. op .. " 0"
   elseif numeric(a) and numeric(b) and a.kind ~= b.kind then
      s.helpers.compare = true
      if a.kind == "number" then
         left, right = right, left
         op = reversed_comparison[op] or op
      end
      local tmp = fresh(s)
      local test = tmp .. " " .. op .. " 0"
      if not equality then test = tmp .. " != 2 && " .. test end
      return "__extension__ ({ int " .. tmp .. " = tl_native_compare(" .. left .. ", " .. right .. "); " .. test .. "; })"
   elseif numeric(a) and numeric(b) or (a.kind == "boolean" and b.kind == "boolean") then
      return left .. " " .. op .. " " .. right
   elseif equality then
      local ap = a.kind == "pointer" or a.kind == "nil" or a.kind == "string" or a.kind == "array" or a.kind == "record"
      local bp = b.kind == "pointer" or b.kind == "nil" or b.kind == "string" or b.kind == "array" or b.kind == "record"
      if ap and bp then return "(const void *)" .. left .. " " .. op .. " (const void *)" .. right end
      if a.kind == "function" and b.kind == "nil" then return left .. " " .. op .. " NULL" end
      if b.kind == "function" and a.kind == "nil" then return right .. " " .. op .. " NULL" end
      if a.kind == "function" and a.key == b.key then return left .. " " .. op .. " " .. right end
      return op == "==" and "0" or "1"
   end
   fail(node, "unsupported comparison '" .. node.op.op .. "'")
end

local arithmetic: {string:boolean} = { ["+"] = true, ["-"] = true, ["*"] = true }
local bitwise: {string:boolean} = { ["&"] = true, ["|"] = true, ["~"] = true }
local function binary(s: State, node: Node, op: string): string
   local a, b = repr(s, node.e1), repr(s, node.e2)
   local left, right = fresh(s), fresh(s)
   local operands = a.ctype .. " " .. left .. " __attribute__((unused)) = " .. expression(s, node.e1) .. "; " ..
                    b.ctype .. " " .. right .. " __attribute__((unused)) = " .. expression(s, node.e2) .. "; "
   local result: string
   if op == ".." and (numeric(a) or (a.kind == "string" and not a.nullable))
      and (numeric(b) or (b.kind == "string" and not b.nullable)) then
      s.helpers.strings = true
      result = "tl_native_concat(" .. scalar_string(s, node, { repr = a, code = left }) .. ", " ..
         scalar_string(s, node, { repr = b, code = right }) .. ")"
   elseif comparison_ops[op] then
      result = compare(s, node, comparison_ops[op], a, b, left, right)
   elseif arithmetic[op] and numeric(a) and numeric(b) then
      if a.kind == "integer" and b.kind == "integer" then
         result = "(int64_t)((uint64_t)" .. left .. " " .. op .. " (uint64_t)" .. right .. ")"
      else
         result = left .. " " .. op .. " " .. right
      end
   elseif (op == "/" or op == "//" or op == "%" or op == "^") and numeric(a) and numeric(b) then
      local ints = a.kind == "integer" and b.kind == "integer"
      if (op == "//" and ints) or op == "%" then
         local name = op == "//" and "idiv" or (ints and "imod" or "fmod")
         s.helpers[name] = true
         result = "tl_native_" .. name .. "(" .. left .. ", " .. right .. ")"
      elseif op == "^" then
         result = "__builtin_pow(" .. left .. ", " .. right .. ")"
      else
         result = "(double)" .. left .. " / (double)" .. right
         if op == "//" then result = "__builtin_floor(" .. result .. ")" end
      end
   elseif (bitwise[op] or op == "<<" or op == ">>") and a.kind == "integer" and b.kind == "integer" then
      if bitwise[op] then
         result = "(int64_t)((uint64_t)" .. left .. " " .. (op == "~" and "^" or op) .. " (uint64_t)" .. right .. ")"
      else
         s.helpers.shift = true
         result = "tl_native_shift((uint64_t)" .. left .. ", " .. right .. ", " .. (op == "<<" and "1" or "0") .. ")"
      end
   else
      fail(node, "unsupported binary operator '" .. op .. "'")
   end
   return "__extension__ ({ " .. operands .. result .. "; })"
end

local function operator(s: State, node: Node): string
   local op = node.op.op
   if op == "@funcall" then return call(s, node) end
   if op == "." then
      local foreign = foreign_symbol(s, node)
      if foreign and not foreign.params and not foreign.typedef then
         return ffi_result(s, foreign.result, foreign.name)
      end
      local builtin = intrinsic(s, node)
      if builtin then
         if math_constants[builtin] then return math_constants[builtin] end
         fail(node, "unsupported standard library value " .. builtin)
      end
      local field = record_field(s, node, node.e1, node.e2.tk)
      local code = "(" .. expression(s, node.e1) .. ")->" .. field.name
      return coerce(s, node, code, field.value, repr(s, node))
   end
   if op == "@index" then
      local r = repr(s, node.e1)
      if r.kind == "record" and node.e2.kind == "string" then
         local field = record_field(s, node, node.e1, node.e2.conststr)
         local code = "(" .. expression(s, node.e1) .. ")->" .. field.name
         return coerce(s, node, code, field.value, repr(s, node))
      end
      local lines: {string} = {}
      local receiver = stage(s, lines, expression(s, node.e1), r)
      local index = stage(s, lines, expression(s, node.e2), repr(s, node.e2))
      local code = array_slot(s, node, receiver, index, false)
      return wrapped(lines, coerce(s, node, code, r.element, repr(s, node)))
   end
   if op == "as" then
      return coerce(s, node, expression(s, node.e1), repr(s, node.e1), repr(s, node))
   end

   if op == "not" then return "!(" .. condition(s, node.e1) .. ")" end
   local a = repr(s, node.e1)
   if op == "is" then
      local tested = c_types.resolve(node.e2.casttype)
      if not tested or tested is types.UnionType or tested is types.EnumType then
         fail(node, "union and enum type tests are unsupported")
      end
      local b = repr(s, node.e2, tested)
      local value = expression(s, node.e1)
      local base = a.payload or a
      local is_type = base.key == b.key or (base.kind == "integer" and b.kind == "number")
      if a.payload and (b.kind == "nil" or is_type) then
         return (b.kind == "nil" and "!" or "") .. "(" .. value .. ").present"
      elseif a.nullable and a.kind ~= "nil" and (b.kind == "nil" or is_type) then
         return value .. (b.kind == "nil" and " == " or " != ") .. "NULL"
      end
      return "((void)(" .. value .. "), " .. (is_type and "1" or "0") .. ")"
   elseif op == "and" or op == "or" then
      local value = expression(s, node.e1)
      local r = repr(s, node)
      local first = c_types.resolve(types.untuple(node.e1.native_type))
      local known_truth: boolean
      if first is types.BooleanType then
         known_truth = first.literal
      elseif a.kind == "nil" then
         known_truth = false
      elseif not a.nullable then
         known_truth = true
      end
      if known_truth ~= nil then
         if (op == "or") == known_truth then return coerce(s, node, value, a, r) end
         return "((void)(" .. value .. "), " .. coerce(s, node, expression(s, node.e2), repr(s, node.e2), r) .. ")"
      end
      if op == "and" and a.nullable and not r.nullable then
         fail(node, "a value-producing 'and' with a nullable left operand needs a nullable result")
      end
      local tmp = fresh(s)
      local right = coerce(s, node, expression(s, node.e2), repr(s, node.e2), r)
      local left = coerce(s, node, tmp, a, r)
      return "__extension__ ({ " .. a.ctype .. " " .. tmp .. " = " .. value .. "; "
         .. truth(s, a, tmp) .. " ? " .. (op == "and" and right or left) .. " : " .. (op == "and" and left or right) .. "; })"
   elseif node.op.arity == 1 then
      local value = expression(s, node.e1)
      if op == "#" and not a.nullable then
         if a.kind == "string" then return "(int64_t)__builtin_strlen(" .. value .. ")" end
         if a.kind == "array" then return "(int64_t)(" .. value .. ")->length" end
      end
      if op == "-" and a.kind == "integer" and not a.nullable then return "(int64_t)(0 - (uint64_t)(" .. value .. "))" end
      if op == "-" and a.kind == "number" and not a.nullable then return "-(" .. value .. ")" end
      if op == "~" and a.kind == "integer" and not a.nullable then return "(int64_t)(~(uint64_t)(" .. value .. "))" end
      fail(node, "unsupported unary operator '" .. op .. "'")
   end
   return binary(s, node, op)
end

local function table_literal(s: State, node: Node): string
   local r = repr(s, node)
   local lines: {string} = {}
   local result: string
   if r.kind == "array" then
      s.helpers.array = true
      local element = r.element
      result = stage(s, lines, "tl_native_array_new(sizeof(" .. element.ctype .. "), " .. tostring(#node) .. ")", r).code
      for i, item in ipairs(node) do
         if item.key.constnum ~= i then fail(item, "native array literals must have consecutive one-based indices") end
         local value = coerce(s, item.value, expression(s, item.value), repr(s, item.value), element)
         table.insert(lines, "((" .. element.ctype .. " *)" .. result .. "->data)[" .. tostring(i - 1) .. "] = " .. value .. ";")
      end
   elseif r.kind == "record" then
      s.helpers.alloc = true
      local name = fresh(s)
      table.insert(lines, r.ctype .. " " .. name .. " = tl_native_alloc(sizeof(*" .. name .. "));")
      result = name
      for _, item in ipairs(node) do
         local key = item.key.conststr
         local field = key and r.fields[key]
         if not field then fail(item, "native record literals require named fields") end
         local value = coerce(s, item.value, expression(s, item.value), repr(s, item.value), field.value)
         table.insert(lines, result .. "->" .. field.name .. " = " .. value .. ";")
      end
   else
      fail(node, "unsupported native table literal")
   end
   return wrapped(lines, result)
end

expression = function(s: State, node: Node): string
   if node.kind == "string" then
      return c_string(node)
   elseif node.kind == "integer" then
      local lexeme = node.tk
      if lexeme:match("^%d+$") then
         lexeme = lexeme:gsub("^0+", "")
         if lexeme == "" then lexeme = "0" end
         if #lexeme > 20 or (#lexeme == 20 and lexeme > "18446744073709551615") then
            fail(node, "integer literal exceeds 64 bits")
         end
      elseif lexeme:match("^0[xX]") then
         local digits = lexeme:sub(3):gsub("^0+", "")
         if #digits > 16 then fail(node, "integer literal exceeds 64 bits") end
         lexeme = "0x" .. (#digits > 0 and digits or "0")
      end
      return "((int64_t)" .. lexeme .. "ULL)"
   elseif node.kind == "number" then
      local lexeme = node.tk
      if lexeme:match("^0[xX]") and not lexeme:match("[pP]") then lexeme = lexeme .. "p0" end
      return "((double)" .. lexeme .. ")"
   elseif node.kind == "boolean" then
      return node.tk == "true" and "((_Bool)1)" or "((_Bool)0)"
   elseif node.kind == "nil" then
      return "NULL"
   elseif node.kind == "variable" or node.kind == "type_identifier" then
      local b = lookup(s, node.tk)
      if b and b.value then return coerce(s, node, b.name, b.value, repr(s, node)) end
      fail(node, "unsupported value '" .. node.tk .. "'")
   elseif node.kind == "literal_table" then
      return table_literal(s, node)
   elseif node.kind == "function" then
      if #s.scopes ~= 1 then fail(node, "anonymous functions must be declared at the top level") end
      local name = fresh(s)
      emit_function(s, node, name, repr(s, node))
      return name
   elseif node.kind == "paren" then
      return "(" .. expression(s, node.e1) .. ")"
   elseif node.kind == "op" then
      return operator(s, node)
   end
   fail(node, "unsupported expression '" .. node.kind .. "'")
end

local statement: function(State, Node, ? boolean)

local function statements(s: State, body: Node)
   for _, node in ipairs(body) do statement(s, node) end
end

local function block(s: State, header: string, body: Node)
   emit(s, header .. "{")
   s.indent = s.indent + 1
   table.insert(s.scopes, {})
   statements(s, body)
   table.remove(s.scopes)
   s.indent = s.indent - 1
   emit(s, "}")
end

local function rhs(s: State, exps: Node, count: integer): {Value}
   local values: {Value} = {}
   local lines: {string} = {}
   for i, e in ipairs(exps or {}) do
      local value = expression(s, e)
      if i <= count then
         values[i] = stage(s, lines, value, repr(s, e))
      else
         table.insert(lines, "(void)(" .. value .. ");")
      end
   end
   for _, line in ipairs(lines) do emit(s, line) end
   return values
end

local function store_local(s: State, var: Node, r: Repr, value: string, top_level: boolean)
   local name = fresh(s)
   local declaration = r.ctype .. " " .. name .. " __attribute__((unused))"
   if top_level then
      table.insert(s.globals, "static " .. declaration .. ";")
      emit(s, name .. " = " .. value .. ";")
   else
      emit(s, declaration .. " = " .. value .. ";")
   end
   s.scopes[#s.scopes][var.tk] = { name = name, value = r }
end

local function local_declaration(s: State, node: Node, top_level: boolean)
   if #node.vars == 1 and node.exps and #node.exps == 1 then
      local source = node.exps[1]
      local builtin = intrinsic(s, source)
      if builtin and not math_constants[builtin] then
         s.scopes[#s.scopes][node.vars[1].tk] = { builtin = builtin }
         return
      elseif is_ffi_reference(s, source) then
         s.scopes[#s.scopes][node.vars[1].tk] = { virtual = true }
         return
      end
   end
   local values = rhs(s, node.exps, #node.vars)
   for i, var in ipairs(node.vars) do
      local r = repr(s, var)
      local value = values[i]
      local stored = value and coerce(s, var, value.code, value.repr, r) or zero(r)
      store_local(s, var, r, stored, top_level)
   end
end

local function local_record(s: State, node: Node, top_level: boolean)
   if node.var.elide_type or node.value.kind ~= "newtype" or node.value.newtype.is_alias then return end
   local t = c_types.resolve(node.var.native_type)
   if not (t is types.RecordType) then return end
   local r = repr(s, node.var)
   if r.kind ~= "record" then return end
   for name, field in pairs(r.fields) do
      if not field.value.nullable and field.value.kind ~= "function" then
         fail(node, "initialize record field '" .. name .. "' with a record literal")
      end
   end
   s.helpers.alloc = true
   local tag = r.ctype:sub(1, -3)
   store_local(s, node.var, r, "tl_native_alloc(sizeof(" .. tag .. "))", top_level)
end

local function assignment_target(s: State, var: Node, lines: {string}): Value
   if var.kind == "variable" then
      local binding = lookup(s, var.tk)
      if not binding or not binding.value or binding.direct_function then
         fail(var, "assignment expects a mutable local, record field, or array element")
      end
      return { code = binding.name, repr = binding.value }
   elseif var.kind == "op" and (var.op.op == "." or var.op.op == "@index") then
      local r = repr(s, var.e1)
      local receiver = stage(s, lines, expression(s, var.e1), r)
      if r.kind == "record" then
         local key = var.op.op == "." and var.e2.tk or var.e2.conststr
         local field = record_field(s, var, var.e1, key)
         return { code = receiver.code .. "->" .. field.name, repr = field.value }
      elseif var.op.op == "@index" then
         local index = stage(s, lines, expression(s, var.e2), repr(s, var.e2))
         return { code = array_slot(s, var, receiver, index, true), repr = r.element }
      end
   end
   fail(var, "assignment expects a mutable local, record field, or array element")
end

local function assignment(s: State, node: Node)
   local lines: {string} = {}
   local destinations: {Value} = {}
   for i, var in ipairs(node.vars) do destinations[i] = assignment_target(s, var, lines) end
   for _, line in ipairs(lines) do emit(s, line) end

   local values = rhs(s, node.exps, #destinations)
   for i = #destinations, 1, -1 do
      local target, value = destinations[i], values[i]
      local stored = value and coerce(s, node.vars[i], value.code, value.repr, target.repr) or zero(target.repr)
      emit(s, target.code .. " = " .. stored .. ";")
   end
end

emit_function = function(s: State, node: Node, name: string, sig: Repr)
   if node.is_method then fail(node, "method definitions are unsupported; use a function field") end
   if sig.kind ~= "function" then fail(node, "unsupported function signature") end

   local params: {string} = {}
   local scope: {string:Binding} = {}
   for i, argument in ipairs(node.args) do
      local r = sig.params[i]
      local param = fresh(s)
      params[i] = r.ctype .. " " .. param .. " __attribute__((unused))"
      scope[argument.tk] = { name = param, value = r }
   end

   local out, indent, return_type, cache = s.out, s.indent, s.return_type, s.module_cache
   s.out, s.indent, s.return_type, s.module_cache = s.functions, 0, sig.result, nil
   emit(s, "static __attribute__((unused)) " .. sig.result.ctype .. " " .. name ..
      "(" .. (#params > 0 and table.concat(params, ", ") or "void") .. ") {")
   table.insert(s.scopes, scope)
   s.indent = 1
   statements(s, node.body)
   if sig.result.nullable then emit(s, "return " .. zero(sig.result) .. ";") end
   table.remove(s.scopes)
   s.indent = 0
   emit(s, "}")
   emit(s, "")
   s.out, s.indent, s.return_type, s.module_cache = out, indent, return_type, cache
end

local function local_function(s: State, node: Node, top_level: boolean)
   if not top_level then fail(node, "local functions must be declared at the top level") end
   local sig = repr(s, node)
   local name = fresh(s)
   s.scopes[#s.scopes][node.name.tk] = { name = name, value = sig, direct_function = true }
   emit_function(s, node, name, sig)
end

local function record_function(s: State, node: Node, top_level: boolean)
   if not top_level then fail(node, "record functions must be declared at the top level") end
   local sig = repr(s, node)
   local field = record_field(s, node, node.fn_owner, node.name.tk)
   local name = fresh(s)
   emit_function(s, node, name, sig)
   local owner = expression(s, node.fn_owner)
   emit(s, "(" .. owner .. ")->" .. field.name .. " = " .. coerce(s, node, name, sig, field.value) .. ";")
end

local function array_for(s: State, node: Node)
   local iterator = node.exps[1]
   if #node.exps ~= 1 or iterator.kind ~= "op" or iterator.op.op ~= "@funcall"
      or intrinsic(s, iterator.e1) ~= "ipairs" or #iterator.e2 ~= 1 then
      fail(node, "native generic loops require ipairs(array)")
   end
   local sequence = iterator.e2[1]
   local r = repr(s, sequence)
   if r.kind ~= "array" or r.nullable then fail(sequence, "ipairs expects a dense array") end
   local array, index = fresh(s), fresh(s)
   emit(s, "{")
   s.indent = s.indent + 1
   emit(s, r.ctype .. " " .. array .. " = " .. expression(s, sequence) .. ";")
   emit(s, "for (size_t " .. index .. " = 0; " .. index .. " < " .. array .. "->length; ++" .. index .. ") {")
   s.indent = s.indent + 1
   table.insert(s.scopes, {})
   store_local(s, node.vars[1], integer, "(int64_t)" .. index .. " + 1", false)
   if node.vars[2] then
      store_local(s, node.vars[2], r.element, "((" .. r.element.ctype .. " *)" .. array .. "->data)[" .. index .. "]", false)
   end
   statements(s, node.body)
   table.remove(s.scopes)
   s.indent = s.indent - 1
   emit(s, "}")
   s.indent = s.indent - 1
   emit(s, "}")
end

local function numeric_for(s: State, node: Node)
   local r = repr(s, node.var)
   local start, limit, step, variable = fresh(s), fresh(s), fresh(s), fresh(s)
   emit(s, "{")
   s.indent = s.indent + 1
   emit(s, r.ctype .. " " .. start .. " = " .. expression(s, node.from) .. ";")
   emit(s, r.ctype .. " " .. limit .. " = " .. expression(s, node.to) .. ";")
   emit(s, r.ctype .. " " .. step .. " = " .. (node.step and expression(s, node.step) or "1") .. ";")
   emit(s, "if (" .. step .. " == 0) __builtin_trap();")
   emit(s, "while (" .. step .. " > 0 ? " .. start .. " <= " .. limit .. " : " .. start .. " >= " .. limit .. ") {")
   s.indent = s.indent + 1
   emit(s, r.ctype .. " " .. variable .. " __attribute__((unused)) = " .. start .. ";")
   table.insert(s.scopes, { [node.var.tk] = { name = variable, value = r } })
   statements(s, node.body)
   table.remove(s.scopes)
   if r.kind == "integer" then
      emit(s, "if (__builtin_add_overflow(" .. start .. ", " .. step .. ", &" .. start .. ")) break;")
   else
      emit(s, start .. " += " .. step .. ";")
   end
   s.indent = s.indent - 1
   emit(s, "}")
   s.indent = s.indent - 1
   emit(s, "}")
end

statement = function(s: State, node: Node, top_level?: boolean)
   if node.kind == "pragma" or node.kind == "global_type"
      or node.kind == "local_macroexp" or node.native_cdef then
      return
   elseif node.kind == "local_type" then
      local_record(s, node, top_level)
   elseif node.kind == "local_declaration" then
      local_declaration(s, node, top_level)
   elseif node.kind == "assignment" then
      assignment(s, node)
   elseif node.kind == "local_function" then
      local_function(s, node, top_level)
   elseif node.kind == "record_function" then
      record_function(s, node, top_level)
   elseif node.kind == "if" then
      for i, branch in ipairs(node.if_blocks) do
         local header = i == 1 and "if " or "else "
         if branch.exp then
            if i > 1 then header = header .. "if " end
            header = header .. "(" .. condition(s, branch.exp) .. ") "
         end
         block(s, header, branch.body)
      end
   elseif node.kind == "while" then
      block(s, "while (" .. condition(s, node.exp) .. ") ", node.body)
   elseif node.kind == "repeat" then
      emit(s, "for (;;) {")
      s.indent = s.indent + 1
      table.insert(s.scopes, {})
      statements(s, node.body)
      emit(s, "if (" .. condition(s, node.exp) .. ") break;")
      table.remove(s.scopes)
      s.indent = s.indent - 1
      emit(s, "}")
   elseif node.kind == "fornum" then
      numeric_for(s, node)
   elseif node.kind == "forin" then
      array_for(s, node)
   elseif node.kind == "do" then
      block(s, "", node.body)
   elseif node.kind == "break" then
      emit(s, "break;")
   elseif node.kind == "return" then
      local value = node.exps[1]
      if #node.exps > 1 then fail(node, "multiple return values are unsupported") end
      if not s.return_type then
         if value and returns_no_values(value) then
            emit(s, "(void)(" .. expression(s, value) .. ");")
            value = nil
         end
         if value and repr(s, value).kind ~= "integer" then fail(node, "the program exit status must be an integer") end
         emit(s, "return " .. (value and int_conversion(s, "int", expression(s, value)) or "0") .. ";")
      elseif s.module_cache then
         local code: string
         if not value or repr(s, value).kind == "nil" then
            if s.return_type.kind ~= "boolean" then fail(node, "C module must return an export value") end
            if value then emit(s, "(void)(" .. expression(s, value) .. ");") end
            code = "1"
         else
            code = coerce(s, value, expression(s, value), repr(s, value), s.return_type)
         end
         emit(s, "return " .. s.module_cache .. " = " .. code .. ";")
      elseif s.return_type.kind == "void" then
         if value then emit(s, "(void)(" .. expression(s, value) .. ");") end
         emit(s, "return;")
      else
         local code = value and coerce(s, value, expression(s, value), repr(s, value), s.return_type) or zero(s.return_type)
         emit(s, "return " .. code .. ";")
      end
   elseif node.kind == "op" and node.op.op == "@funcall" then
      emit(s, "(void)(" .. expression(s, node) .. ");")
   else
      fail(node, "unsupported statement '" .. node.kind .. "'")
   end
end

local function collect_modules(s: State, ast: Node, ordered: {Node})
   traversal.traverse_nodes(s, ast, {
      allow_missing_cbs = true,
      after = function(state: State, node: Node): boolean
         local child = node.native_module
         if child and not state.modules[child] then
            if not child.native_checked then fail(node, "required Teal module failed native type checking") end
            local value = repr(state, child, child.native_module_type)
            if value.nullable then fail(child, "a C module must export a non-nil value") end
            state.modules[child] = { init = fresh(state), value = value }
            collect_modules(state, child, ordered)
            table.insert(ordered, child)
         end
         return true
      end,
   }, {})
end

local record Unit
   ast: Node
   registry: c_types.Registry
   globals: {string}
   functions: {string}
   body: {string}
   helpers: {string:boolean}
end

local function prepare_unit(s: State, ast: Node, public: c_types.Registry): Unit
   local unit: Unit = { ast = ast, registry = c_types.fork(public), globals = {}, functions = {}, body = {}, helpers = {} }
   s.registry = unit.registry
   s.ffi = ast.native_ffi
   s.globals, s.functions, s.out, s.helpers = unit.globals, unit.functions, unit.body, unit.helpers
   s.scopes, s.indent = { {} }, 0
   s.return_type, s.module_cache = nil, nil
   return unit
end

local function compile_module(s: State, ast: Node, public: c_types.Registry): Unit
   local unit = prepare_unit(s, ast, public)
   local module = s.modules[ast]
   local loaded, cache = fresh(s), fresh(s)
   s.return_type, s.module_cache = module.value, cache
   emit(s, module.value.ctype .. " " .. module.init .. "(void) {")
   s.indent = 1
   emit(s, "static _Bool " .. loaded .. ";")
   emit(s, "static " .. module.value.ctype .. " " .. cache .. ";")
   emit(s, "if (" .. loaded .. ") return " .. cache .. ";")
   emit(s, loaded .. " = 1;")
   for _, stmt in ipairs(ast) do statement(s, stmt, true) end
   if not ast.native_module_returns then
      if module.value.kind ~= "boolean" then fail(ast, "C module must return its export value on all paths") end
      emit(s, "return " .. cache .. " = 1;")
   end
   s.indent = 0
   emit(s, "}")
   return unit
end

local function compile_entry(s: State, ast: Node, public: c_types.Registry): Unit
   local unit = prepare_unit(s, ast, public)
   emit(s, "int main(void) {")
   s.indent = 1
   for _, node in ipairs(ast) do statement(s, node, true) end
   if not ast[#ast] or ast[#ast].kind ~= "return" then emit(s, "return 0;") end
   s.indent = 0
   emit(s, "}")
   return unit
end

local generated = "/* Generated by Teal's experimental C target. */"

local function append(out: {string}, lines: {string})
   for _, line in ipairs(lines) do table.insert(out, line) end
end

local function emit_header(s: State, ordered: {Node}, public: c_types.Registry, allocates: boolean): string
   local out = {
      generated, "#ifndef TL_NATIVE_PROGRAM_ABI_H", "#define TL_NATIVE_PROGRAM_ABI_H",
      "#include <stddef.h>", "#include <stdint.h>", "",
   }
   table.insert(out, c_runtime.array_type)
   for _, tag in ipairs(sorted_keys(public.tags)) do table.insert(out, tag .. ";") end
   append(out, public.declarations)

   if #public.declarations > 0 then table.insert(out, "") end
   if allocates then table.insert(out, "void *tl_native_alloc(size_t size);") end
   for _, ast in ipairs(ordered) do
      local module = s.modules[ast]
      table.insert(out, module.value.ctype .. " " .. module.init .. "(void);")
   end
   table.insert(out, "")
   table.insert(out, "#endif")
   return table.concat(out, "\n")
end

local function emit_unit(unit: Unit, header: string, provides_allocator: boolean): string
   local out: {string} = { generated }
   if header then
      table.insert(out, '#include "' .. header .. '"')
   else
      append(out, { "#include <stddef.h>", "#include <stdint.h>" })
      unit.helpers.array = unit.helpers.array or unit.registry.uses_arrays
   end
   table.insert(out, "")
   append(out, c_runtime.emit(unit.helpers, header ~= nil, provides_allocator))
   append(out, unit.ast.native_ffi.declarations)
   if #unit.ast.native_ffi.declarations > 0 then table.insert(out, "") end
   for _, name in ipairs({ "int", "idiv", "imod", "fmod", "shift", "compare" }) do
      if unit.helpers[name] then table.insert(out, helpers[name]) end
   end
   for _, tag in ipairs(sorted_keys(unit.registry.tags)) do table.insert(out, tag .. ";") end
   append(out, unit.registry.declarations)
   if #unit.registry.declarations > 0 then table.insert(out, "") end
   append(out, unit.globals)
   if #unit.globals > 0 then table.insert(out, "") end
   append(out, unit.functions)
   append(out, unit.body)
   return table.concat(out, "\n")
end

local function filename_for(ast: Node, used: {string:boolean}): string
   local path = ast.f:gsub("\\", "/")
   local base = path:match("([^/]+)%.tl$") or "module"
   if base == "init" then base = path:match("([^/]+)/init%.tl$") or base end
   base = "tl_" .. base:gsub("[^%w_-]", "_")
   local name = base
   local index = 1
   while used[name:lower()] do
      index = index + 1
      name = base .. "_" .. tostring(index)
   end
   used[name:lower()] = true
   return name .. ".c"
end

local function generate_program(ast: Node, directory?: string): generator.COutput
   local public = c_types.new()
   local s: State = { registry = public, modules = {}, next_id = 0 }
   local ordered: {Node} = {}
   collect_modules(s, ast, ordered)

   local modules: {Unit} = {}
   local allocates = false
   for _, dependency in ipairs(ordered) do
      local unit = compile_module(s, dependency, public)
      table.insert(modules, unit)
      allocates = allocates or c_runtime.uses_allocation(unit.helpers)
   end
   local entry = compile_entry(s, ast, public)
   if #modules == 0 then return { entry = emit_unit(entry, nil, false), modules = {} } end

   directory = directory or "teal_modules"
   if directory == "" or directory:find('["\\\r\n]') then fail(ast, "invalid C module output directory") end
   allocates = allocates or c_runtime.uses_allocation(entry.helpers)
   local output: generator.COutput = {
      entry = emit_unit(entry, directory .. "/abi.h", allocates),
      directory = directory,
      header = emit_header(s, ordered, public, allocates),
      modules = {},
   }
   local used: {string:boolean} = {}
   for _, unit in ipairs(modules) do
      table.insert(output.modules, {
         source = unit.ast.f,
         filename = filename_for(unit.ast, used),
         code = emit_unit(unit, "abi.h", false),
      })
   end
   return output
end

function generator.generate_program(ast: Node, directory?: string): generator.COutput, string
   if not ast.native_checked then
      return nil, "the C target requires a Teal file successfully checked with target 'c' and '--#pragma strict on'"
   end
   local ok, result = pcall(generate_program, ast, directory)
   if ok then return result as generator.COutput, nil end
   local failure = result as {any}
   if type(failure) == "table" and failure[1] == failure_tag then return nil, failure[2] as string end
   error(result, 0)
end

function generator.generate(ast: Node): string, string
   local output, err = generator.generate_program(ast)
   if not output then return nil, err end
   if #output.modules > 0 then return nil, "use Module:gen_c() or tl.generate_c() for Teal programs with runtime imports" end
   return output.entry
end

return generator
