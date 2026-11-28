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
         return remember({ kind = "reference", name = name, text = named_text or t.typename, type_arguments = arguments },
         named_key or identity("reference", { t.typename }))
      end
      if named_key and named_types[named_key] then
         seen[original] = named_types[named_key]
         return seen[original]
      end

      active[t] = true
      if declaration then active_declarations[declaration] = true end
      local info = { name = name, type_arguments = arguments }
      local key = named_key
      if t.fields then
         local field_key, field_text
         info.kind = t.typename == "interface" and "interface" or "record"

         info.fields, field_key, field_text = fields(t.fields, false)
         local meta_key = ""
         if t.meta_fields then info.metamethods, meta_key = fields(t.meta_fields, true) end
         if t.interface_list then info.interfaces = list(t.interface_list) end
         if t.elements then info.element = visit(t.elements) end
         local item_keys
         if t.types then info.items, item_keys = list(t.types) end
         info.userdata = t.is_userdata or nil
         info.text = named_text or info.kind .. " {" .. field_text .. "}"
         key = key or identity(info.kind, {
            field_key, meta_key, info.element and keys[info.element] or "",
            item_keys and identity("items", item_keys) or "", tostring(info.userdata),
         })
      elseif t.typename == "enum" then
         info.kind = "enum"
         info.values = sorted_keys(t.enumset)
         info.text = named_text or "enum"
         key = key or identity(info.kind, info.values)
      elseif t.typename == "array" then
         info.kind = "array"
         info.element = visit(t.elements)
         info.text = "{" .. info.element.text .. "}"
         key = identity(info.kind, { keys[info.element] })
      elseif t.typename == "map" then
         info.kind = "map"
         info.key = visit(t.keys)
         info.value = visit(t.values)
         info.text = "{" .. info.key.text .. ": " .. info.value.text .. "}"
         key = identity(info.kind, { keys[info.key], keys[info.value] })
      elseif t.typename == "union" or t.typename == "poly" or t.typename == "tupletable" then
         local members, ids, texts = list((t).types)
         if t.typename == "tupletable" then
            info.kind, info.items = "tuple", members
            info.text = "{" .. table.concat(texts, ", ") .. "}"
         else
            info.kind = t.typename == "union" and "union" or "overload"
            info.alternatives = members
            info.text = table.concat(texts, t.typename == "union" and " | " or " & ")
            if t.typename == "union" then table.sort(ids) end
         end
         key = identity(info.kind, ids)
      elseif t.typename == "function" then
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
         info.kind = "type_parameter"
         info.name = parameter:gsub("@.*", "")
         info.constraint = t.constraint and visit(t.constraint)
         info.text = info.name
         if info.constraint and t.typename == "typearg" then
            info.text = info.text .. " is " .. info.constraint.text
         end
         key = identity(info.kind, { bindings[parameter] or info.name, info.constraint and keys[info.constraint] or "" })
      else
         info.kind = primitive_kinds[t.typename] or "unknown"
         info.text = info.kind == "table" and "{}" or info.kind
         if t.typename == "string" then
            info.literal = t.literal
         elseif t.typename == "number" or t.typename == "integer" or t.typename == "boolean" then
            info.literal = (t).literal
         end
         if info.literal ~= nil then
            local literal = info.literal
            info.text = type(literal) == "string" and quote(literal) or tostring(literal)
            key = identity(info.kind, { type(literal) == "number" and number_text(literal) or info.text })
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
