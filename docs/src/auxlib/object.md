# Tagged records with `auxlib.Object`

`Object` is an interface with a `__name: string` field. The `object!`
decorator implements that interface, adds a `where` clause for the record's
declared name, and sets the record's `__index` to itself.

```teal
local type Object = require("auxlib.Object")
local macro object! = Object.object!

local record Counter<object!>
   value: integer
end

function Counter:get(): integer
   return self.value
end

local counter = setmetatable({value = 42} as Counter, Counter as metatable<Counter>)
local tagged: Object = counter
if tagged is Counter then
   print(tagged:get(), tagged.__name) -- 42  Counter
end
```

Use `setmetatable` when you construct an instance so it can look up methods
and the tag on the record. When a variable has type `Object`, use `is Counter`
to check the generated tag and narrow the variable to `Counter`.

`object!` accepts local and global record declarations, including generic
records. A decorated record gets its `where` clause from the macro. Write
`record ... is Object` when you want to supply the clause yourself.
