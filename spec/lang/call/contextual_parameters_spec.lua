local tl = require('teal.api.v2')

local function check(code)
   local env = assert(tl.new_env({defaults = {gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on'}}))
   env.opts.run_internal_compiler_checks = true
   local result = tl.check_string(code, env, 'contextual.tl')
   assert.same({}, result.syntax_errors)
   return result
end

local function run(code)
   local result = check(code)
   assert.same({}, result.type_errors)
   return assert(loadstring(tl.generate(result.ast, '5.1')))()
end

local apply = [[
   local function apply<A, B>(value: A, f: function(A): B): B
      return f(value)
   end
]]

describe('contextual function parameter inference', function()
   it('uses typed declarations for short and regular anonymous functions', function()
      assert.same({3, 4}, {run([[
         local short: function(integer): integer = x -> x + 1
         local regular: function(integer): integer = function(x) return x + 2 end
         return short(2), regular(2)
      ]])})
   end)

   it('resolves nominal generic function signatures', function()
      assert.equals(3, run([[
         local type Mapper<T> = function(T): T
         local f: Mapper<integer> = x -> x + 1
         return f(2)
      ]]))
   end)

   it('infers vararg element types from the signature', function()
      assert.equals(3, run([[
         local f: function(...: integer): {integer} = |...| -> {...}
         local values = f(2, 3)
         return values[2]
      ]]))
   end)

   it('uses assignments, record fields, and nested return signatures', function()
      assert.same({4, 5, 7}, {run([[
         local assigned: function(integer): integer
         assigned = x -> x + 1
         local record Holder
            callback: function(integer): integer
         end
         local h: Holder = {callback = function(x) return x + 2 end}
         local factory: function(integer): (function(integer): integer) = outer -> inner -> outer + inner
         return assigned(3), h.callback(3), factory(3)(4)
      ]])})
   end)

   it('uses existing signatures for named functions and record methods', function()
      assert.same({3, 5}, {run([[
         local f: function(integer): integer
         function f(x) return x + 1 end
         local record Item
            value: integer
            add: function(Item, integer): integer
         end
         function Item:add(amount) return self.value + amount end
         Item.value = 2
         return f(2), Item:add(3)
      ]])})
   end)

   it('infers generic callback inputs from literals, fields and call results', function()
      assert.same({3, 5, 7}, {run(apply .. [[
         local record Item value: integer end
         local item: Item = {value = 4}
         local function value(): integer return 6 end
         return apply(2, x -> x + 1), apply(item.value, x -> x + 1), apply(value(), x -> x + 1)
      ]])})
   end)

   it('infers callback inputs from table literals', function()
      assert.equals(5, run([[
         local function collect<A, B>(items: {A}, f: function(A): B): {B}
            local out: {B} = {}
            for i, value in ipairs(items) do out[i] = f(value) end
            return out
         end
         local out = collect({2, 4}, x -> x + 1)
         return out[2]
      ]]))
   end)

   it('handles callbacks before the arguments supplying their generic types', function()
      assert.equals(5, run([[
         local function apply<A, B>(f: function(A): B, value: A): B return f(value) end
         local function value(): integer return 4 end
         return apply((x -> x + 1), value())
      ]]))
   end)

   it('propagates inference through multiple callbacks', function()
      assert.equals('3', run([[
         local function chain<A, B, C>(value: A, first: function(A): B, second: function(B): C): C
            return second(first(value))
         end
         return chain(2, x -> x + 1, x -> tostring(x))
      ]]))
   end)

   it('infers regular generic callbacks with no return annotation', function()
      assert.equals(5, run(apply .. [[return apply(4, function(x) return x + 1 end)]]))
   end)

   it('unwraps nullable callback signatures and infers ignored parameters', function()
      assert.equals(4, run([[
         local function use(f: (function(integer, integer, integer): integer) | nil): integer
            if f then return f(1, 2, 3) end
            return 0
         end
         return use(|_, _, index| -> index + 1)
      ]]))
   end)

   it('handles method receiver offsets', function()
      assert.equals(5, run([[
         local record Box end
         function Box:apply<A, B>(value: A, f: function(A): B): B return f(value) end
         return Box:apply(4, x -> x + 1)
      ]]))
   end)

   it('keeps runtime argument evaluation in source order', function()
      assert.same({5, 'lrc'}, {run([[
         local order = ''
         local function left(): integer order = order .. 'l'; return 2 end
         local function right(): integer order = order .. 'r'; return 3 end
         local function use<A, B>(value: A, f: function(A): B, ignored: integer): B return f(value) end
         local value = use(left(), function(x) order = order .. 'c'; return x + 3 end, right())
         return value, order
      ]])})
   end)

   it('reports errors using the inferred parameter type', function()
      local result = check(apply .. [[local value = apply('text', x -> x + 1)]])
      assert.is_true(#result.type_errors > 0)
      local found = false
      for _, err in ipairs(result.type_errors) do
         if err.msg:find('string', 1, true) and err.msg:find("operator '+'", 1, true) then found = true end
      end
      assert.is_true(found)
   end)

   it('respects explicit parameter and return annotations', function()
      local parameter = check(apply .. [[local value = apply(1, |x: string| -> x)]])
      assert.is_true(#parameter.type_errors > 0)
      local returns = check([[local f: function(integer): integer = function(x): string return tostring(x) end]])
      assert.is_true(#returns.type_errors > 0)
      local contract = check([[
         local record Item end
         local mt: metatable<Item> = {}
         mt.__tostring = function() return 42 end
      ]])
      assert.is_true(#contract.type_errors > 0)
   end)
end)
