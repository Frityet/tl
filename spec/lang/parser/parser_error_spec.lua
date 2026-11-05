local tl = require("teal.api.v2")
local util = require("spec.util")

describe("parser errors", function()
   it("reports damaged macro bodies without compiling recovery blocks", function()
      for _, code in ipairs({
         "local macro broken!(x: Expre)\nlocal t = {value = }",
         "local macro broken!(x: Expression)\nlocal t = {value = }",
         "local macro broken!(x: Expression)\nreturn {value = }\nend",
         'local macro broken!(x: Expression): Operator<"@", infix, additive>\nreturn {value = }\nend',
      }) do
         local _, errs = tl.parse(code, "broken.tl")
         assert.is_true(#errs > 0, code)
         for _, err in ipairs(errs) do
            assert.equals("broken.tl", err.filename)
         end
      end
   end)

   it("does not execute macros when the input has syntax errors", function()
      local _, errs = tl.parse([[
         local macro broken!(): Expression
            error("macro should not execute")
         end
         broken!()
         local unfinished =
      ]], "broken.tl")
      assert.is_true(#errs > 0)
      for _, err in ipairs(errs) do
         assert.not_matches("macro should not execute", err.msg, 1, true)
      end
   end)

   it("names invalid macro splices in diagnostics", function()
      for _, declaration in ipairs({ "", "local missing = 42", "local missing = false" }) do
         local _, errs = tl.parse(table.concat({
            "local macro broken!(x: Expression): Expression",
            declaration,
            "return `($missing)($x)`",
            "end",
            "local value = broken!(1)",
         }, "\n"), "broken.tl")
         assert.equals(1, #errs)
         assert.matches("macro splice '$missing' expected a Block, got ", errs[1].msg, 1, true)
         assert.not_matches("teal/macro_eval", errs[1].msg, 1, true)
         assert.equals("broken.tl", errs[1].filename)
         assert.equals(5, errs[1].y)
      end
   end)

   it("reports invalid macro return values without indexing scalars", function()
      for _, value in ipairs({ "nil", "false", "1", '"text"', "{}" }) do
         local _, errs = tl.parse(
            "local macro broken!(): Expression return " .. value .. " end; local x = broken!()",
            "broken.tl")
         assert.equals(1, #errs)
         assert.equals("macro 'broken' did not return a Block", errs[1].msg)
      end
   end)

   it("parse errors include filename", function ()
      local result = tl.check_string("local x 1", nil, "foo.tl")
      assert.same("foo.tl", result.syntax_errors[1].filename, "parse errors should contain .filename property")
   end)

   it("parse errors in a required package include filename of required file", function ()
      util.mock_io(finally, {
         ["bar.tl"] = [[
            local x 1
         ]],
      })

      local code = [[
         local bar = require "bar"
      ]]
      local result = tl.check_string(code, nil, "foo.tl")
      assert.is_not_nil(string.match(result.env.loaded["./bar.tl"].syntax_errors[1].filename, "bar.tl$"), "errors should contain .filename property")
   end)
end)
