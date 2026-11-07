-- Import with:
-- local structs = require("extras.struct")
-- local macro (struct)! = structs.(struct)!
local record Struct end

macro Struct.(struct)!(definition: Expression): Operator<prefix, unary>
   local B = BLOCK_INDEXES
   local function node(kind, tk)
      local result = block(kind)
      result.tk = tk or ""
      return result
   end
   local function ident(name) return node("identifier", name) end
   local function str(value) return node("string", string.format("%q", value)) end
   local function boolean(value) return node("boolean", value and "true" or "false") end
   local used_names, visited = {}, {}
   local function collect_names(value)
      if visited[value] then return end
      visited[value] = true
      if value.tk then used_names[value.tk] = true end
      for key, child in pairs(value) do
         if type(key) == "number" and type(child) == "table" and child.kind then collect_names(child) end
      end
   end
   collect_names(definition)
   local function fresh(stem)
      local name, index = stem, 0
      while used_names[name] do index = index + 1; name = stem .. "_" .. index end
      used_names[name] = true
      return ident(name)
   end
   local function tuple(items)
      local out = node("tuple_type")
      out[1] = node("type_list")
      for _, item in ipairs(items) do table.insert(out[1], clone(item)) end
      return out
   end
   local function object(items)
      local out = node("literal_table")
      for _, item in ipairs(items) do
         local entry = node("literal_table_item", item[1])
         entry[B.LITERAL_TABLE_ITEM.KEY] = str(item[1])
         entry[B.LITERAL_TABLE_ITEM.VALUE] = clone(item[2])
         table.insert(out, entry)
      end
      return out
   end
   local function array(items)
      local out = node("literal_table")
      for i, value in ipairs(items) do
         local entry = node("literal_table_item")
         entry[B.LITERAL_TABLE_ITEM.KEY] = node("integer", tostring(i))
         entry[B.LITERAL_TABLE_ITEM.VALUE] = clone(value)
         table.insert(out, entry)
      end
      return out
   end
   local function name_value(value)
      if value.kind == "identifier" then return value.tk end
      if value.kind == "string" then
         local text = value.tk:match("^['\"]([%a_][%w_]*)['\"]$")
         if text then return text end
      end
      error("struct: expected an identifier or an identifier string", 0)
   end
   local function entries(value)
      assert(value and value.kind == "literal_table", "struct: expected a metadata table")
      local out = {}
      for _, item in ipairs(value) do
         local key = item[B.LITERAL_TABLE_ITEM.KEY]
         assert(key.kind == "string", "struct: metadata entries must have names")
         local name = name_value(key)
         assert(not out[name], "struct: duplicate metadata '" .. name .. "'")
         out[name] = item[B.LITERAL_TABLE_ITEM.VALUE]
      end
      return out
   end
   local function list(value)
      assert(value and value.kind == "literal_table", "struct: expected a list")
      local out = {}
      for _, item in ipairs(value) do
         assert(item[B.LITERAL_TABLE_ITEM.KEY].kind == "integer", "struct: expected a list")
         table.insert(out, item[B.LITERAL_TABLE_ITEM.VALUE])
      end
      return out
   end
   local function call(value)
      if value and value.kind == "op_funcall" then return value[B.OP.E1], value[B.OP.E2] end
      return nil, nil
   end
   local function nominal(value)
      local names = {}
      local function collect(part)
         if part.kind == "op_dot" then collect(part[B.OP.E1]); collect(part[B.OP.E2])
         else
            assert(part.kind == "identifier", "struct: expected an interface name")
            table.insert(names, part)
         end
      end
      collect(value)
      local out = node("nominal_type", names[1].tk)
      for _, part in ipairs(names) do table.insert(out, clone(part)) end
      return out, table.concat((function()
         local text = {}; for _, part in ipairs(names) do table.insert(text, part.tk) end; return text
      end)(), ".")
   end
   local function function_type(arguments, returns, optional)
      local out = node("function")
      local args = {}
      for i, typ in ipairs(arguments) do
         local argument = node("argument_type")
         argument[B.ARGUMENT_TYPE.TYPE] = clone(typ)
         if optional and optional[i] then argument[B.ARGUMENT_TYPE.OPTIONAL] = node("question", "?") end
         table.insert(args, argument)
      end
      out[B.FUNCTION_TYPE.ARGS] = tuple(args)
      out[B.FUNCTION_TYPE.RETS] = tuple(returns)
      return out
   end
   local function local_value(name, value, typ)
      local out = node("local_declaration")
      out[B.LOCAL_DECLARATION.VARS] = node("variable_list")
      out[B.LOCAL_DECLARATION.VARS][1] = clone(name)
      out[B.LOCAL_DECLARATION.EXPS] = node("expression_list")
      out[B.LOCAL_DECLARATION.EXPS][1] = clone(value)
      if typ then out[B.LOCAL_DECLARATION.DECL] = tuple({typ}) end
      return out
   end

   local name, arguments = call(definition)
   assert(name and arguments and #arguments == 1, "struct: expected Name { ... }")
   assert(name.kind == "identifier", "struct: generic parameters are deferred; expected a bare struct name")
   local schema = arguments[1]
   assert(schema.kind == "literal_table", "struct: expected a field table")
   local type_name = name.tk
   local self_type = nominal(name)
   local fields, by_name, traits, interfaces = {}, {}, {}, {}
   local auto = false
   local whole_invariant
   local header_seen = {}
   local reserved = {Init = true, from = true, validate = true}
   local builtin_methods = {Equal = "equal", Copy = "copy", Show = "show", Json = "to_json"}

   for _, item in ipairs(schema) do
      local typ = item[B.LITERAL_TABLE_ITEM.VALUE]
      local default = item[B.LITERAL_TABLE_ITEM.TYPED_VALUE]
      if default then
         local field_name = name_value(item[B.LITERAL_TABLE_ITEM.KEY])
         assert(not by_name[field_name], "struct: duplicate field '" .. field_name .. "'")
         local options, required = {}, false
         local target, args = call(default)
         if default.kind == "identifier" and default.tk == "required" then required = true
         elseif target and target.kind == "identifier" and target.tk == "required" then
            assert(#args == 1, "struct: required expects one options table")
            options = entries(args[1]); required = true
         elseif target and target.kind == "identifier" and target.tk == "property" then
            assert(#args == 1, "struct: property expects one options table")
            options = entries(args[1])
            assert(options.default, "struct: property needs a default (use required for required fields)")
            default = options.default
         end
         for key in pairs(options) do
            assert(key == "default" or key == "get" or key == "set" or key == "invariant" or key == "readonly" or key == "message",
               "struct: unknown property option '" .. key .. "'")
         end
         if options.readonly then assert(options.readonly.kind == "boolean", "struct: readonly must be a boolean literal") end
         if options.message then assert(options.message.kind == "string", "struct: message must be a string literal") end
         local field = {name = field_name, typ = typ, default = default, required = required, options = options}
         table.insert(fields, field); by_name[field_name] = field
      else
         assert(item[B.LITERAL_TABLE_ITEM.KEY].kind == "integer", "struct: fields require a type annotation and default")
         local target, args = call(typ)
         assert(target and target.kind == "identifier", "struct: expected implements(...), deriving {...}, constructor(auto), or invariant(...)")
         local header = target.tk
         assert(not header_seen[header], "struct: duplicate header '" .. header .. "'")
         header_seen[header] = true
         if header == "implements" then
            local implemented = #args == 1 and args[1].kind == "literal_table" and list(args[1]) or args
            for _, interface in ipairs(implemented) do table.insert(interfaces, interface) end
         elseif header == "deriving" then
            assert(#args == 1, "struct: deriving expects one table")
            traits = list(args[1])
         elseif header == "constructor" then
            assert(#args == 1 and args[1].kind == "identifier" and args[1].tk == "auto", "struct: constructor only accepts auto")
            auto = true; reserved.create = true
         elseif header == "invariant" then
            assert(#args == 1, "struct: invariant expects one callback")
            whole_invariant = args[1]
         else error("struct: unknown header '" .. header .. "'", 0) end
      end
   end

   local derives, custom_traits, derive_seen = {}, {}, {}
   local function field_set(value)
      local result, seen = {}, {}
      for _, entry in ipairs(list(value)) do
         local key = name_value(entry)
         assert(by_name[key], "struct: unknown field '" .. key .. "' in deriving options")
         assert(not seen[key], "struct: duplicate field '" .. key .. "' in deriving options")
         seen[key] = true; table.insert(result, {key, boolean(true)})
      end
      return object(result)
   end
   for _, trait in ipairs(traits) do
      local provider, args = call(trait)
      local options = {}
      if provider then
         assert(#args == 1, "struct: a deriving trait expects one options table")
         options = entries(args[1])
      else provider = trait end
      local builtin = provider.kind == "identifier" and builtin_methods[provider.tk]
      if builtin then
         assert(not derive_seen[provider.tk], "struct: duplicate deriving trait '" .. provider.tk .. "'")
         derive_seen[provider.tk] = true; reserved[builtin] = true
         local result = {}
         for key, value in pairs(options) do
            local allowed = (provider.tk == "Equal" and key == "ignore") or
               (provider.tk == "Copy" and key == "deep") or
               (provider.tk == "Show" and (key == "redact" or key == "omit")) or
               (provider.tk == "Json" and (key == "omit" or key == "rename"))
            assert(allowed, "struct: unknown " .. provider.tk .. " option '" .. key .. "'")
            if key == "rename" then
               local renamed, used = {}, {}
               for original, alias in pairs(entries(value)) do
                  assert(by_name[original], "struct: unknown renamed field '" .. original .. "'")
                  local text = name_value(alias)
                  assert(not used[text], "struct: duplicate Json output name '" .. text .. "'")
                  used[text] = true; table.insert(renamed, {original, str(text)})
               end
               table.sort(renamed, function(a, b) return a[1] < b[1] end)
               table.insert(result, {key, object(renamed)})
            elseif key == "deep" and value.kind == "boolean" then table.insert(result, {key, value})
            else table.insert(result, {key, field_set(value)}) end
         end
         if provider.tk == "Json" then
            local omitted, renamed, output_names = {}, {}, {}
            if options.omit then for _, entry in ipairs(list(options.omit)) do omitted[name_value(entry)] = true end end
            if options.rename then for key, value in pairs(entries(options.rename)) do renamed[key] = name_value(value) end end
            for _, field in ipairs(fields) do
               if not omitted[field.name] then
                  local key = renamed[field.name] or field.name
                  assert(not output_names[key], "struct: duplicate Json output name '" .. key .. "'")
                  output_names[key] = true
               end
            end
         end
         table.sort(result, function(a, b) return a[1] < b[1] end)
         table.insert(derives, {provider.tk, object(result)})
      else
         nominal(provider)
         for key in pairs(options) do assert(key == "implements" or key == "methods", "struct: unknown custom trait option '" .. key .. "'") end
         assert(options.methods, "struct: custom traits need an explicit methods list and an interface contract")
         assert(options.implements or #interfaces > 0, "struct: custom traits need an interface contract")
         if options.implements then
            for _, interface in ipairs(list(options.implements)) do table.insert(interfaces, interface) end
         end
         table.insert(custom_traits, {provider = provider, methods = list(options.methods)})
      end
   end
   table.sort(derives, function(a, b) return a[1] < b[1] end)
   for _, field in ipairs(fields) do
      assert(not reserved[field.name], "struct: reserved/generated member '" .. field.name .. "'")
      assert(not by_name["_" .. field.name], "struct: backing field collision for '" .. field.name .. "'")
   end

   local out = block("statements")
   local declaration = (```local record $name end```)[1]
   local record_type = declaration[B.LOCAL_TYPE.VALUE][B.NEWTYPE.TYPEDECL][B.TYPEDECL.TYPE]
   local members = record_type[B.RECORD.FIELDS]
   local function add_member(container, member_name, typ)
      local member = node("record_field")
      member[B.RECORD_FIELD.NAME] = ident(member_name)
      member[B.RECORD_FIELD.TYPE] = clone(typ)
      table.insert(container, member)
   end
   local interface_list, seen_interfaces = node("interface_list"), {}
   for _, interface in ipairs(interfaces) do
      local typ, key = nominal(interface)
      if not seen_interfaces[key] then table.insert(interface_list, typ); seen_interfaces[key] = true end
   end
   if #interface_list > 0 then record_type[B.RECORD.INTERFACES] = interface_list end
   local init_name = ident("Init")
   local input = (```local record $init_name end```)[1]
   local input_members = input[B.LOCAL_TYPE.VALUE][B.NEWTYPE.TYPEDECL][B.TYPEDECL.TYPE][B.RECORD.FIELDS]
   for _, field in ipairs(fields) do
      add_member(members, field.name, field.typ)
      local input_type = clone(field.typ)
      if not field.required then
         local union = node("union_type")
         union[1] = input_type; union[2] = nominal(ident("nil")); input_type = union
      end
      add_member(input_members, field.name, input_type)
   end
   table.insert(members, input)
   local input_type = nominal(`$name.Init`)
   add_member(members, "from", function_type({self_type, input_type}, {self_type}))
   add_member(members, "validate", function_type({self_type}, {self_type}))
   local positional, constructor_types, optional = {}, {self_type}, {}
   for _, required in ipairs({true, false}) do
      for _, field in ipairs(fields) do
         if field.required == required then
            table.insert(positional, str(field.name)); table.insert(constructor_types, field.typ)
            optional[#constructor_types] = not field.required
         end
      end
   end
   if auto then add_member(members, "create", function_type(constructor_types, {self_type}, optional)) end
   for _, trait in ipairs({"Equal", "Copy", "Show", "Json"}) do
      local method = builtin_methods[trait]
      if derive_seen[trait] then
         local args, returns = {self_type}, {self_type}
         if trait == "Equal" then table.insert(args, self_type); returns = {(nominal(ident("boolean")))}
         elseif trait == "Show" or trait == "Json" then returns = {(nominal(ident("string")))} end
         add_member(members, method, function_type(args, returns))
      end
   end
   table.insert(out, declaration)

   local setup = (```do end```)[1]
   local statements = setup[B.DO.BODY]
   local runtime = fresh("__struct_runtime")
   table.insert(statements, local_value(runtime, `require("extras.struct_runtime")`))
   local runtime_fields = {}
   for i, field in ipairs(fields) do
      local metadata = {{"name", str(field.name)}, {"required", boolean(field.required)},
         {"readonly", field.options.readonly or boolean(false)}, {"array", boolean(field.typ.kind == "array_type")}}
      if not field.required then
         local expression = field.default
         local callback = `|| -> $expression`
         local default_name = fresh("__struct_default_" .. i)
         table.insert(statements, local_value(default_name, callback, function_type({}, {field.typ})))
         table.insert(metadata, {"default", default_name})
      end
      for _, key in ipairs({"get", "invariant", "set"}) do
         local callback = field.options[key]
         if callback then
            assert(callback.kind == "function", "struct: " .. key .. " needs a function literal")
            assert(#callback[B.FUNCTION.ARGS] == 1, "struct: " .. key .. " needs exactly one value parameter")
            callback = clone(callback)
            local callback_name = fresh("__struct_" .. key .. "_" .. i)
            local args, returns = {field.typ}, {field.typ}
            if key == "invariant" then returns = {(nominal(ident("boolean")))} end
            if key == "set" then
               assert(callback[B.FUNCTION.ARGS][1].tk ~= "field", "struct: setter parameter cannot shadow the implicit 'field' binding")
               local current = fresh("__struct_current")
               local argument = node("argument", current.tk)
               table.insert(callback[B.FUNCTION.ARGS], 1, argument)
               args = {field.typ, field.typ}
               local body = block("statements")
               table.insert(body, local_value(ident("field"), current, field.typ))
               local scope = (```do end```)[1]
               scope[B.DO.BODY] = callback[B.FUNCTION.BODY]
               table.insert(body, scope)
               table.insert(body, (```return field```)[1])
               callback[B.FUNCTION.BODY] = body
            end
            table.insert(statements, local_value(callback_name, callback, function_type(args, returns)))
            table.insert(metadata, {key, callback_name})
         end
      end
      if field.options.message then table.insert(metadata, {"message", field.options.message}) end
      table.insert(runtime_fields, object(metadata))
   end
   local descriptor = {{"name", str(type_name)}, {"fields", array(runtime_fields)},
      {"positional", array(positional)}, {"auto", boolean(auto)}, {"derives", object(derives)}}
   if whole_invariant then
      assert(whole_invariant.kind == "function", "struct: invariant needs a function literal")
      local callback_name = fresh("__struct_invariant")
      table.insert(statements, local_value(callback_name, whole_invariant, function_type({self_type}, {(nominal(ident("boolean")))})))
      table.insert(descriptor, {"invariant", callback_name})
   end
   local description = object(descriptor)
   table.insert(statements, (`$runtime.define($name, $description)`))
   table.insert(out, setup)
   local supplied_methods, backing_names = {}, {}
   for _, field in ipairs(fields) do backing_names["_" .. field.name] = true end
   for _, trait in ipairs(custom_traits) do
      for _, method in ipairs(trait.methods) do
         local key = name_value(method)
         assert(not by_name[key] and not reserved[key] and not supplied_methods[key] and not backing_names[key], "struct: duplicate/reserved trait method '" .. key .. "'")
         supplied_methods[key] = true
         local provider, member = trait.provider, ident(key)
         table.insert(out, (```$name.$member = $provider.$member```)[1])
      end
   end
   return out
end

return Struct
