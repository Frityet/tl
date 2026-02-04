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

   it("preserves literal types in local type aliases", util.check_type_error([[
      local type S = "hello"
      local type I = 1
      local type N = 1.5
      local type B = true

      local s: S = "bye"
      local i: I = 2
      local n: N = 2.5
      local b: B = false
   ]], {
      { msg = "in local declaration: s: got string \"bye\", expected S" },
      { msg = "in local declaration: i: got integer 2, expected I" },
      { msg = "in local declaration: n: got number 2.5, expected N" },
      { msg = "in local declaration: b: got boolean false, expected B" },
   }))

   it("preserves literal types in function signatures", util.check([[
      local function get(x: integer): "hello" | "world"
         if x < 42 then
            return "hello"
         else
            return "world"
         end
      end

      local v: "hello" | "world" = get(10)
   ]]))

   it("rejects non-member return values for literal unions", util.check_type_error([[
      local function get(x: integer): 1 | 2
         if x < 42 then return 1 else return 3 end
      end
   ]], {
      { msg = "in return value: got integer 3, expected integer 1 | integer 2" },
   }))

   it("keeps literal unions from function returns in local inference", util.check([[
      local function get(x: integer): 1 | 2
         if x < 42 then return 1 else return 2 end
      end

      local record R
         k: 1 | 2 | 3
      end

      local v = get(10)
      local x: R = {}

      if v then
         x.k = v
      end
   ]]))

   it("narrows literal unions with equality across constant types", util.check([[
      local function get(x: integer): 1 | 2 | 3 | 4
         if x < 42 then return 1 else return 3 end
      end

      local record R
         k: 1 | 2 | 3
      end

      local v = get(10)
      local x: R = {}

      if v and (v == 1 or v == 2) then
         x.k = v
      end

      local s: "a" | "b" | "c" = "a"
      if s == "a" or s == "b" then
         local t: "a" | "b" = s
      end

      local n: 1.5 | 2.5 | 3.5 = 1.5
      if n == 1.5 or n == 2.5 then
         local t: 1.5 | 2.5 = n
      end

      local b: boolean = true
      if b == true then
         local t: true = b
      end

      local enum Color
         "red"
         "blue"
         "green"
      end

      local c: Color = "red"
      if c == "red" or c == "blue" then
         local t: "red" | "blue" = c
      end
   ]]))

   it("rejects non-member boolean literal returns", util.check_type_error([[
      local function only_true(): true
         return false
      end
   ]], {
      { msg = "in return value: got boolean false, expected boolean true" },
   }))

   it("rejects assigning literal unions to literal fields", util.check_type_error([[
      local function get(x: integer): "hello" | "world"
         if x < 42 then return "hello" else return "world" end
      end

      local record R
         k: "hello"
      end

      local v: "hello" | "world" = get(10)
      local x: R = { k = "hello" }

      if v ~= "hello" then
         x.k = v
      end
   ]], {
      { msg = "in assignment: got string \"hello\" | string \"world\", expected string \"hello\"" }
   }))
end)
