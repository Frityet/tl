local util = require("spec.block-util")

describe("assignment to union", function()
   it("accepts either type", util.check([[
      local t: number | string
      t = 12
      t = "hello"
   ]]))

   it("accepts valid but rejects invalid types", util.check_type_error([[
      local t: number | string | boolean | function(number | string, {string | boolean}):{number | string:string | boolean}
      t = 12
      t = "hello"
      t = true
      t = function(n: number | string, a: {string | boolean}):{number | string:string | boolean}
         n = 12
         n = "hello"
         a[1] = "hello"
         a[2] = true
         return {}
      end
      t = { false, false, false } -- will fail!
      t = function() -- will also fail
      end
   ]], {
      { y = 12, msg = 'in assignment: got {boolean}, expected ' },
      { y = 13, msg = 'in assignment: got function(), expected ' },
   }))

   it("accepts narrower types", util.check([[
      local t: number | string | boolean
      local u: number | string
      u = 12
      t = u
   ]]))

   it("rejects wider types", util.check_type_error([[
      local t: number | string | boolean
      local u: number | string
      t = 12
      if math.random(10) > 5 then
         t = true
      end
      u = t
   ]], {
      { y = 7, msg = 'in assignment: got number | string | boolean, expected number | string' },
   }))

   pending("resolves union types in map keys", util.check([[
      function foo(n: number | string, a: {string | boolean}):{(number | string):(string | boolean)}
         n = 12
         n = "hello"
         a[1] = "hello"
         a[2] = true
         return {
            [12] = "hello",
            [13] = false,
            ["hello"] = "world",
            ["world"] = true,
         }
      end
   ]]))

   it("resolves arrays of unions", util.check([[
      local type Item = record
         name: string
      end

      local e: string | Item = {name="myname"}

      local e1: {string | number} = {12, "name1"}

      local x: {string | Item} = {"name1", e}

      local x: {string | Item} = {"name1", {name="myname"}}
   ]]))

   it("do not produce a confusing message when reporting on incompatible types with the same local names", util.check_type_error([[
      local record A
         record X
         end

         f: function(X | integer)
      end

      local record B
         record X
         end

         g: function(): X | integer
      end

      A.f(B.g())
   ]], {
      { msg = "argument 1: types are incompatible" }
   }))

end)
