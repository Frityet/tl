








local Async = { Loop = {}, Scheduler = {}, Task = {}, Scope = {}, Job = {} }


































































































local try_callback = pcall
local active = {}
local suspended = {}
local cancelled = "async task cancelled"

local function current_job()
   local co = coroutine.running()
   return co and active[co]
end

local function request_turn(scheduler)
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

local function enqueue(scheduler, callback)
   scheduler._tail = scheduler._tail + 1
   scheduler._ready[scheduler._tail] = callback
   request_turn(scheduler)
end

function Async.Scheduler:step(limit)
   assert(not current_job(), "async scheduler must be stepped from its host loop")
   assert(not self._stepping, "async scheduler is already stepping")
   assert(not limit or limit >= 0, "async step limit must be non-negative")


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




function Async.new(loop)
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




function Async.configure(loop)
   default_scheduler = Async.new(loop)
   return default_scheduler
end



function Async.current()
   local job = current_job()
   return job and job.scheduler or default_scheduler
end

local function new_job(scheduler, parent, supervised)
   if parent then
      assert(parent.scheduler == scheduler, "cannot start a child on a different async scheduler")
      if parent.status ~= "pending" then error(parent.value, 0) end
   end
   local job = {
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

local function run_cleanup(scheduler, cleanup)
   local ok, err = try_callback(cleanup)
   if not ok then enqueue(scheduler, function() error(err, 0) end) end
end

local function finish(job, status, value)
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

local function listen(job, callback)
   local run = callback
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

local function resume_job(job)
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

local function read_result(self)
   local job = self._job
   if job.status == "pending" then error("async task is pending", 2) end
   if job.status ~= "fulfilled" then error(job.value, 0) end
   return job.value
end

local function depends_on(target, job)
   local pending = { target }
   local seen = {}
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

local function await_task(self)
   local job = current_job()
   if job and job.status ~= "pending" then error(job.value, 0) end
   local target = self._job
   if target.status == "pending" then
      assert(job, "await of a pending task requires an async coroutine")
      assert(job.scheduler == target.scheduler, "cannot await a pending task on a different async scheduler")
      assert(not depends_on(target, job), "cyclic async task dependency")
      job.waiting_on = { target }
      job.unlisten = listen(target, function()
         job.waiting_on, job.unlisten = nil, nil
         resume_job(job)
      end)
      coroutine.yield(suspended)
   end
   return read_result(self)
end



function Async.yield()
   local job = assert(current_job(), "async.yield requires an async coroutine")
   if job.status ~= "pending" then error(job.value, 0) end
   enqueue(job.scheduler, function() resume_job(job) end)
   coroutine.yield(suspended)
end

local function task_handle(job)
   return {
      _job = job,
      await = await_task,
      result = read_result,
      status = function(self) return self._job.status end,
      cancel = function(self, reason)
         if self._job.status ~= "pending" then return false end
         if reason == nil then reason = cancelled end
         finish(self._job, "cancelled", reason)
         return true
      end,
      on_complete = function(self, callback)
         return listen(self._job, function() callback(self) end)
      end,
   }
end

local function start_job(scheduler, parent, supervised, body)
   local job = new_job(scheduler, parent, supervised)
   job.co = coroutine.create(body)
   enqueue(scheduler, function() resume_job(job) end)
   return job
end

function Async.Scheduler:start(body)
   return task_handle(start_job(self, current_job(), false, body))
end




function Async.start(body)
   return Async.current():start(body)
end




function Async.start_void(body)
   return task_handle(start_job(Async.current(), current_job(), false, function()
      body()
   end))
end

function Async.Scope:spawn(factory)
   local job = self._job
   assert(self._open and job.status == "pending", "async nursery scope is closed")
   assert(current_job() == job, "spawn must be called from its nursery body")
   return task_handle(start_job(job.scheduler, job, true, function()
      return factory():await()
   end))
end





function Async.nursery(body)
   return Async.start(function()
      local scope = { _job = assert(current_job()), _open = true, spawn = Async.Scope.spawn }
      local value = body(scope)
      scope._open = false
      return value
   end)
end

local function callback_job(register)
   local job = new_job(Async.current(), current_job(), false)
   local ok, cleanup = pcall(register,
   function(value) finish(job, "fulfilled", value) end,
   function(err) finish(job, "rejected", err) end)
   if not ok then
      finish(job, "rejected", cleanup)
   elseif job.status == "pending" then
      job.cancel_hook = cleanup
   elseif job.status == "cancelled" and cleanup then
      run_cleanup(job.scheduler, cleanup)
   end
   return job
end






function Async.from_callback(register)
   return task_handle(callback_job(register))
end

local function timer_for(scheduler, seconds)
   assert(seconds >= 0 and seconds < math.huge, "async timer delay must be finite and non-negative")
   local loop = scheduler._loop
   return assert(loop and loop.after, "async timers require a run loop with an after function")
end




function Async.sleep(seconds)
   local after = timer_for(Async.current(), seconds)
   return task_handle(callback_job(function(resolve)
      return after(seconds, function() resolve(nil) end)
   end))
end

local function watch_tasks(tasks, settle)
   local scheduler, parent = Async.current(), current_job()
   local targets = {}
   for index, task in ipairs(tasks) do
      local target = task._job
      if target.status == "pending" then
         assert(target.scheduler == scheduler, "cannot wait for a pending task on a different async scheduler")
         assert(not parent or not depends_on(target, parent), "cyclic async task dependency")
      end
      targets[index] = target
   end

   local job = new_job(scheduler, parent, false)
   local removals = {}
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





function Async.all(tasks)
   local remaining = #tasks
   local values = {}
   local job = watch_tasks(tasks, function(group, index, target)
      if target.status == "fulfilled" then
         values[index] = target.value
         remaining = remaining - 1
         if remaining == 0 then finish(group, "fulfilled", values) end
      else
         finish(group, target.status, target.value)
      end
   end)
   if #tasks == 0 then finish(job, "fulfilled", values) end
   return task_handle(job)
end

local function forward_result(job, _, target)
   finish(job, target.status, target.value)
end





function Async.race(tasks)
   assert(#tasks > 0, "async.race requires at least one task")
   return task_handle(watch_tasks(tasks, forward_result))
end






function Async.timeout(task, seconds)
   local target = task._job
   if target.status ~= "pending" then return task end

   local scheduler = Async.current()
   local after = timer_for(scheduler, seconds)
   local job = watch_tasks({ task }, forward_result)
   local remove_listeners = assert(job.unlisten)
   local stop_timer
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



























































































return Async
