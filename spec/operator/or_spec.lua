local util = require("spec.util")

describe("or", function()
   it("map or record matching map", util.check [[
      local type Ty = record
         name: string
         foo: number
      end
      local t: Ty = { name = "bla" }
      local m1: {string:Ty} = {}
      local m2: {string:Ty} = m1 or { foo = t }
   ]])

   it("record or record: need to be compatible", util.check_type_error([[
      local record R1
         x: number
      end
      local record R2
         x: string
      end
      local r1: R1
      local r2: R2
      local r3 = r2 or r1
   ]], {
      { msg = "cannot use operator 'or' for types R2 and R1" }
   }))

   it("or works with subtypes", util.check [[
      local record R1
         x: string
         y: string
      end
      local r1: R1

      local u: string | R1 = "hello"

      local u2 = u or r1
      u2 = "world" -- u2 is a u
   ]])

   it("string or enum matches enum", util.check [[
      local type Dir = enum
         "left"
         "right"
      end

      local v: Dir = "left"
      local x: Dir = v or "right"
      local y: Dir = "right" or v
   ]])

   it("enum constants flow on both sides (#487)", util.check_type_error([[
      local enum State
           "enabled"
           "disabled"
      end

      local state: State

      local enabled: boolean
      state = enabled and "eNnabled" or "disabled"
      state = enabled and "enabled" or "disSabled"

   ]], {
      { y = 9, x = 27, msg = "in assignment: string is not a State" },
      { y = 10, x = 40, msg = "in assignment: string is not a State" },
   }))

   it("works with tables and {}", util.check [[
      local type Ty = record
         name: string
         foo: number
      end
      local t: Ty = { name = "bla" }
      local z = t or {}
      local map: {string:number}
      local zz = map or {}
      local arr: {string}
      local zzz = arr or {}
   ]])

   it("rejects non-tables and {}", util.check_type_error([[
      local a: string
      local z = a or {}
      local b: number
      local zz = b or {}
      local c: boolean
      local zzz = c or {}
   ]], {
      { msg = "cannot use operator 'or' for types string and {}" },
      { msg = "cannot use operator 'or' for types number and {}" },
      { msg = "cannot use operator 'or' for types boolean and {}" },
   }))

   it("does not produce new unions if not asked to", util.check_type_error([[
      local x: number | string

      local s = x is string and x .. "!" or x + 1
   ]], {
      { y = 3, msg = [[cannot use operator 'or' for types string and number]] },
   }))

   it("produces a union if expected context asks for one", util.check [[
      local x: number | string

      local s: number | string = x is string and x .. "!" or x + 1
   ]])

   it("does not produce a union if expected but both sides are the same type (regression test for #551)", util.check [[
      local x: string | number = "hello" or "world"
   ]])

end)
