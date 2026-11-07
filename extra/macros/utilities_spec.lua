local tl = require('teal.api.v2')
local util = require('spec.util')

describe('extras utilities operators', function()
   local imports = [[
local utilities = require("extra.macros.utilities")
local macro (|>)! = utilities.(|>)!
local macro (||>)! = utilities.(||>)!
local macro (+=>)! = utilities.(+=>)!
local macro (?>)! = utilities.(?>)!
local macro (from)! = utilities.(from)!
local macro (import)! = utilities.(import)!
]]

   local function run(source, macro_only)
      local ast, errors = tl.parse(imports .. source, 'utilities-fixture.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'utilities-fixture.tl', {
         gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
      })
      assert.same({}, result.type_errors)
      local output = assert(tl.generate(result.ast, '5.1'))
      if macro_only then
         assert.not_matches('extra.macros.utilities', output, 1, true)
      end
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
      ]], true)})
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

   it('infers both input and output types when remapping entries', function()
      assert.same({[10] = 'one!', [20] = 'two!'}, run([[
         local source: {string:integer} = {one = 1, two = 2}
         local mapped = source ||> |k, v| -> do return v * 10, k .. "!" end
         local typed: {integer:string} = mapped
         assert(source.one == 1 and source.two == 2)
         return typed
      ]]))
   end)

   it('maps array indices and evaluates the source and callback once', function()
      assert.same({{[2] = 10, [3] = 12}, 1, 1}, {run([[
         local source_calls, callback_calls = 0, 0
         local function values(): {integer}
            source_calls = source_calls + 1
            return {5, 6}
         end
         local function mapper(): function(integer, integer): (integer, integer)
            callback_calls = callback_calls + 1
            return |k, v| -> do return k + 1, v * 2 end
         end
         local mapped = values() ||> mapper()
         return mapped, source_calls, callback_calls
      ]])})
   end)

   it('requires a callback that returns a key and a value', function()
      local ast, errors = tl.parse(imports .. [[
         local source: {string:integer} = {one = 1}
         local mapped = source ||> |k, v| -> k .. tostring(v)
      ]], 'utilities-fixture.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'utilities-fixture.tl')
      assert.equals(1, #result.type_errors)
      assert.matches('incompatible number of returns', result.type_errors[1].msg, 1, true)
   end)

   it('sums numeric projections of table entries and returns zero for empty tables', function()
      assert.same({6.5, 0}, {run([[
         local input: {string:integer} = {abc = 3, de = 2}
         local mapped = input ||> |k, v| -> do return k, v end
         local empty: {string:integer} = {}
         return mapped +=> |k, v| -> #k * v / 2, empty +=> |k, v| -> #k * v
      ]])})
   end)

   it('reduces to the seed type and evaluates the seed once', function()
      assert.same({'abc', 'seed', 1}, {run([[
         local input: {string:integer} = {abc = 3, de = 2}
         local empty: {string:integer} = {}
         local calls = 0
         local function seed(): string
            calls = calls + 1
            return ""
         end
         local longest = input +=> {seed(), |acc, k, v| -> #acc < v and k or acc}
         local unchanged = empty +=> {"seed", |acc, k, v| -> acc .. k .. tostring(v)}
         local typed: string = longest
         return typed, unchanged, calls
      ]])})
   end)

   it('rejects malformed reductions and checks the accumulator type', function()
      local _, errors = tl.parse(imports .. 'return source +=> {initial = 0, step = reducer}', 'utilities-fixture.tl')
      assert.equals(1, #errors)
      assert.matches('expects a sum callback or { initial, reducer }', errors[1].msg, 1, true)

      local ast, type_syntax = tl.parse(imports .. [[
         local input: {integer} = {2}
         return input +=> {0, |acc, k, v| -> tostring(acc + k + v)}
      ]], 'utilities-fixture.tl')
      assert.same({}, type_syntax)
      local result = tl.check(ast, 'utilities-fixture.tl')
      assert.equals(1, #result.type_errors)
      assert.matches('expected integer', result.type_errors[1].msg, 1, true)
   end)

   it('filters and groups entries while preserving their original keys', function()
      assert.same({{[2] = 20, [4] = 40}, {small = {[2] = 20}, large = {[4] = 40}}}, {run([[
         local items: {integer} = {10, 20, 30, 40}
         local selected: {integer:integer} = items ?> |k, v| -> k % 2 == 0 and v >= 20
         local grouped: {string:{integer:integer}} =
            utilities.group_by(selected, |_, v| -> v < 30 and "small" or "large")
         return selected, grouped
      ]])})
   end)

   it('short-circuits any, all, and find and handles empty tables', function()
      assert.same({true, false, false, 3}, {run([[
         local entries: {string:boolean} = {a = false, b = false, c = false}
         local empty: {string:boolean} = {}
         local calls = 0
         local function count(_: string, v: boolean): boolean
            calls = calls + 1
            return not v
         end
         local first = entries |> utilities.any(count)
         local every = utilities.all(entries, |k, v| -> not count(k, v))
         local match: boolean | nil = utilities.find(entries, count)
         assert(not utilities.any(empty, count) and utilities.all(empty, count) and utilities.find(empty, count) == nil)
         return first, every, match, calls
      ]])})
   end)

   it('extracts typed arrays of keys and values', function()
      assert.same({{'a', 'b'}, {10, 20}}, {run([[
         local entries: {string:integer} = {a = 20, b = 10}
         local names: {string} = utilities.keys(entries)
         local amounts: {integer} = utilities.values(entries)
         table.sort(names)
         table.sort(amounts)
         return names, amounts
      ]])})
   end)

   it('taps a pipeline without changing the value passed to the next stage', function()
      assert.same({42, 21, 1}, {run([[
         local seen, calls = 0, 0
         local function observe(value: integer)
            seen = value
            calls = calls + 1
         end
         local function double(value: integer): integer return value * 2 end
         local result = 20 + 1 |> utilities.tap(observe) |> double
         return result, seen, calls
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
