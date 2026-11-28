local teal = require("teal.init")

local function compile(source, filename, opts)
   local compiler = teal.compiler({ gen_target = "5.1", gen_compat = "off" })
   local code, _, err = compiler:input(source, filename or "reflection.tl"):gen(opts)
   assert.same({}, err.syntax_errors)
   assert.same({}, err.type_errors)
   return code
end

local function run(source, filename)
   return assert(loadstring(compile(source, filename)))()
end

describe("typeof", function()
   it("reuses the static type and exposes descriptions in the reflection namespace", function()
      local equal, text, kind = run([[
         local a = 10
         local b: typeof!(a) = 20
         local c: typeof!(a + b) = 30
         local map: {typeof!(a): string} = { [a] = "ten" }
         local info: reflection.TypeInfo = typeof!(b)
         local kind: reflection.Kind = info.kind
         return typeof!(a) == info and info == typeof!(c) and typeof!(map).kind == "map", tostring(info), kind
      ]])
      assert.is_true(equal)
      assert.equals("integer", text)
      assert.equals("integer", kind)
   end)

   it("checks the operand without running it and uses its first result", function()
      local calls, equals, kind = run([[
         local calls = 0
         local function work(): (integer, string)
            calls = calls + 1
            return 1, "second"
         end
         local n: typeof!(work()) = 9
         local t = typeof!(work())
         return calls, t == typeof!(n), t.kind
      ]])
      assert.equals(0, calls)
      assert.is_true(equals)
      assert.equals("integer", kind)
   end)

   it("skips Lua compatibility shims used only by an operand", function()
      local compiler = teal.compiler({ gen_target = "5.1", gen_compat = "optional" })
      local code, _, err = compiler:input("return typeof!(table.unpack)", "compat.tl"):gen()
      assert.same({}, err.type_errors)
      assert.is_nil(code:find("compat53", 1, true))
      assert.equals("overload", assert(loadstring(code))().kind)
   end)

   it("shows fields, type arguments, and finite recursive descriptions", function()
      local info, other = run([[
         local record Tree<T>
            value: T
            children: {Tree<T>}
         end
         local value: Tree<integer> = { value = 1, children = {} }
         local type Copy = typeof!(value)
         local copy: Copy = value
         local strings: Tree<string> = { value = "one", children = {} }
         assert(typeof!(value) == typeof!(copy))
         return typeof!(value), typeof!(strings)
      ]])
      assert.equals("Tree<integer>", tostring(info))
      assert.equals("record", info.kind)
      assert.equals("integer", info.type_arguments[1].kind)
      assert.equals("integer", info.fields.value.kind)
      assert.equals("array", info.fields.children.kind)
      local child = info.fields.children.element
      assert.equals("reference", child.kind)
      assert.is_true(child == info)
      assert.is_false(info == other)
   end)

   it("shows enums, union members, and generic function signatures", function()
      local info, either, equal, enum = run([[
         local enum State
            "ready" "paused"
         end
         local function identity<T>(value: T): typeof!(value)
            return value
         end
         local function inspect(a: integer | string, b: string | integer, state: State): (reflection.TypeInfo, boolean, reflection.TypeInfo)
            return typeof!(a), typeof!(a) == typeof!(b), typeof!(state)
         end
         return typeof!(identity), inspect(1, 2, "ready")
      ]])
      assert.equals("function", info.kind)
      assert.equals("T", info.type_parameters[1].name)
      assert.equals("type_parameter", info.parameters[1].kind)
      assert.is_true(info.parameters[1] == info.returns[1])
      assert.equals("union", either.kind)
      assert.is_true(equal)
      assert.equals("enum", enum.kind)
      assert.same({ "paused", "ready" }, enum.values)
   end)

   it("compares descriptors across generated chunks and keeps invocations independent", function()
      local a = run([[local a: {integer} = {}; return typeof!(a)]], "a.tl")
      local b = run([[local b: {integer} = {}; return typeof!(b)]], "b.tl")
      local n = run([[local n = 3; return typeof!(n)]], "n.tl")
      assert.is_true(a == b)
      assert.is_true(a.element == n)
      assert.is_false(rawequal(a, b))
      assert.is_function(getmetatable(a).__eq)
      assert.is_function(getmetatable(a).__tostring)
      a.element.kind = "number"
      assert.equals("integer", b.element.kind)
   end)

   it("distinguishes named declarations and keeps ordinary functions named typeof", function()
      local a, alias, b, value = run([[
         local record Point
            x: number
         end
         local type Alias = Point
         local record Other
            x: number
         end
         local a: Point = { x = 0 }
         local named: Alias = a
         local b: Other = { x = 0 }
         local function typeof(x: string): string return x end
         local __tl_typeof = "untouched"
         local setmetatable = "shadowed by source code"
         return typeof!(a), typeof!(named), typeof!(b), typeof(__tl_typeof) .. setmetatable
      ]])
      assert.is_true(a == alias)
      assert.is_false(a == b)
      assert.equals("untouchedshadowed by source code", value)
   end)

   it("composes with user macros and reflects explicit literal types", function()
      local info = run([[
         local macro keep!(value: Expression) return value end
         local state: "open" = "open"
         return keep!(typeof!(keep!(state)))
      ]])
      assert.equals("string", info.kind)
      assert.equals("open", info.literal)
      assert.equals('"open"', tostring(info))
   end)

   it("reports bad arity and type errors in operands", function()
      local compiler = teal.compiler()
      for _, source in ipairs({ "return typeof!()", "return typeof!(1, 2)" }) do
         local _, errors = compiler:input(source, "arity.tl"):parse()
         assert.equals("Give typeof! one operand.", errors[1].msg)
      end
      local _, errors = compiler:input("return typeof!(missing)", "operand.tl"):check()
      assert.matches("unknown variable: missing", errors.type_errors[1].msg, 1, true)
      local _, recursive = compiler:input("local type Alias = typeof!(Alias)", "recursive.tl"):check()
      assert.equals("The typeof operand refers to a type query that has no result yet.", recursive.type_errors[1].msg)
   end)

   it("requires macro syntax in type annotations", function()
      local _, errors = teal.compiler():input("local x = 1; local xs: {typeof x} = {x}", "bare.tl"):parse()
      assert.is_table(errors)
      assert.is_true(#errors > 0)

      assert.equals(4, run("local type typeof = integer; local x: typeof = 4; return x"))
   end)

   it("keeps a hashbang on the first line and emits no helper for type annotations alone", function()
      local code = compile("#!/usr/bin/env lua\nlocal n = 1\nreturn typeof!(n)\n", "script.tl", {
         preserve_hashbang = true,
         preserve_newlines = true,
      })
      assert.matches("^#!/usr/bin/env lua\nlocal __tl_typeof", code)
      assert.equals("integer", tostring(assert(loadstring(code:match("\n(.*)")))()))
      local annotation = compile("local n = 1; local m: typeof!(n) = 2; return m")
      assert.is_nil(annotation:find("__tl_typeof", 1, true))
   end)
end)
