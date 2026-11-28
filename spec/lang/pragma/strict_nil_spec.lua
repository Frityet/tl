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

   it("narrows an assigned nullable value after a guarded break", util.check([[
      --#pragma strict_nil on
      local record Node
         value: integer
         next: Node?
      end

      local function walk(head: Node)
         local n: Node? = head
         while n do
            n = n.next
            if not n then break end
            print(n.value)
         end
      end
   ]]))

   it("narrows after a branch that exits by either break or return", util.check([[
      --#pragma strict_nil on
      local function walk(n: string?, stop: boolean)
         while true do
            if not n then
               if stop then
                  do break end
               else
                  return
               end
            end
            local value: string = n
            print(value)
            break
         end
      end
   ]]))

   it("keeps a value nullable if a nested break can be bypassed", util.check_type_error([[
      --#pragma strict_nil on
      local function walk(n: string?, stop: boolean)
         while true do
            if not n then
               if stop then break end
            end
            local value: string = n
            print(value)
            break
         end
      end
   ]], {
      { y = 7, msg = "in local declaration: value: got string | nil, expected string" },
   }))

   it("keeps a value nullable after a loop whose guard can break", util.check_type_error([[
      --#pragma strict_nil on
      local function walk(n: string?)
         while true do
            if not n then break end
            break
         end
         local value: string = n
         print(value)
      end
   ]], {
      { y = 7, msg = "in local declaration: value: got string | nil, expected string" },
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

   it("implicitly makes optional parameter types nilable", util.check([[
      --#pragma strict_nil on
      local read: function(string?): string? = function(value?: string): string?
         return value
      end
      local fn_type: function(x?: string): string? = read
      local anon_type: function(? string): string? = function(value?: string?): string?
         return value
      end
      local from_short = |x?: string|: string? -> x
      read(nil)
      fn_type()
      fn_type(nil)
      fn_type("ok")
      anon_type()
      anon_type(nil)
      anon_type("ok")
      from_short()
      from_short(nil)
      from_short("ok")

      local generic_opt: function<T>(x?: T): T? = function<T>(x?: T): T?
         return x
      end
      local g1 = generic_opt()
      local g2 = generic_opt(nil)
      local g3 = generic_opt(42)

      local record ForwardHolder
         method: function(ForwardHolder, x?: ForwardTarget): string?
      end
      local record ForwardTarget
         label: string
      end
      local fh: ForwardHolder = {
         method = function(_self: ForwardHolder, x?: ForwardTarget): string?
            return x and x.label or nil
         end
      }
      fh:method()
      fh:method(nil)
      fh:method({ label = "ok" })

      assert(table.concat({ "a", "b" }, nil, 2) == "b")
      local _tb: string = debug.traceback(nil, 2)
   ]]))

   it("rejects treating contextually inferred optional parameters as non-nilable", util.check_type_error([[
      --#pragma strict_nil on
      local fn: function(x?: integer) = function(x)
         local n: integer = x
         local _ = n
      end
   ]], {
      { y = 3, msg = "in local declaration: n: got integer | nil" },
   }))

   it("treats (name?: T) as identical to (name?: T?) in error types", util.check_type_error([[
      --#pragma strict_nil on
      local f1: function(x?: integer) = function(x?: integer)
         local n: integer = x
      end
      local f2: function(x?: integer) = function(x: string)
      end
      local f3: function(x?: integer) = 1
   ]], {
      { y = 3, msg = "in local declaration: n: got integer | nil, expected integer" },
      { y = 5, msg = "in local declaration: f2: argument 1: got string, expected integer | nil" },
      { y = 7, msg = "in local declaration: f3: got integer, expected function(? integer | nil)" },
   }))
end)
