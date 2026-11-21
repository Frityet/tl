--#pragma strict_nil on

local type Async = require("auxlib.async")
local type RunLoop = Async.RunLoop

--- Connect an async scheduler to the default libuv loop from `luv`.
--- The host owns the loop. All adapters use the same loop as `luv.run()`.
local record Luv
   record LuvLoop is RunLoop where self.__name == "luv"
      __name: string
   end

   enum RunMode
      "default"
      "once"
      "nowait"
   end
end

-- Declare the part of the optional native module that the adapter calls.
local record Timer
   start: function(self, integer, integer, Async.Callback): integer | nil, string | nil
   close: function(self)
end

local record UV
   new_timer: function(): Timer | nil, string | nil
   run: function(Luv.RunMode | nil): boolean
   update_time: function()
end

local module_name = "luv"
local uv = require(module_name) as UV

local function schedule(milliseconds: integer, callback: Async.Callback): Async.Cancel
   assert(milliseconds >= 0 and milliseconds <= 2^53 - 1, "luv timer delay is out of range")
   local handle, err = uv.new_timer()
   local timer = assert(handle, err)
   local open = true
   local function close()
      if open then
         open = false
         timer:close()
      end
   end
   uv.update_time()
   local ok, result, message = pcall(timer.start, timer, milliseconds, 0, function()
      close()
      callback()
   end)
   if not ok or result == nil then
      close()
      error(ok and message or result, 0)
   end
   return close
end

--- Create a libuv run-loop adapter. Positive delays round up to a millisecond.
--- @return A run loop that posts callbacks and starts cancellable timers.
function Luv.new(): Luv.LuvLoop
   return {
      __name = "luv",
      defer = function(callback: Async.Callback)
         schedule(0, callback)
      end,
      after = function(seconds: number, callback: Async.Callback): Async.Cancel | nil
         return schedule(math.ceil(seconds * 1000.0), callback)
      end,
   }
end

--- Run the default libuv loop.
--- @param mode If nil or `"default"`, run until the loop stops or has no active work.
---   Use `"once"` to poll once or `"nowait"` to poll once without blocking.
--- @return True if the loop still has active work.
function Luv.run(mode?: Luv.RunMode): boolean
   return uv.run(mode)
end

return Luv
