# Async functions and nurseries

Add the repository root to your Teal and Lua module search paths. Import the
runtime and the two macros in each Teal module that uses the syntax.

```lua
local tasks = require("extras.macros.async")
local macro (async)! = tasks.(async)!
local macro (await)! = tasks.(await)!
local type Scope = tasks.Scope
```

Given `load_profile` and `load_alerts` functions that return tasks, a dashboard
loader can run both requests concurrently.

```lua
local load_dashboard = async function(id: integer): Dashboard
   return await tasks.nursery(function(scope: Scope): Dashboard
      local profile = scope:spawn(async || -> await load_profile(id))
      local alerts = scope:spawn(async || -> await load_alerts(id))

      return { profile = await profile, alerts = await alerts }
   end)
end
```

Calling `load_dashboard(42)` schedules work and returns a `tasks.Task<Dashboard>`.
The `: Dashboard` annotation describes the result of the async body. An async
literal accepts ordinary or mini function syntax with fixed parameters and one
result. Use a record to return several values. Use `: nil` for an expression
whose only result has type `nil`, for example
`async ||: nil -> await tasks.sleep(0.5)`. A body with no value-returning
statement also produces `Task<nil>`. Async literals use concrete parameter and
result types in their own signatures.

`await task` calls `task:await()`. A pending task suspends the current managed
coroutine until the result is ready. A settled task returns its value or raises
its original error or cancellation reason. The runtime rejects pending awaits
across schedulers and dependency cycles.

A nursery waits for its spawned children before it completes, even if the body
returns first. A child failure rejects the nursery with that error and cancels
its other children. Cancelling a parent also cancels tasks it started. A task
passed in from outside the parent retains its original owner. Cancellation
discards suspended Lua execution and calls registered cancellation hooks for
pending host operations. It takes effect at scheduler boundaries for running Lua
code.

## Use your own event loop

`configure(adapter)` sets the default scheduler for future root tasks and
returns it. `new(adapter)` creates an independent scheduler. Use
`scheduler:start(function() ... end)` to start work on a specific scheduler.
Nested work inherits its parent's scheduler. `current()` returns the active
scheduler, or the default when called outside a task.

Connect your host's deferred callbacks and timers with two functions.

```lua
local scheduler = tasks.configure({
   defer = function(resume: tasks.Callback)
      host.post(resume)
   end,
   after = function(seconds: number, fire: tasks.Callback): tasks.Cancel | nil
      local timer = host.set_timer(seconds, fire)
      return function() host.cancel_timer(timer) end
   end,
})

local root = load_dashboard(42)
root:on_complete(function(done: tasks.Task<Dashboard>)
   if done:status() == "fulfilled" then
      render(done:result())
   else
      local _, reason = pcall(done.result, done)
      report_error(reason)
   end
end)
```

`host` stands for the loop you already use. `defer` must post the callback for a
later turn on the same Lua thread. `after` registers a one-shot timer in seconds
and may return a cancellation function. It is needed only for `tasks.sleep`.
Both hooks are optional. A frame loop or manually driven program can omit
`defer` and call `scheduler:step()` once per tick. `step(limit)` runs up to
`limit` callbacks from the current queue and returns the number it processed.
Callbacks queued during a step run in a later step.

## Wrap callback-based operations

`from_callback` registers a host operation immediately and returns its task.
The first call to `resolve(value)` or `reject(reason)` wins. If registration
throws before completing, the task rejects with that error. A cancellation
function is optional and runs if the task is cancelled while pending.

```lua
local function read_text(path: string): tasks.Task<string>
   return tasks.from_callback(function(resolve: function(string), reject: function(any)): tasks.Cancel | nil
      local request = host.read_text(path, resolve, reject)
      return function() host.cancel_request(request) end
   end)
end
```

Run host registration, completion, and cancellation on the owning Lua thread.
If a worker thread completes the operation, post its completion to that thread
through the host. Lua coroutines let other tasks run while a callback is pending.
A synchronous operation inside a coroutine still occupies the Lua thread.

`Task:status()` returns `"pending"`, `"fulfilled"`, `"rejected"`, or
`"cancelled"`. `Task:result()` reads a settled result from host code and raises
if the task failed, was cancelled, or is still pending. `Task:on_complete(fn)`
queues the callback on the scheduler and returns an unsubscribe function.
`Task:cancel(reason)` returns whether the task was pending and changed state.
