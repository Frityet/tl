

local source = debug.getinfo(1, "S").source:sub(2)
local here = source:match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../?.lua;" .. here .. "/../../?/init.lua;" .. package.path
local runner = require("extras.fuzz.runner")
local ok, result = xpcall(function() return runner.main(arg, here) end, debug.traceback)
runner.shutdown()
if not ok then io.stderr:write(tostring(result), "\n"); os.exit(2) end
os.exit(result)
