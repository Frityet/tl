# Macros

Teal macros are compile-time code generators. They let you write Lua code that
constructs and returns AST blocks, which are then spliced into your program
before type checking and code generation. Macros are a separate feature from
macro expressions (see [Macro expressions](./macroexp.md)).

Macros are compile-time only: their declarations are removed after expansion
and produce no Lua code at runtime.

## Declaring a macro

A macro is declared with `local macro`, a name ending in `!`, and a function
body:

```lua
local macro inc!(x: Expression)
   return `$x + 1`
end

local y = inc!(2)
```

Here, `inc!` receives an expression AST and returns a new expression AST built
from a quote.

Macros can also be attached to records or interfaces using a top-level declaration:

```lua
local record macros end

macro macros.double!(x: Statement)
   return ```
      $x
      $x
   ```
end
```

## Importing attached macros

Attached macros can be imported through regular `require` aliases:

```lua
-- macros.tl
local record macros
   record Helper end
end

macro macros.double!(x: Statement)
   return ```
      $x
      $x
   ```
end

macro macros.Helper.side!(x: Statement)
   return ```
      print("side")
      $x
   ```
end

return macros
```

```lua
-- main.tl
local m = require("macros")
-- also supported: local type m = require("macros")

m.double!(print("hi"))
m.Helper.side!(print("there"))
```

Macros that you import from another module are attached to the record, just as `macroexp`s are, so you must qualify it with the record name (which may be nested). 

## Aliasing a macro

Use a local macro alias when an imported macro is used frequently:

```lua
local format = require("auxlib.format")
local macro f! = format.f!

local message = f!"Hello, {name}!"
```

Aliases are resolved at compile time, produce no Lua code, and retain the
target macro's argument signature.

## Invoking a macro

A macro call uses the `!` postfix operator and accepts the same argument forms
as function calls:

```lua
foo!(a, b)
foo!"string"
foo!{ key = "value" }
```

Macros can appear in expression or statement positions, as long as the macro
returns a compatible kind of block.

### Assignment targets

A macro invocation, including a custom operator, can appear in any target
position of an assignment or as the target of a compound assignment. Its
expansion must be a single assignable expression, such as a variable, field
access, or index access. The normal assignment and type-checking rules apply
to that expression.

```lua
local macro test_field!(tbl: Expression)
   return `($tbl).test`
end

local tbl = {test = 0}
test_field!(tbl) = 4
```

An expansion to a call, a computed value, or a statement is rejected as a
target. A call can still be the receiver of an assignable field or index.

## Macro arguments

Macro parameters must be annotated as one of:

- `Expression`
- `Statement`
- `...: Expression` (vararg)
- `...: Statement` (vararg)

Example:

```lua
local macro wrap!(s: Statement, e: Expression)
   local out = block("statements")
   table.insert(out, s)
   table.insert(out, `print($e)`)
   return out
end

wrap!(do
   local x = 1
end, "ok")
```

`Statement` arguments are passed as a `statements` block, which can contain one
or more statements.

Macro arguments are **AST blocks**. Teal expands any nested macro calls and
operators in each argument before invoking the outer macro. For example, in
`outer!(inner!())`, `outer` receives the block produced by `inner`. An inner
macro runs even if the outer macro discards its argument. If the outer macro
splices an expanded block twice, the resulting Lua can evaluate it twice.

## Quoting and splicing

Macros usually construct AST blocks by quoting Teal syntax:

- **Single backticks** quote an expression: `` `a + 1` ``
- **Triple backticks** quote statements: use three backticks (```` ``` ````)

The expansion must fit the invocation's context. A standalone macro call can
expand to statements or a function call. A different expression, such as
`` `1 + 2` ``, must be assigned, returned, or used within another expression.
Triple-backtick quotes must contain valid statements; quoting `1 + 2` with
triple backticks is a syntax error.

A macro that generates a declaration (for example, `local record Name end`)
must be invoked as a standalone statement. Writing `local x = declare!()`
does not turn the generated declaration into a value. These context errors
are reported at the macro invocation before Lua is generated.

Inside a macro quote, `$name` splices the macro argument named `name`:

```lua
local macro twice!(x: Expression)
   return `$x + $x`
end
```

For statement quotes, you can splice a `Statement` argument by putting `$name`
on its own line (optional semicolon):

````lua
local macro insert!(s: Statement)
   return ```
      $s
      print("after")
   ```
end
````

## Building AST blocks directly

The macro sandbox provides helpers for manual AST construction:

- `block(kind)` creates a block of a given kind
- `BLOCK_INDEXES` gives numeric indices for block fields
- `clone(b)` makes a deep copy of a block
- `string_value(b)` returns a string block's contents between its delimiters,
  preserving escape sequences
- `parse_expression(source)` parses exactly one Teal expression from a string,
  without executing it; its names are resolved and type-checked when the block
  is spliced into the caller. Invalid expressions, expression lists and statement
  sequences are rejected.

Example:

```lua
local macro make_local!(name: Expression, value: Expression)
   local BI = BLOCK_INDEXES
   local decl = block("local_declaration")
   decl[BI.LOCAL_DECLARATION.VARS] = block("variable_list")
   decl[BI.LOCAL_DECLARATION.VARS][1] = name
   decl[BI.LOCAL_DECLARATION.EXPS] = block("expression_list")
   decl[BI.LOCAL_DECLARATION.EXPS][1] = value
   return decl
end
```

which is the equivalent to

````lua
local macro make_local!(name: Expression, value: Expression)
   local decl = ```
      local $name = $value
   ```
   return decl
end
````

## Putting it all together, writing a pipe! macro

Using all these tools given to us by the macro system, we can write a simple `pipe!` macro that takes in an expression like

```lua
x | f | g(y)
```

and produces

```lua
g(f(x), y)
```

First, we declare the macro with the appropriate argument type:

```lua
local macro pipe!(pipe_expr: Expression)

end
```

now we want to make sure we are taking in an `op_bor` (`|`). We can do this using `expect`

```lua
local macro pipe!(pipe_expr: Expression)
   expect(pipe_expr, "op_bor")
end
```

Now we want to be extracting all of the "calls" that are being piped together. We do this by traversing the `op_bor` nodes until we reach the last expression.

```lua
local macro pipe!(pipe_expr: Expression)
   expect(pipe_expr, "op_bor")
   local BI = BLOCK_INDEXES

   local calls = {}
   local function append_call(expr)
      if expr.kind == "op_bor" then
         -- see below for the indexes
         -- because op_bor is a binary operator,
         -- we are going to use E1 and E2 to get the left and right expressions
         append_call(expr[BI.OP.E1])
         append_call(expr[BI.OP.E2])
      else
         -- this will be a block of a variable (f) or a func call (g(y))
         table.insert(calls, expr)
      end
      return nil
   end
   append_call(pipe_expr)
end
```

Now that we have the calls in order, we need to build the nested function calls. For our macro, we also want to make it so any variables on their own (for example, just `f` in `x | f`) are treated as function calls with no arguments (`f()`).

```lua
local macro pipe!(pipe_expr: Expression)
   expect(pipe_expr, "op_bor")
   local BI = BLOCK_INDEXES

   local calls = {}
   local function append_call(expr)
      if expr.kind == "op_bor" then
         -- see below for the indexes
         -- because op_bor is a binary operator,
         -- we are going to use E1 and E2 to get the left and right expressions
         append_call(expr[BI.OP.E1])
         append_call(expr[BI.OP.E2])
      else
         -- this will be a block of a variable (f) or a func call (g(y))
         table.insert(calls, expr)
      end
      return nil
   end
   append_call(pipe_expr)

   -- this is what we are gonna keep updating
   local invocation = calls[1]
   for i = 2, #calls do
      local call = calls[i]
      if call.kind ~= "op_funcall" then
         -- this is the case where we have a variable (f)
         -- we just need to give it an expression list to store its parameters
         call = `($call)()`
      end

      -- this is the parametres of the call itself
      local exprlist = call[BI.OP.E2]
      --we need a clone so we can mutate safely
      local newexprlist = clone(exprlist)
      -- adding in the previous invocation as the first parameter
      -- so `x | f` becomes `f(x)` and `x | f | g(y)` becomes `g(f(x), y)`
      table.insert(newexprlist, 1, invocation)
      invocation = clone(call)
      -- assigning the new parameter list back to our new call
      invocation[BI.OP.E2] = newexprlist
   end

   -- good job! we did it!
   return invocation
end
```

And we can test it out:

```lua
local function add(x: integer, y: integer): integer
    return x + y
end

local function double(x: integer): integer
    return x * 2
end

local z = pipe!(3 | add(4) | double)

print(z) -- prints 14
```

## By-design limitations

| Detail | Notes |
| --- | --- |
| Scope and import | `local macro` declarations are file-local. Attached macros (`macro Owner.name!`) can be imported through `require` aliases when their owner record or interface is the returned owner or nested under it. |
| Compile-time only | Macros run before type checking, and their declarations produce no runtime code. |
| Restricted environment | Macro bodies run in a sandbox with a limited standard library (no `require`, file I/O, or OS access beyond basic timing functions). |
| Argument types are fixed | Every parameter must be annotated as `Statement` or `Expression` (varargs allowed). Other annotations are errors. |
| Quotes are only valid inside macros | Backtick quotes and `$name` splices are rejected outside `local macro` bodies. |
| No macro calls inside macros | Macro bodies and both quote forms cannot invoke another macro, including custom operators and explicit operator macro calls. Use ordinary helper functions and construct the AST directly or quote built-in syntax. |
| Invocation style | Use `owner.macro!()`. Method-style `owner:macro!()` is rejected. |
| Statement args with top-level commas need a wrapper | When passing a statement argument like `local a, b = 1, 2`, wrap it in `do ... end` to avoid parsing ambiguity. |

## Block kinds

Blocks have a kind, token text, source coordinates, and numbered children.
Use `BLOCK_INDEXES` to access syntax attached to a block:

| Syntax | Block representation |
| --- | --- |
| An implicit array key | `LITERAL_TABLE_ITEM.IMPLICIT_KEY` |
| A short function | `FUNCTION.SHORT` |
| A native `const` | `LOCAL_DECLARATION.CONST` or `LOCAL_FUNCTION.CONST` |
| Optional navigation | `OP.SAFE` |
| Compound assignment | `ASSIGNMENT.OPERATOR` contains the full token, such as `+=` |
| A custom operator declaration or alias | `LOCAL_MACRO.OPERATOR` holds an `operator_spec` block |
| An operator use or its generated grouping | `MACRO_INVOCATION.OPERATOR` or `PAREN.OPERATOR_GROUPING` |

Long-bracket strings retain their delimiters in `tk`.

All block kinds that can be returned from macros are listed below (from
`teal/block.tl`):

```
nil
string
number
integer
boolean
literal_table
literal_table_item
function
expression_list
if
if_block
while
fornum
forin
goto
label
repeat
do
continue
conditional
break
return
newtype
argument
type_identifier
variable_list
statements
assignment
argument_list
local_function
global_function
local_type
global_type
record_function
local_declaration
global_declaration
identifier
...
:
;
comment
hashbang
paren
macroexp
local_macroexp
local_macro
macro_quote
macro_var
macro_invocation
operator_spec
operator_use
operator_grouping
implicit_table_key
short_function
native_const
safe_navigation
compound_operator
record
interface
enum
pragma
error_block
userdata
op_not
op_len
op_unm
op_bnot
op_or
op_and
op_is
op_lt
op_gt
op_le
op_ge
op_ne
op_eq
op_bor
op_bxor
op_band
op_shl
op_shr
op_sar
op_coalesce
op_concat
op_add
op_sub
op_mul
op_div
op_idiv
op_mod
op_pow
op_as
op_funcall
op_index
op_dot
op_colon
typeargs
type_list
generic_type
typedecl
tuple_type
nominal_type
map_type
array_type
union_type
argument_type
interface_list
record_body
record_field
question
```

## BLOCK_INDEXES reference

`BLOCK_INDEXES` maps block kinds to the numeric slots used by their children.
This is the full table used by the macro API (from `teal/block.tl`):

```lua
MACROEXP.RETS
MACROEXP.ARGS
MACROEXP.EXP

GLOBAL_TYPE.VALUE
GLOBAL_TYPE.VAR

ASSIGNMENT.VARS
ASSIGNMENT.OPERATOR
ASSIGNMENT.EXPS

MACRO_INVOCATION.ARGS
MACRO_INVOCATION.MACRO
MACRO_INVOCATION.OPERATOR

PAREN.EXP
PAREN.OPERATOR_GROUPING

DO.BODY

FUNCTION.BODY
FUNCTION.RETS
FUNCTION.TYPEARGS
FUNCTION.ARGS
FUNCTION.SHORT

LOCAL_MACROEXP.NAME
LOCAL_MACROEXP.EXP

LOCAL_TYPE.VALUE
LOCAL_TYPE.VAR

MACRO_VAR.NAME

GLOBAL_DECLARATION.EXPS
GLOBAL_DECLARATION.VARS
GLOBAL_DECLARATION.DECL

RECORD.FIELDS
RECORD.META_FIELDS
RECORD.ARRAY_TYPE
RECORD.WHERE_CLAUSE
RECORD.INTERFACES

RECORD_FUNCTION.ARGS
RECORD_FUNCTION.BODY
RECORD_FUNCTION.RETS
RECORD_FUNCTION.TYPEARGS
RECORD_FUNCTION.NAME
RECORD_FUNCTION.OWNER

RETURN.EXPS

MAP_TYPE.KEYS
MAP_TYPE.VALUES

OP.E1
OP.E2
OP.SAFE

OPERATOR_SPEC.BINDING
OPERATOR_SPEC.FIXITY
OPERATOR_SPEC.PRECEDENCE
OPERATOR_SPEC.ASSOCIATIVITY

ARRAY_TYPE.ELEMENT

NOMINAL_TYPE.NAME

NEWTYPE.TYPEDECL

GENERIC_TYPE.TYPEARGS
GENERIC_TYPE.BASE

TYPEARG.NAME
TYPEARG.CONSTRAINT

ARGUMENT_TYPE.NAME

TYPEDECL.TYPE

PRAGMA.KEY
PRAGMA.VALUE

WHILE.BODY
WHILE.COND

RECORD_FIELD.DEFAULT_VAL
RECORD_FIELD.VAL
RECORD_FIELD.TYPE
RECORD_FIELD.NAME
RECORD_FIELD.METHOD

RECORD_BODY.META_FIELDS
RECORD_BODY.FIELDS

MACRO_QUOTE.BLOCK

INTERFACE.FIELDS
INTERFACE.INTERFACES
INTERFACE.ARRAY_TYPE

LITERAL_TABLE_ITEM.VALUE
LITERAL_TABLE_ITEM.KEY
LITERAL_TABLE_ITEM.TYPED_VALUE
LITERAL_TABLE_ITEM.IMPLICIT_KEY

FUNCTION_TYPE.MACROEXP
FUNCTION_TYPE.ARGS
FUNCTION_TYPE.RETS

LOCAL_DECLARATION.EXPS
LOCAL_DECLARATION.VARS
LOCAL_DECLARATION.DECL
LOCAL_DECLARATION.CONST

LOCAL_FUNCTION.RETS
LOCAL_FUNCTION.BODY
LOCAL_FUNCTION.TYPEARGS
LOCAL_FUNCTION.NAME
LOCAL_FUNCTION.ARGS
LOCAL_FUNCTION.CONST

FORIN.EXPS
FORIN.VARS
FORIN.BODY

GOTO.LABEL

GLOBAL_FUNCTION.RETS
GLOBAL_FUNCTION.BODY
GLOBAL_FUNCTION.TYPEARGS
GLOBAL_FUNCTION.NAME
GLOBAL_FUNCTION.ARGS

VARIABLE.ANNOTATION

REPEAT.BODY
REPEAT.COND

LABEL.NAME

IF_BLOCK.BODY
IF_BLOCK.COND

LOCAL_MACRO.RETS
LOCAL_MACRO.BODY
LOCAL_MACRO.TYPEARGS
LOCAL_MACRO.NAME
LOCAL_MACRO.ARGS
LOCAL_MACRO.OPERATOR

FORNUM.TO
FORNUM.VAR
FORNUM.FROM
FORNUM.BODY
FORNUM.STEP

ARGUMENT.TYPE
```

## Custom operators

A parenthesized macro such as `(@)!` returning `Operator<infix, multiplicative>` declares an operator
that expands through that macro. See [Custom operators](custom_operators.md)
for named and symbolic spellings, fixities, precedence, scope, and imports.
