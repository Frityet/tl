--#pragma strict on
local lower = require("teal.gen.c_bootstrap").generate

local build = assert(arg[1])
local generated = assert(arg[2])
local function read(path: string): string
   local file = assert(io.open(path, "rb"))
   local data = assert(file:read("*a"))
   assert(file:close())
   return data
end

local function write(path: string, code: string)
   local old = io.open(path, "rb")
   if old then
      local text = old:read("*a")
      assert(old:close())
      if text == code then return end
   end
   local file = assert(io.open(path, "wb"))
   assert(file:write(code))
   assert(file:close())
end

local declarations: {string} = {'#include "tl_runtime.h"', ''}
local modules: {string} = {}
local argparse_path = assert(arg[3])
assert(argparse_path ~= "", "the argparse Lua source is required to build the C CLI")
local argparse_code, argparse_error = lower(read(argparse_path), "argparse.lua", "tl_module_argparse")
write(build .. "/tl_module_argparse.c", assert(argparse_code, argparse_error))
table.insert(declarations, "int tl_module_argparse(tl_State *L);")
table.insert(modules, '   tl_preload(L, "argparse", tl_module_argparse);')

for i = 4, #arg do
   local input = arg[i]
   local name = input ~= "extras/c/entry.tl" and input:gsub("%.[^.]+$", ""):gsub("/", ".") or nil
   local symbol = name and ("tl_module_" .. name:gsub("%.", "_")) or "tl_entry"
   local path = input == "teal/precompiled/default_env.lua" and input
      or generated .. "/" .. input:gsub("%.tl$", ".lua")
   local code, err = lower(read(path), input, symbol)
   write(build .. "/" .. symbol .. ".c", assert(code, err))
   if name then
      declarations[#declarations + 1] = ("int %s(tl_State *L);"):format(symbol)
      modules[#modules + 1] = ("   tl_preload(L, %q, %s);"):format(name, symbol)
   end
end

declarations[#declarations + 1] = [[
static int teal_alias(tl_State *L) {
   tl_getglobal(L, "require");
   tl_pushstring(L, "teal.init");
   tl_call(L, 1, 1);
   return 1;
}

void tl_register_modules(tl_State *L) {
   tl_preload(L, "teal", teal_alias);
]]
declarations[#declarations + 1] = table.concat(modules, "\n")
declarations[#declarations + 1] = "}\n"
write(build .. "/register.c", table.concat(declarations, "\n"))
