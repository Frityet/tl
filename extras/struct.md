# Struct operator

Run the example from the repository root with `./tl run extras/struct_example.tl`.
Import the operator explicitly.

```lua
local structs = require("extras.struct")
local macro (struct)! = structs.(struct)!
```

The macro and runtime live in [`struct.tl`](struct.tl), with strict nil checking
enabled. The macro emits a native Teal record and typed callbacks. Generated
programs load `extras/struct.lua` from their Lua module path.

```lua
struct Counter {
   constructor(auto);
   value: integer = property {
      default = 1;
      invariant = x -> x > 0;
      get = x -> x * 10;
      set = new -> do field = new end;
   };
}

local counter = Counter:create()
counter.value = 3
print(counter.value) -- 30
```

## Fields and construction

- A typed field takes an ordinary default expression, `required`,
  `required { ... }`, or `property { default = value, ... }`.
- `:from { ... }` is always generated. Its input type, `Name.Init`, has
  required fields and nullable entries for defaulted fields.
- `constructor(auto)` also generates `:create(...)`. Its arguments are the
  required fields followed by optional defaulted fields, in declaration order
  within each group. Omitted or `nil` inputs use the default; required fields
  need a non-nil value. Defaults run separately for each instance.
- A handwritten `Name:create(...)` can call `self:from { ... }`. Omit
  `constructor(auto)` for that form. There is no `constructor(manual)` mode.
- `implements(Interface, OtherInterface)` emits native interface conformance.
  List the data fields in the struct body, and supply ordinary record methods
  after the declaration.
- Generic struct declarations are deferred.

## Hooks and storage

`get` and `invariant` each receive the stored field value. `set` takes the
incoming value and can assign the implicit mutable `field` binding, initially
the current stored value. During construction, its initial value is the input
or evaluated default. The setter's result is checked before writing the slot.
Callback parameters and results are checked against the declared field type;
invariants must return a boolean. `message` can customize an invariant error.

Instances use `_name` backing slots. `__index` reads the slot and runs its
getter, and `__newindex` runs the setter and checks before committing. Public
keys stay absent, so this also works on repeated direct writes such as
`employee.name = "ADA"`. Underscore backing slots are absent from the public
record type. `readonly = true` rejects public writes at runtime after construction.

An optional header `invariant (x -> x.minimum <= x.maximum)` checks the whole
record after construction and checks a staged view before a property write.
`instance:validate()` reruns the checks and returns the instance. Hooks cover
assignments to the property itself; in-place edits inside a table field are
ordinary table operations. Use validation hooks as predicates, since their
side effects are not rolled back.

To regenerate the Lua runtime, run this command from the repository root.

```sh
./tl gen --gen-target=5.1 --gen-compat=off -o extras/struct.lua extras/struct.tl
```
