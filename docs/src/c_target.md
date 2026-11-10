# Experimental C target

Generate a standalone C program from one Teal file with
[`--#pragma strict on`](./pragmas.md#strict-mode). Compile the resulting
translation unit with Clang.

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

Use `-o -` to emit C on standard output. You can also set `gen_target = "c"`
in `tlconfig.lua`. With the Teal API, pass the same option to `teal.compiler`
or to the defaults for `tl.new_env`.

## Foreign declarations

The `auxlib.ffi` import in the example is expanded at compile time. Type
imports such as `local type Types = require("types")` are also allowed. The only
runtime require syntax accepted by the target is `require("ffi")`, which the
compiler resolves to its built-in FFI namespace. You can also use its
`ffi.cdef` directly.

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

## Supported Teal code

The target supports scalar locals, top-level local functions, assignments,
conditionals, loops, and scalar arithmetic. A top-level integer return is
the process exit status. The generated program includes its helpers and
needs no Lua runtime. On platforms with a separate math library, link with
`-lm` if your program uses power, floating-point modulo, or floor division.

The initial subset excludes runtime Lua modules and libraries, tables,
closures, multiple return values, and nullable numeric and boolean values.
Strings use C's NUL-terminated representation. C struct bodies, function
pointers, arrays, and preprocessor directives are outside the supported
`cdef` declaration syntax. Declare the ABI of any additional C functions
you use and link their implementation with Clang.
