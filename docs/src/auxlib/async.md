# Coroutine tasks with `auxlib.async`

An async scheduler runs coroutines on its Lua thread. Step it from the host
loop or give it a run-loop adapter. A task can wait for another task with
`:await()` or yield until a later turn with `async.yield()`.

```teal
local async = require("auxlib.async")
local scheduler = async.new()

local task = scheduler:start(function(): string
   async.yield()
   return "ready"
end)

scheduler:step()
scheduler:step()
print(task:result()) -- ready
```

`scheduler:step(limit?)` runs callbacks that were ready at the start of the
step and returns the number it ran. Work queued during that step runs on a
later turn. `async.configure(loop?)` sets the default scheduler for new root
tasks. `async.current()` returns the current task's scheduler, or the default
scheduler when called from the host.

## Starting and waiting for tasks

| Function | Behavior |
| --- | --- |
| `async.start(body)` | Start a task on the current scheduler. |
| `async.start_void(body)` | Start a task whose successful result is `nil`. |
| `scheduler:start(body)` | Start a task on the given scheduler. |
| `async.from_callback(register)` | Call `register(resolve, reject)` and settle the task on the first completion or registration error. `register` can return a cancellation function. |
| `async.sleep(seconds)` | Start a timer that fulfills with `nil`. The scheduler needs an adapter with timer support. |
| `async.all(tasks)` | Collect successful results at their input indices, or forward the first failure or cancellation. |
| `async.race(tasks)` | Forward the result of the first task to finish. Supply at least one task. |
| `async.timeout(task, seconds)` | Forward the result or reject the wait when the timer expires. |
| `async.nursery(body)` | Run a body with a scope. Use `scope:spawn(factory)` to supervise a child and cancel the other children if one fails. |

`async!` can decorate a local function as `local function name<async!>()`
or wrap a function literal as `async!(|| -> value)`. Calling the resulting
function starts a task that yields the original function's result. See the
[macro guide](../macros.md) for decorator syntax.

## Task handles and run loops

* `task:status()` returns `pending`, `fulfilled`, `rejected`, or `cancelled`.
* `task:await()` waits inside an async task on the same scheduler when the
  target is pending. It returns the value or raises the failure reason.
* `task:result()` reads a finished task's value and raises for a pending,
  rejected, or cancelled task.
* `task:cancel(reason?)` cancels a pending task and its children.
* `task:on_complete(callback)` queues a callback after completion and returns
  a function that can remove it before it runs.

A task waits for its children before it finishes. Waiting for another task
leaves that task's ownership with its original parent. `all`, `race`, and
`timeout` leave the other input tasks running when the wait ends.

An adapter implements `async.RunLoop`. Its optional `defer(callback)` posts
work for a later turn. Its optional `after(seconds, callback)` starts a
one-shot timer and can return a cancellation function. The host runs these
callbacks on the scheduler's Lua thread. See [the frame adapter](async_frame.md)
and [the `luv` adapter](async_luv.md).
