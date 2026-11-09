local tl = require('teal.api.v2')
local load_code = loadstring or load
local filename = 'macro-targets.tl'

local function checked(source, target)
   local ast, errors = tl.parse(source, filename)
   assert.same({}, errors)
   return tl.check(ast, filename, {gen_target = target, gen_compat = 'off'})
end

local function generated(source, target)
   local result = checked(source, target)
   assert.same({}, result.type_errors)
   return assert(tl.generate(result.ast, target))
end

local function run(source, target)
   local code = generated(source, target or '5.1')
   return assert(load_code(code))()
end

local function rejects(source, message, line)
   local _, errors = tl.parse(source, filename)
   assert.equals(1, #errors)
   assert.matches(message, errors[1].msg, 1, true)
   assert.equals(line, errors[1].y)
end

describe('macro assignment targets', function()
   it('assigns to a field, an index, and a variable in a single assignment', function()
      assert.same({4, 5, 6}, {run([[
         local macro field!(tbl: Expression) return `($tbl).test` end
         local macro index!(arr: Expression) return `($arr)[1]` end
         local macro variable!(x: Expression) return x end
         local tbl = {test = 1}
         local arr = {2}
         local n = 3
         local function values(): integer, integer, integer return 4, 5, 6 end
         field!(tbl), index!(arr), variable!(n) = values()
         return tbl.test, arr[1], n
      ]])})
   end)

   it('preserves operator grouping in reads and removes it from whole targets', function()
      assert.same({3, 8, 7}, {run([[
         local macro (@)!(p: Expression): Operator<prefix, unary> return `($p)[1]` end
         local macro forward!(x: Expression) return clone(x) end
         local a, b = {3}, {4}
         @a, @b = @b, @a
         forward!(@a) = 8
         local before = @b
         (@)!(b) = 7
         return before, @a, @b
      ]])})
   end)

   it('allows an expression macro to supply the receiver of a target', function()
      assert.equals(4, run([[
         local macro receiver!(f: Expression) return `($f)()` end
         local record Item test: integer end
         local tbl: Item = {test = 1}
         local function get_tbl(): Item return tbl end
         receiver!(get_tbl).test = 4
         return tbl.test
      ]]))
   end)

   it('preserves native compound assignment and evaluates the receiver and key once', function()
      local source = [[
         local macro slot!(tbl: Expression, key: Expression) return `($tbl)[$key]` end
         local tbl: {string: integer} = {test = 4}
         local receivers, keys = 0, 0
         local function receiver(): {string: integer} receivers = receivers + 1; return tbl end
         local function key(): string keys = keys + 1; return "test" end
         slot!(receiver(), key()) += 3
         return tbl.test, receivers, keys
      ]]
      local code = generated(source, 'luajit')
      assert.matches('(receiver())[key()] += 3', code, 1, true)
      if load_code('local n = 0; n += 1') then
         assert.same({7, 1, 1}, {assert(load_code(code))()})
      end
   end)

   it('applies normal type and const checks to expanded targets', function()
      local result = checked([[
         local macro target!(x: Expression) return x end
         const n = 1
         local x: integer = 2
         target!(n) = 3
         target!(x) = "wrong"
      ]], 'luajit')
      assert.equals(2, #result.type_errors)
      assert.matches('const', result.type_errors[1].msg, 1, true)
      assert.matches('expected integer', result.type_errors[2].msg, 1, true)
   end)

   it('rejects expansions that are not targets in either position', function()
      rejects('local macro bad!() return `f()` end\nbad!() = 4',
         'invalid assignment target', 2)
      rejects('local macro bad!() return `1 + 2` end\na, bad!() = 1, 2',
         'invalid assignment target', 2)
      rejects('local macro bad!() return `(a[1])` end\nbad!() += 4',
         'invalid assignment target', 2)
      rejects('local macro bad!() return ```print(1)``` end\nbad!() = 4',
         'invalid assignment target', 2)
      rejects('local macro bad!() return ```local x = 1``` end\nbad!() = 4',
         'returned statements in an expression context', 2)
      rejects('a, 1 + 2 = 1, 2', 'invalid assignment target', 1)
   end)
end)
