# LuaJIT syntax extensions

Teal accepts the [LuaJIT 3.0 syntax extensions backported to LuaJIT 2.1](https://github.com/LuaJIT/LuaJIT/issues/1476).
Select the runtime target explicitly:

```sh
tl gen --check --gen-target=luajit program.tl
tl run --gen-target=luajit program.tl
```

For a project, use:

```lua
return {
   gen_target = "luajit",
}
```

The API equivalent is `gen_target = "luajit"` in compiler/environment options
and `tl.generate(ast, "luajit")`. Compilation does not require running the
compiler itself under LuaJIT. Executing the generated code requires LuaJIT
2.1 with the syntax backport and its fixes. LuaJIT `2.1.1793383622` was used
for runtime validation, including the complete optional-chain behavior.

## Syntax and lowering

| Extension | Example | Generated LuaJIT code |
| --- | --- | --- |
| Bit operators | `~a`, `a & b`, `a \| b`, `a ~ b`, `a << b`, `a >> b`, `a ~>> b` | Native operators with LuaJIT's `bit.*` semantics |
| Customary operators | `!a`, `a && b`, `a \|\| b`, `a != b` | `not a`, `a and b`, `a or b`, `a ~= b` |
| Conditional expression | `condition ? yes : no` | Parenthesized native conditional |
| Nil coalescing | `value ?? fallback` | Native nil-coalescing operator |
| Safe navigation | `obj?.field`, `obj?.[key]`, `f?.(args)`, `obj?.:method?.(args)` | Native safe-navigation chain |
| Compound assignment | `a += b`, `t[key()] ..= text` | Native compound assignment |
| Continue | `if skip then continue end` | Native `continue` |
| Constant declaration | `const N: integer = 10` | `const N = 10` |
| Constant function | `const function f(): integer return 1 end` | `const function f() return 1 end` |
| Short function | `x -> x + 1`, `\|x: integer\| -> do return x + 1 end` | Ordinary `function(x) ... end` |
| Numeric separators | `1_000`, `0x_ff`, `0_b_10`, `1_2e_1` | Separators removed |

The compound operators are `+= -= *= /= %= &= |= ~= <<= >>= ~>>= ..=`.
In statement context, `a ~= b` means xor assignment. In an expression,
`a ~= b` remains inequality. Compound assignments take one target and one
expression.

Native lowering preserves runtime details that a rewrite such as
`a and b or c` or `t[key()] = t[key()] + rhs` would lose: false/nil results,
short-circuit evaluation, FFI NULL comparisons, and evaluating receivers
and keys exactly once. An optional chain also suppresses subsequent
operations and assignment RHS evaluation when a safe check fails.
Parentheses end a chain: `(obj?.field).next` performs the final access
unconditionally.

`??` has the same precedence and left associativity as `or`. Ternaries
have lower precedence and associate to the right. Parenthesize method
calls in the middle ternary branch: `condition ? (obj:method()) : default`.

## Types and scope

Short functions support all four forms:

```lua
local increment: function(integer): integer = x -> x + 1
local add = |a: integer, b: integer| -> a + b
local answer = || -> 42
local pair = || -> do return 1, 2 end
```

Place an explicit return annotation after the closing pipe and before `->`.

```lua
local answer = ||: integer -> 4
local increment = |x: integer|: integer -> x + 1
local pair = ||: (integer, string) -> do return 4, "four" end
```

The annotation supplies the return types for both expression and block bodies.
An expected function signature can still supply omitted parameter types.

Parameters can use Teal annotations between the pipes. Unannotated
parameters receive contextual types when an expected function signature
is available. Otherwise, they follow Teal's usual unannotated parameter
rules. Contextual inference includes generic callbacks, using the types of
other arguments even when supplied as literals, fields, or call results.
See [contextual parameter inference](functions.md#contextual-parameter-inference).
Omitted return types are inferred when no expected signature is available,
including unions across returns and nil for paths that fall through.
The expression form returns one expression, which may itself produce
multiple results; the block form can use an explicit return list.

Safe navigation adds nil to its result type. A further unguarded access
still needs a non-nil field type; use another `?.` for a genuinely nullable
intermediate field. Coalescing removes nil from the left-hand result while
retaining false. Ternary branches use the same narrowing facts as an if/else
and produce their combined result type. Compound assignment checks the
operator's result against the target type and respects constant writes.

`const` variables cannot be assigned again or shadowed in their scope or
an inner scope, including function parameters. A referenced table remains
mutable. These shadowing rules are stronger than Teal's existing
`local x <const>` attribute. Both `const` and `continue` remain soft keywords
and may still be ordinary variable names.

`continue` targets the innermost loop in the same function and must end its
block. In a repeat loop, it cannot jump past a declaration whose scope
extends into the until condition.

## Other targets and exclusions

Customary operators, short functions, numeric separators, and constant
bindings can also be lowered to the existing standard Lua targets.
Native-only syntax requires the explicit `luajit` target; other targets
report an error. Existing bit-operator compatibility lowering for `5.1`
remains unchanged.

Macro quotes and spliced syntax retain the extension metadata. Macro
implementations can use native extensions when the compiler host itself
supports the backport; quoting native syntax does not require that host.

The backport does not supply bit-operator metamethods, floor division,
compound-assignment metamethods with a third `true` argument, or named
vararg parameters. LuaJIT generation rejects bit-operator metamethod use.
Teal's existing `//` and named-vararg features continue to use compatibility
lowering when compatibility generation is enabled; they are not emitted
as unsupported native syntax. LuaJIT integer and imaginary numeric suffixes
are retained and require the `luajit` target.
