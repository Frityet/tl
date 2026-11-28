# Reflection

Teal's built-in `typeof!` macro queries the static type of an expression.
Teal checks the operand without evaluating it. If the operand returns several
values, the macro uses the first result type.

## Using the result as a type

Use `typeof!(expression)` in a type annotation or a type alias to reuse the
type of an expression.

```lua
local a = 10
local b: typeof!(a) = 20
local type Sum = typeof!(a + b)
local c: Sum = 30
print(c) -- 30
```

## Inspecting a type at runtime

In an expression, `typeof!` generates a Lua table of type
`reflection.TypeInfo`. The `reflection` namespace also provides the
`reflection.Kind` enum.

```lua
local record Point
   x: number
   y: number
end

local p: Point = { x = 1, y = 2 }
local q: Point = { x = 3, y = 4 }
local info: reflection.TypeInfo = typeof!(p)
local kind: reflection.Kind = info.kind
print(kind, tostring(info)) -- record  Point
print(info == typeof!(q))  -- true

local fields = info.fields
if fields then
   print(fields.x.kind) -- number
end
```

Inside a generic function, `typeof!` describes a type parameter as it appears
in the function's signature. A recursive link has kind `reference`, so a
recursive type produces a finite description.

## `reflection.TypeInfo`

Every description has `kind` and `text` fields. An optional field has the
value `nil` when it does not apply.

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `reflection.Kind` | The kind of type. |
| `text` | `string` | The text returned by `tostring(info)`. |
| `name` | `string?` | The name of a declared type or type parameter, when available. |
| `literal` | `(string \| number \| boolean)?` | The value of a literal type. |
| `element` | `reflection.TypeInfo?` | The element type of an array or an array part. |
| `key` | `reflection.TypeInfo?` | The key type of a map. |
| `value` | `reflection.TypeInfo?` | The value type of a map. |
| `items` | `{reflection.TypeInfo}?` | The types of tuple entries, in order. |
| `fields` | `{string: reflection.TypeInfo}?` | The value fields of a record or interface, keyed by name. |
| `metamethods` | `{string: reflection.TypeInfo}?` | The metamethod signatures of a record or interface, keyed by name. |
| `interfaces` | `{reflection.TypeInfo}?` | The declared interfaces, including any array or tuple part. |
| `userdata` | `boolean?` | `true` if a record or interface describes userdata. |
| `values` | `{string}?` | The allowed strings of an enum. |
| `alternatives` | `{reflection.TypeInfo}?` | The members of a union or the signatures of an overload. |
| `parameters` | `{reflection.TypeInfo}?` | The types of a function's parameters, in order. |
| `returns` | `{reflection.TypeInfo}?` | The types of a function's results, in order. |
| `required_parameters` | `integer?` | The minimum number of arguments to a function. |
| `variadic_parameters` | `boolean?` | Whether the final parameter type can repeat for additional arguments. |
| `variadic_returns` | `boolean?` | Whether the final result type can repeat for additional results. |
| `method` | `boolean?` | `true` if the function is a method. |
| `type_arguments` | `{reflection.TypeInfo}?` | The types supplied as arguments to a generic type. |
| `type_parameters` | `{reflection.TypeInfo}?` | The parameter declarations of a generic type. |
| `constraint` | `reflection.TypeInfo?` | The constraint on a type parameter. |

Each call creates a fresh description table with these [metamethods](metamethods.md).

| Metamethod | Type | Behavior |
| --- | --- | --- |
| `__eq` | `function(reflection.TypeInfo, reflection.TypeInfo): boolean` | `==` compares the types described by the tables. |
| `__tostring` | `function(reflection.TypeInfo): string` | `tostring(info)` returns `info.text`. |

Equality for named records, interfaces, and enums uses the type declaration
and any type arguments. Union members can appear in either order.

## `reflection.Kind`

The `kind` field can have any of these values.

* `any`, `unknown`, `nil`, `boolean`, `integer`, `number`, `string`, `thread`, `userdata`
* `table`, `array`, `map`, `tuple`, `record`, `interface`, `enum`, `function`
* `overload`, `union`, `type_parameter`, `reference`
