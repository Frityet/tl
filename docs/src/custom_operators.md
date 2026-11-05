# Custom operators

A macro can declare an operator using an `Operator` return annotation:

```lua
local macro matmul!(lhs: Expression, rhs: Expression): Operator<'@', infix, multiplicative>
   return `utils.matmul($lhs, $rhs)`
end

local result = a @ b
```

The compiler parses `a @ b` with multiplicative precedence and expands it
through `matmul!` before type checking. The generated expression is
`(utils.matmul(a, b))`; the declaration and the operator symbol do not appear
in the emitted code. Expanded expressions receive normal Teal type checking.
This works with every Lua generation target and needs no runtime operator
library or LuaJIT syntax flag.

## Names and symbols

The spelling must be a string literal containing a non-reserved identifier
or an unused symbol or symbol sequence. Examples include `matmul`,
`cross_product`, `@`, `**`, `<=>`, `|>`, and `⊗`.

```lua
local macro cross!(lhs: Expression, rhs: Expression): Operator<'cross_product', infix, multiplicative>
   return `utils.cross($lhs, $rhs)`
end

local result = a cross_product b
```

Existing operators and Lua reserved keywords cannot be replaced. Teal soft
keywords such as `const`, `continue`, and `type` are available as identifier
operators in expression contexts. Whitespace,
digits within symbol spellings, mixed identifier/symbol spellings, quoting
characters, macro splice delimiters, structural delimiters, and sequences
containing the comment introducer `--` are rejected. Multi-character symbols
must be adjacent in source; the longest declared spelling wins. Identifier
operators match complete tokens, so `cross_product` never matches part of
`cross_product_other`.

## Fixity, precedence, and associativity

The second parameter is `prefix`, `infix`, or `postfix`. Infix declarations
require exactly two `Expression` parameters; prefix and postfix declarations
require exactly one. Optional parameters, `Statement` parameters, and varargs
are not allowed in operator declarations.

```lua
local macro squared!(value: Expression): Operator<'squared', postfix, postfix>
   return `$value * $value`
end

local macro negate!(value: Expression): Operator<'negate', prefix, unary>
   return `-$value`
end

local a = 3 squared
local b = negate 4
```

The third parameter selects a binding strength. These groups are listed from
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
exponentiation group. An optional fourth parameter selects `left` or `right`:

```lua
local macro power!(lhs: Expression, rhs: Expression): Operator<'**', infix, exponentiation, right>
   return `$lhs ^ $rhs`
end

local n = 2 ** 3 ** 2 -- 2 ** (3 ** 2)
```

A symbol may have both prefix and infix declarations. Infix and postfix
bindings for the same spelling are ambiguous and are rejected.

The expanded expression is parenthesized, preserving its grouping even when
the expansion uses a different built-in precedence. An operator produces one
value, including when its expansion is a call returning multiple values.
A standalone operator expression is allowed when it expands to a function
call, just as ordinary Lua call statements can discard their results.

## Scope and macros

Declare an operator statically before using it. Macro-generated declarations
do not introduce new parsing syntax. Operator bindings are local to the block
that declares them, are inherited by nested blocks/functions, and may be
shadowed in an inner block. Duplicate declarations in the same scope are
errors. Bindings do not leak between files. Explicit `matmul!(a, b)` calls
remain available, and retain the same lexical binding as the operator.

Operators can appear in macro arguments and quotes. Quoted operator uses
retain the bindings visible when the quote is parsed. The usual macro rules
control operand evaluation: the returned syntax determines evaluation order,
duplication, and short-circuiting. For example, the call expansion in the
first example evaluates each operand once, while the illustrative `squared`
expansion duplicates its operand.

Attached operator macros can be exported through records or interfaces like
other attached macros. Import one explicitly to activate its spelling:

```lua
local ops = require('matrix_operators')
local macro matmul! = ops.matmul!

local result = a @ b
```

The exported macro must carry its `Operator` annotation. Requiring a module
alone does not activate its custom operator spellings.
