local type Async = require("auxlib.async")
local type RunLoop = Async.RunLoop

--- Frame-stepped run-loop adapter for `auxlib.async`.
--- Agnostic to the host engine: any main loop (LOVR, Love2D, headless tests)
--- that provides a frame delta `dt` in seconds can drive `Async.sleep`,
--- `Async.timeout`, and async coroutines by calling `loop:tick(scheduler, dt)`.
---
--- ```teal
--- local async = require("auxlib.async")
--- local frame = require("auxlib.async.frame")
---
--- local loop = frame.new()
--- local scheduler = async.configure(loop)
--- local task = async.start(function(): string
---    async.sleep(0.05):await()
---    return "done"
--- end)
--- loop:tick(scheduler, 0.03)
--- loop:tick(scheduler, 0.03)
--- print(task:result()) -- "done"
--- ```
local record Frame
   record TimerEntry
      fire_at: number
      callback: Async.Callback
      cancelled: boolean
   end

   record FrameLoop is RunLoop where self.__name == "frame"
      __name: string
      advance: function(self: FrameLoop, dt: number): integer
      tick: function(self: FrameLoop, scheduler: Async.Scheduler, dt: number, max_steps?: integer): integer
      now: function(self: FrameLoop): number
      pending_timers: function(self: FrameLoop): integer
      _elapsed: number
      _timers: {TimerEntry}
   end
end

--- Advance internal clock by `dt` seconds and invoke due non-cancelled timers
--- in chronological order.
--- @param dt Frame delta time in seconds (negative values clamp to 0).
--- @return Number of timers fired.
function Frame.FrameLoop:advance(dt: number): integer
   self._elapsed = self._elapsed + math.max(0.0, dt)
   local due: {Frame.TimerEntry} = {}
   local pending: {Frame.TimerEntry} = {}

   for _, entry in ipairs(self._timers) do
      if not entry.cancelled then
         if entry.fire_at <= self._elapsed then
            table.insert(due, entry)
         else
            table.insert(pending, entry)
         end
      end
   end

   self._timers = pending
   table.sort(due, |a: Frame.TimerEntry, b: Frame.TimerEntry|: boolean -> a.fire_at < b.fire_at)

   local fired = 0
   for _, entry in ipairs(due) do
      if not entry.cancelled then
         fired = fired + 1
         entry.callback()
      end
   end
   return fired
end

--- Drain ready callbacks before and after advancing timers by `dt` seconds.
--- @param scheduler Scheduler configured with this loop.
--- @param dt Frame delta time in seconds.
--- @param max_steps Maximum scheduler turns to drain per phase (default 16).
--- @return Total ready callbacks executed across scheduler steps.
function Frame.FrameLoop:tick(scheduler: Async.Scheduler, dt: number, max_steps?: integer): integer
   local limit = max_steps or 16
   local total = 0
   for _ = 1, limit do
      local ran = scheduler:step()
      total = total + ran
      if ran == 0 then
         break
      end
   end
   self:advance(dt)
   for _ = 1, limit do
      local ran = scheduler:step()
      total = total + ran
      if ran == 0 then
         break
      end
   end
   return total
end

--- Return monotonic elapsed seconds tracked by this frame loop.
function Frame.FrameLoop:now(): number
   return self._elapsed
end

--- Return number of active non-cancelled timers waiting to fire.
function Frame.FrameLoop:pending_timers(): integer
   local count = 0
   for _, entry in ipairs(self._timers) do
      if not entry.cancelled then
         count = count + 1
      end
   end
   return count
end

--- Create a new frame-driven `Async.RunLoop` adapter.
--- @return A fresh `FrameLoop` supporting timers, `Async.sleep`, and `Async.timeout`.
function Frame.new(): Frame.FrameLoop
   local loop: Frame.FrameLoop
   loop = {
      __name = "frame",
      _elapsed = 0.0,
      _timers = {},
      after = function(seconds: number, callback: Async.Callback): Async.Cancel | nil
         assert(seconds >= 0.0 and seconds < math.huge, "frame timer delay must be finite and non-negative")
         local entry: Frame.TimerEntry = {
            fire_at = loop._elapsed + seconds,
            callback = callback,
            cancelled = false,
         }
         table.insert(loop._timers, entry)
         return function()
            entry.cancelled = true
         end
      end,
      advance = Frame.FrameLoop.advance,
      tick = Frame.FrameLoop.tick,
      now = Frame.FrameLoop.now,
      pending_timers = Frame.FrameLoop.pending_timers,
   }
   return loop
end

return Frame
