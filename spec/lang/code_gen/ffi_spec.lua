local tl = require("teal.api.v2")
local load_code = loadstring or load

local import = [[
local ffi = require("auxlib.ffi")
]]

local function generate(code, target)
   local env = assert(tl.new_env({ defaults = { gen_target = target, gen_compat = "off" } }))
   return tl.gen(import .. code, env)
end

describe("typed FFI in Lua generation", function()
   it("checks C argument types without the strict pragma", function()
      local _, result = generate([=[
         ffi.cdef! [[int puts(const char *);]]
         C.puts(42)
      ]=], "5.1")
      assert.same({}, result.syntax_errors)
      assert.match("expected string", result.type_errors[1].msg, 1, true)
   end)

   it("supports typed varargs, nullable pointers, and scalar returns on LuaJIT", function()
      local source = [=[
         local _tl_typed_ffi = "caller binding"
         ffi.cdef! [[int snprintf(char * _Nullable, size_t, const char *, ...);]]
         local length = C.snprintf
         ffi.cdef! [[
            typedef void *TealFfiSpecHandle;
            TealFfiSpecHandle malloc(size_t);
            void free(TealFfiSpecHandle);
            char *strchr(const char *, int);
            long labs(long);
         ]]

         local function format_args(): integer, number, boolean
            return 1234567, 2.0, true
         end
         local handle: C.TealFfiSpecHandle | nil = C.malloc(16)
         local allocated = handle is C.TealFfiSpecHandle
         if handle is C.TealFfiSpecHandle then C.free(handle) end
         return length(nil, 0, "%d %.1f %d", format_args()),
            C.strchr("abc", 98), C.strchr("abc", 120), C.labs(-42), allocated, _tl_typed_ffi
      ]=]
      for _, target in ipairs({ "5.1", "luajit" }) do
         local code, result = generate(source, target)
         assert.same({}, result.syntax_errors)
         assert.same({}, result.type_errors)
         assert.match('4, "i_b"', code, 1, true)
         assert(load_code(code))
      end
      if not pcall(require, "ffi") then
         pending("LuaJIT FFI is unavailable")
         return
      end
      local code = generate(source, "luajit")
      local length, suffix, missing, absolute, allocated, binding = assert(load_code(code))()
      assert.same(13, length)
      assert.same("bc", suffix)
      assert.is_nil(missing)
      assert.same(42, absolute)
      assert.is_true(allocated)
      assert.same("caller binding", binding)
   end)

   it("requires standalone top-level declarations", function()
      local _, result = generate([=[
         do
            ffi.cdef! [[int puts(const char *);]]
         end
      ]=], "luajit")
      assert.same({}, result.syntax_errors)
      assert.match("must be a standalone top-level statement", result.type_errors[1].msg, 1, true)
   end)

   it("preserves raw LuaJIT cdef calls", function()
      local code, result = tl.gen([=[
         local ffi = require("ffi")
         ffi.cdef [[struct TealFfiSpecRaw { int field; };]]
         local C = ffi.C
         return C
      ]=])
      assert.same({}, result.syntax_errors)
      assert.same({}, result.type_errors)
      assert.match("struct TealFfiSpecRaw { int field; };", code, 1, true)
      assert.not_matches("_tl_typed_ffi", code, 1, true)
   end)
end)
