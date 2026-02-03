local util = require("spec.util")

describe("subtyping of nil:", function()

   it("nil <: nil", util.check([[
      --#pragma strict_nil off
      local n: nil
      n = nil
   ]]))

   it("nil <: any", util.check([[
      --#pragma strict_nil off
      local a: any
      a = nil
   ]]))

   it("nil <: unknown", util.lax_check([[
      --#pragma strict_nil off
      local function f(unk)
         unk = nil
      end
   ]], {
      "unk"
   }))

   it("nil <: string", util.check([[
      --#pragma strict_nil off
      local s: string
      s = nil
   ]]))

   it("nil <: number", util.check([[
      --#pragma strict_nil off
      local n: number
      n = nil
   ]]))

   it("nil <: integer", util.check([[
      --#pragma strict_nil off
      local n: integer
      n = nil
   ]]))

   it("nil <: boolean", util.check([[
      --#pragma strict_nil off
      local b: boolean
      b = nil
   ]]))

   it("nil <: thread", util.check([[
      --#pragma strict_nil off
      local c = coroutine.create(function() end)
      c = nil
   ]]))

   it("nil <: poly", util.check([[
      --#pragma strict_nil off
      local record R
         poly: function(s: string)
         poly: function(n: number)
      end

      local r: R = {}
      r.poly = nil
   ]]))

   it("nil <: union", util.check([[
      --#pragma strict_nil off
      local u: string | number
      u = nil
   ]]))

   it("nil <: nominal", util.check([[
      --#pragma strict_nil off
      local record R
      end

      local n: R
      n = nil
   ]]))

   it("nil <: enum", util.check([[
      --#pragma strict_nil off
      local enum E
         "a"
         "b"
      end

      local e: E
      e = nil
   ]]))

   it("nil <: emptytable", util.check([[
      --#pragma strict_nil off
      local et = {}
      et = nil
   ]]))

   it("nil <: array", util.check([[
      --#pragma strict_nil off
      local a: {string}
      a = nil
   ]]))

   it("nil <: arrayrecord", util.check([[
      --#pragma strict_nil off
      local record AR
         {number}
         x: string
      end
      local ar: AR
      ar = nil
   ]]))

   it("nil <: map", util.check([[
      --#pragma strict_nil off
      local m: {string:number}
      m = nil
   ]]))

   it("nil <: record", util.check([[
      --#pragma strict_nil off
      local m = {}
      function m.method()
      end

      m = nil
   ]]))

   it("nil <: function", util.check([[
      --#pragma strict_nil off
      local f = function()
      end

      f = nil
   ]]))
end)
