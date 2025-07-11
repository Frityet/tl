util = require("spec.block-util")

describe("function call", function()
   it("does not crash attempting to infer an emptytable when there's no return type", util.check_type_error([[
      local function f()
      end

      local x = {}

      x = f()
   ]], {
      { y = 6, msg = "variable is not being assigned a value" },
   }))

   it("can perform recursive calls on varargs (regression test for #727)", util.check([[
      local message:string = "hello world!"

      local function foo(...: string): string
          local n = select("#", ...)
          if n < 3 then
              return ""
          end
          if message ~= "hello world" then
              return foo("hi there", select(2, ...))
          else
              local r = {"hi there", select(2, ...)}
              return foo(table.unpack(r))
          end
      end

      local function bar(...: string): string
          return foo("hi there", select(2, ...))
      end
   ]]))

   it("does not allow passing non-record type definitions as values (#813)" , util.check_type_error([[
      local enum TestEnum
          "test1"
      end

      local function testFunc(param1:TestEnum)
      end

      testFunc(TestEnum)

      local interface X
      end

      local function testFunc2(param1:X)
      end

      testFunc2(X)
   ]], {
      { y = 8, msg = "argument 1: cannot use a type definition as a concrete value" },
      { y = 16, msg = "argument 1: interfaces are abstract" },
   }))

   describe("call functions with string literals:", function()
      it("with single quotes", util.check([[
         local function f(a: string) end
         f'hello'
      ]]))

      it("with double quotes", util.check([[
         local function f(a: string) end
         f"hello"
      ]]))

      it("with double square brackets", util.check([=[
         local function f(a: string) end
         f[[hello]]
      ]=]))

      it("with double square brackets across multiple lines", util.check([=[
         local function f(a: string) end
         f[[hello
         world]]
      ]=]))

      it("with double square brackets with equals", util.check([[
         local function f(a: string) end
         f[=[hello]=]
      ]]))

      it("with double square brackets with equals across multiple lines", util.check([[
         local function f(a: string) end
         f[=[hello
         world]=]
      ]]))
   end)

   describe("check the arity of functions:", function()
      it("when excessive", util.check_type_error([[
         local function f(n: number, m: number): number
            return n + m
         end

         local x = f(1, 2, 3)
      ]], {
         { y = 5, msg = "wrong number of arguments (given 3, expects 2)" },
      }))

      it("when insufficient", util.check_type_error([[
         local function f(n: number, m: number): number
            return n + m
         end

         local x = f(1)
      ]], {
         { y = 5, msg = "wrong number of arguments (given 1, expects 2)" },
      }))

      it("when using optional", util.check([[
         local function f(n: number, m?: number): number
            return n + (m or 0)
         end

         local x = f(1)
      ]]))

      it("when insufficient with optionals", util.check_type_error([[
         local function f(n: number, m?: number): number
            return n + (m or 0)
         end

         local x = f()
      ]], {
         { y = 5, msg = "wrong number of arguments (given 0, expects at least 1 and at most 2)" },
      }))

      it("when using all optionals", util.check([[
         local function f(n?: number, m?: number): number
            return (n or 0) + (m or 0)
         end

         local x = f()
      ]]))

      it("when using all optionals", util.check([[
         local function f(n?: number, m?: number): number
            return (n or 0) + (m or 0)
         end

         local x = f(1, 2)
      ]]))

      it("when excessive with optionals", util.check_type_error([[
         local function f(n: number, m?: number): number
            return (n or 0) + (m or 0)
         end

         local x = f(1, 2, 3)
      ]], {
         { y = 5, msg = "wrong number of arguments (given 3, expects at least 1 and at most 2)" },
      }))

      it("with insufficient arguments (regression test)", util.check_type_error([[
         local chunk: function()
         chunk = load()
      ]], {
         { y = 2, msg = "wrong number of arguments (given 0, expects at least 1 and at most 4)" },
      }))

      it("with insufficient arguments (regression test)", util.check_type_error([[
         local function a(f: (function(): any), ...: any): (function():any)
            return function(...): (function():any)
                  return f(a, ...)
            end
         end
      ]], {
         { y = 3, msg = "wrong number of arguments (given 2, expects 0)" },
      }))
   end)
end)
