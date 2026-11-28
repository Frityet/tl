# SQLite with `auxlib.database.sqlite`

`sqlite.open(filename)` opens a SQLite database using the native `lsqlite3`
Lua module. It returns a [`database.Connection`](database.md#connection-methods)
that owns the SQLite handle. Use `":memory:"` for a database that lasts for
the life of the connection.

```teal
local sqlite = require("auxlib.database.sqlite")
local db = sqlite.open(":memory:")

db:execute("CREATE TABLE books (title TEXT, checked_out INTEGER)")
db:execute("INSERT INTO books VALUES (?, ?)", {"Teal", false})
print(db:scalar("SELECT title FROM books WHERE checked_out = ?", "title", {false})) -- Teal
db:close()
```

Pass one statement per call and bind parameters in placeholder order. Use
`database.NULL` to bind SQL null or detect it in a result. The adapter binds
booleans as integers `0` and `1`. Read the resulting column as a number.

Use `query`, `one`, or `scalar` for statements with result columns. Give
each result column a distinct name or alias. Counts returned by `execute`
include changes made by triggers.
