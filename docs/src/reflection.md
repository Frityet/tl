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
`reflection.Type`. Use `is` to narrow the description to the record for its
`kind` and read the fields of that record.

```lua
local record Point
   x: number
   y: number
end

local p: Point = { x = 1, y = 2 }
local q: Point = { x = 3, y = 4 }
local info: reflection.Type = typeof!(p)
local kind: reflection.Kind = info.kind
print(kind, tostring(info)) -- record Point
print(info == typeof!(q))  -- true

if info is reflection.RecordType then
   print(info.fields.x.kind) -- number
end
```

Inside a generic function, `typeof!` describes a type parameter as it appears
in the function's signature. A recursive link has kind `reference`, so a
recursive type produces a finite description.

## `reflection.Type`

`reflection.Type` is an interface with `where self.kind`. Every description
has `kind` and `text` fields. An optional field has the value `nil` when it
does not apply.

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `reflection.Kind` | The kind of type. |
| `text` | `string` | The text returned by `tostring(info)`. |
| `type_arguments` | `{reflection.Type}?` | The types supplied as arguments to a generic type. |
| `type_parameters` | `{reflection.TypeParameter}?` | The parameter declarations of a generic type. |

Each call creates a fresh description table with these [metamethods](metamethods.md).

| Metamethod | Type | Behavior |
| --- | --- | --- |
| `__eq` | `function(reflection.Type, reflection.Type): boolean` | `==` compares the types described by the tables. |
| `__tostring` | `function(reflection.Type): string` | `tostring(info)` returns `info.text`. |

Equality for named records, interfaces, and enums uses the type declaration
and any type arguments. Union members can appear in either order.

## Type records

Each record refines `kind` to the literal shown in the table. These literals
are the values of the `reflection.Kind` enum.

| Record | `kind` type | Fields in addition to `reflection.Type` |
| --- | --- | --- |
| `reflection.AnyType` | `"any"` | |
| `reflection.UnknownType` | `"unknown"` | |
| `reflection.NilType` | `"nil"` | |
| `reflection.BooleanType` | `"boolean"` | `literal: boolean?` |
| `reflection.IntegerType` | `"integer"` | `literal: integer?` |
| `reflection.NumberType` | `"number"` | `literal: number?` |
| `reflection.StringType` | `"string"` | `literal: string?` |
| `reflection.ThreadType` | `"thread"` | |
| `reflection.UserdataType` | `"userdata"` | |
| `reflection.TableType` | `"table"` | |
| `reflection.ArrayType` | `"array"` | `element: reflection.Type` |
| `reflection.MapType` | `"map"` | `key: reflection.Type`, `value: reflection.Type` |
| `reflection.TupleType` | `"tuple"` | `items: {reflection.Type}` |
| `reflection.RecordType` | `"record"` | [Record and interface fields](#record-and-interface-fields) |
| `reflection.InterfaceType` | `"interface"` | [Record and interface fields](#record-and-interface-fields) |
| `reflection.EnumType` | `"enum"` | `name: string?`, `values: {string}` |
| `reflection.FunctionType` | `"function"` | [Function fields](#function-fields) |
| `reflection.OverloadType` | `"overload"` | `alternatives: {reflection.FunctionType}` |
| `reflection.UnionType` | `"union"` | `alternatives: {reflection.Type}` |
| `reflection.TypeParameter` | `"type_parameter"` | `name: string`, `constraint: reflection.Type?` |
| `reflection.ReferenceType` | `"reference"` | `name: string?` |

### Record and interface fields

`reflection.RecordType` and `reflection.InterfaceType` implement
`reflection.RecordLikeType`. Use `is reflection.RecordLikeType` to read their
shared fields.

| Field | Type | Description |
| --- | --- | --- |
| `name` | `string?` | The declared name, when available. |
| `fields` | `{string: reflection.Type}` | The value fields, keyed by name. |
| `metamethods` | `{string: reflection.Type}?` | The metamethod signatures, keyed by name. |
| `interfaces` | `{reflection.Type}?` | The interfaces, including any array or tuple part. |
| `userdata` | `boolean?` | `true` if the type describes userdata. |
| `element` | `reflection.Type?` | The element type of an array part. |
| `items` | `{reflection.Type}?` | The entries of a tuple part, in order. |

### Function fields

| Field | Type | Description |
| --- | --- | --- |
| `parameters` | `{reflection.Type}` | The parameter types, in order. |
| `returns` | `{reflection.Type}` | The result types, in order. |
| `required_parameters` | `integer` | The minimum number of arguments. |
| `variadic_parameters` | `boolean` | Whether the final parameter type repeats for additional arguments. |
| `variadic_returns` | `boolean` | Whether the final result type repeats for additional results. |
| `method` | `boolean?` | `true` if the function is a method. |
