# Database providers with `auxlib.database`

`database.connect(provider)` wraps an open database provider in a
`Connection`. The provider defines the SQL dialect and placeholder syntax.
Use [the SQLite adapter](database_sqlite.md) for an example with a real
connection.

Bind values through the `params` argument. `database.Params` is an array of
`database.Value`. A value can be a boolean, number, string, or
`database.NULL`. A row is a table keyed by column name. SQL null appears as
`database.NULL`. A missing row or column is `nil`.

## Connection methods

| Method | Result |
| --- | --- |
| `db:execute(sql, params?)` | The number of rows affected, or zero when no count applies. Use it for statements that return no rows. |
| `db:query(sql, params?)` | An array of all result rows. |
| `db:one(sql, params?)` | One row or `nil`. Raises if the query returns more than one row. |
| `db:scalar(sql, column, params?)` | A named value from up to one row. Returns `nil` for no row and raises if the row lacks the column. |
| `db:transaction(body)` | The value returned by `body(db)` after commit. |
| `db:close()` | Release the connection. Repeat calls have no effect after a successful close. |

A transaction rolls back when the body or commit raises an error. Run the
body on the same connection without yielding. The connection allows one
transaction at a time and must stay open until it finishes. After a rollback
failure, only `close()` is available.

## SQL helpers

```teal
local database = require("auxlib.database")

print(database.quote_identifier("order detail")) -- "order detail"
print(database.placeholders(3)) -- ?, ?, ?
```

`quote_identifier(name)` quotes one identifier using standard SQL double
quotes. Quote each component of a qualified name separately.
`placeholders(count)` returns comma-separated `?` markers for a positive
count.

## Writing a provider

Implement `database.DatabaseProvider` with `execute`, `query`, `begin`,
`commit`, `rollback`, and `close`. Report failures by raising Lua errors.
`execute` and `query` receive the SQL text and a parameter array. Give
each returned column a name and represent SQL null with `database.NULL`.
The connection calls the provider's `close` method when it closes.
