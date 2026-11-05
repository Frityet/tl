local tl = require('teal.api.v2')

local function checked(code, target)
   local ast, errs = tl.parse(code, 'extensions.tl')
   assert.same({}, errs)
   return assert(tl.check(ast, 'extensions.tl', {
      gen_target = target or 'luajit', gen_compat = 'off', feat_strict_nil = 'on',
   }))
end

local function generated(code)
   local result = checked(code)
   assert.same({}, result.type_errors)
   return tl.generate(result.ast, 'luajit')
end

local function run(code)
   local out = generated(code)
   return assert(loadstring(out), out)()
end

local function type_error(code, pattern)
   local result = checked(code)
   for _, err in ipairs(result.type_errors) do
      if err.msg:match(pattern) then return end
   end
   error('expected type error matching ' .. pattern)
end

local native = loadstring('return true ? 1 : 2') ~= nil
local runtime_it = native and it or pending

describe('LuaJIT 3.0 syntax backported to 2.1', function()
   it('normalizes customary operators and strips numeric separators for standard Lua', function()
      local result = checked('return !false && (1_000 != 2 || false)', '5.1')
      assert.same({}, result.type_errors)
      assert.matches('not false and %(1000 ~= 2 or false%)', tl.generate(result.ast, '5.1'))
   end)

   it('preserves native bit operators and arithmetic shifts without bit32 wrappers', function()
      local out = generated('return (~0 & 255) | ((1 << 4) ~ (8 >> 1)) ~>> 1')
      assert.matches('~>>', out, 1, true)
      assert.not_matches('bit32', out)
   end)

   runtime_it('uses LuaJIT signed 32-bit and masked shift semantics', function()
      assert.same({-1, 2147483647, -1, 2}, {run('return 0xffffffff | 0, -1 >> 1, -1 ~>> 1, 1 << 33')})
   end)

   runtime_it('keeps false and nil ternary branches and skips the unused branch', function()
      assert.same({false, 0}, {run([[
         local calls = 0
         local function bad(): boolean calls += 1; return true end
         local v = true ? false : bad()
         local n = true ? nil : bad()
         assert(n == nil)
         return v, calls
      ]])})
   end)

   runtime_it('parses ternaries right-associatively below logical operators', function()
      assert.same({2, 3, 4}, {run('return false ? 1 : true ? 2 : 3, false || true ? 3 : 4, false ? 1 : false ? 2 : 4')})
   end)

   runtime_it('allows parenthesized method calls in the middle ternary branch', function()
      assert.equals('bc', run('return true ? (("abcd"):sub(2, 3)) : "no"'))
   end)

   runtime_it('allows nested method calls inside a ternary middle branch', function()
      assert.same({'bc', 'bc', 'bc'}, {run([[
         local function id(s: string): string return s end
         local a = true ? id(("abcd"):sub(2, 3)) : "no"
         local b = true ? {("abcd"):sub(2, 3)} : {"no"}
         local c = true ? (|| -> do return ("abcd"):sub(2, 3) end) : (|| -> "no")
         return a, b[1], c()
      ]])})
   end)

   runtime_it('coalesces nil while retaining false and short-circuiting the fallback', function()
      assert.same({false, 7, 0, true}, {run([[
         local calls = 0
         local function fallback(): boolean calls += 1; return true end
         local f: boolean | nil = false
         local n: integer | nil = nil
         return f ?? fallback(), n ?? 7, calls, false || nil ?? true
      ]])})
   end)

   runtime_it('evaluates compound table receivers and keys exactly once', function()
      assert.same({15, 1, 1}, {run([[
         local t: {string: integer} = {x = 10}
         local receivers = 0
         local keys = 0
         local function receiver(): {string: integer} receivers += 1; return t end
         local function key(): string keys += 1; return "x" end
         receiver()[key()] += 5
         return t.x, receivers, keys
      ]])})
   end)

   runtime_it('supports every backported compound assignment', function()
      assert.same({4, 'ab'}, {run([[
         local a: number = 8
         a += 2; a -= 1; a *= 2; a /= 3; a %= 5
         local b: integer = 8
         b |= 3; b &= 15; b ~= 2; b <<= 1; b >>= 1; b ~>>= 1
         local s = "a"; s ..= "b"
         return b, s
      ]])})
   end)

   runtime_it('short-circuits an entire optional chain and its assignment RHS', function()
      assert.same({nil, 0}, {run([[
         local t: {string: {string: integer}} | nil = nil
         local calls = 0
         local function key(): string calls += 1; return "x" end
         local function rhs(): integer calls += 1; return 9 end
         local value = t?.[key()].x
         t?.[key()].x = rhs()
         t?.[key()].x += rhs()
         return value, calls
      ]])})
   end)

   runtime_it('supports optional function calls and string and table argument shorthands', function()
      assert.same({nil, 'xy', 5}, {run([[
         local missing: (function(integer): integer) | nil = nil
         local function text(s: string): string return s .. "y" end
         local function tab(t: {string: integer}): integer return t.x + 2 end
         return missing?.(1), text?."x", tab?.{x = 3}
      ]])})
   end)

   runtime_it('supports safe receivers, safe methods, and both together', function()
      assert.same({'bc', 'bc', 'bc'}, {run([[
         return ("abcd")?.:sub(2, 3), ("abcd"):sub?.(2, 3), ("abcd")?.:sub?.(2, 3)
      ]])})
   end)

   it('propagates nil in safe navigation result types', function()
      type_error([[
         local function get(t: {string: integer} | nil): integer
            return t?.x
         end
      ]], 'expected integer')
   end)

   it('removes nil from coalescing result types while retaining boolean', function()
      assert.same({}, checked([[
         local function get(v: boolean | nil): boolean return v ?? false end
         local a: boolean = get(nil)
      ]]).type_errors)
   end)

   runtime_it('continues numeric, generic, while, repeat, and nested loops', function()
      assert.equals(24, run([[
         local n = 0
         for i = 1, 3 do if i == 2 then continue end; n += i end
         for _, i in ipairs({1, 2, 3}) do if i == 2 then continue end; n += i end
         local i = 0
         while i < 3 do i += 1; if i == 2 then continue end; n += i end
         i = 0
         repeat i += 1; if i == 2 then continue end; n += i until i >= 3
         for a = 1, 2 do
            for b = 1, 3 do if b == 2 then continue end; n += 1 end
            n += 2
         end
         return n
      ]]))
   end)

   it('rejects continue outside a loop, across function boundaries, and into repeat locals', function()
      for _, code in ipairs({
         'continue',
         'while true do local f = function() continue end end',
         'repeat if true then continue end local x = 1 until x > 0',
         'repeat if true then continue end local function f() end until true',
      }) do
         local _, errs = tl.parse(code, 'bad.tl')
         assert.is_true(#errs > 0, code)
      end
   end)

   runtime_it('keeps const and continue as soft keywords', function()
      assert.equals(4, run('local const = 1; local continue = 2; const += 1; return const + continue'))
   end)

   runtime_it('supports const functions and mutable contents of const tables', function()
      assert.equals(7, run([[
         const t: {string: integer} = {x = 2}
         const function add(n: integer): integer return n + t.x end
         t.x += 3
         return add(2)
      ]]))
   end)

   it('rejects reassignment and shadowing of const variables and functions', function()
      type_error('const x = 1; x = 2', 'const')
      type_error('const f = function() end; function f() end', 'const')
      type_error('const x = 1; do local x = 2 end', 're%-declare const')
      type_error('const x = 1; local function f(x: integer) end', 're%-declare const')
      type_error('const function f(): integer return 1 end; f = function(): integer return 2 end', 'const')
      type_error('const function f(): integer return 1 end; do local f = 2 end', 're%-declare const')
   end)

   runtime_it('lowers all short function forms to regular Lua functions', function()
      assert.same({2, 3, 4, 5}, {run([[
         local a: function(integer): integer = x -> x + 1
         local b = |x: integer| -> x + 2
         local c = || -> 4
         local d = |x: integer| -> do return x + 4 end
         return a(1), b(1), c(), d(1)
      ]])})
   end)

   runtime_it('infers block short function return unions and preserves multiple results', function()
      assert.same({false, 2, 3}, {run([[
         local choose = |b: boolean| -> do if b then return false else return 2 end end
         local pair = || -> do return 2, 3 end
         return choose(true), pair()
      ]])})
   end)

   runtime_it('infers unresolved generic callback return types from short functions', function()
      assert.same({4, '2', 5, 'ok'}, {run([[
         local function apply<A, B>(x: A, f: function(A): B): B
            return f(x)
         end
         local n = apply(3, |x: number| -> x + 1)
         local s: string = apply(2, |x: number| -> tostring(x))
         local t = apply(4, |x: number| -> {x, x + 1})
         local f = apply(0, |x: number| -> |s: string| -> s)
         return n, s, t[2], f('ok')
      ]])})
   end)

   it('preserves generic callback result type errors', function()
      type_error([[
         local function apply<A, B>(x: A, f: function(A): B): B return f(x) end
         local n: number = apply(1, |x: number| -> 'text')
      ]], 'expected number')
   end)

   it('checks continue with internal compiler assertions enabled', function()
      local env = assert(tl.new_env({defaults = {gen_target = 'luajit', gen_compat = 'off'}}))
      env.opts.run_internal_compiler_checks = true
      local result = tl.check_string('for i = 1, 3 do if i == 2 then continue end end', env, 'continue.tl')
      assert.same({}, result.syntax_errors)
      assert.same({}, result.type_errors)
   end)

   runtime_it('preserves outer varargs and multi-return expression short functions', function()
      assert.same({1, nil, 3}, {run([[
         local f = |...: integer | nil| -> ...
         return f(1, nil, 3)
      ]])})
   end)

   runtime_it('accepts numeric separators in decimal, hexadecimal, binary, and exponents', function()
      assert.same({1234, 18, 2, 120, 3}, {run('return 1_2_3__4__, 0__x__1__2__, 0__b__1__0__, 1_2e_1, 0x_1_8p_-3')})
   end)

   it('rejects parallel compound assignments and unavailable compound operators', function()
      for _, code in ipairs({'a, b += 1, 2', 'a += 1, 2', 'a ^= 2', 'a //= 2', 'a ??= 2'}) do
         local _, errs = tl.parse(code, 'bad.tl')
         assert.is_true(#errs > 0, code)
      end
   end)

   it('checks compound assignment result types and const writes', function()
      type_error('local n: integer = 1; n /= 2', 'expected integer')
      type_error('local n: integer = 1; n += "x"', 'cannot use operator')
      type_error('const n = 1; n += 2', 'const')
   end)

   it('rejects native-only extensions on standard Lua generation targets', function()
      for _, code in ipairs({'return true ? 1 : 2', 'return nil ?? 2', 'return -1 ~>> 1', 'local n = 1; n += 2'}) do
         local result = checked(code, '5.1')
         assert.is_true(#result.type_errors > 0, code)
         assert.has_error(function() tl.generate(result.ast, '5.1') end)
      end
   end)

   it('does not suppress genuine nullable intermediate fields', function()
      type_error([[
         local record Inner
            x: integer
         end
         local record Outer
            inner: Inner | nil
         end
         local function get(o: Outer | nil): integer | nil
            return o?.inner.x
         end
      ]], 'nil')
   end)

   it('infers nil for short function paths without a return', function()
      type_error([[
         local f = |b: boolean| -> do if b then return 1 end end
         local n: integer = f(false)
      ]], 'nil')
   end)

   it('rejects parameters shadowing their own const function', function()
      type_error('const function f(f: integer) end', 're%-declare const')
   end)

   it('reports malformed numeric literals', function()
      for _, code in ipairs({'return 0x_', 'return 1e_', 'return 1LLU'}) do
         local _, errs = tl.parse(code, 'bad.tl')
         assert.is_true(#errs > 0, code)
      end
   end)

   runtime_it('retains 64-bit cdata literal spelling and bit operations', function()
      assert.equals('4294967296ULL', run('return tostring(0xffff_ffffULL + 1ULL)'))
   end)

   runtime_it('preserves extension metadata through macro quoting and expansion', function()
      assert.equals(4, run([[
         local macro update!()
            return ```const K = 2; n += K```
         end
         local macro skip!()
            return ```continue```
         end
         local n = 0
         for i = 1, 3 do
            if i == 2 then skip!() end
            update!()
         end
         return n
      ]]))
   end)

   runtime_it('uses contextual short functions as generic callbacks', function()
      assert.equals(1, run([[
         local t = {3, 1, 2}
         table.sort(t, |a, b| -> a < b)
         return t[1]
      ]]))
   end)

   runtime_it('supports extensions in macro implementations on a capable host', function()
      assert.equals(2, run([[
         local macro two!()
            const start = 1
            local n = start
            n += 1
            return n == 2 ? `2` : `0`
         end
         return two!()
      ]]))
   end)

   it('recovers incomplete ternaries for editor diagnostics', function()
      for _, code in ipairs({'return true ?', 'return true ? 1 :', 'return true ? : 1'}) do
         local ast, errs = tl.parse(code, 'incomplete.tl')
         assert.is_true(#errs > 0)
         assert.has_no.errors(function()
            tl.check(ast, 'incomplete.tl', {gen_target = 'luajit', gen_compat = 'off'})
         end)
      end
   end)

   it('rejects bit operator metamethods for the LuaJIT backport', function()
      type_error([[
         local record Bits
            metamethod __band: function(Bits, Bits): Bits
         end
         local a: Bits = {}
         local b = a & a
      ]], 'bit operator metamethods')
   end)
end)
