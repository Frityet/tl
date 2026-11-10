# Experimental C target

Generate a standalone C program from a Teal entry file with
[`--#pragma strict on`](./pragmas.md#strict-mode) and its Teal imports.
Each runtime source file produces its own C translation unit for Clang.

```lua
-- hello.tl
--#pragma strict on
local ffi = require("auxlib.ffi")

ffi.cdef! [[
   int printf(const char *, ...);
]]

C.printf("Hello, world!\n")
```

```sh
tl gen --gen-target=c hello.tl
clang -std=c11 -O2 hello.c -o hello
./hello
```

For programs with one translation unit, use `-o -` to emit C on standard
output. You can also set `gen_target = "c"`
in `tlconfig.lua`. With the Teal API, pass the same option to `teal.compiler`
or to the defaults for `tl.new_env`.

## Foreign declarations

The `auxlib.ffi` import in the example is expanded at compile time. Type
imports such as `local type Types = require("types")` are also allowed.
`require("ffi")` resolves to the built-in FFI namespace. You can use its
`ffi.cdef` directly when targeting C.

Each `ffi.cdef!` must be a top-level statement with a string literal. Use
it to declare function prototypes, read-only extern objects, typedefs, and
opaque struct or union tags. Teal checks calls and makes declared symbols
available under `C`. Named scalar and pointer typedefs are also available as
Teal types, for example `C.Handle` after `typedef void *Handle;`.

| C declaration type | Type in Teal |
| --- | --- |
| `void` return | No return value |
| `_Bool` or `bool` | `boolean` |
| C integer types, including `size_t` and fixed-width integers | `integer` (signed 64-bit) |
| `float`, `double` | `number` (double) |
| `const char *` | `string` |
| `char *` return | Borrowed `string` |
| Other single-level pointers | Opaque pointer type |

Pointer returns and extern pointer values include `nil` by default. Annotate a
pointer with `_Nonnull` when its C contract guarantees a value. Pointer
parameters require a value unless annotated with `_Nullable`. Foreign
strings are borrowed and must stay valid while Teal uses them.

C variadic arguments use `int` for Teal integers and booleans, `double` for
numbers, and C strings for strings. For example, use `%d` for an integer and
`%f` for a number with `printf`. Integer conversions across the FFI boundary
trap on overflow.

## Typed FFI in LuaJIT

The same `ffi.cdef!` macro creates a typed `C` namespace in Lua output.
You can use it in regular or strict Teal files. Run the generated Lua with
LuaJIT.

```sh
tl gen --gen-target=luajit hello.tl -o hello.lua
luajit hello.lua
```

LuaJIT output registers the declarations with `ffi.cdef`, copies returned
C strings into Lua strings, and converts null pointer results to `nil`.
Opaque pointers remain C data. Integer results returned as C data must fit
LuaJIT's safe integer range of ±(2⁵³ − 1).

Calls that retain their typed C variadic signature promote integer and
boolean arguments to C `int`, as in the C target. Fixed arguments use
LuaJIT's FFI conversions. For declarations that use the full LuaJIT FFI
syntax, you can call the raw `ffi.cdef` with its dynamic `ffi.C` namespace.

## Teal modules

Use a literal `require("name")` for a Teal module. The compiler looks for
`name.tl` and `name/init.tl` beside the importing file, then searches the
usual Teal module path, including directories passed with `-I`. A dotted
name such as `app.stats` searches a nested directory. Runtime imports use
`.tl` implementations and undergo strict checking automatically.
Type-only imports can also use `.d.tl` declarations.

Each required file initializes at its first runtime use. Repeated imports of the same resolved
path reuse its export value and state. Circular runtime imports produce a compiler
error. A module can export a non-nil value such as a record of functions,
or return implicitly to provide `true`.

```lua
-- stats.tl
local function sum(values: {integer}): integer
   local total = 0
   for _, value in ipairs(values) do
      total = total + value
   end
   return total
end

return { sum = sum }
```

```lua
-- main.tl
--#pragma strict on
local stats = require("stats")
local values: {integer} = {2, 3, 5}
table.insert(values, 7)
print("Total: " .. tostring(stats.sum(values)))
```

```sh
tl gen --gen-target=c main.tl
clang -std=c11 -O2 main.c main.modules/tl_*.c -o main
./main
```

This emits `main.c`, `main.modules/tl_stats.c`, and the shared
`main.modules/abi.h` header. The module directory follows the entry output
name if you use `-o`. Compile the C sources together or compile them into
separate object files and link the objects.

The programmatic API exposes these outputs through `Module:gen_c()` or
`tl.generate_c(checked_ast)`. The result holds the `entry` source and, for
multi-file programs, the module `directory`, `header` source for `abi.h`,
and a `modules` list with each unit's `source` path, output `filename`,
and generated `code`.

## Standard library

| Area | Supported functions and values |
| --- | --- |
| Core | `print`, `tostring` for scalars, `tonumber(value)`, `type`, `assert`, `error`, `ipairs` in a generic loop |
| Math | `abs`, `acos`, `asin`, `atan`, `atan2`, `ceil`, `cos`, `cosh`, `deg`, `exp`, `floor`, `fmod`, `log`, `log10`, `max`, `min`, `pow`, `rad`, `sin`, `sinh`, `sqrt`, `tan`, `tanh`, `huge`, `maxinteger`, `mininteger`, `pi` |
| Strings | `len`, `lower`, `rep`, `reverse`, `sub`, `upper`, and the corresponding string methods |
| Tables | `insert` and `remove` for dense arrays, `concat` for string arrays |

Access the supported library namespaces directly or through a literal
`require` of `math`, `string`, or `table`. On platforms with a separate
math library, link with `-lm` for math functions, power, floating-point
modulo, or floor division.

## Supported Teal code

The target supports scalars, nullable scalars, opaque pointers, fixed-field
records, and dense one-based arrays. Arrays support indexing, assignment,
length, and appending at `#array + 1`. Runtime checks report out-of-bounds
access. Initialize required data fields with a record literal. Top-level
functions and function fields use statically known parameter and return
types, with at most one return value.

A top-level integer return in the entry file is the process exit status.
The generated program includes its runtime helpers. Strings are
NUL-terminated. Allocations for records, arrays, and constructed strings
live until process exit. C struct bodies, function pointers, arrays, and
preprocessor directives are outside the supported `cdef` declaration
syntax. Declare the ABI of additional C functions and link their
implementation with Clang.
