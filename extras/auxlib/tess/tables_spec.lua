local tl = require('teal.api.v2')
local util = require('spec.util')

describe('auxlib tables operators', function()
   local imports = [[
local tables = require("auxlib.tables")
local macro (|>)! = tables.(|>)!
local macro (||>)! = tables.(||>)!
local macro (+=>)! = tables.(+=>)!
local macro (?>)! = tables.(?>)!
local macro (from)! = tables.(from)!
local macro (import)! = tables.(import)!
]]

   local function run(source, macro_only)
      local ast, errors = tl.parse(imports .. source, 'tables-fixture.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'tables-fixture.tl', {
         gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
      })
      assert.same({}, result.type_errors)
      local output = assert(tl.generate(result.ast, '5.1'))
      if macro_only then
         assert.not_matches('auxlib.tables', output, 1, true)
      end
      return assert(loadstring(output), output)()
   end

   it('inserts the piped value first and calls the result of a parenthesized expression', function()
      assert.same({6, 6, 34, 6, 9, 14, 34}, {run([[
         local function double(value: integer): integer return value * 2 end
         local function digits(first: integer, second: integer): integer
            return first * 10 + second
         end
         local function factory(): function(integer): integer
            return value -> value + 6
         end
         local macro target!() return `digits(4)` end

         assert(3 |> double == 6)
         return 3 |> double, 3 |> double(), 3 |> digits(4), 3 |> (double),
            3 |> (factory()), 1 + 3 |> double |> (factory()), 3 |> target!()
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

   it('maps arrays to new element types in index order', function()
      assert.same({'1:10', '2:20'}, run([[
         local source: {integer} = {10, 20}
         local mapped = source ||> |value, idx| -> tostring(idx) .. ":" .. tostring(value)
         local typed: {string} = mapped
         assert(source[1] == 10 and source[2] == 20)
         return typed
      ]]))
   end)

   it('passes value then index and evaluates the source and callback expressions once', function()
      assert.same({{11, 14}, 1, 1}, {run([[
         local source_calls, callback_calls = 0, 0
         local function values(): {integer}
            source_calls = source_calls + 1
            return {5, 6}
         end
         local function mapper(): function(integer, integer): integer
            callback_calls = callback_calls + 1
            return |value, idx| -> value * 2 + idx
         end
         local mapped = values() ||> mapper()
         return mapped, source_calls, callback_calls
      ]])})
   end)

   it('returns an empty array without invoking the callback for empty input', function()
      assert.same({{}, 0}, {run([[
         local source: {integer} = {}
         local calls = 0
         local mapped: {string} = source ||> |value, idx| -> do
            calls = calls + 1
            return tostring(value + idx)
         end
         return mapped, calls
      ]])})
   end)

   it('rejects dictionaries and callbacks with incompatible element types', function()
      for _, source in ipairs({
         'local source: {string:integer} = {one = 1}\nlocal mapped = source ||> |value, idx| -> value + idx',
         'local source: {integer} = {1}\nlocal mapped = source ||> function(value: string, idx: integer): string return value end',
      }) do
         local ast, errors = tl.parse(imports .. source, 'tables-fixture.tl')
         assert.same({}, errors)
         local result = tl.check(ast, 'tables-fixture.tl', {feat_strict_nil = 'on'})
         assert.is_true(#result.type_errors > 0, source)
      end
   end)

   it('sums numeric projections of table entries and returns zero for empty tables', function()
      assert.same({6.5, 0}, {run([[
         local input: {string:integer} = {abc = 3, de = 2}
         local empty: {string:integer} = {}
         return input +=> |k, v| -> #k * v / 2, empty +=> |k, v| -> #k * v
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
      local _, errors = tl.parse(imports .. 'return source +=> {initial = 0, step = reducer}', 'tables-fixture.tl')
      assert.equals(1, #errors)
      assert.matches('expects a sum callback or { initial, reducer }', errors[1].msg, 1, true)

      local ast, type_syntax = tl.parse(imports .. [[
         local input: {integer} = {2}
         return input +=> {0, |acc, k, v| -> tostring(acc + k + v)}
      ]], 'tables-fixture.tl')
      assert.same({}, type_syntax)
      local result = tl.check(ast, 'tables-fixture.tl')
      assert.equals(1, #result.type_errors)
      assert.matches('expected integer', result.type_errors[1].msg, 1, true)
   end)

   it('filters and groups entries while preserving their original keys', function()
      assert.same({{[2] = 20, [4] = 40}, {small = {[2] = 20}, large = {[4] = 40}}}, {run([[
         local items: {integer} = {10, 20, 30, 40}
         local selected: {integer:integer} = items ?> |k, v| -> k % 2 == 0 and v >= 20
         local grouped: {string:{integer:integer}} =
            tables.group_by(selected, |_, v| -> v < 30 and "small" or "large")
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
         local first = entries |> tables.any(count)
         local every = tables.all(entries, |k, v| -> not count(k, v))
         local match: boolean | nil = tables.find(entries, count)
         assert(not tables.any(empty, count) and tables.all(empty, count) and tables.find(empty, count) == nil)
         return first, every, match, calls
      ]])})
   end)

   it('extracts typed arrays of keys and values', function()
      assert.same({{'a', 'b'}, {10, 20}}, {run([[
         local entries: {string:integer} = {a = 20, b = 10}
         local names: {string} = tables.keys(entries)
         local amounts: {integer} = tables.values(entries)
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
         local result = 20 + 1 |> tables.tap(observe) |> double
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
         local macro selection!() return `{ some_function as other, number as table }` end
         import selection!() from "utility fixture"
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
         {'import {[1] = a} from source', 'bare field names'},
         {'import {a} from get_module()', 'dotted module name or a string literal'},
         {'import {a as b, b} from source', "duplicate binding 'b'"},
         {'import {a as other.name} from source', 'alias must be a bare name'},
      }
      for _, case in ipairs(cases) do
         local _, errors = tl.parse(imports .. case[1], 'tables-fixture.tl')
         assert.equals(1, #errors, case[1])
         assert.matches(case[2], errors[1].msg, 1, true)
      end
   end)
end)
