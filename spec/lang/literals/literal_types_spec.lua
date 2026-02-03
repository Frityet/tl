local util = require("spec.util")

describe("literal types", function()
   it("accepts matching string literals", util.check([[
      local s: "hello" = "hello"
   ]]))

   it("rejects mismatched string literals", util.check_type_error([[
      local s: "hello" = "bye"
   ]], {
      { msg = "got string \"bye\", expected string \"hello\"" }
   }))

   it("accepts matching integer literals", util.check([[
      local n: 1 = 1
   ]]))

   it("rejects mismatched integer literals", util.check_type_error([[
      local n: 1 = 2
   ]], {
      { msg = "got integer 2, expected integer 1" }
   }))

   it("accepts matching number literals", util.check([[
      local n: 1.5 = 1.5
   ]]))

   it("rejects mismatched number literals", util.check_type_error([[
      local n: 1.5 = 2.5
   ]], {
      { msg = "got number 2.5, expected number 1.5" }
   }))

   it("accepts matching boolean literals", util.check([[
      local b: true = true
   ]]))

   it("rejects mismatched boolean literals", util.check_type_error([[
      local b: true = false
   ]], {
      { msg = "got boolean false, expected boolean true" }
   }))

   it("accepts nil type", util.check([[
      local n: nil = nil
   ]]))

   it("rejects non-nil for nil type", util.check_type_error([[
      local n: nil = 1
   ]], {
      { msg = "got integer, expected nil" }
   }))

   it("accepts matching literal type arguments", util.check([[
      local record R<S>
         k: S
      end

      local x: R<"test"> = { k = "test" }
   ]]))

   it("rejects mismatched literal type arguments", util.check_type_error([[
      local record R<S>
         k: S
      end

      local x: R<"test"> = { k = "tes4t" }
   ]], {
      { msg = "in record field: k: got string \"tes4t\", expected string \"test\"" }
   }))
end)
