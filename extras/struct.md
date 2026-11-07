# Struct operator

Run the example from the repository root with `./tl run extras/struct_example.tl`.
Import the operator explicitly:

```lua
local structs = require("extras.struct")
local macro (struct)! = structs.(struct)!
```

The declaration module is [`struct.d.tl`](struct.d.tl). It emits a native Teal
record and typed callbacks, plus a call to the [`struct_runtime`](struct_runtime.tl)
helper. The generated program needs `extras/struct_runtime.lua` on its Lua
module path. The declaration module itself is used at compile time.

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
  after the declaration or through deriving.
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

## Deriving

```lua
deriving {
   Equal {ignore = {"created_at"}},
   Copy {deep = {"tags"}},
   Show {redact = {"access_token"}},
   Json {omit = {"access_token"}, rename = {id = "employee_id"}},
};
```

| Trait | Generated API | Behavior |
| --- | --- | --- |
| `Equal` | `a:equal(b)`, `a == b` | Compares stored values structurally, skipping ignored fields. |
| `Copy` | `a:copy()` | Copies backing slots without rerunning setters. `deep = true` copies all nested tables; a list selects fields. |
| `Show` | `a:show()`, `tostring(a)` | Formats public values in declaration order. Supports `omit` and `redact`. |
| `Json` | `a:to_json()` | Encodes public values, with field omission and renaming. Direct array annotations preserve empty arrays. |

Custom traits are ordinary typed method providers. This keeps them reusable
with native interface polymorphism and avoids macro calls inside another macro:

```lua
local interface Labelled
   id: integer
   label: function(self: Labelled): string
end

local record Labels end
function Labels.label(self: Labelled): string
   return "item:" .. tostring(self.id)
end

struct Item {
   deriving {Labels {implements = {Labelled}, methods = {label}}};
   id: integer = required;
}

print(Item:from {id = 7}:label()) -- item:7
```

The expansion adds `Labelled` to the record's interfaces and assigns
`Item.label = Labels.label`. Teal checks that assignment against the interface.
If the interface is already listed in the main `implements` header, the provider
can specify just `methods`. A provider can also be a qualified module field.

To regenerate the runtime after editing it:

```sh
./tl gen --check --gen-target=5.1 --gen-compat=off extras/struct_runtime.tl -o extras/struct_runtime.lua
```
