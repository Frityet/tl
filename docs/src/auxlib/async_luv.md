# libuv tasks with `auxlib.async.luv`

Use this [async](async.md) adapter with the native `luv` Lua module. The
`luv` adapter posts ready callbacks and timers to the default libuv loop.
Adapters use the same loop as `luv.run()`.

```teal
local async = require("auxlib.async")
local luv = require("auxlib.async.luv")

local scheduler = async.new(luv.new())
local task = scheduler:start(function(): string
   async.sleep(0.01):await()
   return "timer fired"
end)

luv.run()
print(task:result()) -- timer fired
```

`luv.new()` returns a `LuvLoop` for `async.new` or `async.configure`. Timer
delays are in seconds. The adapter rounds positive delays up to the next
millisecond and closes each timer when it fires or is cancelled.

`luv.run(mode?)` returns whether there is still active work. The default mode
runs until the loop stops or runs out of work. Use `"once"` for one poll or
`"nowait"` for one poll without blocking.
