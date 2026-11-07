# Custom operators

A macro can declare an operator using an `Operator` return annotation:

```lua
local macro (@)!(lhs: Expression, rhs: Expression): Operator<infix, multiplicative>
   return `utils.matmul($lhs, $rhs)`
end

local result = a @ b
```

The compiler parses `a @ b` with multiplicative precedence and expands it
through `(@)!` before type checking. The generated expression is
`(utils.matmul(a, b))`; the declaration and the operator symbol do not appear
in the emitted code. Expanded expressions receive normal Teal type checking.
This works with every Lua generation target and needs no runtime operator
library or LuaJIT syntax flag.

## Names and symbols

The spelling goes in the parenthesized macro name and must be a non-reserved
identifier or an unused symbol or symbol sequence. Examples include `matmul`,
`cross_product`, `@`, `**`, `<=>`, `|>`, and `⊗`.

```lua
local macro (cross_product)!(lhs: Expression, rhs: Expression): Operator<infix, multiplicative>
   return `utils.cross($lhs, $rhs)`
end

local result = a cross_product b
```

Existing operators and Lua reserved keywords cannot be replaced. Teal soft
keywords such as `const`, `continue`, and `type` are available as identifier
operators in expression contexts. Whitespace,
digits within symbol spellings, mixed identifier/symbol spellings, quoting
characters, macro splice delimiters, structural delimiters, and sequences
containing the comment introducer `--` are rejected. `(` and `)` delimit the
name and cannot appear inside an operator spelling. Multi-character symbols
must be adjacent in source; the longest declared spelling wins. Identifier
operators match complete tokens, so `cross_product` never matches part of
`cross_product_other`.

## Fixity, precedence, and associativity

The first `Operator` parameter is `prefix`, `infix`, or `postfix`. Infix declarations
require exactly two `Expression` parameters; prefix and postfix declarations
require exactly one. Optional parameters, `Statement` parameters, and varargs
are not allowed in operator declarations.

```lua
local macro (squared)!(value: Expression): Operator<postfix, postfix>
   return `$value * $value`
end

local macro (negate)!(value: Expression): Operator<prefix, unary>
   return `-$value`
end

local a = 3 squared
local b = negate 4
```

The second parameter selects a binding strength. These groups are listed from
weakest to strongest:

| Group | Corresponding built-in operators |
| --- | --- |
| `conditional` | Below `or`, above the ternary `?:` expression |
| `logical_or` or `disjunction` | `or`, `||`, `??` |
| `logical_and` or `conjunction` | `and`, `&&` |
| `comparison` or `relational` | `==`, `~=`, `!=`, `<`, `>`, `<=`, `>=`, `is` |
| `bitwise_or` | `|` |
| `bitwise_xor` | Binary `~` |
| `bitwise_and` | `&` |
| `shift` | `<<`, `>>`, `~>>` |
| `concatenation` or `concatenative` | `..` |
| `additive` | `+`, `-` |
| `multiplicative` | `*`, `/`, `//`, `%` |
| `unary` | `not`, `!`, unary `-`, `~`, `#` |
| `exponentiation` or `power` | `^` |
| `postfix` or `primary` | Calls, indexing, and field access |

Infix operators default to left associativity, including ones in the
exponentiation group. An optional third parameter selects `left` or `right`:

```lua
local macro (**)!(lhs: Expression, rhs: Expression): Operator<infix, exponentiation, right>
   return `$lhs ^ $rhs`
end

local n = 2 ** 3 ** 2 -- 2 ** (3 ** 2)
```

A symbol may have both prefix and infix declarations. Infix and postfix
bindings for the same spelling are ambiguous and are rejected.

In expression position, the expanded expression is parenthesized, preserving
its grouping even when the expansion uses a different built-in precedence.
An operator produces one value, including when its expansion is a call
returning multiple values.

In statement position, an operator macro may return a statement or a
`statements` block, including an empty block. Statements are inserted directly
into the surrounding block, so generated locals and types are available to
following code. The `Operator` annotation describes the operator's parsing;
no additional annotation is needed to return statements.

````lua
local macro (declare)!(name: Expression): Operator<prefix, unary>
   return ```local record $name value: integer end```
end

declare Item
local item: Item = {value = 42}
````

Prefix, infix, postfix and explicit `(declare)!(Item)` invocations all support
statement expansion. Generated statements receive normal Teal type checking.
An invocation in an assignment value, argument, or other expression position
must expand to an expression. A standalone expression expansion must be a
function call, just as ordinary Lua call statements can discard their results.

If a spelling has both prefix and infix meanings, it can continue an
expression on the preceding line. Use a semicolon to establish a new statement
boundary when needed; newlines do not terminate expressions.

## Scope and macros

Declare an operator statically before using it. Macro-generated declarations
do not introduce new parsing syntax. Operator bindings are local to the block
that declares them, are inherited by nested blocks/functions, and may be
shadowed in an inner block. Duplicate declarations in the same scope are
errors. Bindings do not leak between files. Explicit `(@)!(a, b)` calls
remain available, and retain the same lexical binding as the operator.

Nested macro calls and operators expand before the enclosing macro or operator
runs. Each operand contains the expanded syntax, with the grouping set by the
parser. Macro bodies and quotes cannot invoke other macros, including custom
operators or explicit `(operator)!(...)` calls. Use ordinary helper functions
within a macro body and build the resulting AST directly or quote built-in
expressions. Supplied arguments can still be forwarded or spliced.

The usual macro rules control operand evaluation: the returned syntax determines
evaluation order, duplication, and short-circuiting. For example, the call expansion in the
first example evaluates each operand once, while the illustrative `squared`
expansion duplicates its operand.

Attached operator macros can be exported through records or interfaces like
other attached macros. A qualified declaration keeps its spelling inactive;
bind it with `local macro` to activate it, even in the declaring file. This
allows different records to export implementations of the same spelling.
Import one explicitly to activate it:

```lua
-- matrix_operators.tl
local record Export end
macro Export.(@)!(lhs: Expression, rhs: Expression): Operator<infix, multiplicative>
   return `$lhs * $rhs`
end
return Export
```

```lua
local ops = require('matrix_operators')
local macro (@)! = ops.(@)!

local result = a @ b
```

The exported macro must carry its `Operator` annotation. Requiring a module
alone does not activate its custom operator spellings.

The `!` marker is required on declarations and both sides of imports, just as
for ordinary named macros. Explicit calls also use `!`, including
qualified calls such as `ops.(@)!(a, b)`. Bare operator macro references cannot
be used as runtime values.

An import can rename the spelling while preserving fixity and precedence:

```lua
local macro (times)! = ops.(@)!
local result = a times b
```

Operator declarations using the old `name!: Operator<'symbol', ...>` syntax are
rejected; put the spelling in `(symbol)` and remove it from `Operator<...>`.

## Utility operators

The `extra.macros.utilities` module provides operators for pipelines and imports
alongside typed table functions. The table operators `||>`, `+=>`, and `?>`
call the module's runtime functions, so compiled programs using them load
`extra/macros/utilities.lua`.

```lua
local utilities = require("extra.macros.utilities")
local macro (|>)! = utilities.(|>)!
local macro (||>)! = utilities.(||>)!
local macro (+=>)! = utilities.(+=>)!
local macro (?>)! = utilities.(?>)!
local macro (from)! = utilities.(from)!
local macro (import)! = utilities.(import)!
```

`|>` inserts the value as the first argument and chains from left to right.
A parenthesized target is evaluated as written, then called with the value.
If a macro target expands to a bare call, `|>` inserts the value into that call.
Pipes bind more tightly than comparisons.

| Usage | Equivalent call |
| --- | --- |
| `x \|> f` | `f(x)` |
| `x \|> f()` | `f(x)` |
| `x \|> f(y)` | `f(x, y)` |
| `x \|> (f)` | `(f)(x)` |
| `x \|> (f())` | `(f())(x)` |

`||>` maps a table's entries into a new table. It takes a `{K:V}` and a callback
of type `function(K, V): (UK, UV)`, returning a `{UK:UV}`. The callback receives
the original key and value and returns the new key and value.

```lua
local scores: {string:integer} = { ada = 10, grace = 20 }
local by_score: {integer:string} = scores ||> |name, score| -> do
   return score, name:upper()
end
print(by_score[10]) -- ADA
```

The source and callback expressions are each evaluated once. Entries are visited
with `pairs`, so when several entries produce the same key, the last one visited
wins.

`+=>` reduces a `{K:V}` to a single value. A callback of type
`function(K, V): number` projects entries to numbers and sums them. For a
different accumulator type `U`, pass `{ initial, reducer }` with a reducer of
type `function(U, K, V): U`.

```lua
local scores: {string:integer} = { ada = 10, grace = 20 }
local total = scores +=> |_, score| -> score
local winner = scores +=> {"", |best, name, score| -> do
   if best == "" or score > scores[best] then return name end
   return best
end}
```

Both forms iterate with `pairs`. An empty table yields zero in the sum form
and the initial value in the seeded form.

### Filtering, searching, and grouping

```lua
local scores: {string:integer} = { ada = 10, grace = 20 }
local high = scores ?> |_, score| -> score >= 20
local has_perfect = scores |> utilities.any(|_, score| -> score == 100)
local all_positive = utilities.all(scores, |_, score| -> score > 0)
local grace_score = utilities.find(scores, |name, _| -> name == "grace")
local buckets = utilities.group_by(scores, |_, score| -> math.floor(score / 10))
local names = utilities.keys(scores)
local amounts = utilities.values(scores)
```

| Utility | Result |
| --- | --- |
| `?>`, `filter` | A new table containing matching entries at their original keys. |
| `any` | Whether at least one entry matches. Returns `false` for an empty table. |
| `all` | Whether every entry matches. Returns `true` for an empty table. |
| `find` | The first matching value in iteration order, or `nil`. |
| `group_by` | A table of groups. Each group preserves the original entry keys. |
| `keys`, `values` | Arrays of the table's keys or values. |

These utilities use `pairs`, so iteration order is unspecified. `any`, `all`,
and `find` stop as soon as they can determine the result.

### Inspecting a pipeline

`utilities.tap` calls a function with the input and returns the input itself.

```lua
local function double(value: integer): integer return value * 2 end

local answer = 21 |> utilities.tap(print) |> double -- prints 21, returns 42
```

### Destructuring and imports

`from` takes a list of bare field names and declares them as locals in the
surrounding scope. It evaluates the source once and reads the fields in order.

```lua
local row = { width = 3, height = 4 };
{ width, height } from row
print(width * height) -- 12
```

Use a semicolon after a preceding expression when its parser could consume
the opening brace as a table argument.

`import` uses `from` to select fields from a required module. The module name
can be dotted or quoted, and `as` gives an imported field a different local name.

```lua
import { some_function as fn, version } from module.name
import { load as load_file } from "module name"
```
