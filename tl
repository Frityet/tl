#!/usr/bin/env luajit

assert(jit and jit.version_num >= 20100, "Teal requires LuaJIT 2.1 or later")

-- Search for development modules in the script directory first.
do
   local script_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "."
   local save_package_path = package.path
   package.path = script_path .. "/?.lua;" .. script_path .. "/?/init.lua;" ..
      script_path .. "/extras/?.lua;" .. script_path .. "/extras/?/init.lua;" .. package.path

   pcall(require, "luarocks.loader")

   -- Make the public API available to programs that use tl run.
   require("teal")

   require("tlcli.main")({...})

   -- Restore the initial search path.
   package.path = save_package_path
end
