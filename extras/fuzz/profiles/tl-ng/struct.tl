local structs = require("extras.struct")
local macro (struct)! = structs.(struct)!

struct Counter {
   constructor(auto), deriving {Copy, Equal};
   value: integer = required {
      invariant = x -> x > 0;
      set = new -> do field = new end;
   };
}

local counter = Counter:create(1)
counter.value = 2
return counter:copy().value
