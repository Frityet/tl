local util = require("spec.util")
local teal = require("teal.init")
local unpack = table.unpack or unpack

local source = [=[
--#pragma strict on
local ffi = require("auxlib.ffi")
ffi.cdef! [[
   int printf(const char *, ...);
   typedef void *Handle;
   Handle malloc(size_t);
   void free(Handle);
]]

local handle: C.Handle | nil = C.malloc(16)
if handle is nil then return 1 end
C.free(handle)

local calls = 0
local function bound(value: integer): integer
   calls = calls + 1
   return value
end

local total = 0
for i = bound(3), bound(1), -1 do
   total = total + i
end
local decimal: number = 2
C.printf("Hello,\x20%s! %d %d %.1f\n", "world", total, calls, decimal)
]=]

local function run(command, ...)
   local fd = assert(io.popen(util.tl_cmd(command, ...) .. " 2>&1", "r"))
   local output = fd:read("*a")
   return output, { fd:close() }
end

local function generate(input, ...)
   return run("gen", { "--gen-target=c" }, input, ...)
end

describe("tl gen --gen-target=c", function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it("writes a C file with typed foreign declarations by default", function()
      local input = util.write_tmp_file(finally, source)
      local output, status = generate(input)
      util.assert_popen_close(0, unpack(status))
      local filename = input:match("[^/\\]+$"):gsub("%.tl$", ".c")
      assert.match("Wrote: " .. filename, output, 1, true)
      local c = util.read_file(filename)
      os.remove(filename)
      assert.match("int printf(const char *, ...);", c, 1, true)
      assert.match("int main(void)", c, 1, true)
      assert.not_matches("require(", c, 1, true)
   end)

   it("compiles with Clang and runs with typed calls and Lua evaluation order", function()
      local status = os.execute("clang --version >" .. util.os_null .. " 2>&1")
      if status ~= true and status ~= 0 then
         pending("Clang is unavailable")
         return
      end
      local input = util.write_tmp_file(finally, source)
      local c_file = util.get_tmp_filename(finally, "c")
      local binary = util.get_tmp_filename(finally, "exe")
      local output, gen_status = generate(input, "-o", c_file)
      util.assert_popen_close(0, unpack(gen_status))
      assert.match("Wrote:", output, 1, true)
      local compiler = assert(io.popen(("clang -std=c11 -Wall -Wextra -Werror %q -o %q 2>&1"):format(c_file, binary), "r"))
      local diagnostics = compiler:read("*a")
      util.assert_popen_close(0, compiler:close())
      assert.equal("", diagnostics)
      local process = assert(io.popen(("%q"):format(binary), "r"))
      local result = process:read("*a")
      util.assert_popen_close(0, process:close())
      assert.equal("Hello, world! 6 2 2.0\n", result:gsub("\r\n", "\n"))
   end)

   it("requires one strictly checked file", function()
      local plain = util.write_tmp_file(finally, "local x = 1")
      local output, status = generate(plain)
      util.assert_popen_close(1, unpack(status))
      assert.match("requires '--#pragma strict on'", output, 1, true)

      output, status = generate(plain, plain)
      util.assert_popen_close(1, unpack(status))
      assert.match("requires a single Teal input", output, 1, true)

      output, status = generate(plain, "--no-check")
      util.assert_popen_close(1, unpack(status))
      assert.match("--no-check is incompatible", output, 1, true)
   end)

   it("permits type imports but rejects runtime requires other than ffi", function()
      local dir = util.write_tmp_dir(finally, {
         ["external.d.tl"] = "local type External = integer\nreturn External",
      })
      local input = util.write_tmp_file(finally, [[
         --#pragma strict on
         local type External = require("external")
         local answer: External = 42
         return answer
      ]])
      local output, status = run("gen", { "--gen-target=c", "-I", string.format("%q", dir) }, input, "-o", "-")
      util.assert_popen_close(0, unpack(status))
      assert.match("int main(void)", output, 1, true)
      assert.not_matches("Wrote:", output, 1, true)

      local runtime = util.write_tmp_file(finally, [[
         --#pragma strict on
         local tables = require("auxlib.tables")
      ]])
      output, status = generate(runtime)
      util.assert_popen_close(1, unpack(status))
      assert.match("only supports runtime require('ffi')", output, 1, true)
   end)

   it("checks C call signatures and unsupported declarations before writing output", function()
      local malformed = util.write_tmp_file(finally, [=[
         --#pragma strict on
         local ffi = require("auxlib.ffi")
         ffi.cdef! [[int bad(int (*callback)(int));]]
      ]=])
      local output, status = generate(malformed)
      util.assert_popen_close(1, unpack(status))
      assert.match("unsupported C declarator", output, 1, true)

      local wrong_type = util.write_tmp_file(finally, [=[
         --#pragma strict on
         local ffi = require("ffi")
         ffi.cdef [[int puts(const char *);]]
         C.puts(42)
      ]=])
      output, status = generate(wrong_type)
      util.assert_popen_close(1, unpack(status))
      assert.match("expected string", output, 1, true)
   end)

   it("returns an error from the API for unsupported native values", function()
      local compiler = teal.compiler({ gen_target = "c" })
      local input = compiler:input("--#pragma strict on\nlocal values = { 1, 2 }", "native.tl")
      local code, _, diagnostics = input:gen()
      assert.is_nil(code)
      assert.same({}, diagnostics.type_errors)
      assert.match("native.tl:2:", diagnostics.gen_error, 1, true)
      assert.match("C target: unsupported", diagnostics.gen_error, 1, true)
   end)
end)
