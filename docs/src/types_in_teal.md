## Types in Teal

Teal is a dialect of Lua. This tutorial will assume you already know Lua, so
we'll focus on the things that Teal adds to Lua, and those are primarily type
declarations.

Types in Teal are more specific than in Lua, because Lua tables are so general.
These are the basic types in Teal:

* `any`
* `nil`
* `boolean`
* `integer`
* `number`
* `string`
* `thread` (coroutine)

Note: An `integer` is a sub-type of number; it is of undefined precision,
deferring to the Lua VM.

You can also declare more types using type constructors. This is the summary
list with a few examples of each; we'll discuss them in more detail below:

* arrays - `{number}`, `{{number}}`
* tuples - `{number, integer, string}`
* maps - `{string:boolean}`
* functions - `function(number, string): {number}, string`

Finally, there are types that must be declared and referred to using names:

* enums
* records
* interfaces

Here is an example declaration of each. Again, we'll go into more detail below,
but this should give you an overview:

```lua
-- an enum: a set of accepted strings
local enum State
   "open"
   "closed"
end

-- a record: a table with a known set of fields
local record Point
   x: number
   y: number
end

-- an interface: an abstract record type
local interface Character
   sprite: Image
   position: Point
   kind: string
end

-- records can implement interfaces, using a type-identifying `where` clause
local record Spaceship
   is Character
   where self.kind == "spaceship"

   weapon: Weapons
end

-- a record can also declare an array interface, making it double as a record and an array
local record TreeNode<T>
   is {TreeNode<T>}

   item: T
end

-- a userdata record: a record which is implemented as a userdata
local record File
   is userdata

   status: function(): State
   close: function(File): boolean, string
end
```

### Query a static type

Use `typeof value` in a type annotation to reuse the type of a value. Use
`typeof!(expression)` for a query that contains an operator, a method call, or
another compound expression.

```teal
local a = 10
local b: typeof a = 20
local c: typeof!(a + b) = 30

local info: reflection.TypeInfo = typeof!(b)
local kind: reflection.Kind = info.kind
print(kind, tostring(info))      -- integer  integer
print(typeof!(a) == typeof!(b))  -- true
```

In an expression, `typeof!` creates a Lua table that describes the type Teal
sees at that point. Teal checks the operand and uses its first result type.
The generated Lua skips the operand, so its calls and other side effects
never run. The actual values passed to a generic function do not change the
description of a type parameter inside that function.

The default `reflection` namespace provides `TypeInfo` and `Kind` for type
annotations. Each `TypeInfo` has a `kind` and a short `text` description.
Other fields are present when they apply to that kind.

| Description | Fields |
| --- | --- |
| Named type or literal type | `name`, `literal` |
| Array, map, or tuple | `element`, `key` and `value`, or `items` |
| Record or interface | `fields`, `metamethods`, `interfaces`, `userdata`, and any `element` or `items` |
| Enum | `values` |
| Union or overload | `alternatives` |
| Function | `parameters`, `returns`, `required_parameters`, `variadic_parameters`, `variadic_returns`, `method` |
| Generic type or type parameter | `type_arguments`, `type_parameters`, `constraint` |

Recursive links have kind `reference` so the descriptions stay finite.
`tostring(info)` returns `info.text`. `==` compares the described types,
including their type arguments and the declaration of a named record, interface,
or enum. The order of union members does not affect equality. Each invocation
creates fresh tables.
