#!/usr/bin/env -S tl run

local api_module = assert(arg[1], "missing argument: api module")
local output_file = assert(arg[2], "missing argument: output file")

local module_to_file: {string:string} = {}
local module_to_content: {string:string} = {}

local function scan_deps(k: string)
   if not module_to_content[k] then
      local fn = k:gsub("%.", "/") .. ".lua"
      module_to_file[k] = fn

      local f = assert(io.open(fn, "rb"))
      local modcontent = assert(f:read("*a"))
      assert(f:close())
      module_to_content[k] = modcontent

      -- Include the Teal modules. LuaJIT supplies its own modules.
      for requirement in modcontent:gmatch([[require%("(teal%.[^"]+)"%)]]) do
         scan_deps(requirement)
      end
   end
end

scan_deps(api_module)

local keys = {}
for k in pairs(module_to_content) do table.insert(keys, k) end
table.sort(keys)

-- Check the runtime before the bundle changes the module loader.
local content = {[[assert(jit and jit.version_num >= 20100, "Teal requires LuaJIT 2.1 or later")

]]}
for _, k in ipairs(keys) do
   local fn = module_to_file[k]
   local modcontent = module_to_content[k]
   table.insert(content,
string.format([[
-- module %s from %s
package.preload[%q] = function(...)
%s
end

]], k, fn, k, modcontent)
   )
end

table.insert(content,[[
return require("]] .. api_module .. [[")
]])

local f = assert(io.open(output_file, 'wb'))
assert(f:write(table.concat(content)))
assert(f:close())
