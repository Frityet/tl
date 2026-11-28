# C bindings with `auxlib.ffi`

`ffi!` generates typed bindings for a native library and loads it through
LuaJIT FFI at run time. Pass one local record marked `is CLib`. Its `where`
clause lists library names to try in order. Declare functions and exported
variables as fields on that record.

```teal
local bindings = require("auxlib.ffi")
local macro ffi! = bindings.ffi!

ffi!(
   local record C is CLib where lib == "c" or lib == "System"
      puts: function(CString): int
   end
)

C.puts("Hello from Teal")
```

Declare a nested `record ... is CStruct` for each C struct. Match the C
field order and types. Function declarations take a fixed list of required
parameters and return at most one value. Use `void` for no return value or
as the target of a pointer.

| C declaration type | Teal representation |
| --- | --- |
| `char`, `schar`, `uchar`, `short`, `ushort`, `int`, `uint`, and fixed-width integers up to 32 bits | `integer` |
| `long`, `ulong`, `size_t`, `ptrdiff_t` | `integer \| userdata` |
| `longlong`, `ulonglong`, `int64_t`, `uint64_t` | `userdata` for fields and results. Parameters also accept `integer`. |
| `float`, `double` | `number` |
| `bool` | `boolean` |
| `ptr<T>` | `userdata` for fields and results. Parameters accept `userdata` or `nil`. |
| `CString`, `ptr<const<char>>` | `userdata` for fields and results. Parameters also accept Lua strings. |
| A declared `CStruct` name | The typed userdata record for that struct. |

Use `const<T>` to qualify a C type. `bindings.string(pointer, length?)`
copies readable bytes from a character buffer into a Lua string. Omit the
length to read through the first NUL byte.

The generated code calls `bindings.bind(namespace, definition, names)`.
It tries the listed libraries, registers the C declarations, and attaches
symbol lookup to the namespace. The library must export the names declared
by the record.
