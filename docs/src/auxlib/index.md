# Auxlib

Auxlib provides Teal modules for common application tasks. From a Teal
checkout, use `./tl check example.tl` or `./tl run example.tl` with the
examples in this section. In Xmake, add `add_deps("tl.auxlib")` to the target
that uses the modules.

When you run generated Lua directly, put the compiled auxlib modules on
`package.path`. Macros expand during Teal compilation. The `luv` and SQLite
adapters also need their native Lua packages at run time.

| Module | Use |
| --- | --- |
| [`auxlib.argparse`](argparse.md) | Parse command-line arguments and generate help. |
| [`auxlib.async`](async.md) | Schedule coroutine tasks and wait for their results. |
| [`auxlib.async.frame`](async_frame.md) | Advance a scheduler with frame deltas. |
| [`auxlib.async.luv`](async_luv.md) | Run a scheduler on the `luv` event loop. |
| [`auxlib.database`](database.md) | Query a database through a provider. |
| [`auxlib.database.sqlite`](database_sqlite.md) | Open a SQLite connection with `lsqlite3`. |
| [`auxlib.ffi`](ffi.md) | Declare typed bindings for LuaJIT FFI. |
| [`auxlib.format`](format.md) | Interpolate Teal expressions in strings. |
| [`auxlib.math`](math.md) | Clamp, interpolate, and ease numeric values. |
| [`auxlib.Object`](object.md) | Add a type tag and method lookup to a record. |
| [`auxlib.struct`](struct.md) | Build records with constructors and property validation. |
| [`auxlib.tables`](tables.md) | Process arrays and maps and compose operations. |
| [`auxlib.testing`](testing.md) | Run test suites and report results. |
