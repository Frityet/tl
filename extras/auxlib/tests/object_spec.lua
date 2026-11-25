local tl = require("teal.api.v2")

local function check(source)
   local ast, syntax_errors = tl.parse(source, "object-fixture.tl")
   assert.same({}, syntax_errors)
   return tl.check(ast, "object-fixture.tl", {
      gen_target = "5.1", gen_compat = "off", feat_strict_nil = "on",
   })
end

describe("auxlib Object", function()
   it("provides a tag field for an explicit where clause", function()
      local result = check([[
         local type Object = require("auxlib.Object")
         local record A is Object where self.__name == "A" end
         local function matches(value: Object): boolean
            return value is A
         end
         assert(matches({__name = "A"}))
         assert(not matches({__name = "B"}))
      ]])
      assert.same({}, result.type_errors)
      assert(loadstring((tl.generate(result.ast, "5.1"))))()
   end)

   it("sets the name and index and tags each decorated record", function()
      local result = check([[
         local type Object = require("auxlib.Object")
         local macro object! = Object.object!
         local record A<object!>
            value: integer
         end
         local record B<Object.object!> end

         function A:get(): integer
            return self.value
         end

         local function matches(value: Object): boolean
            return value is A
         end
         local a = setmetatable({value = 42} as A, A as metatable<A>)
         assert(a:get() == 42 and a.__name == "A")
         assert(A.__name == "A" and A.__index == A)
         assert(B.__name == "B" and B.__index == B)
         assert(matches(a) and not matches(B))
      ]])
      assert.same({}, result.type_errors)
      local generated = tl.generate(result.ast, "5.1")
      assert.is_nil(generated:find("require", 1, true))
      assert(loadstring(generated))()
   end)

   it("keeps diagnostics on the original record field", function()
      local result = check([[
local type Object = require("auxlib.Object")
local macro object! = Object.object!
local record A<object!>
   value: MissingType
end
      ]])
      assert.equals(1, #result.type_errors)
      assert.equals(4, result.type_errors[1].y)
      assert.matches("MissingType", result.type_errors[1].msg, 1, true)
   end)

   it("works with generics and global records alongside ordinary attributes", function()
      local result = check([[
         local macro keep!(declaration: Statement) return declaration end
         local type Tags<keep!> = require("auxlib.Object")
         local interface Flag
            enabled: boolean
         end
         local record Box<Tags.object!><T> is Tags, Flag
            value: T
         end
         global record GlobalObject<Tags.object!> end
         local record<const> = "ordinary constant"
         local box: Box<integer> = {__name = "Box", enabled = true, value = 5}
         assert(box.enabled and box.value == 5 and Box.__index == Box)
         assert(GlobalObject.__name == "GlobalObject" and GlobalObject.__index == GlobalObject)
         assert(record == "ordinary constant")
      ]])
      assert.same({}, result.type_errors)
      assert(loadstring((tl.generate(result.ast, "5.1"))))()
   end)
end)
