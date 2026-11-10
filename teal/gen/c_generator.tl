--#pragma strict_nil off
local type Node = require("teal.parser").Node
local ffi = require("teal.gen.c_ffi")
local type CType = ffi.CType
local type Symbol = ffi.Symbol
local types = require("teal.types")
local type Type = types.Type

local record generator
end

local enum Kind
   "integer"
   "number"
   "boolean"
   "string"
   "pointer"
   "nil"
   "void"
end

local record Repr
   kind: Kind
   ctype: string
   nullable: boolean
end

local record Binding
   name: string
   params: {Repr}
   virtual: boolean
end

local record State
   ffi: ffi.State
   scopes: {{string:Binding}}
   globals: {string}
   functions: {string}
   out: {string}
   indent: integer
   next_id: integer
   helpers: {string:boolean}
   return_type: Repr -- nil while emitting main
end

local integer: Repr = { kind = "integer", ctype = "int64_t" }
local number: Repr = { kind = "number", ctype = "double" }
local boolean: Repr = { kind = "boolean", ctype = "_Bool" }
local string_type: Repr = { kind = "string", ctype = "const char *" }
local nil_type: Repr = { kind = "nil", ctype = "void *", nullable = true }
local void: Repr = { kind = "void", ctype = "void" }

local failure_tag = {}
local function fail(node: Node, message: string)
   local position = ("%s:%d:%d"):format(node.f or "<input>", node.y or 1, node.x or 1)
   error({ failure_tag, position .. ": C target: " .. message }, 0)
end

local function resolve(t: Type): Type
   if not (t is types.NominalType or t is types.TypeDeclType) then return t end
   local seen: {Type:boolean} = {}
   while t is types.NominalType or t is types.TypeDeclType do
      if seen[t] then return nil end
      seen[t] = true
      if t is types.NominalType then
         t = t.resolved or (t.found and t.found.def)
      else
         t = t.def
      end
   end
   return t
end

local function representation(t: Type): Repr
   t = resolve(t)
   if not t then return nil end
   if t is types.TupleType then
      if t.is_va or #t.tuple > 1 then return nil end
      if #t.tuple == 0 then return nil_type end
      return representation(t.tuple[1])
   elseif t is types.UnionType then
      local value: Repr
      local nullable = false
      for _, member in ipairs(t.types) do
         local r = representation(member)
         if not r then return nil end
         if r.kind == "nil" then
            nullable = true
         elseif not value or value.ctype == r.ctype then
            value = r
            nullable = nullable or r.nullable
         else
            return nil
         end
      end
      if not value then return nil_type end
      if nullable then
         if value.kind ~= "string" and value.kind ~= "pointer" then return nil end
         return { kind = value.kind, ctype = value.ctype, nullable = true }
      end
      return value
   elseif t is types.RecordType and t.native_pointer then
      return { kind = "pointer", ctype = t.native_pointer }
   end
   if t.typename == "integer" then return integer end
   if t.typename == "number" then return number end
   if t.typename == "boolean" then return boolean end
   if t.typename == "string" or t.typename == "enum" then return string_type end
   if t.typename == "nil" then return nil_type end
end

local function repr(node: Node, t?: Type): Repr
   t = t or node.native_type
   local r = representation(t)
   if not r then fail(node, "unsupported value type " .. (t and types.show_type(t) or node.kind)) end
   return r
end

local function emit(s: State, line: string)
   table.insert(s.out, ("   "):rep(s.indent) .. line)
end

local function fresh(s: State): string
   s.next_id = s.next_id + 1
   return "tl_native_" .. tostring(s.next_id)
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
      return t.typeid == s.ffi.ffi.typeid and node.op.op == "@funcall" and node.e1.kind == "variable"
         and node.e1.tk == "require" and #node.e2 == 1 and node.e2[1].conststr == "ffi"
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

local function returns_no_values(node: Node): boolean
   local t = node.native_type
   return t is types.TupleType and #t.tuple == 0 and not t.is_va
end

local function vararg(s: State, node: Node, value: string): string
   local r = repr(node)
   if r.kind == "integer" then return int_conversion(s, "int", value) end
   if r.kind == "boolean" then return "(int)(" .. value .. ")" end
   return value
end

local function call(s: State, node: Node): string
   local callee = node.e1
   while callee.kind == "paren" do callee = callee.e1 end
   local foreign = foreign_symbol(s, callee)
   local binding = callee.kind == "variable" and lookup(s, callee.tk)
   if not (foreign and foreign.params) and not (binding and binding.params) then
      fail(node, "only direct calls to local functions and declared C functions are supported")
   end

   local params: {string} = {}
   local temps: {string} = {}
   for i, argument in ipairs(node.e2) do
      local value = expression(s, argument)
      if i == #node.e2 and returns_no_values(argument) then
         table.insert(temps, "(void)(" .. value .. ");")
         break
      end
      local fixed = foreign and foreign.params[i]
      local r = repr(argument)
      if fixed and fixed.kind == "integer" then
         value = int_conversion(s, fixed.spelling:gsub("^const ", ""), value)
         r = { kind = "integer", ctype = fixed.spelling }
      elseif foreign and not fixed then
         value = vararg(s, argument, value)
         if r.kind == "integer" or r.kind == "boolean" then r = { kind = "integer", ctype = "int" } end
      end

      -- Retain literal format strings so Clang can check printf-family calls.
      if argument.kind ~= "string" and argument.kind ~= "integer" and argument.kind ~= "number"
         and argument.kind ~= "boolean" and argument.kind ~= "nil" then
         local tmp = fresh(s)
         table.insert(temps, r.ctype .. " " .. tmp .. " = " .. value .. ";")
         value = tmp
      end
      table.insert(params, value)
   end

   if binding then
      for i = #params + 1, #binding.params do
         if not binding.params[i].nullable then fail(node, "missing argument " .. tostring(i)) end
         params[i] = "NULL"
      end
   end
   local name = foreign and foreign.name or binding.name
   local value = name .. "(" .. table.concat(params, ", ") .. ")"
   if foreign then
      value = ffi_result(s, foreign.result, value)
   elseif representation(node.native_type) == nil_type then
      value = "((void)(" .. value .. "), (void *)0)"
   end
   if #temps > 0 then
      value = "__extension__ ({ " .. table.concat(temps, " ") .. " " .. value .. "; })"
   end
   return value
end

local function truth(r: Repr, value: string): string
   if r.kind == "boolean" then return value end
   if r.kind == "nil" then return "((void)(" .. value .. "), 0)" end
   if r.nullable then return value .. " != NULL" end
   return "((void)(" .. value .. "), 1)"
end

local function condition(s: State, node: Node): string
   return truth(repr(node), expression(s, node))
end

local function numeric(r: Repr): boolean
   return r.kind == "integer" or r.kind == "number"
end

local comparison_ops: {string:string} = {
   ["=="] = "==", ["~="] = "!=", ["<"] = "<", [">"] = ">", ["<="] = "<=", [">="] = ">=",
}
local reversed_comparison: {string:string} = { ["<"] = ">", [">"] = "<", ["<="] = ">=", [">="] = "<=" }
local function compare(s: State, node: Node, op: string, a: Repr, b: Repr, left: string, right: string): string
   local equality = op == "==" or op == "!="
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
      local ap = a.kind == "pointer" or a.kind == "nil" or a.kind == "string"
      local bp = b.kind == "pointer" or b.kind == "nil" or b.kind == "string"
      if ap and bp then return "(const void *)" .. left .. " " .. op .. " (const void *)" .. right end
      return op == "==" and "0" or "1"
   end
   fail(node, "unsupported comparison '" .. node.op.op .. "'")
end

local arithmetic: {string:boolean} = { ["+"] = true, ["-"] = true, ["*"] = true }
local bitwise: {string:boolean} = { ["&"] = true, ["|"] = true, ["~"] = true }
local function binary(s: State, node: Node, op: string): string
   local a, b = repr(node.e1), repr(node.e2)
   local left, right = fresh(s), fresh(s)
   local operands = a.ctype .. " " .. left .. " __attribute__((unused)) = " .. expression(s, node.e1) .. "; " ..
                    b.ctype .. " " .. right .. " __attribute__((unused)) = " .. expression(s, node.e2) .. "; "
   local result: string
   if comparison_ops[op] then
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
      fail(node, "only declared C objects can be read through a field access")
   end
   if op == "as" then
      local r = repr(node)
      return "(" .. r.ctype .. ")(" .. expression(s, node.e1) .. ")"
   end

   local a = repr(node.e1)
   if op == "is" then
      local tested = resolve(node.e2.casttype)
      if not tested or tested is types.UnionType or tested is types.EnumType then
         fail(node, "union and enum type tests are unsupported")
      end
      local b = repr(node.e2, tested)
      local value = expression(s, node.e1)
      if a.nullable and a.kind ~= "nil" and (b.kind == "nil" or a.ctype == b.ctype) then
         return value .. (b.kind == "nil" and " == " or " != ") .. "NULL"
      end
      local is_type = a.ctype == b.ctype or (a.kind == "integer" and b.kind == "number")
      return "((void)(" .. value .. "), " .. (is_type and "1" or "0") .. ")"
   elseif op == "and" or op == "or" then
      local value = expression(s, node.e1)
      local r = repr(node)
      local first = resolve(types.untuple(node.e1.native_type))
      local known_truth: boolean
      if first is types.BooleanType then
         known_truth = first.literal
      elseif a.kind == "nil" then
         known_truth = false
      elseif not a.nullable then
         known_truth = true
      end
      if known_truth ~= nil then
         if (op == "or") == known_truth then return "(" .. r.ctype .. ")(" .. value .. ")" end
         return "((void)(" .. value .. "), (" .. r.ctype .. ")(" .. expression(s, node.e2) .. "))"
      end
      local tmp = fresh(s)
      local right = "(" .. r.ctype .. ")(" .. expression(s, node.e2) .. ")"
      local left = "(" .. r.ctype .. ")" .. tmp
      return "__extension__ ({ " .. a.ctype .. " " .. tmp .. " = " .. value .. "; "
         .. truth(a, tmp) .. " ? " .. (op == "and" and right or left) .. " : " .. (op == "and" and left or right) .. "; })"
   elseif node.op.arity == 1 then
      local value = expression(s, node.e1)
      if op == "not" then return "!(" .. truth(a, value) .. ")" end
      if op == "#" and a.kind == "string" and not a.nullable then return "(int64_t)__builtin_strlen(" .. value .. ")" end
      if op == "-" and a.kind == "integer" then return "(int64_t)(0 - (uint64_t)(" .. value .. "))" end
      if op == "-" and a.kind == "number" then return "-(" .. value .. ")" end
      if op == "~" and a.kind == "integer" then return "(int64_t)(~(uint64_t)(" .. value .. "))" end
      fail(node, "unsupported unary operator '" .. op .. "'")
   end
   return binary(s, node, op)
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
   elseif node.kind == "variable" then
      local b = lookup(s, node.tk)
      if b and not b.params and not b.virtual then return b.name end
      fail(node, "unsupported value '" .. node.tk .. "'")
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

local function rhs(s: State, exps: Node, count: integer): {string}
   local values: {string} = {}
   for i, e in ipairs(exps or {}) do
      local value = expression(s, e)
      if i <= count then
         local tmp = fresh(s)
         emit(s, repr(e).ctype .. " " .. tmp .. " = " .. value .. ";")
         values[i] = tmp
      else
         emit(s, "(void)(" .. value .. ");")
      end
   end
   return values
end

local function local_declaration(s: State, node: Node, top_level: boolean)
   if #node.vars == 1 and node.exps and #node.exps == 1 and is_ffi_reference(s, node.exps[1]) then
      s.scopes[#s.scopes][node.vars[1].tk] = { virtual = true }
      return
   end
   local values = rhs(s, node.exps, #node.vars)
   for i, var in ipairs(node.vars) do
      local r = repr(var)
      local name = fresh(s)
      local declaration = r.ctype .. " " .. name .. " __attribute__((unused))"
      local value = values[i] or "NULL"
      if top_level then
         table.insert(s.globals, "static " .. declaration .. ";")
         emit(s, name .. " = " .. value .. ";")
      else
         emit(s, declaration .. " = " .. value .. ";")
      end
      s.scopes[#s.scopes][var.tk] = { name = name }
   end
end

local function local_function(s: State, node: Node, top_level: boolean)
   if not top_level then fail(node, "local functions must be declared at the top level") end
   if (node.typeargs and #node.typeargs > 0) or node.rets.is_va or #node.rets.tuple > 1 then
      fail(node, "generic functions and multiple return values are unsupported")
   end

   local name = fresh(s)
   local binding: Binding = { name = name, params = {} }
   s.scopes[#s.scopes][node.name.tk] = binding
   local ret = node.native_return_type and repr(node, node.native_return_type) or void
   local params: {string} = {}
   local scope: {string:Binding} = {}
   for i, argument in ipairs(node.args) do
      if argument.tk == "..." then fail(argument, "variadic Teal functions are unsupported") end
      local r = repr(argument)
      local param = fresh(s)
      binding.params[i] = r
      params[i] = r.ctype .. " " .. param .. " __attribute__((unused))"
      scope[argument.tk] = { name = param }
   end

   local saved = s.out
   s.out, s.indent, s.return_type = s.functions, 0, ret
   emit(s, "static __attribute__((unused)) " .. ret.ctype .. " " .. name ..
      "(" .. (#params > 0 and table.concat(params, ", ") or "void") .. ") {")
   table.insert(s.scopes, scope)
   s.indent = 1
   statements(s, node.body)
   if ret.nullable then emit(s, "return NULL;") end
   table.remove(s.scopes)
   s.indent = 0
   emit(s, "}")
   emit(s, "")
   s.out, s.indent, s.return_type = saved, 1, nil
end

local function numeric_for(s: State, node: Node)
   local r = repr(node.var)
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
   table.insert(s.scopes, { [node.var.tk] = { name = variable } })
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
   if node.kind == "pragma" or node.kind == "local_type" or node.kind == "global_type"
      or node.kind == "local_macroexp" or node.native_cdef then
      return
   elseif node.kind == "local_declaration" then
      local_declaration(s, node, top_level)
   elseif node.kind == "assignment" then
      local values = rhs(s, node.exps, #node.vars)
      for i, var in ipairs(node.vars) do
         local binding = var.kind == "variable" and lookup(s, var.tk)
         if not binding or binding.virtual or binding.params then
            fail(var, "only local variables can be assigned")
         end
         emit(s, binding.name .. " = " .. (values[i] or "NULL") .. ";")
      end
   elseif node.kind == "local_function" then
      local_function(s, node, top_level)
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
         if value and repr(value).kind ~= "integer" then fail(node, "the program exit status must be an integer") end
         emit(s, "return " .. (value and int_conversion(s, "int", expression(s, value)) or "0") .. ";")
      elseif s.return_type.kind == "void" then
         if value then emit(s, "(void)(" .. expression(s, value) .. ");") end
         emit(s, "return;")
      else
         emit(s, "return " .. (value and expression(s, value) or "NULL") .. ";")
      end
   elseif node.kind == "op" and node.op.op == "@funcall" then
      emit(s, "(void)(" .. expression(s, node) .. ");")
   else
      fail(node, "unsupported statement '" .. node.kind .. "'")
   end
end

local function generate(ast: Node): string
   local s: State = {
      ffi = ast.native_ffi, scopes = { {} }, globals = {}, functions = {},
      out = {}, indent = 1, next_id = 0, helpers = {},
   }
   for _, node in ipairs(ast) do statement(s, node, true) end

   local out = { "/* Generated by Teal's experimental C target. */", "#include <stddef.h>", "#include <stdint.h>", "" }
   for _, decl in ipairs(s.ffi.declarations) do table.insert(out, decl) end
   if #s.ffi.declarations > 0 then table.insert(out, "") end
   for _, name in ipairs({ "int", "idiv", "imod", "fmod", "shift", "compare" }) do
      if s.helpers[name] then table.insert(out, helpers[name]) end
   end
   for _, decl in ipairs(s.globals) do table.insert(out, decl) end
   if #s.globals > 0 then table.insert(out, "") end
   for _, line in ipairs(s.functions) do table.insert(out, line) end
   table.insert(out, "int main(void) {")
   for _, line in ipairs(s.out) do table.insert(out, line) end
   if not ast[#ast] or ast[#ast].kind ~= "return" then table.insert(out, "   return 0;") end
   table.insert(out, "}")
   return table.concat(out, "\n")
end

function generator.generate(ast: Node): string, string
   if not ast.native_checked then
      return nil, "the C target requires a Teal file successfully checked with target 'c' and '--#pragma strict on'"
   end
   local ok, result = pcall(generate, ast)
   if ok then return result as string, nil end
   local failure = result as {any}
   if type(failure) == "table" and failure[1] == failure_tag then return nil, failure[2] as string end
   error(result, 0)
end

return generator
