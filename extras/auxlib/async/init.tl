--#pragma strict_nil on

--- Schedule coroutine tasks on a Lua thread.
--- A scheduler runs ready callbacks. A host run loop can post callbacks and
--- start timers, or the host can step the scheduler by hand.
--- Tasks started inside a task use its scheduler and belong to that task.
--- A parent waits for its children. If a parent fails or is cancelled, it
--- cancels its children. Only a nursery propagates a supervised child's error.
--- Waiting for another task leaves its ownership unchanged.
local record Async
   type Callback = function()
   type Cancel = Callback

   enum Status
      "pending"
      "fulfilled"
      "rejected"
      "cancelled"
   end

   --- Supply functions that the scheduler can call on its Lua thread.
   --- Declare a record with `is RunLoop` to define a host adapter.
   interface RunLoop
      --- Post a callback for a later turn. If nil, the host must call `Scheduler:step()`.
      defer: (function(Callback)) | nil
      --- Start a one-shot timer with a delay in seconds. Return a cancel function
      --- if the host can stop the timer. If nil, the scheduler has no timer support.
      after: (function(number, Callback): Cancel | nil) | nil
   end

   --- Store run-loop functions in a table.
   record Loop is RunLoop
   end

   record Scheduler
      --- Schedule a function that returns one value.
      --- @param body Function to run in a coroutine.
      --- @return A pending task on this scheduler.
      start: function<T>(self: Scheduler, body: function(): T): Task<T>
      --- Run ready callbacks from the host loop. Callbacks queued during this
      --- step run in a later step.
      --- @param limit Maximum number of callbacks to run. If nil, run all callbacks that were ready at the start.
      --- @return Number of callbacks run.
      step: function(self: Scheduler, limit?: integer | nil): integer
      _loop: RunLoop | nil
      _ready: {Callback | nil}
      _head: integer
      _tail: integer
      _stepping: boolean
      _scheduled: boolean
   end

   record Task<T>
      --- Wait for a task to finish. To wait for a pending task, call this from
      --- a task on the same scheduler. The wait must not cause a dependency cycle.
      --- @return The task value. Raise the task's error or cancellation reason on failure.
      await: function(self: Task<T>): T
      --- Read the result of a fulfilled task. Raise an error if the task is pending.
      --- @return The task value. Raise the task's error or cancellation reason on failure.
      result: function(self: Task<T>): T
      --- Read the task state.
      --- @return `"pending"`, `"fulfilled"`, `"rejected"`, or `"cancelled"`.
      status: function(self: Task<T>): Status
      --- Cancel a pending task and its children.
      --- @param reason Error value to report. If nil, use the default cancellation message.
      --- @return True if the task was pending.
      cancel: function(self: Task<T>, reason?: any): boolean
      --- Queue a callback on the scheduler when the task finishes.
      --- @param callback Function that receives the completed task.
      --- @return A function that removes the callback before it runs.
      on_complete: function(self: Task<T>, callback: function(Task<T>)): Cancel
      _job: Job
   end

   record Scope
      --- Schedule a supervised child from the nursery body.
      --- @param factory Function that starts a task for the child to await.
      --- @return The child task. Its result is the result of the task from the factory.
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
      waiting_on: {Job} | nil
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
local type RunLoop = Async.RunLoop
local type Timer = function(number, Callback): Cancel | nil

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

--- Create a scheduler.
--- @param loop Host run loop. If nil, step the scheduler by hand.
--- @return A new scheduler.
function Async.new(loop?: RunLoop): Scheduler
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

--- Set the default scheduler for new root tasks. Existing tasks keep their scheduler.
--- @param loop Host run loop. If nil, step the scheduler by hand.
--- @return The new default scheduler.
function Async.configure(loop?: RunLoop): Scheduler
   default_scheduler = Async.new(loop)
   return default_scheduler
end

--- Get the scheduler for the current task.
--- @return The current task's scheduler, or the default scheduler outside a task.
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
      finish(job, "rejected", "async tasks must suspend through Task:await() or async.yield()")
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
      if dependency.status == "pending" and not seen[dependency] then
         seen[dependency] = true
         local waiting_on = dependency.waiting_on
         if waiting_on then
            for _, source in ipairs(waiting_on) do
               table.insert(pending, source)
            end
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
      job.waiting_on = {target}
      job.unlisten = listen(target, function()
         job.waiting_on, job.unlisten = nil, nil
         resume_job(job)
      end)
      coroutine.yield(suspended)
   end
   return read_result(self)
end

--- Pause the current task until a later scheduler step.
--- Call this from a task. Other ready callbacks can run before the task resumes.
function Async.yield()
   local job = assert(current_job(), "async.yield requires an async coroutine")
   if job.status ~= "pending" then error(job.value, 0) end
   enqueue(job.scheduler, function() resume_job(job) end)
   coroutine.yield(suspended)
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

function Async.Scheduler:start<T>(body: function(): T): Task<T>
   return task_handle(start_job(self, current_job(), false, body))
end

--- Schedule a function on the current scheduler.
--- @param body Function that returns one value.
--- @return A pending task with the result type of the function.
function Async.start<T>(body: function(): T): Task<T>
   return Async.current():start(body)
end

--- Schedule a function that returns no values.
--- @param body Function to run on the current scheduler.
--- @return A task that fulfills with nil.
function Async.start_void(body: function()): Task<nil>
   return task_handle(start_job(Async.current(), current_job(), false, function()
      body()
   end))
end

function Async.Scope:spawn<T>(factory: function(): Task<T>): Task<T>
   local job = self._job
   assert(self._open and job.status == "pending", "async nursery scope is closed")
   assert(current_job() == job, "spawn must be called from its nursery body")
   return task_handle(start_job(job.scheduler, job, true, function(): T
      return factory():await()
   end))
end

--- Run a function with a nursery scope. If a supervised child fails, reject
--- the nursery and cancel its other children.
--- @param body Function that receives a scope and returns a value.
--- @return A task that fulfills with the function's value after its children finish.
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

--- Start a host operation and wrap it in a task.
--- Run registration and completion on the scheduler's Lua thread.
--- @param register Function that receives `resolve(value)` and `reject(reason)`.
---   It can return a function to stop the operation if the task is cancelled.
--- @return A task that finishes on the first completion call or registration error.
function Async.from_callback<T>(register: function(function(T), function(any)): Cancel | nil): Task<T>
   return task_handle(callback_job(register))
end

local function timer_for(scheduler: Scheduler, seconds: number): Timer
   assert(seconds >= 0 and seconds < math.huge, "async timer delay must be finite and non-negative")
   local loop = scheduler._loop
   return assert(loop and loop.after, "async timers require a run loop with an after function")
end

--- Start a timer on the current scheduler. The run loop must supply `after`.
--- @param seconds Finite delay in seconds, zero or greater.
--- @return A task that fulfills with nil when the timer fires.
function Async.sleep(seconds: number): Task<nil>
   local after = timer_for(Async.current(), seconds)
   return task_handle(callback_job(function(resolve: function(any)): Cancel | nil
      return after(seconds, function() resolve(nil) end)
   end))
end

local function watch_tasks<T>(tasks: {Task<T>}, settle: function(Job, integer, Job)): Job
   local scheduler, parent = Async.current(), current_job()
   local targets: {Job} = {}
   for index, task in ipairs(tasks) do
      local target = task._job
      if target.status == "pending" then
         assert(target.scheduler == scheduler, "cannot wait for a pending task on a different async scheduler")
         assert(not parent or not depends_on(target, parent), "cyclic async task dependency")
      end
      targets[index] = target
   end

   local job = new_job(scheduler, parent, false)
   local removals: {Cancel} = {}
   job.waiting_on = targets
   job.unlisten = function()
      for _, remove in ipairs(removals) do remove() end
   end
   for index, target in ipairs(targets) do
      if target.status == "pending" then
         table.insert(removals, listen(target, function() settle(job, index, target) end))
      else
         settle(job, index, target)
         if job.status ~= "pending" then break end
      end
   end
   return job
end

--- Wait for all input tasks to fulfill. Forward the first error or cancellation.
--- The other input tasks keep running.
--- @param tasks Dense array of tasks. Pending tasks must use the current scheduler.
--- @return A task with the results at their input indices. Nil results leave gaps.
function Async.all<T>(tasks: {Task<T>}): Task<{T}>
   local remaining = #tasks
   local values: {T} = {}
   local job = watch_tasks(tasks, function(group: Job, index: integer, target: Job)
      if target.status == "fulfilled" then
         values[index] = target.value as T
         remaining = remaining - 1
         if remaining == 0 then finish(group, "fulfilled", values) end
      else
         finish(group, target.status, target.value)
      end
   end)
   if #tasks == 0 then finish(job, "fulfilled", values) end
   return task_handle(job)
end

local function forward_result(job: Job, _: integer, target: Job)
   finish(job, target.status, target.value)
end

--- Wait for the first input task to finish. If several have already finished,
--- select the first of them in the array. The other input tasks keep running.
--- @param tasks Nonempty dense array of tasks. Pending tasks must use the current scheduler.
--- @return A task with the selected task's value, error, or cancellation reason.
function Async.race<T>(tasks: {Task<T>}): Task<T>
   assert(#tasks > 0, "async.race requires at least one task")
   return task_handle(watch_tasks(tasks, forward_result))
end

--- Wait for a task with a time limit. The run loop must supply `after` if the
--- task is pending. The time limit does not cancel the input task.
--- @param task Task to wait for. A pending task must use the current scheduler.
--- @param seconds Finite delay in seconds, zero or greater, for a pending task.
--- @return A task that forwards the input result or rejects with `"async task timed out"`.
function Async.timeout<T>(task: Task<T>, seconds: number): Task<T>
   local target = task._job
   if target.status ~= "pending" then return task end

   local scheduler = Async.current()
   local after = timer_for(scheduler, seconds)
   local job = watch_tasks({task}, forward_result)
   local remove_listeners = assert(job.unlisten)
   local stop_timer: Cancel | nil
   local timer_fired = false
   job.unlisten = function()
      remove_listeners()
      if stop_timer and not timer_fired then run_cleanup(scheduler, stop_timer) end
   end
   local ok, cancel_timer = pcall(after, seconds, function()
      timer_fired = true
      if target.status == "pending" then
         finish(job, "rejected", "async task timed out")
      else
         forward_result(job, 1, target)
      end
   end)
   if not ok then
      finish(job, "rejected", cancel_timer)
   elseif job.status == "pending" then
      stop_timer = cancel_timer
   elseif cancel_timer and not timer_fired then
      run_cleanup(scheduler, cancel_timer)
   end
   return task_handle(job)
end

--- Make a function schedule a task when called.
--- Decorate a declaration with `local function name<async!>(): async.Task<Result>`.
--- Use `async!(||: async.Task<Result> -> value)` or `async!(|| -> value)` for literals.
--- @param source A local function declaration or a function literal with fixed parameters.
--- @return A function that starts a task.
macro Async.async!(source: Statement | Expression)
   local B = BLOCK_INDEXES
   local F = B.FUNCTION
   local fn = source
   if source.kind == "statements" then
      fn = #source == 1 and source[1]
   end
   assert(fn and (fn.kind == "local_function" or fn.kind == "function"),
      "async! expects a local function declaration or a function literal")
   local named = fn.kind == "local_function"
   assert(not fn[F.TYPEARGS], "async functions cannot declare type parameters")
   for _, arg in ipairs(fn[F.ARGS]) do
      assert(arg.tk ~= "...", "async functions cannot declare variadic parameters")
   end
   local rets = fn[F.RETS]
   local types = rets and rets[1]
   assert(not types or #types <= 1, "async functions declare at most one result type")
   local result_type = types and types[1]

   local function extract_task_inner(typ)
      local node = typ
      while node and node.kind == "paren" do
         node = node[B.PAREN.EXP]
      end
      if not node or node.kind ~= "nominal_type" or #node < 2 then
         return nil
      end
      local typeargs = node[#node]
      local name_part = node[#node - 1]
      if typeargs.kind ~= "type_list" or #typeargs ~= 1 then
         return nil
      end
      if name_part.kind ~= "identifier" or name_part.tk ~= "Task" then
         return nil
      end
      return typeargs[1]
   end

   local inner_type
   if result_type then
      inner_type = assert(extract_task_inner(result_type), "async functions must declare a Task<T> return type")
   elseif named then
      assert(false, "async functions must declare a Task<T> return type")
   end

   local inner = clone(fn)
   inner.kind = "function"
   inner[F.ARGS] = block("argument_list")
   inner[F.SHORT] = block("short_function")
   if named then inner[B.LOCAL_FUNCTION.CONST] = nil end
   if inner_type then
      inner[F.RETS][1][1] = clone(inner_type)
   end

   local void = inner_type and inner_type.kind == "nil"
   if not inner_type then
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
   if not named then
      local wrapper = `|| -> $start`
      wrapper[F.ARGS] = clone(fn[F.ARGS])
      if result_type then
         wrapper[F.RETS] = clone(fn[F.RETS])
      end
      return wrapper
   end

   local name = fn[B.LOCAL_FUNCTION.NAME]
   local declaration = ```
      local function __teal_async_function()
         return $start
      end
   ```
   local wrapper = declaration[1]
   wrapper[B.LOCAL_FUNCTION.NAME] = clone(name)
   wrapper[B.LOCAL_FUNCTION.CONST] = fn[B.LOCAL_FUNCTION.CONST]
   wrapper[F.ARGS] = clone(fn[F.ARGS])
   wrapper[F.RETS] = clone(fn[F.RETS])
   return declaration
end

return Async
