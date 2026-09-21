local util = require("spec.util")

describe("nil generic inference", function()
   it("infers nil in invariant generic arguments from a destination annotation", util.check([[
      local record Box<T>
         value: T | nil
      end
      local function create<T>(): Box<T>
         return {value = nil}
      end
      local box: Box<nil> = create()
      print(box.value)
   ]]))
end)
