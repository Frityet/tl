
local Tables = {}























function Tables.map(source, transform)
   local output = {}
   for idx, value in ipairs(source) do
      output[idx] = transform(value, idx)
   end
   return output
end





function Tables.sum(source, project)
   local total = 0
   for key, value in pairs(source) do
      total = total + project(value, key)
   end
   return total
end







function Tables.reduce(source, accumulator, step)
   for key, value in pairs(source) do
      accumulator = step(accumulator, value, key)
   end
   return accumulator
end





function Tables.filter(source, predicate)
   local output = {}
   for key, value in pairs(source) do
      if predicate(value, key) then output[key] = value end
   end
   return output
end





function Tables.any(source, predicate)
   for key, value in pairs(source) do
      if predicate(value, key) then return true end
   end
   return false
end





function Tables.all(source, predicate)
   for key, value in pairs(source) do
      if not predicate(value, key) then return false end
   end
   return true
end






function Tables.find(source, predicate)
   for key, value in pairs(source) do
      if predicate(value, key) then return value end
   end
   return nil
end





function Tables.group_by(source, select_group)
   local groups = {}
   for key, value in pairs(source) do
      local group_key = select_group(value, key)
      local group = groups[group_key]
      if not group then
         group = {}
         groups[group_key] = group
      end
      group[key] = value
   end
   return groups
end




function Tables.keys(source)
   local output = {}
   for key in pairs(source) do
      output[#output + 1] = key
   end
   return output
end




function Tables.values(source)
   local output = {}
   for _, value in pairs(source) do
      output[#output + 1] = value
   end
   return output
end





function Tables.tap(value, inspect)
   inspect(value)
   return value
end











































































































































return Tables
