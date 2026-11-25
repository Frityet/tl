local tl = require('tl')
local lua_generator = require('teal.gen.lua_generator')

local function check(code)
   local ast, errors = tl.parse(code, 'decorators.tl')
   assert.same({}, errors)
   return tl.check(ast, 'decorators.tl', {gen_target = '5.1', gen_compat = 'off'})
end

local function run(code)
   local result = check(code)
   assert.same({}, result.type_errors)
   local output = assert(tl.generate(result.ast, '5.1'))
   local fn = assert(loadstring(output))
   setfenv(fn, setmetatable({}, {__index = _G}))
   return fn()
end

describe('macro parameter kinds', function()
   it('requires a supported parameter annotation', function()
      local code = [[
         local macro bad1!(x)
            return `$x`
         end
      ]]
      local _, errs = tl.parse(code)
      assert.not_same({}, errs)

      local code2 = [[
         local macro bad2!(x: number)
            return `$x`
         end
      ]]
      local _, errs2 = tl.parse(code2)
      assert.not_same({}, errs2)
   end)

   it('passes decorated variables, functions, and records as declarations', function()
      local code = [=[
         local count = 0
         local macro decorate!(declaration: Statement): Statement
            return ```
               $declaration
               count = count + 1
            ```
         end

         local a<decorate!> = 4
         local function f<decorate!>(): integer return a end
         local record<decorate!> Rec end
         decorate!(local b = 8)
         return a, f(), b, count, Rec
      ]=]
      local ast, errors = tl.parse(code)
      assert.same({}, errors)
      local output = assert(lua_generator.generate(ast, '5.1'))
      local a, value, b, count = assert(loadstring(output))()
      assert.same({4, 4, 8, 4}, {a, value, b, count})
   end)

   it('stacks function decorators before generic parameters', function()
      assert.same({4, 'five'}, {run([[
         local macro inline!(fn: Function) return fn end
         local macro pure!(fn: Function) return fn end
         local function pair<inline!, pure!><T, U>(x: T, y: U): T, U
            return x, y
         end
         local x, y: integer, string = pair(4, "five")
         return x, y
      ]])})
   end)

   it('expands the rightmost decorator first and passes extra macro arguments', function()
      assert.same({9, 'dcba'}, {run([=[
         local trace = ""
         local macro note!(declaration: Statement, text: Expression, after: Statement)
            return ```
               $declaration
               $after
               trace = trace .. $text
            ```
         end
         local function square<
            note!("a", trace = trace .. "b"),
            note!("c", trace = trace .. "d")
         >(x: number): number
            return x * x
         end
         return square(3), trace
      ]=])})
   end)

   it('decorates global functions, named definitions, and record functions', function()
      assert.same({4, 6, 7, 9}, {run([[
         local macro keep!(declaration: Statement) return declaration end
         global function decorated_global<keep!>(x: integer): integer return x + 1 end
         local forward: function(): integer
         function forward<keep!>(): integer return 6 end
         local record R value: integer end
         local r: R = {value = 1}
         function R.identity<keep!><T>(x: T): T return x end
         function R:add<keep!>(x: integer): integer return self.value + x end
         return decorated_global(3), forward(), R.identity(7), R.add(r, 8)
      ]])})
   end)

   it('preserves const when decorators are stacked', function()
      local result = check([[
         local macro keep!(fn: Function) return fn end
         const function f<keep!, keep!>(): integer return 1 end
         f = function(): integer return 2 end
      ]])
      assert.equals(1, #result.type_errors)
      assert.matches('const', result.type_errors[1].msg, 1, true)
   end)

   it('rejects the previous function decorator position', function()
      local _, errors = tl.parse([[
         local macro keep!(declaration: Statement) return declaration end
         local function f()<keep!> end
      ]])
      assert.is_true(#errors > 0)
   end)

   it('accepts Expression arguments and rejects Statement blocks', function()
      local code = [[
         local macro echo!(x: Expression)
            return `$x`
         end

         local a = echo!(1 + 2)
      ]]
      local ast, errs = tl.parse(code)
      assert.same({}, errs)
      local out, err = lua_generator.generate(ast, '5.4')
      assert.is_nil(err)
      out = out:gsub('^%s+', ''):gsub('%s+$', '')
      assert.same('local a = 1 + 2', out)

   end)

   it('supports typed varargs (...: Expression)', function()
      local code = [[
         local macro twice_all!(...: Expression)
            local out = block('statements')
            for i = 1, select('#', ...) do
               local b = select(i, ...)
               table.insert(out, `$b`)
               table.insert(out, `$b`)
            end
            return out
         end

         twice_all!(print('a'), print('b'))
      ]]
      local ast, errs = tl.parse(code)
      assert.same({}, errs)
      local out, err = lua_generator.generate(ast, '5.4')
      assert.is_nil(err)
      local count = 0
      for _ in out:gmatch("print%(") do count = count + 1 end
      assert.is_true(count >= 4)

      local bad = [[
         local macro eat!(...: Expression)
            return ```$...```
         end

         eat!(```x = 1```)
      ]]
      local _, berrs = tl.parse(bad)
      assert.not_same({}, berrs)
   end)
end)
