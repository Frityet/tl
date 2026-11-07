




local Struct = { Field = {}, Descriptor = {} }



























local function fail(desc, field, message)
   error(desc.name .. "." .. field.name .. ": " .. message, 0)
end

local function validate_field(desc, field, value)
   if field.required and value == nil then fail(desc, field, "a value is required") end
   local invariant = field.invariant
   if invariant and not invariant(value) then
      fail(desc, field, field.message or "invariant failed")
   end
end

local function backing(field)
   return "_" .. field.name
end

local function transformed(desc, field, current, value)
   if field.required and value == nil then fail(desc, field, "a value is required") end
   local setter = field.set
   if setter then value = setter(current, value) end
   validate_field(desc, field, value)
   return value
end

local function validate_invariant(desc, instance)
   local invariant = desc.invariant
   if invariant and not invariant(instance) then error(desc.name .. ": struct invariant failed", 0) end
end

local function validate(desc, value)
   local object = value
   if getmetatable(value) ~= desc.mt then error(desc.name .. ": expected a struct instance", 0) end
   for _, field in ipairs(desc.fields) do validate_field(desc, field, rawget(object, backing(field))) end
   validate_invariant(desc, value)
end

local function construct(desc, values)
   for key in pairs(values) do
      if not desc.by_name[key] then error(desc.name .. ": unknown constructor field '" .. key .. "'", 0) end
   end
   local out = {}
   for _, field in ipairs(desc.fields) do
      local value = values[field.name]
      if value == nil then
         if field.required then fail(desc, field, "a value is required") end
         local default = assert(field.default, "struct default callback is missing")
         value = default()
      end


      out[backing(field)] = transformed(desc, field, value, value)
   end
   local instance = setmetatable(out, desc.mt)
   validate_invariant(desc, instance)
   return instance
end

function Struct.define(class_value, description)
   local class = class_value
   local desc = description
   desc.by_name = {}
   for _, field in ipairs(desc.fields) do desc.by_name[field.name] = field end
   desc.mt = {
      __index = function(self, key)
         local field = desc.by_name[key]
         if field then
            local value = rawget(self, backing(field))
            local getter = field.get
            if getter then return getter(value) end
            return value
         end
         return class[key]
      end,
      __newindex = function(self, key, value)
         local field = desc.by_name[key]
         if not field then return error(desc.name .. ": unknown property '" .. tostring(key) .. "'", 0) end
         if field.readonly then fail(desc, field, "property is readonly") end
         local candidate = transformed(desc, field, rawget(self, backing(field)), value)
         if desc.invariant then
            local staged = {}
            for _, member in ipairs(desc.fields) do staged[backing(member)] = rawget(self, backing(member)) end
            staged[backing(field)] = candidate
            local view = setmetatable(staged, desc.mt)
            validate_invariant(desc, view)
         end
         rawset(self, backing(field), candidate)
      end,
   }
   class.from = function(_class, values) return construct(desc, values) end
   class.validate = function(self) validate(desc, self); return self end
   if desc.auto then
      class.create = function(_class, ...)
         if select("#", ...) > #desc.positional then error(desc.name .. ": too many constructor arguments", 0) end
         local values = {}
         for i, name in ipairs(desc.positional) do values[name] = select(i, ...) end
         return construct(desc, values)
      end
   end
end





































































































































































































































































































return Struct
