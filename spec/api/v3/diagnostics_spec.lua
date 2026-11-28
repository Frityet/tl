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
end)
