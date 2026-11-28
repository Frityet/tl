--#pragma strict_nil off
local types = require("teal.types")
local util = require("teal.util")
local sorted_keys = util.sorted_keys

local type Type = types.Type
local type NominalType = types.NominalType
local type TypeInfo = reflection.TypeInfo

local record type_reflection
   record Description
      info: TypeInfo
      keys: {TypeInfo: string}
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

function type_reflection.describe(root: Type, resolve: function(NominalType): Type): Description
   local keys: {TypeInfo: string} = {}
   local active: {Type: boolean} = {}
   local active_declarations: {string: boolean} = {}
   local seen: {Type: TypeInfo} = {}
   local named_types: {string: TypeInfo} = {}
   local leaves: {string: TypeInfo} = {}
   local bindings: {string: string} = {}
   local generic_level = 0
   local visit: function(Type): TypeInfo

   local function remember(info: TypeInfo, key: string): TypeInfo
      keys[info] = key
      return info
   end

   local function list(ts: {Type}): {TypeInfo}, {string}, {string}
      local infos, ids, texts: {TypeInfo}, {string}, {string} = {}, {}, {}
      for i, t in ipairs(ts) do
         local info = visit(t)
         infos[i], ids[i], texts[i] = info, keys[info], info.text
      end
      return infos, ids, texts
   end

   local function fields(ts: {string: Type}, include_types: boolean): {string: TypeInfo}, string, string
      local infos, ids, texts: {string: TypeInfo}, {string}, {string} = {}, {}, {}
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

   visit = function(t: Type): TypeInfo
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
      local arguments, argument_keys, argument_texts: {TypeInfo}, {string}, {string}
      if nominal and nominal.typevals and not t is types.GenericType then
         arguments, argument_keys, argument_texts = list(nominal.typevals as {Type})
      end
      local named_key = not t is types.GenericType and declaration
         and (argument_keys and identity(declaration, argument_keys) or declaration)
      local named_text = name and (argument_texts and name .. "<" .. table.concat(argument_texts, ", ") .. ">" or name)
      if active[t] or (declaration and active_declarations[declaration]) then
         return remember({ kind = "reference", name = name, text = named_text or t.typename, type_arguments = arguments },
            named_key or identity("reference", { t.typename }))
      end
      if named_key and named_types[named_key] then
         seen[original] = named_types[named_key]
         return seen[original]
      end

      active[t] = true
      if declaration then active_declarations[declaration] = true end
      local info: TypeInfo = { name = name, type_arguments = arguments }
      local key = named_key
      if t is types.RecordLikeType then
         local field_key, field_text: string, string
         info.kind = t.typename == "interface" and "interface" or "record"
         -- Nested type declarations belong to the declaration, not the value.
         info.fields, field_key, field_text = fields(t.fields, false)
         local meta_key = ""
         if t.meta_fields then info.metamethods, meta_key = fields(t.meta_fields, true) end
         if t.interface_list then info.interfaces = list(t.interface_list as {Type}) end
         if t.elements then info.element = visit(t.elements) end
         local item_keys: {string}
         if t.types then info.items, item_keys = list(t.types) end
         info.userdata = t.is_userdata or nil
         info.text = named_text or info.kind .. " {" .. field_text .. "}"
         key = key or identity(info.kind, {
            field_key, meta_key, info.element and keys[info.element] or "",
            item_keys and identity("items", item_keys) or "", tostring(info.userdata),
         })
      elseif t is types.EnumType then
         info.kind = "enum"
         info.values = sorted_keys(t.enumset)
         info.text = named_text or "enum"
         key = key or identity(info.kind, info.values)
      elseif t is types.ArrayType then
         info.kind = "array"
         info.element = visit(t.elements)
         info.text = "{" .. info.element.text .. "}"
         key = identity(info.kind, { keys[info.element] })
      elseif t is types.MapType then
         info.kind = "map"
         info.key = visit(t.keys)
         info.value = visit(t.values)
         info.text = "{" .. info.key.text .. ": " .. info.value.text .. "}"
         key = identity(info.kind, { keys[info.key], keys[info.value] })
      elseif t is types.UnionType or t is types.PolyType or t is types.TupleTableType then
         local members, ids, texts = list((t as types.AggregateType).types)
         if t is types.TupleTableType then
            info.kind, info.items = "tuple", members
            info.text = "{" .. table.concat(texts, ", ") .. "}"
         else
            info.kind = t is types.UnionType and "union" or "overload"
            info.alternatives = members
            info.text = table.concat(texts, t is types.UnionType and " | " or " & ")
            if t is types.UnionType then table.sort(ids) end
         end
         key = identity(info.kind, ids)
      elseif t is types.FunctionType then
         info.kind = "function"
         local parameters, parameter_keys, parameter_texts = list(t.args.tuple)
         local returns, return_keys, return_texts = list(t.rets.tuple)
         for i = t.min_arity + 1, #parameter_texts do
            if i ~= #parameter_texts or not t.args.is_va then parameter_texts[i] = "?" .. parameter_texts[i] end
         end
         info.parameters, info.returns = parameters, returns
         info.required_parameters = t.min_arity
         info.variadic_parameters, info.variadic_returns = t.args.is_va or false, t.rets.is_va or false
         info.method = t.is_method or nil
         info.text = "function(" .. table.concat(parameter_texts, ", ") .. (t.args.is_va and "..." or "") .. ")"
         if #return_texts > 0 then
            info.text = info.text .. ": (" .. table.concat(return_texts, ", ") .. (t.rets.is_va and "..." or "") .. ")"
         end
         key = identity(info.kind, {
            identity("parameters", parameter_keys), identity("returns", return_keys),
            tostring(info.required_parameters), tostring(info.variadic_parameters), tostring(info.variadic_returns),
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
         info.type_parameters = parameters
         local parameter_text = "<" .. table.concat(parameter_texts, ", ") .. ">"
         info.text = info.kind == "function" and "function" .. parameter_text .. body.text:sub(9) or body.text .. parameter_text
         key = identity("generic", { identity("parameters", parameter_keys), keys[body] })
      elseif t is types.TypeVarType or t is types.TypeArgType then
         local parameter = t is types.TypeVarType and t.typevar or (t as types.TypeArgType).typearg
         info.kind = "type_parameter"
         info.name = parameter:gsub("@.*", "")
         info.constraint = t.constraint and visit(t.constraint)
         info.text = info.name
         if info.constraint and t is types.TypeArgType then
            info.text = info.text .. " is " .. info.constraint.text
         end
         key = identity(info.kind, { bindings[parameter] or info.name, info.constraint and keys[info.constraint] or "" })
      else
         info.kind = primitive_kinds[t.typename] or "unknown"
         info.text = info.kind == "table" and "{}" or info.kind
         if t is types.StringType then
            info.literal = t.literal
         elseif t is types.NumberType or t is types.IntegerType or t is types.BooleanType then
            info.literal = (t as types.NumberType).literal
         end
         if info.literal ~= nil then
            local literal = info.literal
            info.text = type(literal) == "string" and quote(literal as string) or tostring(literal)
            key = identity(info.kind, { type(literal) == "number" and number_text(literal as number) or info.text })
         end
         key = key or info.kind
         info = leaves[key] or info
         leaves[key] = info
      end
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
   local slots: {TypeInfo: integer} = {}
   local rows: {string} = {}
   local store: function(TypeInfo): integer

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
         if keys[value as TypeInfo] then
            parts[#parts + 1] = "d[" .. tostring(store(value as TypeInfo)) .. "]"
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

   store = function(info: TypeInfo): integer
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
