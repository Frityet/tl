--#pragma strict_nil off
local types = require("teal.types")
local util = require("teal.util")
local sorted_keys = util.sorted_keys

local type Type = types.Type
local type NominalType = types.NominalType
local type ReflectedType = reflection.Type

local record type_reflection
   record Description
      info: ReflectedType
      keys: {ReflectedType: string}
   end

   describe: function(Type, function(NominalType): Type): Description
   encode: function(Description): string
   factory: string
end

local type Description = type_reflection.Description

-- Lua 5.1 requires both operands to have the same __eq function. Share the
-- factory across generated chunks, with a local fallback in restricted hosts.
type_reflection.factory = ([[(function(setmt, cache)
   local slot = "teal.runtime.type_info.v1"
   if cache and cache[slot] then return cache[slot] end
   local keys = setmt({}, { __mode = "k" })
   local mt = {
      __eq = function(a, b) return keys[a] ~= nil and keys[a] == keys[b] end,
      __tostring = function(t) return t.text end,
   }
   local function make(info, key)
      keys[info] = key
      return setmt(info, mt)
   end
   if cache then cache[slot] = make end
   return make
end)(setmetatable, package and package.loaded)]]):gsub("%s*\n%s*", " ")

local function quote(value: string): string
   return (string.format("%q", value):gsub("\\\n", "\\n"))
end

local function number_text(value: number): string
   if value == math.huge then return "(1/0)" end
   if value == -math.huge then return "(-1/0)" end
   if value == 0 then return "0" end
   return string.format("%.17g", value)
end

local function identity(kind: string, parts: {string}): string
   local out = { kind, "(" }
   for _, part in ipairs(parts) do
      out[#out + 1] = tostring(#part)
      out[#out + 1] = ":"
      out[#out + 1] = part
   end
   out[#out + 1] = ")"
   return table.concat(out)
end

local function declared_type(t: Type, nominal?: NominalType): string, string
   if t is types.GenericType then t = t.t end
   if t is types.RecordLikeType or t is types.EnumType then
      local named = t as types.HasDeclName
      if named.declname then
         local decl = nominal and nominal.found
         local where: Type = t
         if decl then where = decl end
         local name = named.declname
         if decl and (decl.f ~= t.f or decl.y ~= t.y or decl.x ~= t.x) then
            name = nominal.names[#nominal.names]
         end
         local filename = (where.f or ""):gsub("\\", "/"):gsub("^%./+", ""):gsub("/%./", "/")
         return name, identity(t.typename, {
            filename, tostring(where.y), tostring(where.x),
         })
      end
   end
end

local primitive_kinds: {types.TypeName: reflection.Kind} = {
   ["any"] = "any", ["nil"] = "nil", ["boolean"] = "boolean", ["boolean_context"] = "boolean",
   ["integer"] = "integer", ["number"] = "number", ["string"] = "string", ["thread"] = "thread",
   ["userdata"] = "userdata", ["emptytable"] = "table",
}

local function describe_leaf(t: Type): ReflectedType, string
   local kind = primitive_kinds[t.typename] or "unknown"
   local info: ReflectedType = { kind = kind, text = kind == "table" and "{}" or kind }
   local literal: string | number | boolean
   if t is types.StringType then
      (info as reflection.StringType).literal = t.literal
      literal = t.literal
   elseif t is types.BooleanType then
      (info as reflection.BooleanType).literal = t.literal
      literal = t.literal
   elseif t is types.IntegerType then
      (info as reflection.IntegerType).literal = t.literal as integer
      literal = t.literal
   elseif t is types.NumberType then
      (info as reflection.NumberType).literal = t.literal
      literal = t.literal
   end

   if literal == nil then return info, kind end
   info.text = type(literal) == "string" and quote(literal as string) or tostring(literal)
   local key = type(literal) == "number" and number_text(literal as number) or info.text
   return info, identity(kind, { key })
end

function type_reflection.describe(root: Type, resolve: function(NominalType): Type): Description
   local keys: {ReflectedType: string} = {}
   local active: {Type: boolean} = {}
   local active_declarations: {string: boolean} = {}
   local seen: {Type: ReflectedType} = {}
   local named_types: {string: ReflectedType} = {}
   local leaves: {string: ReflectedType} = {}
   local bindings: {string: string} = {}
   local generic_level = 0
   local visit: function(Type): ReflectedType

   local function remember(info: ReflectedType, key: string): ReflectedType
      keys[info] = key
      return info
   end

   local function list(ts: {Type}): {ReflectedType}, {string}, {string}
      local infos, ids, texts: {ReflectedType}, {string}, {string} = {}, {}, {}
      for i, t in ipairs(ts) do
         local info = visit(t)
         infos[i], ids[i], texts[i] = info, keys[info], info.text
      end
      return infos, ids, texts
   end

   local function fields(ts: {string: Type}, include_types: boolean): {string: ReflectedType}, string, string
      local infos, ids, texts: {string: ReflectedType}, {string}, {string} = {}, {}, {}
      for _, name in ipairs(sorted_keys(ts)) do
         local t = ts[name]
         if include_types or not t is types.TypeDeclType then
            local info = visit(t)
            infos[name] = info
            ids[#ids + 1] = identity("field", { name, keys[info] })
            texts[#texts + 1] = name .. ": " .. info.text
         end
      end
      return infos, identity("fields", ids), table.concat(texts, ", ")
   end

   visit = function(t: Type): ReflectedType
      local original = t
      if seen[original] then return seen[original] end
      local nominal: NominalType
      if t is NominalType then
         nominal = t
         t = t.resolved or resolve(t)
      end
      if t is types.TypeDeclType then
         local def = t.def
         if def is NominalType then return visit(def) end
         t = def
      elseif t is types.SelfType and t.display_type then
         return visit(t.display_type)
      end

      local name, declaration = declared_type(nominal and nominal.found and nominal.found.def or t, nominal)
      local arguments, argument_keys, argument_texts: {ReflectedType}, {string}, {string}
      if nominal and nominal.typevals and not t is types.GenericType then
         arguments, argument_keys, argument_texts = list(nominal.typevals as {Type})
      end
      local named_key = not t is types.GenericType and declaration
         and (argument_keys and identity(declaration, argument_keys) or declaration)
      local named_text = name and (argument_texts and name .. "<" .. table.concat(argument_texts, ", ") .. ">" or name)
      if active[t] or (declaration and active_declarations[declaration]) then
         local link: reflection.ReferenceType = {
            kind = "reference", name = name, text = named_text or t.typename, type_arguments = arguments,
         }
         return remember(link, named_key or identity("reference", { t.typename }))
      end
      if named_key and named_types[named_key] then
         seen[original] = named_types[named_key]
         return seen[original]
      end

      active[t] = true
      if declaration then active_declarations[declaration] = true end
      local info: ReflectedType
      local key = named_key
      if t is types.RecordLikeType then
         -- Nested type declarations belong to the declaration, not the value.
         local field_types, field_key, field_text = fields(t.fields, false)
         local kind: reflection.Kind = t.typename == "interface" and "interface" or "record"
         local record_info: reflection.RecordLikeType = {
            kind = kind, name = name, text = named_text or kind .. " {" .. field_text .. "}",
            fields = field_types, userdata = t.is_userdata or nil,
         }
         local meta_key = ""
         if t.meta_fields then record_info.metamethods, meta_key = fields(t.meta_fields, true) end
         if t.interface_list then record_info.interfaces = list(t.interface_list as {Type}) end
         if t.elements then record_info.element = visit(t.elements) end
         local item_keys: {string}
         if t.types then record_info.items, item_keys = list(t.types) end
         info = record_info
         key = key or identity(kind, {
            field_key, meta_key, record_info.element and keys[record_info.element] or "",
            item_keys and identity("items", item_keys) or "", tostring(record_info.userdata),
         })
      elseif t is types.EnumType then
         local enum_info: reflection.EnumType = {
            kind = "enum", name = name, text = named_text or "enum", values = sorted_keys(t.enumset),
         }
         info = enum_info
         key = key or identity(info.kind, enum_info.values)
      elseif t is types.ArrayType then
         local element = visit(t.elements)
         local array_info: reflection.ArrayType = { kind = "array", text = "{" .. element.text .. "}", element = element }
         info = array_info
         key = identity(info.kind, { keys[element] })
      elseif t is types.MapType then
         local key_type, value_type = visit(t.keys), visit(t.values)
         local map_info: reflection.MapType = {
            kind = "map", text = "{" .. key_type.text .. ": " .. value_type.text .. "}", key = key_type, value = value_type,
         }
         info = map_info
         key = identity(info.kind, { keys[key_type], keys[value_type] })
      elseif t is types.UnionType or t is types.PolyType or t is types.TupleTableType then
         local members, ids, texts = list((t as types.AggregateType).types)
         if t is types.TupleTableType then
            local tuple_info: reflection.TupleType = { kind = "tuple", text = "{" .. table.concat(texts, ", ") .. "}", items = members }
            info = tuple_info
         elseif t is types.UnionType then
            local union_info: reflection.UnionType = { kind = "union", text = table.concat(texts, " | "), alternatives = members }
            info = union_info
            table.sort(ids)
         else
            local overload_info: reflection.OverloadType = {
               kind = "overload", text = table.concat(texts, " & "), alternatives = members as {reflection.FunctionType},
            }
            info = overload_info
         end
         key = identity(info.kind, ids)
      elseif t is types.FunctionType then
         local parameters, parameter_keys, parameter_texts = list(t.args.tuple)
         local returns, return_keys, return_texts = list(t.rets.tuple)
         for i = t.min_arity + 1, #parameter_texts do
            if i ~= #parameter_texts or not t.args.is_va then parameter_texts[i] = "?" .. parameter_texts[i] end
         end
         local text = "function(" .. table.concat(parameter_texts, ", ") .. (t.args.is_va and "..." or "") .. ")"
         if #return_texts > 0 then
            text = text .. ": (" .. table.concat(return_texts, ", ") .. (t.rets.is_va and "..." or "") .. ")"
         end
         local fn: reflection.FunctionType = {
            kind = "function", text = text, parameters = parameters, returns = returns,
            required_parameters = t.min_arity, variadic_parameters = t.args.is_va or false,
            variadic_returns = t.rets.is_va or false, method = t.is_method or nil,
         }
         info = fn
         key = identity(info.kind, {
            identity("parameters", parameter_keys), identity("returns", return_keys),
            tostring(fn.required_parameters), tostring(fn.variadic_parameters), tostring(fn.variadic_returns),
         })
      elseif t is types.GenericType then
         generic_level = generic_level + 1
         local outer_seen, outer_named_types = seen, named_types
         seen, named_types = {}, {}
         local previous: {string: string} = {}
         for i, parameter in ipairs(t.typeargs) do
            previous[parameter.typearg] = bindings[parameter.typearg]
            bindings[parameter.typearg] = tostring(generic_level) .. "." .. tostring(i)
         end
         local parameters, parameter_keys, parameter_texts = list(t.typeargs as {Type})
         -- Let the body describe its own declaration if this is a generic record.
         if declaration then active_declarations[declaration] = nil end
         local body = visit(t.t)
         for _, parameter in ipairs(t.typeargs) do bindings[parameter.typearg] = previous[parameter.typearg] end
         generic_level = generic_level - 1
         seen, named_types = outer_seen, outer_named_types
         info = util.shallow_copy_table(body)
         info.type_parameters = parameters as {reflection.TypeParameter}
         local parameter_text = "<" .. table.concat(parameter_texts, ", ") .. ">"
         info.text = info.kind == "function" and "function" .. parameter_text .. body.text:sub(9) or body.text .. parameter_text
         key = identity("generic", { identity("parameters", parameter_keys), keys[body] })
      elseif t is types.TypeVarType or t is types.TypeArgType then
         local parameter = t is types.TypeVarType and t.typevar or (t as types.TypeArgType).typearg
         local parameter_name = parameter:gsub("@.*", "")
         local constraint = t.constraint and visit(t.constraint)
         local text = parameter_name
         if constraint and t is types.TypeArgType then
            text = text .. " is " .. constraint.text
         end
         local parameter_info: reflection.TypeParameter = { kind = "type_parameter", name = parameter_name, text = text, constraint = constraint }
         info = parameter_info
         key = identity(info.kind, { bindings[parameter] or parameter_name, constraint and keys[constraint] or "" })
      else
         info, key = describe_leaf(t)
         if not arguments then
            info = leaves[key] or info
            leaves[key] = info
         end
      end
      if arguments then info.type_arguments = arguments end
      active[t] = nil
      if declaration then active_declarations[declaration] = nil end
      seen[original] = info
      if named_key then named_types[named_key] = info end
      return remember(info, key)
   end

   return { info = visit(root), keys = keys }
end

function type_reflection.encode(description: Description): string
   local keys = description.keys
   local slots: {ReflectedType: integer} = {}
   local rows: {string} = {}
   local store: function(ReflectedType): integer

   local emit: function(any, {string})
   local function emit_table(tbl: {any: any}, parts: {string})
      parts[#parts + 1] = "{"
      for _, child in ipairs(tbl as {any}) do
         emit(child, parts)
         parts[#parts + 1] = ","
      end
      local named: {string} = {}
      for k in pairs(tbl) do
         if type(k) == "string" then named[#named + 1] = k as string end
      end
      table.sort(named)
      for _, k in ipairs(named) do
         parts[#parts + 1] = "[" .. quote(k) .. "]="
         emit(tbl[k], parts)
         parts[#parts + 1] = ","
      end
      parts[#parts + 1] = "}"
   end

   emit = function(value: any, parts: {string})
      local kind = type(value)
      if kind == "table" then
         if keys[value as ReflectedType] then
            parts[#parts + 1] = "d[" .. tostring(store(value as ReflectedType)) .. "]"
         else
            emit_table(value as {any: any}, parts)
         end
      elseif kind == "string" then
         parts[#parts + 1] = quote(value as string)
      elseif kind == "number" then
         parts[#parts + 1] = number_text(value as number)
      else
         parts[#parts + 1] = tostring(value)
      end
   end

   store = function(info: ReflectedType): integer
      if slots[info] then return slots[info] end
      local parts = { "(" }
      emit_table(info as {any: any}, parts)
      parts[#parts + 1] = "," .. quote(keys[info]) .. ")"
      local slot = #rows + 1
      rows[slot] = table.concat(parts)
      slots[info] = slot
      return slot
   end

   local root = store(description.info)
   -- The generator replaces the NUL with a fresh factory name. Literal NUL
   -- bytes in reflected strings are escaped by quote().
   if root == 1 then return "\0" .. rows[1] end
   local parts = { "(function(make) local d={}; " }
   for i, row in ipairs(rows) do
      parts[#parts + 1] = "d[" .. tostring(i) .. "]=make" .. row .. "; "
   end
   parts[#parts + 1] = "return d[" .. tostring(root) .. "] end)(\0)"
   return table.concat(parts)
end

return type_reflection
