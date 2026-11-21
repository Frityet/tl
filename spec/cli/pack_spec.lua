local util = require("spec.util")
local lfs = require("lfs")

local function capture(cmd, status)
   local pipe = assert(io.popen(cmd .. " 2>&1", "r"))
   local output = pipe:read("*a")
   util.assert_popen_close(status, pipe:close())
   return output
end

local function lua54()
   local ok = os.execute("pkg-config --exists lua5.4 && cc --version >/dev/null 2>&1")
   return ok == true or ok == 0
end

describe("tl pack", function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it("discovers the entry script in pretend mode without writing an executable", function()
      if util.os_sep ~= "/" then pending("POSIX host required"); return end
      local dir = util.write_tmp_dir(finally, {
         ["main.tl"] = 'local item = require("item")\nprint(item.value)',
         ["item.tl"] = 'return {value = "ok"}',
      })
      util.do_in(dir, function()
         local output = capture(util.tl_cmd("pack", {"--pretend"}, "-o", "my program"), 0)
         assert.matches("Would write: my program", output, 1, true)
         assert.is_nil(lfs.attributes("my program"))
      end)
   end)

   it("reports a missing runtime module in pretend mode", function()
      if util.os_sep ~= "/" then pending("POSIX host required"); return end
      local dir = util.write_tmp_dir(finally, {["main.lua"] = 'require "missing_pack_fixture"'})
      util.do_in(dir, function()
         local output = capture(util.tl_cmd("pack", {"--pretend"}), 1)
         assert.matches('cannot find source for module "missing_pack_fixture"', output, 1, true)
         assert.is_nil(lfs.attributes("main"))
      end)
   end)

   it("bundles transitive and explicitly included modules with default bytecode", function()
      if util.os_sep ~= "/" or not lua54() then pending("Lua 5.4 development files required"); return end
      local marker = "tl-pack-fixture-source-comment"
      local dir = util.write_tmp_dir(finally, {
         ["main.tl"] = 'local item = require("item")\nprint(item, arg[1], ...)\n-- ' .. marker,
         item = {["init.tl"] = 'return require("leaf")'},
         ["leaf.tl"] = [[
            local name = "extra"
            return require(name) as string
         ]],
         ["extra.lua"] = 'return "bundled"',
         isolated = {},
      })
      util.do_in(dir, function()
         local output = capture(util.tl_cmd("pack", "--lua-version", "5.4", "--module", "extra", "-o", "isolated/my program"), 0)
         assert.matches("Wrote: isolated/my program", output, 1, true)
         assert.not_matches(marker, util.read_file("isolated/my program"), 1, true)
         util.do_in("isolated", function()
            assert.equals("bundled\thello\thello\n", capture("'./my program' hello", 0))
         end)
      end)
   end)

   it("compresses both source and bytecode and preserves an existing output on failure", function()
      if util.os_sep ~= "/" or not lua54() then pending("Lua 5.4 development files required"); return end
      local pipe = assert(io.popen("cc -print-file-name=libz.a", "r"))
      local zlib = pipe:read("*l")
      pipe:close()
      if not zlib or not lfs.attributes(zlib) then pending("static zlib required"); return end
      local dir = util.write_tmp_dir(finally, {
         ["main.lua"] = 'print((require "part"))',
         ["part.lua"] = 'return "compressed"',
         ["invalid.lua"] = 'local =',
      })
      util.do_in(dir, function()
         for _, mode in ipairs({"--no-precompile", "--precompile"}) do
            local output = capture(util.tl_cmd("pack", "--lua-version", "5.4", mode, "--compress-source", "-o", "program"), 0)
            assert.matches("Wrote: program", output, 1, true)
            assert.equals("compressed\n", capture("./program", 0))
         end
         local output = capture(util.tl_cmd("pack", "--lua-version", "5.4", "invalid.lua", "-o", "program"), 1)
         assert.matches("encoding invalid.lua failed", output, 1, true)
         assert.equals("compressed\n", capture("./program", 0))
         for name in lfs.dir(".") do assert.not_matches("^%.tl%-pack%-", name) end
      end)
   end)
end)
