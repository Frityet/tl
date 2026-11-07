local tl = require('teal.api.v2')
local async = require('extras.async')

local imports = [[
local tasks = require("extras.async")
local macro (async)! = tasks.(async)!
local macro (await)! = tasks.(await)!
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

describe('extras async macros', function()
   it('runs the dashboard nursery and starts both requests before either completes', function()
      assert.same({'profile:7', 'alert:7'}, {run([[
         local record Dashboard
            profile: string
            alerts: {string}
         end

         local load_profile = async function(id: integer): string
            await tasks.sleep(0)
            return "profile:" .. tostring(id)
         end
         local load_alerts = async |id: integer|: {string} -> do
            await tasks.sleep(0)
            return {"alert:" .. tostring(id)}
         end

         local load_dashboard = async function(id: integer): Dashboard
            return await tasks.nursery(function(scope: Scope): Dashboard
               local profile = scope:spawn(async || -> await load_profile(id))
               local alerts = scope:spawn(async || -> await load_alerts(id))
               return { profile = await profile, alerts = await alerts }
            end)
         end

         local timers: {tasks.Callback} = {}
         local loop = tasks.configure({
            after = function(_: number, callback: tasks.Callback): tasks.Cancel | nil
               table.insert(timers, callback)
               return nil
            end,
         })
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
         local echo = async function(value: integer): integer return value end
         local set = async function(value: integer) number = value end
         local job = async ||: integer -> do
            local pending: tasks.Task<nil> = set(7)
            assert((await pending) == nil)
            local empty: tasks.Task<string | nil> = tasks.from_callback(
               function(resolve: function(string | nil)): tasks.Cancel | nil
                  resolve(nil)
                  return nil
               end)
            assert((await empty) == nil)
            return await echo(number)
         end
         local root = job()
         while loop:step() > 0 do end
         return root:result()
      ]]))
   end)

   it('checks the declared result of the original async function', function()
      local result = compile([[local bad = async ||: integer -> "wrong"]])
      assert.matches('expected integer', result.type_errors[1].msg, 1, true)
   end)

   it('requires a function literal for async', function()
      local _, errors = tl.parse(imports .. 'local bad = async 42', 'async-fixture.tl')
      assert.is_true(#errors > 0)
      assert.matches('async expects a function literal', errors[1].msg, 1, true)
   end)
end)

describe('extras async runtime', function()
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
end)
