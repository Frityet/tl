--#pragma strict_nil off
local types = require("teal.types")
local type Type = types.Type
local type RecordType = types.RecordType
local type TypeDeclType = types.TypeDeclType
local type TupleType = types.TupleType
local type FunctionType = types.FunctionType
local type Where = require("teal.errors").Where
local a_type = types.a_type
local util = require("teal.util")

local record c_ffi
   enum Kind
      "void"
      "boolean"
      "integer"
      "number"
      "string"
      "pointer"
      "tag"
   end

   record CType
      kind: Kind
      spelling: string
      pointer: string
      nullability: string
      tag: string
      mutable_char: boolean
   end

   record Symbol
      name: string
      result: CType
      params: {CType} -- nil for an extern object
      variadic: boolean
      declaration: string
      typedef: boolean
   end

   record State
      ffi: RecordType
      namespace: RecordType
      cdef: FunctionType
      symbols: {string:Symbol}
      aliases: {string:CType}
      pointers: {string:RecordType}
      tags: {string:boolean}
      declarations: {string}
   end
end

local type CType = c_ffi.CType
local type Kind = c_ffi.Kind
local type State = c_ffi.State
local type Symbol = c_ffi.Symbol

local function record_type(w: Where, name: string): RecordType
   return a_type(w, "record", { declname = name, fields = {}, field_order = {} } as RecordType)
end

local function tuple(w: Where, members: {Type}, variadic?: boolean): TupleType
   return a_type(w, "tuple", { tuple = members, is_va = variadic } as TupleType)
end

function c_ffi.new(w: Where): State
   local ffi = record_type(w, "ffi")
   local namespace = record_type(w, "C")
   local cdef = types.a_function(w, {
      min_arity = 1,
      args = tuple(w, { a_type(w, "string", {}) }),
      rets = tuple(w, {}),
   } as FunctionType)
   ffi.fields = { C = namespace, cdef = cdef }
   ffi.field_order = { "C", "cdef" }
   return {
      ffi = ffi, namespace = namespace, cdef = cdef,
      symbols = {}, aliases = {}, pointers = {}, tags = {}, declarations = {},
   }
end

local escapes: {string:string} = {
   a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
   ["\\"] = "\\", ["'"] = "'", ['"'] = '"',
}

-- AST string tokens retain Lua spelling, so decode without loading Lua code.
function c_ffi.decode_string(token: string): string, string
   local opening = token:match("^%[=*%[")
   if opening then
      local text = token:sub(#opening + 1, -#opening - 1)
      text = text:gsub("\r\n", "\n"):gsub("\n\r", "\n"):gsub("\r", "\n")
      return (text:gsub("^\n", ""))
   end

   local text = token:sub(2, -2)
   local parts: {string} = {}
   local pos = 1
   while pos <= #text do
      local slash = text:find("\\", pos, true)
      if not slash then
         table.insert(parts, text:sub(pos))
         break
      end
      table.insert(parts, text:sub(pos, slash - 1))
      local c = text:sub(slash + 1, slash + 1)
      pos = slash + 2
      if escapes[c] then
         table.insert(parts, escapes[c])
      elseif c == "\n" or c == "\r" then
         local following = text:sub(pos, pos)
         if (following == "\n" or following == "\r") and following ~= c then pos = pos + 1 end
         table.insert(parts, "\n")
      elseif c == "z" then
         pos = text:find("%S", pos) or (#text + 1)
      elseif c == "u" then
         local hex = text:match("^%{(%x+)%}", pos)
         local codepoint = hex and tonumber(hex, 16)
         if not codepoint or codepoint > 0x10ffff then return nil, "invalid Unicode string escape" end
         table.insert(parts, utf8.char(codepoint as integer))
         pos = pos + #hex + 2
      elseif c == "x" then
         local hex = text:match("^%x%x", pos)
         if not hex then return nil, "invalid hexadecimal string escape" end
         table.insert(parts, string.char(tonumber(hex, 16) as integer))
         pos = pos + 2
      else
         local decimal = text:match("^%d%d?%d?", slash + 1)
         local byte = decimal and tonumber(decimal)
         if not byte or byte > 255 then return nil, "unsupported string escape" end
         table.insert(parts, string.char(byte as integer))
         pos = slash + 1 + #decimal
      end
   end
   return table.concat(parts)
end

local failure_tag = {}
local function fail(message: string)
   error({ failure_tag, message }, 0)
end

local function tokenize(source: string): {string}
   local tokens: {string} = {}
   local pos = 1
   while pos <= #source do
      local space = source:match("^%s+", pos)
      local start = source:sub(pos, pos + 1)
      if space then
         pos = pos + #space
      elseif start == "//" then
         pos = source:find("\n", pos + 2, true) or (#source + 1)
      elseif start == "/*" then
         local close = source:find("*/", pos + 2, true)
         if not close then fail("unterminated C comment") end
         pos = close + 2
      else
         local token = source:match("^[a-zA-Z_][a-zA-Z_0-9]*", pos)
            or source:match("^%.%.%.", pos) or source:match("^[*(),;]", pos)
         if not token then
            fail("unexpected character " .. string.format("%q", source:sub(pos, pos)))
         end
         table.insert(tokens, token)
         pos = pos + #token
      end
   end
   return tokens
end

local integer_spellings: {string:string} = {
   ["char"] = "char",
   ["signed char"] = "signed char",
   ["unsigned char"] = "unsigned char",
   ["short"] = "short",
   ["short int"] = "short",
   ["signed short"] = "short",
   ["signed short int"] = "short",
   ["unsigned short"] = "unsigned short",
   ["unsigned short int"] = "unsigned short",
   ["int"] = "int",
   ["signed"] = "int",
   ["signed int"] = "int",
   ["unsigned"] = "unsigned int",
   ["unsigned int"] = "unsigned int",
   ["long"] = "long",
   ["long int"] = "long",
   ["signed long"] = "long",
   ["signed long int"] = "long",
   ["unsigned long"] = "unsigned long",
   ["unsigned long int"] = "unsigned long",
   ["long long"] = "long long",
   ["long long int"] = "long long",
   ["signed long long"] = "long long",
   ["signed long long int"] = "long long",
   ["unsigned long long"] = "unsigned long long",
   ["unsigned long long int"] = "unsigned long long",
}
for _, name in ipairs({ "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
                        "int8_t", "uint8_t", "int16_t", "uint16_t",
                        "int32_t", "uint32_t", "int64_t", "uint64_t" }) do
   integer_spellings[name] = name
end

local reserved: {string:boolean} = {}
for name in ("auto break case char const continue default do double else enum extern float for goto if inline " ..
   "int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile " ..
   "while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local " ..
   "_Nonnull _Nullable alignas alignof bool constexpr false nullptr static_assert thread_local true typeof " ..
   "typeof_unqual NULL main"):gmatch("%S+") do
   reserved[name] = true
end

local function identifier(name: string): boolean
   return name and name:match("^[a-zA-Z_][a-zA-Z_0-9]*$") ~= nil
      and not reserved[name] and not name:match("^tl_native_")
end

local function parse_type(aliases: {string:CType}, words: {string}): CType
   local base: {string} = {}
   local is_const = false
   local is_pointer = false
   local nullability: string
   for _, word in ipairs(words) do
      if word == "*" and not is_pointer then
         is_pointer = true
      elseif (word == "_Nullable" or word == "_Nonnull") and not nullability then
         nullability = word
      elseif word == "const" and not is_pointer and not is_const then
         is_const = true
      elseif is_pointer and (word == "const" or word == "restrict") then
         -- Top-level pointer qualifiers do not change the ABI.
      elseif not is_pointer then
         table.insert(base, word)
      else
         return nil
      end
   end

   local name = table.concat(base, " ")
   local integer = integer_spellings[name]
   local kind: Kind
   local spelling, tag: string, string
   local aliased = aliases[name]
   if aliased then
      if aliased.pointer then
         if is_pointer or is_const then return nil end
         local copy = util.shallow_copy_table(aliased)
         copy.nullability = nullability or copy.nullability
         copy.spelling = name
         return copy
      end
      kind, spelling, tag = aliased.kind, aliased.spelling, aliased.tag
   elseif integer then
      kind, spelling = "integer", integer
   elseif name == "double" or name == "float" then
      kind, spelling = "number", name
   elseif name == "_Bool" or name == "bool" then
      kind, spelling = "boolean", "_Bool"
   elseif name == "void" then
      kind, spelling = "void", name
   elseif #base == 2 and (base[1] == "struct" or base[1] == "union") and identifier(base[2]) then
      kind, spelling, tag = "tag", name, name
   else
      return nil
   end

   if is_pointer then
      local pointer = (is_const and "const " or "") .. spelling .. " *"
      return {
         kind = is_const and spelling == "char" and "string" or "pointer",
         spelling = pointer,
         pointer = pointer,
         nullability = nullability,
         tag = tag,
         mutable_char = not is_const and spelling == "char",
      }
   elseif not nullability and not (is_const and kind == "void") then
      return { kind = kind, spelling = (is_const and "const " or "") .. spelling, tag = tag }
   end
end

local function declared_type(aliases: {string:CType}, words: {string}, needs_name: boolean): CType, string
   local text = table.concat(words, " ")
   if not needs_name then
      local t = parse_type(aliases, words)
      if t then return t, nil end
   end
   local name = table.remove(words)
   local t = identifier(name) and parse_type(aliases, words)
   if not t then fail("unsupported C declarator '" .. text .. "'") end
   return t, name
end

local function parse_declarations(state: State, source: string): {Symbol}, {string:CType}
   local tokens = tokenize(source)
   local aliases = util.shallow_copy_table(state.aliases)
   local symbols: {Symbol} = {}
   local names: {string:boolean} = {}
   local i = 1

   local function consume(token: string)
      if tokens[i] ~= token then
         fail("expected '" .. token .. "' before '" .. (tokens[i] or "end of declaration") .. "'")
      end
      i = i + 1
   end

   local function words_until(delimiters: {string:boolean}): {string}
      local words: {string} = {}
      while tokens[i] and not delimiters[tokens[i]] do
         table.insert(words, tokens[i])
         i = i + 1
      end
      return words
   end

   while tokens[i] do
      local is_extern = tokens[i] == "extern"
      local is_typedef = tokens[i] == "typedef"
      if is_extern or is_typedef then i = i + 1 end
      local head = words_until({ ["("] = true, [";"] = true })
      local is_function = tokens[i] == "("
      local tag = not is_function and not is_typedef and not is_extern and parse_type(aliases, head)
      if tag and tag.kind == "tag" then
         table.insert(symbols, { result = tag })
         consume(";")
      else
         local t, name = declared_type(aliases, head, true)
         if names[name] or state.symbols[name] or integer_spellings[name] then
            fail("duplicate or reserved C name '" .. name .. "'")
         end
         names[name] = true
         local symbol: Symbol = { name = name, result = t, typedef = is_typedef }
         if is_function then
            if is_typedef or t.kind == "tag" then fail("unsupported C function declaration for '" .. name .. "'") end
            consume("(")
            symbol.params = {}
            local spellings: {string} = {}
            if tokens[i] == "void" and tokens[i + 1] == ")" then i = i + 1 end
            if tokens[i] ~= ")" then
               while true do
                  if tokens[i] == "..." then
                     if #symbol.params == 0 then fail("a variadic C function needs a fixed parameter") end
                     symbol.variadic = true
                     table.insert(spellings, "...")
                     i = i + 1
                     break
                  end
                  local param = declared_type(aliases, words_until({ [","] = true, [")"] = true }), false)
                  if param.kind == "tag" or param.kind == "void" then
                     fail("unsupported parameter type '" .. param.spelling .. "' for '" .. name .. "'")
                  end
                  table.insert(symbol.params, param)
                  table.insert(spellings, param.spelling)
                  if tokens[i] ~= "," then break end
                  consume(",")
               end
            end
            consume(")")
            local args = #spellings > 0 and table.concat(spellings, ", ") or "void"
            symbol.declaration = t.spelling .. " " .. name .. "(" .. args .. ");"
         elseif is_typedef then
            aliases[name] = t
            symbol.declaration = "typedef " .. t.spelling .. " " .. name .. ";"
         elseif is_extern and t.kind ~= "void" and t.kind ~= "tag" then
            symbol.declaration = "extern " .. t.spelling .. " " .. name .. ";"
         else
            fail("expected a function prototype, typedef, or extern object declaration for '" .. name .. "'")
         end
         consume(";")
         table.insert(symbols, symbol)
      end
   end
   if #symbols == 0 then fail("expected at least one C declaration") end
   return symbols, aliases
end

local function teal_type(state: State, w: Where, c: CType, output?: boolean): Type
   local t: Type
   if c.kind == "pointer" and not (output and c.mutable_char) then
      t = state.pointers[c.pointer]
      if not t then
         local pointer = record_type(w, c.pointer)
         pointer.is_userdata = true
         pointer.native_pointer = c.pointer
         state.pointers[c.pointer] = pointer
         t = pointer
      end
   elseif c.kind == "string" or (output and c.mutable_char) then
      t = a_type(w, "string", {})
   elseif c.kind == "integer" or c.kind == "number" or c.kind == "boolean" then
      t = a_type(w, c.kind as types.TypeName, {})
   end
   if t and c.pointer and (c.nullability == "_Nullable" or (output and c.nullability ~= "_Nonnull")) then
      t = types.unite(w, { t, a_type(w, "nil", {}) }, true, false)
   end
   return t
end

local function add_tag(state: State, c: CType)
   if c.tag and not state.tags[c.tag] then
      state.tags[c.tag] = true
      table.insert(state.declarations, c.tag .. ";")
   end
end

function c_ffi.declare(state: State, w: Where, source: string): boolean, string
   local ok, result, aliases = pcall(parse_declarations, state, source)
   if not ok then
      local failure = result as {any}
      if type(failure) == "table" and failure[1] == failure_tag then return false, failure[2] as string end
      error(result, 0)
   end

   state.aliases = aliases
   for _, symbol in ipairs(result as {Symbol}) do
      local c = symbol.result
      add_tag(state, c)
      if symbol.name then
         local t: Type
         if symbol.typedef then
            local def = teal_type(state, w, c)
            if def then t = a_type(w, "typedecl", { def = def, closed = true } as TypeDeclType) end
         elseif symbol.params then
            local args: {Type} = {}
            for _, param in ipairs(symbol.params) do
               add_tag(state, param)
               table.insert(args, teal_type(state, w, param))
            end
            if symbol.variadic then
               table.insert(args, types.unite(w, {
                  a_type(w, "number", {}), a_type(w, "boolean", {}),
                  a_type(w, "string", {}), a_type(w, "nil", {}),
               }, true, false))
            end
            local ret = teal_type(state, w, c, true)
            t = types.a_function(w, {
               min_arity = #symbol.params, args = tuple(w, args, symbol.variadic),
               rets = tuple(w, ret and { ret } or {}),
            } as FunctionType)
         else
            t = teal_type(state, w, c, true)
         end
         state.symbols[symbol.name] = symbol
         if t then
            state.namespace.fields[symbol.name] = t
            table.insert(state.namespace.field_order, symbol.name)
         end
         table.insert(state.declarations, symbol.declaration)
      end
   end
   return true
end

return c_ffi
