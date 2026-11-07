--#pragma strict_nil off
-- Runtime support for extras/struct.d.tl. The generated public API stays typed;
-- this module owns the dynamic boundary between properties and backing slots.
local type Object = {any:any}
local attach = setmetatable as function(any, any): any

local record struct_runtime
   record DeriveOptions
      ignore: {string:boolean}
      omit: {string:boolean}
      redact: {string:boolean}
      rename: {string:string}
      deep: boolean | {string:boolean}
   end
   record Field
      name: string
      required: boolean
      readonly: boolean
      array: boolean
      default: function(): any
      get: function(any): any
      set: function(any, any): any
      invariant: function(any): boolean
      message: string
   end

   record Descriptor
      name: string
      fields: {Field}
      positional: {string}
      auto: boolean
      derives: {string:DeriveOptions}
      invariant: function(any): boolean
      by_name: {string:Field}
      mt: {string:any}
   end

   define: function(any, any)
end

local type Field = struct_runtime.Field
local type Descriptor = struct_runtime.Descriptor
local descriptors = attach({}, {__mode = "kv"}) as {any:Descriptor}

local function fail(desc: Descriptor, field: Field, message: string)
   error(desc.name .. "." .. field.name .. ": " .. message, 0)
end

local function validate_field(desc: Descriptor, field: Field, value: any)
   if field.required and value == nil then fail(desc, field, "a value is required") end
   if field.invariant and not field.invariant(value) then
      fail(desc, field, field.message or "invariant failed")
   end
end

local function backing(field: Field): string
   return "_" .. field.name
end

local function transformed(desc: Descriptor, field: Field, current: any, value: any): any
   if field.required and value == nil then fail(desc, field, "a value is required") end
   if field.set then value = field.set(current, value) end
   validate_field(desc, field, value)
   return value
end

local function validate(desc: Descriptor, value: any)
   local object = value as Object
   if getmetatable(value) ~= desc.mt then error(desc.name .. ": expected a struct instance", 0) end
   for _, field in ipairs(desc.fields) do validate_field(desc, field, rawget(object, backing(field))) end
   if desc.invariant and not desc.invariant(value) then error(desc.name .. ": struct invariant failed", 0) end
end

local function construct(desc: Descriptor, values: {string:any}): any
   for key in pairs(values) do
      if not desc.by_name[key] then error(desc.name .. ": unknown constructor field '" .. key .. "'", 0) end
   end
   local out: {string:any} = {}
   for _, field in ipairs(desc.fields) do
      local value = values[field.name]
      local current: any
      if value == nil then
         if field.required then fail(desc, field, "a value is required") end
         value = field.default()
      end
      -- A required field has no previous value. Its initial candidate is also
      -- the initial `field` binding in a setter.
      current = value
      out[backing(field)] = transformed(desc, field, current, value)
   end
   local instance = setmetatable(out, desc.mt as metatable<{string:any}>)
   if desc.invariant and not desc.invariant(instance) then error(desc.name .. ": struct invariant failed", 0) end
   return instance
end

local function copy_value(value: any, seen: {any:any}): any
   if type(value) ~= "table" then return value end
   if seen[value] then return seen[value] end
   local object = value as Object
   local out: Object = {}
   seen[value] = out
   for key, child in pairs(object) do out[copy_value(key, seen)] = copy_value(child, seen) end
   return setmetatable(out, getmetatable(object))
end

local function equal_value(a: any, b: any, seen: {any:any}): boolean
   if rawequal(a, b) then return true end
   if type(a) ~= type(b) or type(a) ~= "table" then return false end
   local pairs_seen = seen[a] as {any:boolean}
   if pairs_seen and pairs_seen[b] then return true end
   if not pairs_seen then pairs_seen = {}; seen[a] = pairs_seen end
   pairs_seen[b] = true
   local left, right = a as Object, b as Object
   for key, value in pairs(left) do
      if not equal_value(value, rawget(right, key), seen) then return false end
   end
   for key in pairs(right) do if rawget(left, key) == nil then return false end end
   return true
end

local function quote_json(value: string): string
   return '"' .. value:gsub('[%z\1-\31\\"]', function(c: string): string
      local escapes: {string:string} = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
      return escapes[c] or string.format("\\u%04x", c:byte())
   end) .. '"'
end

local encode_json: function(any, {any:boolean}, ? boolean): string
encode_json = function(value: any, seen: {any:boolean}, force_array?: boolean): string
   local kind = type(value)
   if kind == "nil" then return "null" end
   if kind == "boolean" then return value and "true" or "false" end
   if kind == "string" then return quote_json(value as string) end
   if kind == "number" then
      if value ~= value or value == math.huge or value == -math.huge then error("Json: non-finite number", 0) end
      return tostring(value)
   end
   if kind ~= "table" then error("Json: unsupported value of type " .. kind, 0) end
   if seen[value] then error("Json: cyclic value", 0) end
   seen[value] = true
   local parts: {string} = {}
   local object = value as Object
   local desc = descriptors[getmetatable(object)]
   if desc then
      local options: struct_runtime.DeriveOptions = desc.derives.Json or {}
      for _, field in ipairs(desc.fields) do
         if not (options.omit and options.omit[field.name]) then
            local key: string = options.rename and options.rename[field.name] or field.name
            parts[#parts + 1] = quote_json(key) .. ":" .. encode_json(object[field.name], seen, field.array)
         end
      end
      seen[value] = nil
      return "{" .. table.concat(parts, ",") .. "}"
   end
   local count, length = 0, #(object as {any})
   local array = force_array or length > 0
   for key in pairs(object) do
      count = count + 1
      if type(key) ~= "number" or (key as number) % 1 ~= 0 or (key as number) < 1 or (key as number) > length then array = false end
   end
   if force_array and (not array or count ~= length) then error("Json: expected a dense array", 0) end
   if array then
      for i = 1, length do parts[#parts + 1] = encode_json(object[i], seen) end
   else
      local keys: {string} = {}
      for key in pairs(object) do
         if type(key) ~= "string" then error("Json: object keys must be strings", 0) end
         keys[#keys + 1] = key as string
      end
      table.sort(keys)
      for _, key in ipairs(keys) do parts[#parts + 1] = quote_json(key) .. ":" .. encode_json(object[key], seen) end
   end
   seen[value] = nil
   return (array and "[" or "{") .. table.concat(parts, ",") .. (array and "]" or "}")
end

local function show_value(value: any, seen: {any:boolean}): string
   if type(value) == "string" then return string.format("%q", value as string) end
   if type(value) ~= "table" then return tostring(value) end
   if seen[value] then return "<cycle>" end
   seen[value] = true
   local parts: {string} = {}
   local object = value as Object
   local desc = descriptors[getmetatable(object)]
   if desc then
      local options: struct_runtime.DeriveOptions = desc.derives.Show or {}
      for _, field in ipairs(desc.fields) do
         if not (options.omit and options.omit[field.name]) then
            local text = options.redact and options.redact[field.name] and "<redacted>" or show_value(object[field.name], seen)
            parts[#parts + 1] = field.name .. " = " .. text
         end
      end
   else
      local keys: {any} = {}
      for key in pairs(object) do keys[#keys + 1] = key end
      table.sort(keys, function(a: any, b: any): boolean return tostring(a) < tostring(b) end)
      for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. " = " .. show_value(object[key], seen) end
   end
   seen[value] = nil
   return (desc and desc.name or "") .. "{" .. table.concat(parts, ", ") .. "}"
end

function struct_runtime.define(class_value: any, description: any)
   local class = class_value as {string:any}
   local desc = description as Descriptor
   desc.by_name = {}
   for _, field in ipairs(desc.fields) do desc.by_name[field.name] = field end
   desc.mt = {
      __index = function(self: Object, key: string): any
         local field = desc.by_name[key]
         if field then
            local value = rawget(self as Object, backing(field))
            if field.get then return field.get(value) end
            return value
         end
         return class[key]
      end,
      __newindex = function(self: any, key: string, value: any)
         local field = desc.by_name[key]
         if not field then error(desc.name .. ": unknown property '" .. tostring(key) .. "'", 0) end
         if field.readonly then fail(desc, field, "property is readonly") end
         local candidate = transformed(desc, field, rawget(self as Object, backing(field)), value)
         if desc.invariant then
            local staged: {string:any} = {}
            for _, member in ipairs(desc.fields) do staged[backing(member)] = rawget(self as Object, backing(member)) end
            staged[backing(field)] = candidate
            local view = setmetatable(staged, desc.mt as metatable<{string:any}>)
            if not desc.invariant(view) then error(desc.name .. ": struct invariant failed", 0) end
         end
         rawset(self, backing(field), candidate)
      end,
   }
   descriptors[desc.mt] = desc
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
   if desc.derives.Equal then
      local options = desc.derives.Equal
      class.equal = function(self: any, other: any): boolean
         if getmetatable(self) ~= desc.mt or getmetatable(other) ~= desc.mt then return false end
         local seen: {any:any} = {}
         for _, field in ipairs(desc.fields) do
            if not (options.ignore and options.ignore[field.name]) and
               not equal_value(rawget(self as Object, backing(field)), rawget(other as Object, backing(field)), seen) then return false end
         end
         return true
      end
      desc.mt.__eq = class.equal
   end
   if desc.derives.Copy then
      local options = desc.derives.Copy
      class.copy = function(self: any): any
         local out: {string:any} = {}
         local seen: {any:any} = {[self] = out}
         for _, field in ipairs(desc.fields) do
            local value = rawget(self as Object, backing(field))
            if options.deep == true or (type(options.deep) == "table" and (options.deep as {string:boolean})[field.name]) then
               value = copy_value(value, seen)
            end
            out[backing(field)] = value
         end
         return attach(out, desc.mt)
      end
   end
   if desc.derives.Show then
      class.show = function(self: any): string return show_value(self, {}) end
      desc.mt.__tostring = class.show
   end
   if desc.derives.Json then
      class.to_json = function(self: any): string return encode_json(self, {}) end
   end
end

return struct_runtime
