local tl = require("teal.api.v2")

describe("strict pragma", function()
   it("allows inference, nil narrowing, and widening casts", function()
      local result = tl.check_string([[
         --#pragma strict on
         local function increment(value: integer | nil): number
            if value is nil then return 0 end
            return (value + 1) as number
         end
         return increment(nil), increment(4)
      ]])
      assert.same({}, result.syntax_errors)
      assert.same({}, result.type_errors)
   end)

   it("rejects explicit and inferred any, unchecked casts, and implicit nil", function()
      local result = tl.check_string([[
         --#pragma strict on
         local a: {string:any} = {}
         local module = "example"
         local b = require(module)
         local c = "abc" as integer
         local d: integer = nil
         local e: string
         local function f(): integer end
         --#pragma strict_nil off
         --#pragma arity off
      ]])
      assert.same({}, result.syntax_errors)
      local messages = {}
      for _, err in ipairs(result.type_errors) do
         table.insert(messages, err.msg)
      end
      local diagnostics = table.concat(messages, "\n")
      for _, message in ipairs({
         "type 'any' is not allowed", "a value cannot have type 'any'",
         "'as' requires a widening conversion", "got nil, expected integer",
         "requires an initializer", "may end without returning a non-nil result",
         "pragma 'strict_nil' must be 'on'", "pragma 'arity' must be 'on'",
      }) do
         assert.match(message, diagnostics, 1, true)
      end
   end)

   it("applies only to the file that opted in", function()
      local env = assert(tl.new_env({ defaults = { feat_strict_nil = "off" } }))
      local strict = tl.check_string("--#pragma strict on\nlocal x: integer = nil", env, "strict.tl")
      assert.match("got nil, expected integer", strict.type_errors[1].msg, 1, true)
      local ordinary = tl.check_string("local x: integer = nil; local y: any = 1", env, "ordinary.tl")
      assert.same({}, ordinary.type_errors)
   end)

   it("rejects a directive after code", function()
      local result = tl.check_string("local x: any = 1\n--#pragma strict on")
      assert.match("must appear once at the beginning", result.type_errors[1].msg, 1, true)
   end)
end)
