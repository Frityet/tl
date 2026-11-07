
local Utilities = {}










function Utilities.map(source, transform)
   local output = {}
   for key, value in pairs(source) do
      local mapped_key, mapped_value = transform(key, value)
      output[mapped_key] = mapped_value
   end
   return output
end

function Utilities.sum(source, project)
   local total = 0
   for key, value in pairs(source) do
      total = total + project(key, value)
   end
   return total
end

function Utilities.reduce(source, accumulator, step)
   for key, value in pairs(source) do
      accumulator = step(accumulator, key, value)
   end
   return accumulator
end

function Utilities.filter(source, predicate)
   local output = {}
   for key, value in pairs(source) do
      if predicate(key, value) then output[key] = value end
   end
   return output
end

function Utilities.any(source, predicate)
   for key, value in pairs(source) do
      if predicate(key, value) then return true end
   end
   return false
end

function Utilities.all(source, predicate)
   for key, value in pairs(source) do
      if not predicate(key, value) then return false end
   end
   return true
end

function Utilities.find(source, predicate)
   for key, value in pairs(source) do
      if predicate(key, value) then return value end
   end
   return nil
end

function Utilities.group_by(source, select_group)
   local groups = {}
   for key, value in pairs(source) do
      local group_key = select_group(key, value)
      local group = groups[group_key]
      if not group then
         group = {}
         groups[group_key] = group
      end
      group[key] = value
   end
   return groups
end

function Utilities.keys(source)
   local output = {}
   for key in pairs(source) do
      output[#output + 1] = key
   end
   return output
end

function Utilities.values(source)
   local output = {}
   for _, value in pairs(source) do
      output[#output + 1] = value
   end
   return output
end

function Utilities.tap(value, inspect)
   inspect(value)
   return value
end


























































































return Utilities
