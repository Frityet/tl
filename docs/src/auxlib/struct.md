# Checked records with `auxlib.struct`

Import the `struct` prefix operator to declare a typed record with
constructors, defaults, and property checks.

```teal
local structs = require("auxlib.struct")
local macro (struct)! = structs.(struct)!

struct Counter {
   constructor(auto);
   value: integer = property {
      default = 1;
      invariant = x -> x > 0;
      get = x -> x * 10;
   };
}

local counter = Counter:create()
counter.value = 3
print(counter.value) -- 30
```

## Construction

Give each field a type and a default, or mark it `required`. Use
`Name:from { ... }` to construct from named values. The generated `Name.Init`
record types those values. Defaults are evaluated for each new instance.

`constructor(auto)` adds `Name:create(...)`. Pass required fields first and
defaulted fields second, in declaration order within each group. An omitted
or `nil` argument uses the default for that field. For a custom constructor,
call `self:from { ... }` from a method you define on the record.

## Properties and checks

Use `property { default = value, ... }` for a default with hooks. Use
`required { ... }` for a required field with hooks.

| Option | Behavior |
| --- | --- |
| `get` | Read the stored value and return the public value. |
| `set` | Receive the new value and assign to `field` to choose what to store. `field` starts with the current stored value, or the initial candidate during construction. |
| `invariant` | Accept the candidate field value when the callback returns `true`. |
| `message` | Supply the error text for a failed field invariant. |
| `readonly` | Prevent writes to the field after construction when set to `true`. |

Use `invariant (x -> x.minimum <= x.maximum)` in the struct body to check
the entire instance after construction and before a field write commits.
Call `instance:validate()` to rerun the checks. A write inside a table-valued
property bypasses that property's setter.

Use `implements(Interface, OtherInterface)` to declare interface conformance.
Define the methods after the struct declaration. The macro uses
`structs.define(class, descriptor)` to install the constructors and property
hooks in the generated Lua.
