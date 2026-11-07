local structs = require("extras.macros.struct")
local macro (struct)! = structs.(struct)!

struct Counter {
   constructor(auto);
   value: integer = required {
      invariant = x -> x > 0;
      set = new -> do field = new end;
   };
}

local counter = Counter:create(1)
counter.value = 2
return counter:validate().value
