local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local types = require("teal.types")
local util = require("teal.util")
local sorted_keys = util.sorted_keys





local type_reflection = { Description = {} }














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

local function quote(value)
   return (string.format("%q", value):gsub("\\\n", "\\n"))
end

local function number_text(value)
   if value == math.huge then return "(1/0)" end
   if value == -math.huge then return "(-1/0)" end
   if value == 0 then return "0" end
   return string.format("%.17g", value)
end

local function identity(kind, parts)
   local out = { kind, "(" }
   for _, part in ipairs(parts) do
      out[#out + 1] = tostring(#part)
      out[#out + 1] = ":"
      out[#out + 1] = part
   end
   out[#out + 1] = ")"
   return table.concat(out)
end

local function declared_type(t, nominal)
   if t.typename == "generic" then t = t.t end
   if t.fields or t.typename == "enum" then
      local named = t
      if named.declname then
         local decl = nominal and nominal.found
         local where = t
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

local primitive_kinds = {
   ["any"] = "any", ["nil"] = "nil", ["boolean"] = "boolean", ["boolean_context"] = "boolean",
   ["integer"] = "integer", ["number"] = "number", ["string"] = "string", ["thread"] = "thread",
   ["userdata"] = "userdata", ["emptytable"] = "table",
}

local function describe_leaf(t)
   local kind = primitive_kinds[t.typename] or "unknown"
   local info = { kind = kind, text = kind == "table" and "{}" or kind }
   local literal
   if t.typename == "string" then
      (info).literal = t.literal
      literal = t.literal
   elseif t.typename == "boolean" then
      (info).literal = t.literal
      literal = t.literal
   elseif t.typename == "integer" then
      (info).literal = t.literal
      literal = t.literal
   elseif t.typename == "number" then
      (info).literal = t.literal
      literal = t.literal
   end

   if literal == nil then return info, kind end
   info.text = type(literal) == "string" and quote(literal) or tostring(literal)
   local key = type(literal) == "number" and number_text(literal) or info.text
   return info, identity(kind, { key })
end

function type_reflection.describe(root, resolve)
   local keys = {}
   local active = {}
   local active_declarations = {}
   local seen = {}
   local named_types = {}
   local leaves = {}
   local bindings = {}
   local generic_level = 0
   local visit

   local function remember(info, key)
      keys[info] = key
      return info
   end

   local function list(ts)
      local infos, ids, texts = {}, {}, {}
      for i, t in ipairs(ts) do
         local info = visit(t)
         infos[i], ids[i], texts[i] = info, keys[info], info.text
      end
      return infos, ids, texts
   end

   local function fields(ts, include_types)
      local infos, ids, texts = {}, {}, {}
      for _, name in ipairs(sorted_keys(ts)) do
         local t = ts[name]
         if include_types or not (t.typename == "typedecl") then
            local info = visit(t)
            infos[name] = info
            ids[#ids + 1] = identity("field", { name, keys[info] })
            texts[#texts + 1] = name .. ": " .. info.text
         end
      end
      return infos, identity("fields", ids), table.concat(texts, ", ")
   end

   visit = function(t)
      local original = t
      if seen[original] then return seen[original] end
      local nominal
      if t.typename == "nominal" then
         nominal = t
         t = t.resolved or resolve(t)
      end
      if t.typename == "typedecl" then
         local def = t.def
         if def.typename == "nominal" then return visit(def) end
         t = def
      elseif t.typename == "self" and t.display_type then
         return visit(t.display_type)
      end

      local name, declaration = declared_type(nominal and nominal.found and nominal.found.def or t, nominal)
      local arguments, argument_keys, argument_texts
      if nominal and nominal.typevals and not (t.typename == "generic") then
         arguments, argument_keys, argument_texts = list(nominal.typevals)
      end
      local named_key = not (t.typename == "generic") and declaration and
      (argument_keys and identity(declaration, argument_keys) or declaration)
      local named_text = name and (argument_texts and name .. "<" .. table.concat(argument_texts, ", ") .. ">" or name)
      if active[t] or (declaration and active_declarations[declaration]) then
         local link = {
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
      local info
      local key = named_key
      if t.fields then

         local field_types, field_key, field_text = fields(t.fields, false)
         local kind = t.typename == "interface" and "interface" or "record"
         local record_info = {
            kind = kind, name = name, text = named_text or kind .. " {" .. field_text .. "}",
            fields = field_types, userdata = t.is_userdata or nil,
         }
         local meta_key = ""
         if t.meta_fields then record_info.metamethods, meta_key = fields(t.meta_fields, true) end
         if t.interface_list then record_info.interfaces = list(t.interface_list) end
         if t.elements then record_info.element = visit(t.elements) end
         local item_keys
         if t.types then record_info.items, item_keys = list(t.types) end
         info = record_info
         key = key or identity(kind, {
            field_key, meta_key, record_info.element and keys[record_info.element] or "",
            item_keys and identity("items", item_keys) or "", tostring(record_info.userdata),
         })
      elseif t.typename == "enum" then
         local enum_info = {
            kind = "enum", name = name, text = named_text or "enum", values = sorted_keys(t.enumset),
         }
         info = enum_info
         key = key or identity(info.kind, enum_info.values)
      elseif t.typename == "array" then
         local element = visit(t.elements)
         local array_info = { kind = "array", text = "{" .. element.text .. "}", element = element }
         info = array_info
         key = identity(info.kind, { keys[element] })
      elseif t.typename == "map" then
         local key_type, value_type = visit(t.keys), visit(t.values)
         local map_info = {
            kind = "map", text = "{" .. key_type.text .. ": " .. value_type.text .. "}", key = key_type, value = value_type,
         }
         info = map_info
         key = identity(info.kind, { keys[key_type], keys[value_type] })
      elseif t.typename == "union" or t.typename == "poly" or t.typename == "tupletable" then
         local members, ids, texts = list((t).types)
         if t.typename == "tupletable" then
            local tuple_info = { kind = "tuple", text = "{" .. table.concat(texts, ", ") .. "}", items = members }
            info = tuple_info
         elseif t.typename == "union" then
            local union_info = { kind = "union", text = table.concat(texts, " | "), alternatives = members }
            info = union_info
            table.sort(ids)
         else
            local overload_info = {
               kind = "overload", text = table.concat(texts, " & "), alternatives = members,
            }
            info = overload_info
         end
         key = identity(info.kind, ids)
      elseif t.typename == "function" then
         local parameters, parameter_keys, parameter_texts = list(t.args.tuple)
         local returns, return_keys, return_texts = list(t.rets.tuple)
         for i = t.min_arity + 1, #parameter_texts do
            if i ~= #parameter_texts or not t.args.is_va then parameter_texts[i] = "?" .. parameter_texts[i] end
         end
         local text = "function(" .. table.concat(parameter_texts, ", ") .. (t.args.is_va and "..." or "") .. ")"
         if #return_texts > 0 then
            text = text .. ": (" .. table.concat(return_texts, ", ") .. (t.rets.is_va and "..." or "") .. ")"
         end
         local fn = {
            kind = "function", text = text, parameters = parameters, returns = returns,
            required_parameters = t.min_arity, variadic_parameters = t.args.is_va or false,
            variadic_returns = t.rets.is_va or false, method = t.is_method or nil,
         }
         info = fn
         key = identity(info.kind, {
            identity("parameters", parameter_keys), identity("returns", return_keys),
            tostring(fn.required_parameters), tostring(fn.variadic_parameters), tostring(fn.variadic_returns),
         })
      elseif t.typename == "generic" then
         generic_level = generic_level + 1
         local outer_seen, outer_named_types = seen, named_types
         seen, named_types = {}, {}
         local previous = {}
         for i, parameter in ipairs(t.typeargs) do
            previous[parameter.typearg] = bindings[parameter.typearg]
            bindings[parameter.typearg] = tostring(generic_level) .. "." .. tostring(i)
         end
         local parameters, parameter_keys, parameter_texts = list(t.typeargs)

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
      elseif t.typename == "typevar" or t.typename == "typearg" then
         local parameter = t.typename == "typevar" and t.typevar or (t).typearg
         local parameter_name = parameter:gsub("@.*", "")
         local constraint = t.constraint and visit(t.constraint)
         local text = parameter_name
         if constraint and t.typename == "typearg" then
            text = text .. " is " .. constraint.text
         end
         local parameter_info = { kind = "type_parameter", name = parameter_name, text = text, constraint = constraint }
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

function type_reflection.encode(description)
   local keys = description.keys
   local slots = {}
   local rows = {}
   local store

   local emit
   local function emit_table(tbl, parts)
      parts[#parts + 1] = "{"
      for _, child in ipairs(tbl) do
         emit(child, parts)
         parts[#parts + 1] = ","
      end
      local named = {}
      for k in pairs(tbl) do
         if type(k) == "string" then named[#named + 1] = k end
      end
      table.sort(named)
      for _, k in ipairs(named) do
         parts[#parts + 1] = "[" .. quote(k) .. "]="
         emit(tbl[k], parts)
         parts[#parts + 1] = ","
      end
      parts[#parts + 1] = "}"
   end

   emit = function(value, parts)
      local kind = type(value)
      if kind == "table" then
         if keys[value] then
            parts[#parts + 1] = "d[" .. tostring(store(value)) .. "]"
         else
            emit_table(value, parts)
         end
      elseif kind == "string" then
         parts[#parts + 1] = quote(value)
      elseif kind == "number" then
         parts[#parts + 1] = number_text(value)
      else
         parts[#parts + 1] = tostring(value)
      end
   end

   store = function(info)
      if slots[info] then return slots[info] end
      local parts = { "(" }
      emit_table(info, parts)
      parts[#parts + 1] = "," .. quote(keys[info]) .. ")"
      local slot = #rows + 1
      rows[slot] = table.concat(parts)
      slots[info] = slot
      return slot
   end

   local root = store(description.info)


   if root == 1 then return "\0" .. rows[1] end
   local parts = { "(function(make) local d={}; " }
   for i, row in ipairs(rows) do
      parts[#parts + 1] = "d[" .. tostring(i) .. "]=make" .. row .. "; "
   end
   parts[#parts + 1] = "return d[" .. tostring(root) .. "] end)(\0)"
   return table.concat(parts)
end

return type_reflection
