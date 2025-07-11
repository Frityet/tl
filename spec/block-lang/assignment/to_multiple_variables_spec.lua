local util = require("spec.block-util")

describe("assignment to multiple variables", function()
   it("from a function call", util.check([[
      local function foo(): boolean, string
         return true, "yeah!"
      end
      local a, b = foo()
      print(b .. " right!")
   ]]))

   it("adjusts arity of tuple", util.check([[
      local function foo(): boolean, string
         return true, "yeah!"
      end
      local a, b, c = 2, foo()
      print(c .. " right!")
   ]]))

   it("reports unsufficient rvalues as an error, simple", util.check_type_error([[
      local a, b = 1, 2
      a, b = 3
   ]], {
      { msg = "variable is not being assigned a value" }
   }))

   it("reports excess lvalues", util.check_warnings([[
      local function foo(_a: integer, _b: string, _c: boolean): string, boolean
         return "hi", true
      end
      local _x, _y, _z, _w: string, boolean, integer, boolean

      _x, _y, _z, _w = foo(1, "hello", true)
   ]], {
      { y = 6, x = 15, msg = "only 2 values are returned by the function" },
      { y = 6, x = 19, msg = "only 2 values are returned by the function" },
   }))

   it("reports unsufficient rvalues as an error, tricky", util.check_type_error([[
      local type T = record
         x: number
         y: number
      end

      function T:returnsTwo(): number, number
         return self.x, self.y
      end

      function T:method()
         local a, b: number, number
         a, b = self.returnsTwo and self:returnsTwo()
      end
   ]], {
      { msg = "variable is not being assigned a value" }
   }))
end)
