# Programming with Types in Teal

## Welcome to Teal!

In this tutorial chapter, we will go through the basics so you can get up and running
type checking your Lua code, through the use of Teal, a typed dialect of Lua.

## Types in Teal

The basic types in Teal are `any`, `nil`, `boolean`, `integer`, `number`,
`string`, `thread`, and `userdata`. An `integer` is a subtype of `number`.
The Lua VM determines its precision.

Teal uses `{number}` for an array, `{number, integer, string}` for a tuple,
and `{string: boolean}` for a map. A signature such as
`function(number, string): {number}, string` gives the types of a function's
parameters and results.

Teal uses named declarations for enums, records, and interfaces. A record can
declare an array part, implement an interface, or describe userdata. See
[Records](records.md), [Interfaces](interfaces.md), and [Enums](enums.md).
