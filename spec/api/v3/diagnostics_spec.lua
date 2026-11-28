local teal = require("teal")

local function check(code, opts, filename)
   local compiler = teal.compiler(opts)
   local module, result = compiler:input(code, filename):check()
   assert.same({}, result.syntax_errors)
   return result, module
end

local function codes(result)
   local found = {}
   for _, diagnostic in ipairs(result.diagnostics) do
      found[#found + 1] = diagnostic.code
   end
   return found
end

local function counts(result)
   local found = {}
   for _, diagnostic in ipairs(result.diagnostics) do
      found[diagnostic.code] = (found[diagnostic.code] or 0) + 1
   end
   return found
end

describe("diagnostics", function()
   it("leaves the default compiler result and generated code intact", function()
      local source = "local unused = 10\nif 0 then print('example') end"
      local baseline, baseline_module = check(source)
      local selected, selected_module = check(source, {diagnostics = {lua = true}})
      assert.same({}, baseline.diagnostics)
      assert.same(baseline.warnings, selected.warnings)
      assert.same(baseline.type_errors, selected.type_errors)
      assert.same(baseline_module:gen(), selected_module:gen())
      assert.same({"lua/truthy-zero-or-empty"}, codes(selected))
      local finding = selected.diagnostics[1]
      assert.same({2, 4, 2, 5}, {finding.y, finding.x, finding.end_y, finding.end_x})
   end)

   it("applies rule, pack, and all options in specificity order", function()
      local source = "if 0 then end\nfor i = 4, 1 do print(i) end\nprint(1 / 0)"
      local result = check(source, {diagnostics = {
         all = "error",
         lua = "info",
         ["lua/truthy-zero-or-empty"] = true,
         ["lua/empty-numeric-for"] = false,
      }})
      assert.same({"lua/truthy-zero-or-empty", "lua/zero-divisor"}, codes(result))
      assert.equals("warning", result.diagnostics[1].severity)
      assert.equals("info", result.diagnostics[2].severity)
   end)

   it("validates selectors and exposes target-aware catalog levels", function()
      local function levels(opts)
         local by_id = {}
         for _, rule in ipairs(teal.diagnostic_catalog(opts)) do
            assert.is_nil(by_id[rule.id])
            by_id[rule.id] = rule
         end
         return by_id
      end
      local defaults = levels()
      local selected = levels({diagnostic_target = "luajit", diagnostics = {
         luajit = true, ["luajit-ffi/unknown-abi"] = "error",
      }})
      assert.equals("off", defaults["lua/zero-divisor"].level)
      assert.is_false(defaults["luajit/hot-print"].available)
      assert.equals("hint", selected["luajit/hot-print"].level)
      assert.equals("error", selected["luajit-ffi/unknown-abi"].level)
      assert.has_error(function() teal.compiler({diagnostics = {luajit_ffi = true}}) end)
      assert.has_error(function() teal.compiler({diagnostics = {lua = "note"}}) end)
   end)

   it("uses typed nilability and ignores Teal-only rules in Lua files", function()
      local source = [[
local function choose(flag: boolean | nil): boolean
   return flag or true
end
print(choose(false))]]
      local typed = check(source, {diagnostics = {teal = true}})
      assert.same({}, typed.type_errors)
      assert.same({"teal/boolean-default-masks-false"}, codes(typed))
      local lua = check("print(false or true)", {diagnostics = {teal = true}}, "choose.lua")
      assert.same({}, lua.diagnostics)
   end)

   it("tracks local aliases without reporting rebound or shadowed functions", function()
      local source = [[
local rng = math["random"]
rng(4, 1)
do
   local math = { random = function(_, _) return 1 end }
   math.random(4, 1)
end
rng = function(_, _) return 1 end
rng(4, 1)
math.random(4, 1)]]
      local result = check(source, {diagnostics = {["lua/random-empty-interval"] = true}}, "aliases.lua")
      assert.same({"lua/random-empty-interval", "lua/random-empty-interval"}, codes(result))
      assert.equals(2, result.diagnostics[1].y)
      assert.equals(9, result.diagnostics[2].y)
   end)

   it("gates LuaJIT findings by the analysis target and separates loop bodies from nested functions", function()
      local source = [[
local ffi = require("ffi")
local function limit(_: ffi.CType): integer return 1 end
for i = 1, limit(ffi.typeof("int")) do
   local function inner(): ffi.CType
      return ffi.typeof("int")
   end
   print(i, ffi.typeof("char *"), inner())
end]]
      local settings = {["luajit/hot-print"] = true, ["luajit-ffi/typeof-in-loop"] = true}
      local stock = check(source, {diagnostics = settings, gen_target = "5.1"})
      assert.same({}, stock.type_errors)
      assert.same({}, stock.diagnostics)
      local result = check(source, {diagnostics = settings, gen_target = "5.1", diagnostic_target = "luajit"})
      assert.same({}, result.type_errors)
      assert.same({"luajit/hot-print", "luajit-ffi/typeof-in-loop"}, codes(result))
      assert.equals(7, result.diagnostics[2].y)
   end)

   it("accepts supported packing directives and keeps FFI calls tied to the library", function()
      local source = [=[
local ffi = require("ffi")
local declare = ffi.cdef
declare([[#pragma pack(push, 1)
struct item { int x; };
#pragma pack(pop)]])
declare([[#include <stddef.h>]])
local function custom(ffi)
   ffi.cdef([[#include <stddef.h>]])
end
]=]
      local result = check(source, {diagnostics = {["luajit-ffi/cdef-preprocessor"] = true}, diagnostic_target = "luajit"}, "ffi-use.lua")
      assert.same({"luajit-ffi/cdef-preprocessor"}, codes(result))
      assert.equals(6, result.diagnostics[1].y)
   end)

   it("ignores C keywords in comments and strings and handles unfinished C comments", function()
      local source = [=[
local ffi = require("ffi")
ffi.cdef[[
/* volatile long double
#include <ignored.h>
*/
extern int example(void) __asm__("volatile long double // ignored");
extern volatile long double value;
]]
]=]
      source = source .. "ffi.cdef[[/* " .. string.rep("/* ", 10000) .. "volatile long double]]\n"
      local result = check(source, {diagnostic_target = "luajit", diagnostics = {
         ["luajit-ffi/cdef-preprocessor"] = true,
         ["luajit-ffi/cdef-volatile"] = true,
         ["luajit-ffi/cdef-long-double"] = true,
      }}, "ffi-comments.lua")
      assert.same({["luajit-ffi/cdef-volatile"] = 1, ["luajit-ffi/cdef-long-double"] = 1}, counts(result))
   end)

   it("recognizes recorder-sensitive call shapes and loop closures", function()
      local source = [[
local search, unpack_values = string.find, unpack
local function scan(text, values, limit, choose)
   search(text, "%d")
   for i = 1, limit do
      search(text, "%d")
      search(text, "%d", 1, true)
      search(text, "literal")
      print(select(i, 11, 22))
      print(select(1, 11, 22))
      print(unpack_values(values, 1, i))
      print(unpack_values(values, 1, 2))
      print(getfenv(), getfenv(0))
      local function item()
         search(text, "%d")
         return i
      end
      local value
      if choose then value = 1 else value = "one" end
      print(value, item())
   end
end]]
      local rules = {
         ["luajit/loop-closure"] = true,
         ["luajit/loop-branch-value-type"] = true,
         ["luajit/string-find-pattern"] = true,
         ["luajit/select-dynamic-index"] = true,
         ["luajit/unpack-bounds"] = true,
         ["luajit/getfenv-recorder"] = true,
      }
      local result = check(source, {diagnostic_target = "luajit", diagnostics = rules}, "trace.lua")
      for code in pairs(rules) do rules[code] = 1 end
      assert.same(rules, counts(result))
   end)

   it("detects FFI constructor and ctype guard limits without executing source", function()
      local source = [[
local ffi = require("ffi")
error("the fixture must only be checked")
for i = 1, 64 do
   local _ = ffi.new("int[?]", i, 1)
   local _ = ffi.new("int[?]", i)
   local _ = ffi.new("int[3]", {1, 2, 3})
   local _ = ffi.new("char[129]", 1)
   local _ = ffi.new("char[129]")
   local _ = ffi.sizeof("int[?]", i)
   local _ = ffi.sizeof("int[2]")
   local _ = ffi.new(i % 2 == 0 and "int" or "double", i)
   print(tonumber(ffi.cast("uint64_t", i)), ffi.cast("uint64_t", i) + 1)
end]]
      local rules = {
         ["luajit-ffi/vla-initializer-in-loop"] = true,
         ["luajit-ffi/array-table-initializer-in-loop"] = true,
         ["luajit-ffi/large-byte-array-initializer-in-loop"] = true,
         ["luajit-ffi/sizeof-variable-length-in-loop"] = true,
         ["luajit-ffi/ctype-choice-in-loop"] = true,
         ["luajit-ffi/int64-tonumber"] = true,
         ["luajit-ffi/boxed-scalar-arithmetic"] = true,
      }
      local result = check(source, {diagnostic_target = "luajit", diagnostics = rules}, "ffi-trace.lua")
      for code in pairs(rules) do rules[code] = 1 end
      assert.same(rules, counts(result))
   end)

   it("uses loaded-library aliases and visible C prototypes for specific findings", function()
      local source = [=[
local ffi = require("ffi")
local lib = ffi.load("fixture")
ffi.cdef[[
   struct Pair { int value; };
   struct Pair result(int val);
   void consume(struct Pair val);
   void scalar(struct Pair *val);
   void visit(void (*callback)(int));
]]
local cached = lib.scalar
local temporary = ffi.load("fixture").scalar
local _ = ffi.load("fixture").constant
local callback = ffi.cast("void (*)(int)", function(_) end)
for i = 1, 64 do
   cached(nil)
   temporary(nil)
   lib[i == 1 and "scalar" or "consume"](nil)
   lib.visit(callback)
   lib.visit(function(_) end)
   lib.consume(lib.result(i))
   lib.scalar(nil)
   local lib = {visit = function(_) end}
   lib.visit(function(_) end)
end]=]
      local result = check(source, {diagnostic_target = "luajit", diagnostics = {
         ["luajit/loop-indexed-dispatch"] = true,
         ["luajit-ffi/cached-symbol-call"] = true,
         ["luajit-ffi/temporary-library-symbol"] = true,
         ["luajit-ffi/dynamic-symbol-call"] = true,
         ["luajit-ffi/aggregate-by-value-call"] = true,
         ["luajit-ffi/callback-call-in-loop"] = true,
         ["luajit-ffi/implicit-callback"] = true,
      }}, "ffi-namespaces.lua")
      assert.same({
         ["luajit-ffi/cached-symbol-call"] = 1,
         ["luajit-ffi/temporary-library-symbol"] = 1,
         ["luajit-ffi/dynamic-symbol-call"] = 1,
         ["luajit-ffi/aggregate-by-value-call"] = 2,
         ["luajit-ffi/callback-call-in-loop"] = 1,
         ["luajit-ffi/implicit-callback"] = 1,
      }, counts(result))
   end)

   it("skips incomplete sources and keeps diagnostics available on recall", function()
      local compiler = teal.compiler({diagnostics = {lua = true}})
      compiler:enable_type_reporting(true)
      local _, incomplete = compiler:input("if 0 then\n  local x =\nend", "broken.tl"):check()
      assert.is_true(#incomplete.syntax_errors > 0)
      assert.same({}, incomplete.diagnostics)
      local _, checked = compiler:input("if 0 then end", "checked.tl"):check()
      local _, recalled = compiler:recall("checked.tl")
      assert.same({"lua/truthy-zero-or-empty"}, codes(checked))
      assert.same(checked.diagnostics, recalled.diagnostics)
   end)

   it("flags incompatible casts, impossible tests, and typeof! reflection pitfalls", function()
      local source = [[
local s: string = "123"
local n: integer = s as integer
local ok = s is number
local never_nil = n == nil
local function inspect_any(raw: any): reflection.Type
   return typeof!(raw)
end
local function inspect<T>(x: T): reflection.Type
   return typeof!(x)
end
local _ = inspect_any(s)
local _ = inspect(n)
local _ = n as number
print(ok, never_nil)]]
      local rules = {
         ["teal/cast-between-primitives"] = true,
         ["teal/impossible-type-test"] = true,
         ["teal/impossible-nil-comparison"] = true,
         ["teal/typeof-untyped"] = true,
         ["teal/typeof-type-parameter"] = true,
      }
      local result = check(source, {diagnostics = rules})
      assert.same({}, result.type_errors)
      for code in pairs(rules) do rules[code] = 1 end
      assert.same(rules, counts(result))
   end)

   it("detects NaN equality, self comparisons, duplicate branches, modified for variables, and pattern/gsub mistakes", function()
      local source = [[
local x: number = 1.0
local s: string = "abc"
if x == 0 / 0 then end
if x ~= x then end
if x < x then end
if s == s then end
if x == 1 then
   print(1)
elseif x == 1 then
   print(2)
end
for i = 1, 5 do
   i = i + 1
end
local _ = string.match(s, "(%1)")
local _ = string.match(s, "([a-z]+)%1")
local _ = string.find(s, "%0")
local _ = string.find(s, "%0", 1, true)
local _ = string.gsub(s, "(a)", "%2")
local _ = string.gsub(s, "a", "%1")
local _ = string.gsub(s, "a", "100%")
local _ = string.gsub(s, "a", "100%%")]]
      local result = check(source, {diagnostics = {
         ["lua/nan-equality"] = true,
         ["lua/self-comparison"] = true,
         ["lua/duplicate-branch-condition"] = true,
         ["lua/for-control-var-modified"] = true,
         ["lua/invalid-pattern-backreference"] = true,
         ["lua/invalid-gsub-replacement"] = true,
      }})
      assert.same({}, result.type_errors)
      assert.same({
         ["lua/nan-equality"] = 1,
         ["lua/self-comparison"] = 2,
         ["lua/duplicate-branch-condition"] = 1,
         ["lua/for-control-var-modified"] = 1,
         ["lua/invalid-pattern-backreference"] = 2,
         ["lua/invalid-gsub-replacement"] = 2,
      }, counts(result))
   end)

   it("detects multi-result loop varargs, %p formatting, hot tostring, and FFI fill/VLA/null-pointer bugs", function()
      local source = [[
local ffi = require("ffi")
local function step(...: integer)
   local t: {integer} = { 1, 2 }
   for i = 1, 10 do
      local first = select(1, ...)
      print(...)
      local _ = { ... }
      local _ = string.format("%p", t)
      local _ = string.format("%d", i)
      local _ = tostring(t)
      local _ = tostring(i)
      local _ = math.fmod(i, 3)
      print(first)
   end
end
step(1, 2)
local buf: ffi.CData = ffi.new("uint8_t[8]")
local _: ffi.CData = ffi.new("int[?]", -4)
ffi.fill(buf, 0, 8)
ffi.fill(buf, 8, 256)
ffi.fill(buf, 8, 0)
local ptr = ffi.cast("void *", 0)
if ptr then end
if not ptr then end
if ptr ~= nil then end]]
      local result = check(source, {diagnostic_target = "luajit", diagnostics = {
         ["luajit/loop-vararg"] = true,
         ["luajit/string-format-pointer"] = true,
         ["luajit/hot-tostring"] = true,
         ["luajit/unrecorded-library-call"] = true,
         ["luajit-ffi/negative-vla-length"] = true,
         ["luajit-ffi/fill-zero-length"] = true,
         ["luajit-ffi/fill-byte-range"] = true,
         ["luajit-ffi/truthy-null-pointer"] = true,
      }})
      assert.same({}, result.type_errors)
      assert.same({
         ["luajit/loop-vararg"] = 2,
         ["luajit/string-format-pointer"] = 1,
         ["luajit/hot-tostring"] = 1,
         ["luajit/unrecorded-library-call"] = 1,
         ["luajit-ffi/negative-vla-length"] = 1,
         ["luajit-ffi/fill-zero-length"] = 1,
         ["luajit-ffi/fill-byte-range"] = 1,
         ["luajit-ffi/truthy-null-pointer"] = 2,
      }, counts(result))
   end)
end)
