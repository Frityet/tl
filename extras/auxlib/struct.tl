--#pragma strict_nil on

local type Object = {any:any}

local record Struct
   record Field
      name: string
      required: boolean
      readonly: boolean
      --- Compute a fresh default for an omitted optional field; nil is permitted when declared.
      default: (function(): any) | nil
      --- Read the stored value and return the exposed value of the declared field type.
      get: (function(any): any) | nil
      --- Receive current and incoming values and return the candidate stored value.
      set: (function(any, any): any) | nil
      --- Validate a candidate field value and return whether it is acceptable.
      invariant: (function(any): boolean) | nil
      message: string | nil
   end

   record Descriptor
      name: string
      fields: {Field}
      positional: {string}
      auto: boolean
      --- Validate the complete instance or staged property-write view.
      invariant: (function(any): boolean) | nil
      by_name: {string:Field | nil}
      mt: {string:any}
   end

   --- Install generated constructors and property hooks for a struct descriptor.
   define: function(any, any)
end

local type Field = Struct.Field
local type Descriptor = Struct.Descriptor

local function fail(desc: Descriptor, field: Field, message: string)
   error(desc.name .. "." .. field.name .. ": " .. message, 0)
end

local function validate_field(desc: Descriptor, field: Field, value: any)
   if field.required and value == nil then fail(desc, field, "a value is required") end
   local invariant = field.invariant
   if invariant and not invariant(value) then
      fail(desc, field, field.message or "invariant failed")
   end
end

local function backing(field: Field): string
   return "_" .. field.name
end

local function transformed(desc: Descriptor, field: Field, current: any, value: any): any
   if field.required and value == nil then fail(desc, field, "a value is required") end
   local setter = field.set
   if setter then value = setter(current, value) end
   validate_field(desc, field, value)
   return value
end

local function validate_invariant(desc: Descriptor, instance: any)
   local invariant = desc.invariant
   if invariant and not invariant(instance) then error(desc.name .. ": struct invariant failed", 0) end
end

local function validate(desc: Descriptor, value: any)
   local object = value as Object
   if getmetatable(value) ~= desc.mt then error(desc.name .. ": expected a struct instance", 0) end
   for _, field in ipairs(desc.fields) do validate_field(desc, field, rawget(object, backing(field))) end
   validate_invariant(desc, value)
end

local function construct(desc: Descriptor, values: {string:any}): any
   for key in pairs(values) do
      if not desc.by_name[key] then error(desc.name .. ": unknown constructor field '" .. key .. "'", 0) end
   end
   local out: {string:any} = {}
   for _, field in ipairs(desc.fields) do
      local value = values[field.name]
      if value == nil then
         if field.required then fail(desc, field, "a value is required") end
         local default = assert(field.default, "struct default callback is missing")
         value = default()
      end
      -- A required field has no previous value. Its initial candidate is also
      -- the initial `field` binding in a setter.
      out[backing(field)] = transformed(desc, field, value, value)
   end
   local instance = setmetatable(out, desc.mt as metatable<{string:any}>)
   validate_invariant(desc, instance)
   return instance
end

--- Install the runtime behavior emitted by the struct macro.
--- Initializes constructors, validation, property accessors and backing storage on the class.
--- @param class_value Generated struct class receiving from, validate and optional create methods.
--- @param description Generated field descriptor, constructor metadata and optional record invariant.
function Struct.define(class_value: any, description: any)
   local class = class_value as {string:any}
   local desc = description as Descriptor
   desc.by_name = {}
   for _, field in ipairs(desc.fields) do desc.by_name[field.name] = field end
   desc.mt = {
      __index = function(self: Object, key: string): any
         local field = desc.by_name[key]
         if field then
            local value = rawget(self, backing(field))
            local getter = field.get
            if getter then return getter(value) end
            return value
         end
         return class[key]
      end,
      __newindex = function(self: any, key: string, value: any)
         local field = desc.by_name[key]
         if not field then return error(desc.name .. ": unknown property '" .. tostring(key) .. "'", 0) end
         if field.readonly then fail(desc, field, "property is readonly") end
         local candidate = transformed(desc, field, rawget(self as Object, backing(field)), value)
         if desc.invariant then
            local staged: {string:any} = {}
            for _, member in ipairs(desc.fields) do staged[backing(member)] = rawget(self as Object, backing(member)) end
            staged[backing(field)] = candidate
            local view = setmetatable(staged, desc.mt as metatable<{string:any}>)
            validate_invariant(desc, view)
         end
         rawset(self, backing(field), candidate)
      end,
   }
   class.from = function(_class: any, values: {string:any}): any return construct(desc, values) end
   class.validate = function(self: any): any validate(desc, self); return self end
   if desc.auto then
      class.create = function(_class: any, ...: any): any
         if select("#", ...) > #desc.positional then error(desc.name .. ": too many constructor arguments", 0) end
         local values: {string:any} = {}
         for i, name in ipairs(desc.positional) do values[name] = select(i, ...) end
         return construct(desc, values)
      end
   end
end

--- Declare typed structs with defaults, property hooks and invariants.
---
--- Import the operator explicitly.
---
--- ```teal
--- local structs = require("auxlib.struct")
--- local macro (struct)! = structs.(struct)!
--- ```
---
--- The macro and runtime live in `struct.tl`, with strict nil checking
--- enabled. The macro emits a native Teal record and typed callbacks. Generated
--- programs load `extras/auxlib/struct.lua` from their Lua module path.
---
--- ```teal
--- struct Counter {
---    constructor(auto);
---    value: integer = property {
---       default = 1;
---       invariant = x -> x > 0;
---       get = x -> x * 10;
---       set = new -> do field = new end;
---    };
--- }
---
--- local counter = Counter:create()
--- counter.value = 3
--- print(counter.value) -- 30
--- ```
---
--- ## Fields and construction
---
--- - A typed field takes an ordinary default expression, `required`,
---   `required { ... }`, or `property { default = value, ... }`.
--- - `:from { ... }` is always generated. Its input type, `Name.Init`, has
---   required fields and nullable entries for defaulted fields.
--- - `constructor(auto)` also generates `:create(...)`. Its arguments are the
---   required fields followed by optional defaulted fields, in declaration order
---   within each group. Omitted or `nil` inputs use the default; required fields
---   need a non-nil value. Defaults run separately for each instance.
--- - A handwritten `Name:create(...)` can call `self:from { ... }`. Omit
---   `constructor(auto)` for that form. There is no `constructor(manual)` mode.
--- - `implements(Interface, OtherInterface)` emits native interface conformance.
---   List the data fields in the struct body, and supply ordinary record methods
---   after the declaration.
--- - Generic struct declarations are deferred.
---
--- ## Hooks and storage
---
--- `get` and `invariant` each receive the stored field value. `set` takes the
--- incoming value and can assign the implicit mutable `field` binding, initially
--- the current stored value. During construction, its initial value is the input
--- or evaluated default. The setter's result is checked before writing the slot.
--- Callback parameters and results are checked against the declared field type;
--- invariants must return a boolean. `message` can customize an invariant error.
---
--- Instances use `_name` backing slots. `__index` reads the slot and runs its
--- getter, and `__newindex` runs the setter and checks before committing. Public
--- keys stay absent, so this also works on repeated direct writes such as
--- `employee.name = "ADA"`. Underscore backing slots are absent from the public
--- record type. `readonly = true` rejects public writes at runtime after construction.
---
--- An optional header `invariant (x -> x.minimum <= x.maximum)` checks the whole
--- record after construction and checks a staged view before a property write.
--- `instance:validate()` reruns the checks and returns the instance. Hooks cover
--- assignments to the property itself; in-place edits inside a table field are
--- ordinary table operations. Use validation hooks as predicates, since their
--- side effects are not rolled back.
---
--- To regenerate the Lua runtime, run this command from the repository root.
---
--- ```sh
--- ./tl gen --gen-target=5.1 --gen-compat=off -o extras/auxlib/struct.lua extras/auxlib/struct.tl
--- ```
--- @param definition Struct name and field table, including optional construction and invariant headers.
--- @return Statements declaring the typed record and initializing its runtime descriptor.
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
   local fields, by_name, interfaces = {}, {}, {}
   local auto = false
   local whole_invariant
   local header_seen = {}
   local reserved = {Init = true, from = true, validate = true}

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
         assert(target and target.kind == "identifier", "struct: expected implements(...), constructor(auto), or invariant(...)")
         local header = target.tk
         assert(not header_seen[header], "struct: duplicate header '" .. header .. "'")
         header_seen[header] = true
         if header == "implements" then
            local implemented = #args == 1 and args[1].kind == "literal_table" and list(args[1]) or args
            for _, interface in ipairs(implemented) do table.insert(interfaces, interface) end
         elseif header == "constructor" then
            assert(#args == 1 and args[1].kind == "identifier" and args[1].tk == "auto", "struct: constructor only accepts auto")
            auto = true; reserved.create = true
         elseif header == "invariant" then
            assert(#args == 1, "struct: invariant expects one callback")
            whole_invariant = args[1]
         else error("struct: unknown header '" .. header .. "'", 0) end
      end
   end

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
      field.input_type = input_type
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
            table.insert(positional, str(field.name)); table.insert(constructor_types, field.input_type)
            optional[#constructor_types] = not field.required
         end
      end
   end
   if auto then add_member(members, "create", function_type(constructor_types, {self_type}, optional)) end
   table.insert(out, declaration)

   local setup = (```do end```)[1]
   local statements = setup[B.DO.BODY]
   local runtime = fresh("__struct_module")
   table.insert(statements, local_value(runtime, `require("auxlib.struct")`))
   local runtime_fields = {}
   for i, field in ipairs(fields) do
      local metadata = {{"name", str(field.name)}, {"required", boolean(field.required)},
         {"readonly", field.options.readonly or boolean(false)}}
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
      {"positional", array(positional)}, {"auto", boolean(auto)}}
   if whole_invariant then
      assert(whole_invariant.kind == "function", "struct: invariant needs a function literal")
      local callback_name = fresh("__struct_invariant")
      table.insert(statements, local_value(callback_name, whole_invariant, function_type({self_type}, {(nominal(ident("boolean")))})))
      table.insert(descriptor, {"invariant", callback_name})
   end
   local description = object(descriptor)
   table.insert(statements, (`$runtime.define($name, $description)`))
   table.insert(out, setup)
   return out
end

return Struct
