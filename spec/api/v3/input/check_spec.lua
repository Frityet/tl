local util = require("spec.util")
local teal = require("teal")

describe("Input.check", function()
   it("recovers from failed macro expansion with type reporting enabled", function()
      local cases = {
         { "local value = missing!(1)", "unknown macro 'missing'" },
         { "local macro bad!() return nil end\nlocal value = bad!()", "did not return a Block" },
         { "local macro one!(x: Expression) return x end\nlocal value = one!()", "expects 1 argument" },
      }
      for _, case in ipairs(cases) do
         local compiler = teal.compiler()
         compiler:enable_type_reporting(true)
         local input = compiler:input(case[1] .. '\nlocal after: integer = "wrong"\nprint(value, after)\n', "macro-recovery.tl")
         local module, check_err = input:check()
         assert(module)
         local found = false
         for _, err in ipairs(check_err.syntax_errors) do
            if err.msg:find(case[2], 1, true) then found = true end
         end
         assert.is_true(found)
         assert.is_true(#check_err.type_errors > 0)
         assert(compiler:get_type_report())
      end
   end)

   it("can check Teal code", function()
      local tl_code = [[
         local foo: string = "hello"
         local planet: integer = 3
      ]]

      local compiler = teal.compiler()
      local input = compiler:input(tl_code)
      local module, check_err = input:check()

      assert(module)
      assert.same(0, #check_err.syntax_errors)
      assert.same(0, #check_err.type_errors)
      assert.same(2, #check_err.warnings)
   end)

   it("reports syntax errors from the lexer", function()
      local tl_code = [[
         2.e + 1
      ]]

      local compiler = teal.compiler()
      local input = compiler:input(tl_code)
      local module, check_err = input:check()

      assert.is_nil(module)
      assert.same(1, #check_err.syntax_errors)
      assert.same(0, #check_err.type_errors)
      assert.same(0, #check_err.warnings)
   end)

   it("reports syntax errors from parsing", function()
      local tl_code = [[
         if if if
      ]]

      local compiler = teal.compiler()
      local input = compiler:input(tl_code)
      local module, check_err = input:check()

      assert.is_nil(module)
      assert.same(3, #check_err.syntax_errors)
      assert.same(0, #check_err.type_errors)
      assert.same(0, #check_err.warnings)
   end)

   it("reports type errors from checking", function()
      local tl_code = [[
         local x: number = "oops"
      ]]

      local compiler = teal.compiler()
      local input = compiler:input(tl_code)
      local module, check_err = input:check()

      assert(module)
      assert.same(0, #check_err.syntax_errors)
      assert.same(1, #check_err.type_errors)
      assert.same(1, #check_err.warnings)
   end)
end)
