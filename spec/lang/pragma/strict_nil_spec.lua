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

   it("desugars nullable union members and adds nil once", util.check_types([[
--#pragma strict_nil on
local value: string? | number?
   ]], {
      { y = 2, x = 14, type = "string | number | nil" },
   }))

   it("accepts nullable types in aliases, groups, and generic arguments", util.check([[
      --#pragma strict_nil on
      local type Maybe = string? | number?
      local function to_explicit(value: Maybe): string | number | nil
         return value
      end
      local function from_explicit(value: string | number | nil): Maybe
         return value
      end
      local grouped: (string | number)? = from_explicit(nil)
      local right_grouped: string | (number | nil)? = grouped
      local record Box<T>
         value: T
      end
      local boxed: Box<number?> = { value = nil }
      local exact_nil: nil? = nil
      to_explicit(right_grouped)
   ]]))

   it("requires nullable function arguments when only the type has a question mark", util.check_type_error([[
      --#pragma strict_nil on
      local read: function(string?): string? = function(value: string?): string?
         return value
      end
      read(nil)
      read()
   ]], {
      { y = 6, msg = "wrong number of arguments" },
   }))

   it("supports independently optional and nullable function arguments", util.check([[
      --#pragma strict_nil on
      local read: function(? string?): (string)? = function(value?: string?): (string)?
         return value
      end
      read()
      read(nil)
   ]]))
end)
