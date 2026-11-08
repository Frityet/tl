--#pragma strict_nil on
local record Async
   type Callback = function()
   type Cancel = Callback

   enum Status
      "pending"
      "fulfilled"
      "rejected"
      "cancelled"
   end

   record Loop
      --- Post a callback for a later turn on the owning Lua thread; nil selects manual stepping.
      defer: (function(Callback)) | nil
      --- Register a one-shot timer in seconds and optionally return its cancellation callback.
      after: (function(number, Callback): Cancel | nil) | nil
   end

   record Scheduler
      --- Schedule a body producing one typed result, including nil when declared nullable.
      start: function<T>(self: Scheduler, body: function(): T): Task<T>
      --- Run up to the optional limit of ready callbacks and return the number processed.
      step: function(self: Scheduler, limit?: integer | nil): integer
      _loop: Loop | nil
      _ready: {Callback | nil}
      _head: integer
      _tail: integer
      _stepping: boolean
      _scheduled: boolean
   end

   record Task<T>
      --- Wait for completion inside a managed coroutine; preserve the task result type.
      await: function(self: Task<T>): T
      --- Read a settled result; raise if pending, rejected, or cancelled.
      result: function(self: Task<T>): T
      --- Return pending, fulfilled, rejected, or cancelled.
      status: function(self: Task<T>): Status
      --- Cancel a pending task and its owned work; nil uses the default cancellation reason.
      cancel: function(self: Task<T>, reason?: any): boolean
      --- Queue a completion callback and return an unsubscribe function.
      on_complete: function(self: Task<T>, callback: function(Task<T>)): Cancel
      _job: Job
   end

   record Scope
      --- Start a supervised child from this open nursery body; the nursery waits for its result.
      spawn: function<T>(self: Scope, factory: function(): Task<T>): Task<T>
      _job: Job
      _open: boolean
   end

   record Job
      scheduler: Scheduler
      parent: Job | nil
      children: {Job:boolean | nil}
      status: Status
      value: any
      co: thread | nil
      body_done: boolean
      listeners: {Callback:boolean | nil}
      waiting_on: Job | nil
      unlisten: Cancel | nil
      cancel_hook: Cancel | nil
   end
end

local type Job = Async.Job
local type Callback = Async.Callback
local type Cancel = Async.Cancel
local type Scheduler = Async.Scheduler
local type Scope = Async.Scope
local type Status = Async.Status
local type Task = Async.Task
local type Loop = Async.Loop

local try_callback = pcall as function(Callback): boolean, any
local active: {thread:Job | nil} = {}
local suspended = {}
local cancelled = "async task cancelled"

local function current_job(): Job | nil
   local co: thread | nil = coroutine.running()
   return co and active[co]
end

local function request_turn(scheduler: Scheduler)
   local loop = scheduler._loop
   local defer = loop and loop.defer
   if not defer or scheduler._scheduled or scheduler._stepping or scheduler._head > scheduler._tail then
      return
   end

   scheduler._scheduled = true
   local posting = true
   local ok, err = try_callback(function()
      defer(function()
         if posting then
            error("async loop.defer must schedule its callback for a later turn", 0)
         end
         scheduler._scheduled = false
         scheduler:step()
      end)
   end)
   posting = false
   if not ok then
      scheduler._scheduled = false
      error(err, 0)
   end
end

local function enqueue(scheduler: Scheduler, callback: Callback)
   scheduler._tail = scheduler._tail + 1
   scheduler._ready[scheduler._tail] = callback
   request_turn(scheduler)
end

--- Run callbacks from the current ready queue, leaving newly queued work for a later step.
--- @param limit Optional maximum number of callbacks; nil processes the current queue.
--- @return Number of callbacks processed. Call this from the host loop, outside a task.
function Async.Scheduler:step(limit?: integer): integer
   assert(not current_job(), "async scheduler must be stepped from its host loop")
   assert(not self._stepping, "async scheduler is already stepping")
   assert(not limit or limit >= 0, "async step limit must be non-negative")

   -- Take a snapshot so work enqueued by a callback runs on a later turn.
   local last = self._tail
   if limit then last = math.min(last, self._head + limit - 1) end
   local count = 0
   self._stepping = true
   while self._head <= last do
      local callback = assert(self._ready[self._head], "async ready queue has a gap")
      self._ready[self._head] = nil
      self._head = self._head + 1
      count = count + 1
      local ok, err = try_callback(callback)
      if not ok then
         self._stepping = false
         request_turn(self)
         error(err, 0)
      end
   end
   self._stepping = false
   if self._head > self._tail then
      self._head, self._tail = 1, 0
   end
   request_turn(self)
   return count
end

--- Create an independent scheduler with an optional host-loop adapter.
--- @param loop Optional defer and timer hooks; nil selects manual stepping.
--- @return A new scheduler without changing the default.
function Async.new(loop?: Loop): Scheduler
   return {
      _loop = loop,
      _ready = {},
      _head = 1,
      _tail = 0,
      _stepping = false,
      _scheduled = false,
      start = Async.Scheduler.start,
      step = Async.Scheduler.step,
   }
end

local default_scheduler = Async.new()

--- Configure the default scheduler and connect an optional host event loop.
---
---
--- `configure(adapter)` sets the default scheduler for future root tasks and
--- returns it. `new(adapter)` creates an independent scheduler. Use
--- `scheduler:start(function() ... end)` to start work on a specific scheduler.
--- Nested work inherits its parent's scheduler. `current()` returns the active
--- scheduler, or the default when called outside a task.
---
--- Connect your host's deferred callbacks and timers with two functions.
---
--- ```teal
--- local scheduler = tasks.configure({
---    defer = function(resume: tasks.Callback)
---       host.post(resume)
---    end,
---    after = function(seconds: number, fire: tasks.Callback): tasks.Cancel | nil
---       local timer = host.set_timer(seconds, fire)
---       return function() host.cancel_timer(timer) end
---    end,
--- })
---
--- local root = load_dashboard(42)
--- root:on_complete(function(done: tasks.Task<Dashboard>)
---    if done:status() == "fulfilled" then
---       render(done:result())
---    else
---       local _, reason = pcall(done.result, done)
---       report_error(reason)
---    end
--- end)
--- ```
---
--- `host` stands for the loop you already use. `defer` must post the callback for a
--- later turn on the same Lua thread. `after` registers a one-shot timer in seconds
--- and may return a cancellation function. It is needed only for `tasks.sleep`.
--- Both hooks are optional. A frame loop or manually driven program can omit
--- `defer` and call `scheduler:step()` once per tick. `step(limit)` runs up to
--- `limit` callbacks from the current queue and returns the number it processed.
--- Callbacks queued during a step run in a later step.
--- @param loop Optional host defer and timer hooks; nil selects manual stepping.
--- @return The new default scheduler for future root tasks.
function Async.configure(loop?: Loop): Scheduler
   default_scheduler = Async.new(loop)
   return default_scheduler
end

--- Return the active task scheduler, or the default scheduler outside a task.
--- @return The active task scheduler, or the default scheduler outside a task.
function Async.current(): Scheduler
   local job = current_job()
   return job and job.scheduler or default_scheduler
end

local function new_job(scheduler: Scheduler, parent: Job | nil, supervised: boolean): Job
   if parent then
      assert(parent.scheduler == scheduler, "cannot start a child on a different async scheduler")
      if parent.status ~= "pending" then error(parent.value, 0) end
   end
   local job: Job = {
      scheduler = scheduler,
      parent = parent,
      status = "pending",
      body_done = false,
      children = {},
      listeners = {},
   }
   if parent then parent.children[job] = supervised end
   return job
end

local function run_cleanup(scheduler: Scheduler, cleanup: Cancel)
   local ok, err = try_callback(cleanup)
   if not ok then enqueue(scheduler, function() error(err, 0) end) end
end

local function finish(job: Job, status: Status, value: any)
   if job.status ~= "pending" then return end
   job.status, job.value, job.co = status, value, nil
   job.waiting_on = nil
   local unlisten = job.unlisten
   job.unlisten = nil
   if unlisten then unlisten() end

   local parent = job.parent
   local supervised = parent and parent.children[job]
   if parent then parent.children[job] = nil end
   job.parent = nil

   if status ~= "fulfilled" then
      for child in pairs(job.children) do
         finish(child, "cancelled", value)
      end
   end
   local cleanup = job.cancel_hook
   job.cancel_hook = nil
   if cleanup and status == "cancelled" then
      run_cleanup(job.scheduler, cleanup)
   end

   if parent and parent.status == "pending" then
      if supervised and status == "rejected" then
         finish(parent, "rejected", value)
      elseif parent.body_done and not next(parent.children) then
         finish(parent, "fulfilled", parent.value)
      end
   end

   local listeners = job.listeners
   job.listeners = {}
   for listener in pairs(listeners) do
      enqueue(job.scheduler, listener)
   end
end

local function listen(job: Job, callback: Callback): Cancel
   local run: Callback | nil = callback
   local function listener()
      local fn = run
      run = nil
      if fn then fn() end
   end
   if job.status == "pending" then
      job.listeners[listener] = true
   else
      enqueue(job.scheduler, listener)
   end
   return function()
      run = nil
      job.listeners[listener] = nil
   end
end

local function resume_job(job: Job)
   if job.status ~= "pending" then return end
   local co = assert(job.co, "pending async coroutine is missing")
   active[co] = job
   local ok, value = coroutine.resume(co)
   active[co] = nil
   if job.status ~= "pending" then return end

   if not ok then
      finish(job, "rejected", value)
   elseif coroutine.status(co) == "dead" then
      job.co, job.body_done, job.value = nil, true, value
      if not next(job.children) then finish(job, "fulfilled", value) end
   elseif value ~= suspended then
      finish(job, "rejected", "async tasks must suspend through await")
   end
end

local function read_result<T>(self: Task<T>): T
   local job = self._job
   if job.status == "pending" then error("async task is pending", 2) end
   if job.status ~= "fulfilled" then error(job.value, 0) end
   return job.value as T
end

local function depends_on(target: Job, job: Job): boolean
   local pending = {target}
   local seen: {Job:boolean} = {}
   while #pending > 0 do
      local dependency = assert(table.remove(pending))
      if dependency == job then return true end
      if not seen[dependency] then
         seen[dependency] = true
         local waiting_on = dependency.waiting_on
         if waiting_on then
            table.insert(pending, waiting_on)
         end
         for child in pairs(dependency.children) do
            table.insert(pending, child)
         end
      end
   end
   return false
end

local function await_task<T>(self: Task<T>): T
   local job = current_job()
   if job and job.status ~= "pending" then error(job.value, 0) end
   local target = self._job
   if target.status == "pending" then
      assert(job, "await of a pending task requires an async coroutine")
      assert(job.scheduler == target.scheduler, "cannot await a pending task on a different async scheduler")
      assert(not depends_on(target, job), "cyclic async task dependency")
      job.waiting_on = target
      job.unlisten = listen(target, function()
         job.waiting_on, job.unlisten = nil, nil
         resume_job(job)
      end)
      coroutine.yield(suspended)
   end
   return read_result(self)
end

local function task_handle<T>(job: Job): Task<T>
   return {
      _job = job,
      await = await_task,
      result = read_result,
      status = function(self: Task<T>): Status return self._job.status end,
      cancel = function(self: Task<T>, reason?: any): boolean
         if self._job.status ~= "pending" then return false end
         if reason == nil then reason = cancelled end
         finish(self._job, "cancelled", reason)
         return true
      end,
      on_complete = function(self: Task<T>, callback: function(Task<T>)): Cancel
         return listen(self._job, function() callback(self) end)
      end,
   }
end

local function start_job(scheduler: Scheduler, parent: Job | nil, supervised: boolean, body: coroutine.Function): Job
   local job = new_job(scheduler, parent, supervised)
   job.co = coroutine.create(body)
   enqueue(scheduler, function() resume_job(job) end)
   return job
end

--- Schedule a typed coroutine task on this scheduler.
--- @param body Function producing one typed result; nullable results retain their nil type.
--- @return A pending task owned by this scheduler.
function Async.Scheduler:start<T>(body: function(): T): Task<T>
   return task_handle(start_job(self, current_job(), false, body))
end

--- Start a typed task on the current scheduler. Nested tasks belong to their parent.
--- @param body Function producing one result.
--- @return A task carrying that result type, including nil when declared.
function Async.start<T>(body: function(): T): Task<T>
   return Async.current():start(body)
end

--- Start a body with no return value and produce a Task<nil>.
--- @param body Function with no return value.
--- @return A Task<nil> representing the body completion.
function Async.start_void(body: function()): Task<nil>
   return task_handle(start_job(Async.current(), current_job(), false, function()
      body()
   end))
end

--- Spawn a supervised child inside the currently running nursery body.
--- @param factory Function creating the child task.
--- @return A task whose result the nursery waits for before completing.
function Async.Scope:spawn<T>(factory: function(): Task<T>): Task<T>
   local job = self._job
   assert(self._open and job.status == "pending", "async nursery scope is closed")
   assert(current_job() == job, "spawn must be called from its nursery body")
   return task_handle(start_job(job.scheduler, job, true, function(): T
      return factory():await()
   end))
end

--- Run a body with a structured scope and wait for its children before completing.
--- A child failure rejects the nursery and cancels sibling tasks. Parent cancellation
--- also cancels tasks started by that parent; external tasks keep their original owner.
--- @param body Function receiving the scope and returning the nursery result.
--- @return A task with the body result, settled after all supervised children.
function Async.nursery<T>(body: function(Scope): T): Task<T>
   return Async.start(function(): T
      local scope: Scope = { _job = assert(current_job()), _open = true, spawn = Async.Scope.spawn }
      local value = body(scope)
      scope._open = false
      return value
   end)
end

local function callback_job(register: function(function(any), function(any)): Cancel | nil): Job
   local job = new_job(Async.current(), current_job(), false)
   local ok, cleanup = pcall(register,
      function(value: any) finish(job, "fulfilled", value) end,
      function(err: any) finish(job, "rejected", err) end)
   if not ok then
      finish(job, "rejected", cleanup)
   elseif job.status == "pending" then
      job.cancel_hook = cleanup
   elseif job.status == "cancelled" and cleanup then
      run_cleanup(job.scheduler, cleanup)
   end
   return job
end

--- Wrap a callback-based host operation in a typed task.
---
---
--- `from_callback` registers a host operation immediately and returns its task.
--- The first call to `resolve(value)` or `reject(reason)` wins. If registration
--- throws before completing, the task rejects with that error. A cancellation
--- function is optional and runs if the task is cancelled while pending.
---
--- ```teal
--- local function read_text(path: string): tasks.Task<string>
---    return tasks.from_callback(function(resolve: function(string), reject: function(any)): tasks.Cancel | nil
---       local request = host.read_text(path, resolve, reject)
---       return function() host.cancel_request(request) end
---    end)
--- end
--- ```
---
--- Run host registration, completion, and cancellation on the owning Lua thread.
--- If a worker thread completes the operation, post its completion to that thread
--- through the host. Lua coroutines let other tasks run while a callback is pending.
--- A synchronous operation inside a coroutine still occupies the Lua thread.
---
--- `Task:status()` returns `"pending"`, `"fulfilled"`, `"rejected"`, or
--- `"cancelled"`. `Task:result()` reads a settled result from host code and raises
--- if the task failed, was cancelled, or is still pending. `Task:on_complete(fn)`
--- queues the callback on the scheduler and returns an unsubscribe function.
--- `Task:cancel(reason)` returns whether the task was pending and changed state.
--- @typearg T Task result type, which may explicitly include nil.
--- @param register Function receiving resolve and reject callbacks and optionally returning a cancellation hook.
--- @return A typed task settled by the first completion callback or registration failure.
function Async.from_callback<T>(register: function(function(T), function(any)): Cancel | nil): Task<T>
   return task_handle(callback_job(register))
end

--- Wait for a finite, non-negative duration using the current scheduler timer adapter.
--- Requires a loop.after hook; cancelling the task calls its optional timer cancellation hook.
--- @param seconds Delay in seconds.
--- @return A Task<nil> that fulfills when the timer fires.
function Async.sleep(seconds: number): Task<nil>
   local loop = Async.current()._loop
   local after = assert(loop and loop.after, "async.sleep requires a loop.after adapter")
   assert(seconds >= 0 and seconds < math.huge, "async sleep duration must be finite and non-negative")
   return task_handle(callback_job(function(resolve: function(any)): Cancel | nil
      return after(seconds, function() resolve(nil) end)
   end))
end

--- Await a task from a managed coroutine, suspending until it settles.
--- Returns its typed result, including nil when the task result is nullable.
--- Raises the original failure or cancellation reason. Pending awaits must use
--- the same scheduler and cannot form dependency cycles.
---
--- ```teal
--- local tasks = require("auxlib.async")
--- local macro (await)! = tasks.(await)!
--- -- Inside an async body: local value = await some_task
--- ```
--- @param task Task expression; evaluated once.
--- @return The task result. A pending task requires a managed async coroutine.
macro Async.(await)!(task: Expression): Operator<prefix, unary>
   return `($task):await()`
end

--- Run coroutine tasks with structured cancellation and nurseries.
---
--- Add the repository root to your Teal and Lua module search paths. Import the
--- runtime and the two macros in each Teal module that uses the syntax.
---
--- ```teal
--- local tasks = require("auxlib.async")
--- local macro (async)! = tasks.(async)!
--- local macro (await)! = tasks.(await)!
--- local type Scope = tasks.Scope
--- ```
---
--- Given `load_profile` and `load_alerts` functions that return tasks, a dashboard
--- loader can run both requests concurrently.
---
--- ```teal
--- local load_dashboard = async function(id: integer): Dashboard
---    return await tasks.nursery(function(scope: Scope): Dashboard
---       local profile = scope:spawn(async || -> await load_profile(id))
---       local alerts = scope:spawn(async || -> await load_alerts(id))
---
---       return { profile = await profile, alerts = await alerts }
---    end)
--- end
--- ```
---
--- Calling `load_dashboard(42)` schedules work and returns a `tasks.Task<Dashboard>`.
--- The `: Dashboard` annotation describes the result of the async body. An async
--- literal accepts ordinary or mini function syntax with fixed parameters and one
--- result. Use a record to return several values. Use `: nil` for an expression
--- whose only result has type `nil`, for example
--- `async ||: nil -> await tasks.sleep(0.5)`. A body with no value-returning
--- statement also produces `Task<nil>`. Async literals use concrete parameter and
--- result types in their own signatures.
---
--- `await task` calls `task:await()`. A pending task suspends the current managed
--- coroutine until the result is ready. A settled task returns its value or raises
--- its original error or cancellation reason. The runtime rejects pending awaits
--- across schedulers and dependency cycles.
---
--- A nursery waits for its spawned children before it completes, even if the body
--- returns first. A child failure rejects the nursery with that error and cancels
--- its other children. Cancelling a parent also cancels tasks it started. A task
--- passed in from outside the parent retains its original owner. Cancellation
--- discards suspended Lua execution and calls registered cancellation hooks for
--- pending host operations. It takes effect at scheduler boundaries for running Lua
--- code.
--- @param fn Function literal with concrete parameter types and at most one result type.
--- @return A function that schedules the body and returns Task<T>, or Task<nil> for a void body.
macro Async.(async)!(fn: Expression): Operator<prefix, unary>
   local B = BLOCK_INDEXES
   local F = B.FUNCTION
   assert(fn.kind == "function", "async expects a function literal")
   assert(not fn[F.TYPEARGS], "async function literals cannot declare type parameters")
   for _, arg in ipairs(fn[F.ARGS]) do
      assert(arg.tk ~= "...", "async function literals cannot declare variadic parameters")
   end
   local rets = fn[F.RETS]
   assert(not rets or not rets[1] or #rets[1] <= 1, "async functions declare one result type")
   local inner = clone(fn)
   inner[F.ARGS] = block("argument_list")
   inner.short_function = true
   local void = rets and rets[1] and rets[1][1] and rets[1][1].kind == "nil"
   if not rets or rets.tk ~= ":" then
      local function returns_value(node)
         if node.kind == "return" then
            local values = node[B.RETURN.EXPS]
            return #values > 1 or (#values == 1 and values[1].kind ~= "nil")
         elseif node.kind ~= "function" and node.kind ~= "local_function" and
            node.kind ~= "global_function" and node.kind ~= "record_function" then
            for key, child in pairs(node) do
               if type(key) == "number" and type(child) == "table" and child.kind and returns_value(child) then
                  return true
               end
            end
         end
         return false
      end
      void = not returns_value(inner[F.BODY])
   end
   local start = void and `require("auxlib.async").start_void($inner)` or `require("auxlib.async").start($inner)`
   local wrapper = `|| -> $start`
   wrapper[F.ARGS] = clone(fn[F.ARGS])
   return wrapper
end

return Async
