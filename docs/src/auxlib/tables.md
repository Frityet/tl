# Arrays and maps with `auxlib.tables`

Array functions read dense sequences in index order. The map functions use
`pairs`, whose iteration order is unspecified.

```teal
local tables = require("auxlib.tables")
local macro (||>)! = tables.(||>)!
local macro (from)! = tables.(from)!

local scores: {integer} = {3, 5}
local labels = scores ||> |score, index| -> tostring(index) .. ":" .. tostring(score)
print(labels[1], labels[2]) -- 1:3  2:5

local size = {width = 3, height = 4};
{width as w, height} from size
print(w * height) -- 12
```

## Functions

| Function | Result |
| --- | --- |
| `map(array, transform)` | A new array with the results of `transform(value, index)` at the original indices. |
| `select(array, predicate)` | A new dense array of matching values, in index order. |
| `filter(table, predicate)` | A new table with the keys and values that match. |
| `sum(table, project)` | The sum of `project(value, key)`, or zero for an empty table. |
| `reduce(table, initial, step)` | The accumulator after applying `step(accumulator, value, key)` to each entry. |
| `count(table, predicate)` | The number of matching entries. |
| `any(table, predicate)` | Whether an entry matches. |
| `all(table, predicate)` | Whether every entry matches. Returns `true` for an empty table. |
| `find(table, predicate)` | The first matching value in `pairs` order, or `nil`. |
| `group_by(table, select_group)` | Groups keyed by `select_group(value, key)`, each with the original entry keys and values. |
| `keys(table)`, `values(table)` | An array of keys or values in `pairs` order. |
| `tap(value, inspect)` | The input value after calling `inspect(value)` once. |

Predicates receive the value and key, or the value and index for dense
arrays. `filter` preserves keys, so a filtered array can have gaps. Use
`select` to return a dense result. Test `find` against `nil` when `false`
can be a matching value.

## Operators

Import each operator you use as a local macro, for example
`local macro (|>)! = tables.(|>)!`.

| Operator | Behavior |
| --- | --- |
| `value \|> f(extra)` | Call `f(value, extra)`. A chain of pipes runs from left to right. |
| `array \|\|> transform` | Apply `map` to the array. |
| `table +=> project` | Apply `sum` with a numeric projection. |
| `table +=> {initial, step}` | Apply `reduce` with an initial accumulator. |
| `table ?> predicate` | Apply `filter`, keeping the original keys. |
| `array ?>> predicate` | Apply `select`, returning a dense array. |
| `value \|? fallback` | Return `value` if it is non-nil, including `false`. Evaluate `fallback` only when `value` is `nil`. |
| `{field, other as name} from source` | Evaluate `source` once and bind its fields to constant locals. |

Use `value |> (factory())` to call the function returned by `factory()`.
If the previous statement could treat the opening brace of a `from` binding
as a call argument, end that statement with `;`.
