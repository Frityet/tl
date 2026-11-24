local tl = require('teal.api.v2')
local util = require('spec.util')

local imports = [[
local bindings = require("auxlib.ffi")
local macro ffi! = bindings.ffi!
]]

local function compile(source)
   local ast, syntax_errors = tl.parse(imports .. source, 'ffi-fixture.tl')
   assert.same({}, syntax_errors)
   return tl.check(ast, 'ffi-fixture.tl', {
      gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
   })
end

describe('auxlib ffi', function()
   it('orders nested struct definitions and checks the generated types', function()
      local result = compile([[
         ffi!(
            local record Lib is CLib where (lib == "first" or lib == "second")
               record Outer is CStruct
                  inner: Inner
                  next: ptr<Outer>
               end
               record Inner is CStruct
                  value: int
               end
               make: function(ptr<void>): Outer
               release: function(ptr<Outer>): void
            end
         )
         local result: Lib.Outer = Lib.make(nil)
         local value: integer = result.inner.value
         Lib.release(result.next)
         return value
      ]])
      assert.same({}, result.type_errors)
      local output = assert(tl.generate(result.ast, '5.1'))
      assert.is_true(assert(output:find('struct $Inner {', 1, true)) < assert(output:find('struct $Outer {', 1, true)))
      assert.matches('struct $Outer $make(void *)', output, 1, true)
      assert.matches('void $release(struct $Outer *)', output, 1, true)
   end)

   it('rejects arguments that do not match the C signature', function()
      local result = compile([[
         ffi!(
            local record Lib is CLib where lib == "mock"
               twice: function(int): int
            end
         )
         Lib.twice("wrong")
      ]])
      assert.equals(1, #result.type_errors)
      assert.matches('expected integer', result.type_errors[1].msg, 1, true)
   end)

   for _, case in ipairs({
      {'where lib == 42', 'twice: function(int): int', 'with or between fallback names'},
      {'where lib == "mock"', 'twice: function(unknown): int', 'unknown C type unknown'},
      {'where lib == "mock"', 'record Bad is CStruct\n member: Bad\n end', 'cyclic by-value struct dependency'},
   }) do
      it('rejects ' .. case[3], function()
         local fixture = 'ffi!(local record Lib is CLib ' .. case[1] .. '\n' .. case[2] .. '\nend)'
         local _, errors = tl.parse(imports .. fixture, 'ffi-fixture.tl')
         assert.equals(1, #errors)
         assert.matches(case[3], errors[1].msg, 1, true)
      end)
   end

   it('loads native libraries, marshals a struct, and isolates distinct symbol signatures', function()
      if not jit or jit.os ~= 'Linux' or jit.arch ~= 'x64' then
         pending('requires Linux x64 LuaJIT for by-value structs')
         return
      end
      local cc = os.execute('cc --version >/dev/null 2>&1')
      if cc ~= 0 and cc ~= true then pending('C compiler unavailable'); return end
      local dir = util.write_tmp_dir(finally, {
         ['a.c'] = [[
            struct layout { int a; const char *str; };
            struct layout tl_ffi_example(int a) {
               struct layout out = {a, "works"};
               return out;
            }
            int tl_ffi_count(const char *s) {
               int n = 0;
               while (s[n]) ++n;
               return n;
            }
            int tl_ffi_value = 3;
         ]],
         ['b.c'] = 'double tl_ffi_count(double x) { return x + 0.5; }',
      })
      for _, name in ipairs({'a', 'b'}) do
         os.execute(('cc -shared -fPIC -o %q %q'):format(dir .. name .. '.so', dir .. name .. '.c'))
         assert(io.open(dir .. name .. '.so', 'rb')):close()
      end
      local result = compile(([[
         ffi!(
            local record Lib is CLib where lib == "missing_tl_ffi_fixture" or lib == %q
               record SomeStruct is CStruct
                  a: int
                  str: ptr<const<char>>
               end
               tl_ffi_example: function(int): SomeStruct
               tl_ffi_count: function(CString): int
               tl_ffi_value: int
            end
         )
         ffi!(
            local record Other is CLib where lib == %q
               tl_ffi_count: function(double): double
            end
         )
         local result: Lib.SomeStruct = Lib.tl_ffi_example(42)
         Lib.tl_ffi_value = 7
         return result.a, bindings.string(result.str), Lib.tl_ffi_count("abc"),
            Lib.tl_ffi_value, Other.tl_ffi_count(2.25)
      ]]):format(dir .. 'a.so', dir .. 'b.so'))
      assert.same({}, result.type_errors)
      local output = assert(tl.generate(result.ast, '5.1'))
      local run = assert(loadstring(output))
      for _ = 1, 2 do
         assert.same({42, 'works', 3, 7, 2.75}, {run()})
      end
   end)
end)
