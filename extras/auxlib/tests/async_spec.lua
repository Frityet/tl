local tl = require('teal.api.v2')
local async = require('auxlib.async')

local imports = [[
local tasks = require("auxlib.async")
local macro async! = tasks.async!
local type Scope = tasks.Scope
]]

local function compile(source)
   local ast, syntax_errors = tl.parse(imports .. source, 'async-fixture.tl')
   assert.same({}, syntax_errors)
   return tl.check(ast, 'async-fixture.tl', {
      gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
   })
end

local function run(source)
   local result = compile(source)
   assert.same({}, result.type_errors)
   local output, err = tl.generate(result.ast, '5.1')
   assert.is_nil(err)
   return assert(loadstring(output), output)()
end

local function drain(loop)
   for _ = 1, 100 do
      if loop:step() == 0 then return end
   end
   error('scheduler did not go idle')
end

describe('auxlib async macros', function()
   it('runs the dashboard nursery and starts both requests before either completes', function()
      assert.same({'profile:7', 'alert:7'}, {run([[
         local record Dashboard
            profile: string
            alerts: {string}
         end

         local function load_profile<async!>(id: integer): tasks.Task<string>
            tasks.sleep(0):await()
            return "profile:" .. tostring(id)
         end
         local load_alerts = async!(|id: integer|: tasks.Task<{string}> -> do
            tasks.sleep(0):await()
            return {"alert:" .. tostring(id)}
         end)

         local function load_dashboard<tasks.async!>(id: integer): tasks.Task<Dashboard>
            return tasks.nursery(function(scope: Scope): Dashboard
               local profile = scope:spawn(|| -> load_profile(id))
               local alerts = scope:spawn(async!(|| -> load_alerts(id):await()))
               return { profile = profile:await(), alerts = alerts:await() }
            end):await()
         end

         local timers: {tasks.Callback} = {}
         local record TestLoop is tasks.RunLoop where self.__name == "test"
            __name: string
         end
         local adapter: TestLoop = {
            __name = "test",
            after = function(_: number, callback: tasks.Callback): tasks.Cancel | nil
               table.insert(timers, callback)
               return nil
            end,
         }
         local loop = tasks.configure(adapter)
         local root: tasks.Task<Dashboard> = load_dashboard(7)
         assert(root:status() == "pending")
         while loop:step() > 0 do end
         assert(root:status() == "pending" and #timers == 2)
         timers[2]()
         while loop:step() > 0 do end
         assert(root:status() == "pending")
         timers[1]()
         while loop:step() > 0 do end
         local value = root:result()
         return value.profile, value.alerts[1]
      ]])})
   end)

   it('preserves typed arguments, nil results, and lexical bindings', function()
      assert.equals(7, run([[
         local loop = tasks.configure()
         local number = 5
         async!(local function echo(value: integer): tasks.Task<integer> return value end)
         local function set<async!>(value: integer): tasks.Task<nil> number = value end
         local job = async!(||: tasks.Task<integer> -> do
            local pending: tasks.Task<nil> = set(7)
            assert(pending:await() == nil)
            local empty: tasks.Task<string | nil> = tasks.from_callback(
               function(resolve: function(string | nil)): tasks.Cancel | nil
                  resolve(nil)
                  return nil
               end)
            assert(empty:await() == nil)
            return echo(number):await()
         end)
         local root = job()
         while loop:step() > 0 do end
         return root:result()
      ]]))
   end)

   it('keeps decorated functions recursive when stacked with a Statement decorator', function()
      assert.equals(7, run([[
         local loop = tasks.configure()
         local macro keep!(declaration: Statement) return declaration end
         local function count<async!, keep!>(value: integer): tasks.Task<integer>
            if value == 0 then return 4 end
            return count(value - 1):await() + 1
         end
         local root = count(3)
         while loop:step() > 0 do end
         return root:result()
      ]]))
   end)

   it('checks the declared result of the original async function', function()
      local result = compile([[local bad = async!(||: tasks.Task<integer> -> "wrong")]])
      assert.matches('expected integer', result.type_errors[1].msg, 1, true)
   end)

   it('requires declared async functions to return Task<T>', function()
      for _, code in ipairs({
         'local function f<async!>() end',
         'local function f<async!>(): integer return 1 end',
         'local f = async!(||: integer -> 1)',
         'local function f<async!>(): tasks.Task<integer, string> return 1 end',
      }) do
         local _, errors = tl.parse(imports .. code, 'async-fixture.tl')
         assert.is_true(#errors >= 1)
         assert.matches('async functions must declare a Task<T> return type', errors[1].msg, 1, true)
      end

      local fake_res = compile([[
         local record Task<T> value: T end
         local function f<async!>(): Task<integer> return 1 end
         local _ = f
      ]])
      assert.is_true(#fake_res.type_errors >= 1)
   end)

   it('requires a local function declaration or a function literal', function()
      for _, code in ipairs({'async!(local value = 42)', 'local bad = async!(42)', 'local bad = async!(return || -> 42)'}) do
         local _, errors = tl.parse(imports .. code, 'async-fixture.tl')
         assert.equals(1, #errors)
         assert.matches('async! expects a local function declaration or a function literal', errors[1].msg, 1, true)
      end
   end)
end)

describe('auxlib async runtime', function()
   it('joins siblings in a nursery even if the body returns first', function()
      local loop = async.configure()
      local resolve, completed
      local root = async.nursery(function(scope)
         scope:spawn(function()
            return async.from_callback(function(ok) resolve = ok end)
         end)
         return 42
      end)
      root:on_complete(function(task) completed = task:result() end)
      drain(loop)
      assert.is_function(resolve)
      assert.equals('pending', root:status())
      resolve(1)
      resolve(2)
      assert.is_nil(completed)
      drain(loop)
      assert.equals(42, completed)
   end)

   it('cancels a suspended sibling and rejects the nursery on child failure', function()
      local loop = async.configure()
      local waiting, bad, fail, late, cleanup
      local root = async.nursery(function(scope)
         waiting = scope:spawn(function()
            return async.from_callback(function(resolve)
               late = resolve
               return function() cleanup = (cleanup or 0) + 1 end
            end)
         end)
         bad = scope:spawn(function()
            return async.from_callback(function(_, reject) fail = reject end)
         end)
         return waiting:await()
      end)
      drain(loop)
      fail('child failed')
      drain(loop)
      assert.equals('rejected', bad:status())
      assert.equals('cancelled', waiting:status())
      assert.equals('rejected', root:status())
      assert.has_error(function() root:result() end, 'child failed')
      late(99)
      drain(loop)
      assert.equals(1, cleanup)
      assert.equals('cancelled', waiting:status())
   end)

   it('adapts host deferral and timers without pumping the host loop', function()
      local posts, timers = {}, {}
      local loop = async.configure({
         defer = function(callback) posts[#posts + 1] = callback end,
         after = function(seconds, callback)
            assert.equals(0.5, seconds)
            timers[#timers + 1] = callback
            return function() timers[#timers] = nil end
         end,
      })
      local task = loop:start(function()
         async.sleep(0.5):await()
         return 42
      end)
      local other = loop:start(function() return false end)
      assert.equals(1, #posts)
      table.remove(posts, 1)()
      assert.equals('pending', task:status())
      assert.is_false(other:result())
      assert.equals(1, #timers)
      table.remove(timers, 1)()
      assert.equals(1, #posts)
      table.remove(posts, 1)()
      assert.equals(42, task:result())

      local aborted = loop:start(function() return async.sleep(0.5):await() end)
      table.remove(posts, 1)()
      assert.equals(1, #timers)
      assert.is_true(aborted:cancel())
      assert.is_false(aborted:cancel())
      assert.equals(0, #timers)
      assert.equals('cancelled', aborted:status())
   end)

   it('keeps existing work on its own scheduler across reconfiguration', function()
      local previous = async.configure()
      local root = async.start(function()
         assert.equals(previous, async.current())
         return async.start(function() return 42 end):await()
      end)
      local current = async.configure()
      assert.equals(current, async.current())
      assert.equals(0, current:step())
      assert.equals(1, previous:step(1))
      assert.equals('pending', root:status())
      drain(previous)
      assert.equals(42, root:result())
   end)

   it('rejects dependency cycles that cross a nursery join', function()
      local loop = async.configure()
      local root, child
      root = async.nursery(function(scope)
         child = scope:spawn(function()
            return async.start(function() return root:await() end)
         end)
         return 1
      end)
      drain(loop)
      assert.equals('rejected', child:status())
      assert.equals('rejected', root:status())
      assert.matches('cyclic async task dependency', select(2, pcall(root.result, root)), 1, true)
   end)

   it('handles synchronous callbacks and allows removing completion listeners', function()
      local loop = async.configure()
      local root = async.from_callback(function(resolve, reject)
         resolve(42)
         reject('already settled')
         return function() error('cleanup after success') end
      end)
      assert.equals(42, root:result())
      local unsubscribe = root:on_complete(function() error('listener was removed') end)
      unsubscribe()
      drain(loop)
      local failed = async.from_callback(function() error('registration failed', 0) end)
      assert.has_error(function() failed:result() end, 'registration failed')
   end)

   it('yields to another ready callback before resuming', function()
      local loop = async.configure()
      local order = {}
      local root = async.start(function()
         table.insert(order, 'start')
         async.yield()
         table.insert(order, 'resume')
         return 42
      end)
      async.start(function() table.insert(order, 'other') end)

      assert.equals(2, loop:step())
      assert.same({'start', 'other'}, order)
      assert.equals('pending', root:status())
      assert.equals(1, loop:step())
      assert.same({'start', 'other', 'resume'}, order)
      assert.equals(42, root:result())
   end)

   it('collects nullable results in input order', function()
      assert.equals(false, run([[
         local loop = tasks.configure()
         local first = tasks.start(function(): boolean | nil
            tasks.yield()
            return nil
         end)
         local second = tasks.start(function(): boolean | nil return false end)
         local group: tasks.Task<{boolean | nil}> = tasks.all({first, second, second})

         assert(loop:step() == 2)
         assert(group:status() == "pending")
         while loop:step() > 0 do end
         local values = group:result()
         assert(values[1] == nil and values[3] == false)
         return values[2]
      ]]))
      assert.same({}, async.all({}):result())
   end)

   it('forwards the first failure without cancelling the other input tasks', function()
      local loop = async.configure()
      local fail
      local slow = async.from_callback(function() end)
      local bad = async.from_callback(function(_, reject) fail = reject end)
      local group = async.all({slow, bad})
      fail('request failed')
      drain(loop)
      assert.has_error(function() group:result() end, 'request failed')
      assert.equals('pending', slow:status())
      slow:cancel()
   end)

   it('races pending tasks by completion order and settled tasks by input order', function()
      local loop = async.configure()
      local settle_first, settle_second
      local first = async.from_callback(function(resolve) settle_first = resolve end)
      local second = async.from_callback(function(resolve) settle_second = resolve end)
      local race = async.race({first, second})
      settle_second(2)
      drain(loop)
      assert.equals(2, race:result())
      assert.equals('pending', first:status())
      settle_first(1)
      assert.equals(1, async.race({first, second}):result())
   end)

   it('rejects dependency cycles that cross an aggregate', function()
      local loop = async.configure()
      local group
      local input = async.start(function() return group:await() end)
      group = async.all({input})
      drain(loop)
      assert.equals('rejected', input:status())
      assert.matches('cyclic async task dependency', select(2, pcall(group.result, group)), 1, true)
   end)

   it('rejects pending inputs on a different scheduler', function()
      local foreign = async.new():start(function() return 42 end)
      async.configure()
      local ok, err = pcall(async.race, {foreign})
      assert.is_false(ok)
      assert.matches('different async scheduler', err, 1, true)
   end)

   it('stops a timeout timer when its wrapper finishes early or is cancelled', function()
      local fired, stopped = {}, 0
      local loop = async.configure({ after = function(seconds, fire)
         assert.equals(1, seconds)
         table.insert(fired, fire)
         return function() stopped = stopped + 1 end
      end })
      local resolve
      local input = async.from_callback(function(ok) resolve = ok end)
      local fast = async.timeout(input, 1)
      local cancelled = async.timeout(input, 1)
      cancelled:cancel()
      assert.equals('pending', input:status())
      resolve(false)
      drain(loop)
      assert.is_false(fast:result())
      assert.equals(2, stopped)
      fired[1]()
      fired[2]()
      assert.is_false(fast:result())
      assert.equals('cancelled', cancelled:status())
   end)

   it('applies the timeout in callback order even before the scheduler steps', function()
      local fire
      local loop = async.configure({ after = function(_, callback) fire = callback end })
      local resolve
      local input = async.from_callback(function(ok) resolve = ok end)
      local early = async.timeout(input, 1)
      resolve(42)
      fire()
      assert.equals(42, early:result())

      local pending = async.from_callback(function() end)
      local late = async.timeout(pending, 1)
      fire()
      drain(loop)
      assert.has_error(function() late:result() end, 'async task timed out')
      assert.equals('pending', pending:status())
      pending:cancel()
   end)
end)

describe('auxlib luv run loop', function()
   it('drives tasks and closes cancelled timers on the real libuv loop', function()
      local available, uv = pcall(require, 'luv')
      if not available then
         pending('luv is unavailable')
         return
      end
      local luv = require('auxlib.async.luv')
      local loop = async.configure(luv.new())
      local root = loop:start(function()
         async.sleep(0.001):await()
         return 42
      end)
      local long = async.sleep(600)
      assert.is_true(long:cancel())
      assert.equals('pending', root:status())
      -- A leaked long timer would leave the native loop alive. Stop the run
      -- as soon as the task completes to make that failure immediate.
      root:on_complete(function() uv.stop() end)
      luv.run()
      assert.equals(42, root:result())
      assert.is_false(luv.run('nowait'))
   end)
end)
