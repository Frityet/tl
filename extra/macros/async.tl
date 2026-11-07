--#pragma strict_nil on
-- LuaJIT 2.1 coroutine tasks. See async.md for the host loop contract.
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
      defer: (function(Callback)) | nil
      after: (function(number, Callback): Cancel | nil) | nil
   end

   record Scheduler
      start: function<T>(self: Scheduler, body: function(): T): Task<T>
      step: function(self: Scheduler, limit?: integer | nil): integer
      _loop: Loop | nil
      _ready: {Callback | nil}
      _head: integer
      _tail: integer
      _stepping: boolean
      _scheduled: boolean
   end

   record Task<T>
      await: function(self: Task<T>): T
      result: function(self: Task<T>): T
      status: function(self: Task<T>): Status
      cancel: function(self: Task<T>, reason?: any): boolean
      on_complete: function(self: Task<T>, callback: function(Task<T>)): Cancel
      _job: Job
   end

   record Scope
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

function Async.configure(loop?: Loop): Scheduler
   default_scheduler = Async.new(loop)
   return default_scheduler
end

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
      local dependency = table.remove(pending)
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

function Async.Scheduler:start<T>(body: function(): T): Task<T>
   return task_handle(start_job(self, current_job(), false, body))
end

function Async.start<T>(body: function(): T): Task<T>
   return Async.current():start(body)
end

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

function Async.from_callback<T>(register: function(function(T), function(any)): Cancel | nil): Task<T>
   return task_handle(callback_job(register))
end

function Async.sleep(seconds: number): Task<nil>
   local loop = Async.current()._loop
   local after = assert(loop and loop.after, "async.sleep requires a loop.after adapter")
   assert(seconds >= 0 and seconds < math.huge, "async sleep duration must be finite and non-negative")
   return task_handle(callback_job(function(resolve: function(any)): Cancel | nil
      return after(seconds, function() resolve(nil) end)
   end))
end

macro Async.(await)!(task: Expression): Operator<prefix, unary>
   return `($task):await()`
end

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
   local start = void and `require("extra.macros.async").start_void($inner)` or `require("extra.macros.async").start($inner)`
   local wrapper = `|| -> $start`
   wrapper[F.ARGS] = clone(fn[F.ARGS])
   return wrapper
end

return Async
