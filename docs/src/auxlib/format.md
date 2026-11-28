# String interpolation with `auxlib.format`

Import `f!` and pass it a literal string. Put a Teal expression in braces
to interpolate it. Teal checks each expression in the caller's scope and
evaluates each one once, from left to right.

```teal
local format = require("auxlib.format")
local macro f! = format.f!

local product = "Notebook"
local cents = 350
print(f!"{{{product}}} costs {cents / 100:.2f}") -- {Notebook} costs 3.50
```

Fields use `tostring` by default, including for `nil`. Add a colon and a
`string.format` conversion for formatting, such as `{value:04d}` or
`{value:.2f}`. The initial `%` is optional, and width and precision must
be literal numbers from 0 to 99. If the template contains a format code,
the generated expression makes one `string.format` call for the template.

Write `{{` and `}}` for literal braces. Quoted strings accept Lua escapes,
and long-bracket literals also work. Parenthesize an expression when its
colon could be read as the start of a format specifier.
