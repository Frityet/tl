local tl = require('teal.api.v2')
local util = require('spec.util')

describe('extras utilities operators', function()
   local imports = [[
local utilities = require("extra.macros.utilities")
local macro (|>)! = utilities.(|>)!
local macro (from)! = utilities.(from)!
local macro (import)! = utilities.(import)!
]]

   local function run(source)
      local ast, errors = tl.parse(imports .. source, 'utilities-fixture.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'utilities-fixture.tl', {
         gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
      })
      assert.same({}, result.type_errors)
      local output = assert(tl.generate(result.ast, '5.1'))
      assert.not_matches('extra.macros.utilities', output, 1, true)
      return assert(loadstring(output), output)()
   end

   it('inserts the piped value first and calls the result of a parenthesized expression', function()
      assert.same({6, 6, 34, 6, 9, 14}, {run([[
         local function double(value: integer): integer return value * 2 end
         local function digits(first: integer, second: integer): integer
            return first * 10 + second
         end
         local function factory(): function(integer): integer
            return value -> value + 6
         end

         assert(3 |> double == 6)
         return 3 |> double, 3 |> double(), 3 |> digits(4), 3 |> (double),
            3 |> (factory()), 1 + 3 |> double |> (factory())
      ]])})
   end)

   it('preserves method receivers and evaluates inserted arguments once', function()
      assert.same({12, 1}, {run([[
         local record Counter
            base: integer
         end
         function Counter:add(first: integer, second: integer): integer
            return self.base + first + second
         end
         local calls = 0
         local function value(): integer
            calls = calls + 1
            return 3
         end
         Counter.base = 5
         return value() |> Counter:add(4), calls
      ]])})
   end)

   it('binds typed fields and evaluates the source expression only once', function()
      assert.same({7, 'item', false, 1}, {run([[
         local record Row
            id: integer
            name: string
            enabled: boolean | nil
         end
         local calls = 0
         local function row(): Row
            calls = calls + 1
            return {id = 7, name = "item", enabled = false}
         end
         { id, name, enabled } from row()
         local typed_id: integer = id
         local typed_name: string = name
         local typed_enabled: boolean | nil = enabled
         return typed_id, typed_name, typed_enabled, calls
      ]])})
   end)

   it('handles shadowed names without leaking a temporary binding', function()
      assert.same({5, 7, 'item'}, {run([[
         local __from_source = 5
         local row = {row = "item", id = "7"};
         { row, id } from row
         return __from_source, tonumber(id), row
      ]])})
   end)

   it('imports from dotted and quoted module names with optional aliases', function()
      local declaration = [[
         local record Export
            some_function: function(integer): integer
            number: integer
         end
         return Export
      ]]
      util.mock_io(finally, {
         ['utility_fixture/source.d.tl'] = declaration,
         ['utility fixture.d.tl'] = declaration,
      })
      local function runtime_module()
         return {some_function = function(value) return value * 2 end, number = 5}
      end
      local dotted = 'utility_fixture.source'
      local quoted = 'utility fixture'
      package.preload[dotted], package.preload[quoted] = runtime_module, runtime_module
      finally(function()
         package.preload[dotted], package.preload[quoted] = nil, nil
         package.loaded[dotted], package.loaded[quoted] = nil, nil
      end)
      assert.same({6, 8, 10}, {run([[
         import { some_function as fn, number } from utility_fixture.source
         import { some_function as other, number as table } from "utility fixture"
         return fn(3), other(4), number + table
      ]])})
   end)

   it('rejects malformed field lists and expression-position destructuring', function()
      local cases = {
         {'{} from row', 'nonempty list'},
         {'{a, a} from row', "duplicate binding 'a'"},
         {'{[1] = a} from row', 'bare field names'},
         {'{key = a} from row', 'bare field names'},
         {'{row.a} from row', 'bare field names'},
         {'local value = {a} from row', 'returned statements in an expression context'},
         {'import {a}', 'expects { fields } from'},
         {'import {a} from get_module()', 'dotted module name or a string literal'},
         {'import {a as b, b} from source', "duplicate binding 'b'"},
         {'import {a as other.name} from source', 'alias must be a bare name'},
      }
      for _, case in ipairs(cases) do
         local _, errors = tl.parse(imports .. case[1], 'utilities-fixture.tl')
         assert.equals(1, #errors, case[1])
         assert.matches(case[2], errors[1].msg, 1, true)
      end
   end)
end)
