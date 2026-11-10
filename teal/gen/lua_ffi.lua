local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table


local traversal = require("teal.traversal")

local lua_ffi = {}




local runtime = [[
(function()
   local require = require
   local unpack = table.unpack or unpack
   local ffi
   local function module()
      ffi = ffi or require('ffi')
      return ffi
   end
   local entries, functions = {}, {}
   local function convert(name, kind, nonnull, value)
      if kind == "string" or kind == "pointer" then
         if value == nil then
            if nonnull then error("C." .. name .. " returned a null pointer", 2) end
            return nil
         end
         if kind == "string" then return ffi.string(value) end
      elseif kind == "integer" and type(value) == "cdata" then
         local integer = tonumber(value)
         if integer < -9007199254740991 or integer > 9007199254740991 then
            error("C." .. name .. " returned an integer outside LuaJIT's safe integer range", 2)
         end
         return integer
      end
      return value
   end
   local C = setmetatable({}, {
      __index = function(_, name)
         local entry = entries[name]
         if not entry then return nil end
         if not entry[1] then return convert(name, entry[2], entry[3], ffi.C[name]) end
         local wrapper = functions[name]
         if not wrapper then
            local native, kind, nonnull = ffi.C[name], entry[2], entry[3]
            if kind == "void" then
               wrapper = function(...) native(...) end
            else
               wrapper = function(...) return convert(name, kind, nonnull, native(...)) end
            end
            functions[name] = wrapper
         end
         return wrapper
      end,
      __newindex = function()
         error("C symbols declared by ffi.cdef! are read-only", 2)
      end,
   })
   local function cdef(code, batch)
      module().cdef(code)
      for name, entry in pairs(batch) do entries[name] = entry end
   end
   local function call(fn, first, promotions, repeat_last, ...)
      local args, count = {...}, select("#", ...)
      local ffi = module()
      for i = first, count do
         local index = i - first + 1
         local promotion = promotions:sub(index, index)
         if promotion == "" and repeat_last then promotion = promotions:sub(-1) end
         local value = args[i]
         if value ~= nil then
            if promotion == "i" then
               local integer = ffi.cast("int", value)
               if tonumber(integer) ~= value then error("C variadic integer does not fit in int", 2) end
               args[i] = integer
            elseif promotion == "b" then
               args[i] = ffi.cast("int", value and 1 or 0)
            end
         end
      end
      return fn(unpack(args, 1, count))
   end
   local function istype(ctype, value)
      return module().istype(ctype, value)
   end
   return { C = C, cdef = cdef, call = call, istype = istype }
end)()
]]

function lua_ffi.local_name(ast)
   local used = {}
   traversal.traverse_nodes(used, ast, {
      allow_missing_cbs = true,
      after = function(names, node)
         if node.tk then names[node.tk] = true end
         return true
      end,
   }, {})
   local name = "_tl_typed_ffi"
   while used[name] do name = name .. "_" end
   return name
end

function lua_ffi.preamble(name)

   return "local " .. name .. " = " .. runtime:gsub("%s*\n%s*", " "):gsub(" $", "") .. "; "
end

function lua_ffi.declare(name, batch)
   local descriptors = {}
   for _, symbol in ipairs(batch.symbols) do
      if symbol.name and not symbol.typedef then
         local result = symbol.result
         local kind = result.mutable_char and "string" or result.kind
         table.insert(descriptors, ("[%q] = {%s, %q, %s}"):format(
         symbol.name, tostring(symbol.params ~= nil), kind, tostring(result.nullability == "_Nonnull")))

      end
   end
   local code = batch.code:gsub("\n", " ")
   return ("%s.cdef(%q, {%s})"):format(name, code, table.concat(descriptors, ", "))
end

return lua_ffi
