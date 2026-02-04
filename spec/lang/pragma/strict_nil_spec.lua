local util = require("spec.util")

describe("strict nil", function()
   it("is off by default in tests", util.check([[
      local n: integer = nil
   ]]))

   it("can be disabled", util.check([[
      --#pragma strict_nil off
      local n: integer = nil
   ]]))

   it("can be enabled", util.check_type_error([[
      --#pragma strict_nil on
      local n: integer = nil
   ]], {
      { msg = "got nil, expected integer" }
   }))

   it("can be re-disabled", util.check_type_error([[
      --#pragma strict_nil on
      local n: integer = nil
      --#pragma strict_nil off
      local m: integer = nil
   ]], {
      { msg = "in local declaration: n: got nil, expected integer" }
   }))

   it("requires non-nilable record fields in literals", util.check_type_error([[
      --#pragma strict_nil on
      local record R<S>
         k: S
         a: integer | nil
      end

      local x: R<integer> = {}
   ]], {
      { msg = "record literal is missing required fields (missing: k)" }
   }))

   it("treats optional parameters as nilable", util.check_type_error([[
      --#pragma strict_nil on
      local record R<S>
         k: S
         a: integer | nil
      end

      local function test(x?: integer): R<integer>
         local r: R<integer> = { k = x }
         return r
      end
   ]], {
      { msg = "in record field: k: got integer | nil, expected integer" }
   }))
end)
