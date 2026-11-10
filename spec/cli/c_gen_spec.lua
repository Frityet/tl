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

local function compile_and_run(finally, c_file, link_math, modules)
   local status = os.execute("clang --version >" .. util.os_null .. " 2>&1")
   if status ~= true and status ~= 0 then
      pending("Clang is unavailable")
      return
   end
   local binary = util.get_tmp_filename(finally, "exe")
   local flags = link_math and util.os_sep ~= "\\" and " -lm" or ""
   local sources = { ("%q"):format(c_file) }
   for _, module in ipairs(modules or {}) do table.insert(sources, ("%q"):format(module)) end
   local cmd = ("clang -std=c11 -Wall -Wextra -Werror %s -o %q%s 2>&1"):format(table.concat(sources, " "), binary, flags)
   local compiler = assert(io.popen(cmd, "r"))
   local diagnostics = compiler:read("*a")
   util.assert_popen_close(0, compiler:close())
   assert.equal("", diagnostics)
   local process = assert(io.popen(("%q"):format(binary), "r"))
   local result = process:read("*a")
   util.assert_popen_close(0, process:close())
   return (result:gsub("\r\n", "\n"))
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
      local input = util.write_tmp_file(finally, source)
      local c_file = util.get_tmp_filename(finally, "c")
      local output, status = generate(input, "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.match("Wrote:", output, 1, true)
      local result = compile_and_run(finally, c_file)
      if result then assert.equal("Hello, world! 6 2 2.0\n", result) end
   end)

   it("generates one translation unit per module and links lazy shared state", function()
      local dir = util.write_tmp_dir(finally, {
         ["main.tl"] = [=[
            --#pragma strict on
            local ffi = require("auxlib.ffi")
            ffi.cdef! [[typedef unsigned long LocalCode; union LocalTag;]]
            local function unused(): boolean return require("unused") end
            print("entry")
            local stats = require("stats")
            local same = require("stats.init")
            assert(stats == same)
            local sequence: {integer} = {1, 2, 3}
            table.insert(sequence, 2, 4)
            sequence[#sequence + 1] = 8
            local removed: number | nil = table.remove(sequence)
            assert(removed == 8)
            local total = stats.sum(sequence)
            local value = tonumber("6.25")
            if value == nil then return 1 end
            local mathlib = require("math")
            local words: {string} = {string.upper("total"), tostring(total)}
            print(table.concat(words, " "), mathlib.floor(value), stats.next(), same.next())
         ]=],
         stats = {
            ["init.tl"] = [[
               local counter = require("counter")
               local function sum(values: {integer}): integer
                  local total = 0
                  for _, value in ipairs(values) do total = total + value end
                  return total
               end
               return { sum = sum, next = counter.next }
            ]],
            ["counter.tl"] = [=[
               local ffi = require("auxlib.ffi")
               ffi.cdef! [[typedef int LocalCode; struct LocalTag; int puts(const char *);]]
               C.puts("counter")
               local count = 0
               local record Counter end
               function Counter.next(): integer
                  count = count + 1
                  return count
               end
               return Counter
            ]=],
         },
         ["unused.tl"] = [[print("unused")]],
      })
      local c_file = dir .. "program.c"
      local modules_dir = dir .. "program.modules" .. util.os_sep
      local output, status = generate(dir .. "main.tl", "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.match("Wrote:", output, 1, true)
      local entry = util.read_file(c_file)
      local counter = util.read_file(modules_dir .. "tl_counter.c")
      local header = util.read_file(modules_dir .. "abi.h")
      assert.match('#include "program.modules/abi.h"', entry, 1, true)
      assert.match('#include "abi.h"', counter, 1, true)
      assert.not_matches('"counter"', entry, 1, true)
      assert.match('"counter"', counter, 1, true)
      assert.not_matches("LocalTag", header, 1, true)
      local result = compile_and_run(finally, c_file, true, {
         modules_dir .. "tl_counter.c", modules_dir .. "tl_stats.c", modules_dir .. "tl_unused.c",
      })
      if result then assert.equal("entry\ncounter\nTOTAL 10\t6\t1\t2\n", result) end

      output, status = generate(dir .. "main.tl", "-o", "-")
      util.assert_popen_close(1, unpack(status))
      assert.match("Teal imports require a file output path", output, 1, true)

      local compiler = teal.compiler({ gen_target = "c" })
      local module = assert(compiler:open(dir .. "main.tl")):check()
      local project = assert(module:gen_c())
      assert.same(3, #project.modules)
      assert.match('#include "teal_modules/abi.h"', project.entry, 1, true)
   end)

   it("removes stale generated units when the import graph changes", function()
      local dir = util.write_tmp_dir(finally, {
         ["main.tl"] = '--#pragma strict on\nrequire("first")',
         ["first.tl"] = 'print("first")',
         ["second.tl"] = 'print("second")',
      })
      local main, c_file = dir .. "main.tl", dir .. "program.c"
      local modules_dir = dir .. "program.modules" .. util.os_sep
      local output, status = generate(main, "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.match("tl_first.c", output, 1, true)

      local fd = assert(io.open(main, "wb"))
      fd:write('--#pragma strict on\nrequire("second")')
      fd:close()
      output, status = generate(main, "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.match("tl_second.c", output, 1, true)
      assert.is_nil(io.open(modules_dir .. "tl_first.c", "rb"))

      fd = assert(io.open(main, "wb"))
      fd:write('--#pragma strict on\nprint("standalone")')
      fd:close()
      output, status = generate(main, "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.is_nil(io.open(modules_dir .. "tl_second.c", "rb"))
      assert.is_nil(io.open(modules_dir .. "abi.h", "rb"))
   end)

   it("lowers string methods, nullable scalars, and typed records", function()
      local input = util.write_tmp_file(finally, [[
         --#pragma strict on
         local record Report
            total: number
            label: string
         end
         local report: Report = { total = math.sqrt(81), label = "label" }
         local label = report.label:sub(2, -2):upper()
         local invalid = tonumber("word")
         local valid = tonumber("2.5")
         if not (invalid ~= nil and invalid > 0) and valid and valid > 0 then
            report.total = report.total + valid
         end
         local double = function (x: number): number return x * 2 end
         print(label, double(report.total), string.rep("x", 3, "-"), type(invalid))
      ]])
      local c_file = util.get_tmp_filename(finally, "c")
      local output, status = generate(input, "-o", c_file)
      util.assert_popen_close(0, unpack(status))
      assert.match("Wrote:", output, 1, true)
      local result = compile_and_run(finally, c_file, true)
      if result then assert.equal("ABE\t23.0\tx-x-x\tnil\n", result) end
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

   it("permits type imports and requires a Teal implementation for runtime imports", function()
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
         local external = require("external")
      ]])
      output, status = run("gen", { "--gen-target=c", "-I", string.format("%q", dir) }, runtime)
      util.assert_popen_close(1, unpack(status))
      assert.match("module 'external' needs a .tl implementation", output, 1, true)
   end)

   it("reports dependency type errors and circular or dynamic imports", function()
      local dir = util.write_tmp_dir(finally, {
         ["main.tl"] = '--#pragma strict on\nrequire("cycle")',
         ["cycle.tl"] = 'require("main")',
         ["bad_main.tl"] = '--#pragma strict on\nrequire("bad")',
         ["bad.tl"] = 'local value: integer = nil',
      })
      local c_file = util.get_tmp_filename(finally, "c")
      local output, status = generate(dir .. "main.tl", "-o", c_file)
      util.assert_popen_close(1, unpack(status))
      assert.match("circular C module import 'main'", output, 1, true)
      assert.is_nil(io.open(c_file, "rb"))

      output, status = generate(dir .. "bad_main.tl", "-o", c_file)
      util.assert_popen_close(1, unpack(status))
      assert.match("bad.tl:1:", output, 1, true)
      assert.match("got nil, expected integer", output, 1, true)
      assert.is_nil(io.open(c_file, "rb"))

      local dynamic = util.write_tmp_file(finally, '--#pragma strict on\nlocal name = "math"\nrequire(name)')
      output, status = generate(dynamic, "-o", c_file)
      util.assert_popen_close(1, unpack(status))
      assert.match("requires a literal module name", output, 1, true)
      assert.is_nil(io.open(c_file, "rb"))
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
      local input = compiler:input("--#pragma strict on\nlocal values: {string:integer} = { key = 1 }", "native.tl")
      local code, _, diagnostics = input:gen()
      assert.is_nil(code)
      assert.same({}, diagnostics.type_errors)
      assert.match("native.tl:2:", diagnostics.gen_error, 1, true)
      assert.match("C target: unsupported", diagnostics.gen_error, 1, true)
   end)
end)
