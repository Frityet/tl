local util = require("spec.util")

describe("conditional compilation in the CLI", function()
   it("shares defines and checked strict-nil settings with runtime dependencies", function()
      util.do_in(util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = 'return { defines = { MODE = "release", LOG = true } }',
         ["main.tl"] = [[
--#pragma strict_nil off
local answer = require("answer")
--#pragma strict_nil on
local n: integer = answer
print(n)
]],
         ["answer.tl"] = [==[
--[=[
#if not STRICT_NIL and TL_NG and MODE == "debug" and EXTRA and not LOG then
return 42
#end
]=]
]==],
      }), function()
         local process = io.popen(util.tl_cmd("run", { "-DMODE=debug" }, "-D", "EXTRA", "-DLOG=false", "main.tl") .. " 2>&1", "r")
         local output = process:read("*a")
         util.assert_popen_close(0, process:close())
         assert.matches("^42%s*$", output)
      end)
   end)
end)
