

local ffi = require("ffi")




local Bindings = {}

local registered = {}
local next_namespace = 0





function Bindings.bind(namespace, definition, names)
   local failures = {}
   for _, name in ipairs(names) do
      local ok, library = pcall(ffi.load, name)
      if ok then
         local prefix = registered[definition]
         if not prefix then


            next_namespace = next_namespace + 1
            prefix = "tl_auxlib_ffi_" .. tostring(next_namespace) .. "_"
            ffi.cdef((definition:gsub("%$", prefix)))
            registered[definition] = prefix
         end
         local symbol_prefix = assert(prefix)
         local proxy = {
            __index = function(_, symbol)
               return library[symbol_prefix .. symbol]
            end,
            __newindex = function(_, symbol, value)
               library[symbol_prefix .. symbol] = value
            end,
         }
         setmetatable(namespace, proxy)
         return
      end
      table.insert(failures, name .. " (" .. tostring(library) .. ")")
   end
   error("ffi: could not load a library: " .. table.concat(failures, ", "), 2)
end





function Bindings.string(value, length)
   if length then return ffi.string(value, length) end
   return ffi.string(value)
end



























































































































































































































return Bindings
