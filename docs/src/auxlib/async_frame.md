# Frame-driven tasks with `auxlib.async.frame`

Use this [async](async.md) adapter when the host supplies a frame delta in
seconds. Call `loop:tick(scheduler, dt)` from your update function to run
ready tasks and advance timers.

```teal
local async = require("auxlib.async")
local frame = require("auxlib.async.frame")

local loop = frame.new()
local scheduler = async.new(loop)
local task = scheduler:start(function(): string
   async.sleep(0.05):await()
   return "done"
end)

loop:tick(scheduler, 0.03)
loop:tick(scheduler, 0.03)
print(task:result()) -- done
```

| Function | Behavior |
| --- | --- |
| `frame.new()` | Create a `FrameLoop` with a clock that starts at zero. |
| `loop:tick(scheduler, dt, max_steps?)` | Run ready work, advance timers, then run ready work again. Each phase takes at most `max_steps` scheduler turns, which defaults to 16. Returns the number of ready callbacks run. |
| `loop:advance(dt)` | Advance the clock and fire due timers in deadline order. Negative deltas count as zero. Returns the number of timers fired. |
| `loop:now()` | Read elapsed time in seconds. |
| `loop:pending_timers()` | Count active timers that are waiting to fire. |
