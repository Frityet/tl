--#pragma strict_nil on

--- Run SQL through a database provider. Each connection uses a provider that
--- supplies binding, query results, and transaction control for its database.
--- Pass data as bound parameters. Use `NULL` for a SQL null in parameters
--- and results. In Lua, nil means a row or column is absent.
local record Database
   record Null end
   --- Represent a SQL null in a parameter list or a result row.
   NULL: Null
   type Value = boolean | number | string | Null
   type Params = {Value}
   type Row = {string: Value | nil}

   --- Define how one database connection runs SQL. Raise a Lua error when an
   --- operation fails. The provider chooses the SQL dialect and parameter syntax.
   --- Declare a record with `is DatabaseProvider` to define a provider.
   interface DatabaseProvider
      --- Run a statement that returns no rows.
      --- @param sql SQL text with placeholders for parameters.
      --- @param params Values to bind in order.
      --- @return Number of rows affected, or zero if no row count applies.
      execute: function(self, sql: string, params: Params): integer
      --- Run a statement that returns rows.
      --- @param sql SQL text with placeholders for parameters.
      --- @param params Values to bind in order.
      --- @return An array of rows. Use result column names as keys and `NULL` for SQL nulls.
      query: function(self, sql: string, params: Params): {Row}
      --- Start a transaction.
      begin: function(self)
      --- Commit the open transaction.
      commit: function(self)
      --- Roll back the open transaction.
      rollback: function(self)
      --- Release the backend connection.
      close: function(self)
   end

   record Connection
      _provider: DatabaseProvider
      _transaction_owner: thread | boolean | nil
      _broken: boolean
      _closed: boolean
   end
end

local type Connection = Database.Connection
local type DatabaseProvider = Database.DatabaseProvider
local type Params = Database.Params
local type Row = Database.Row
local type Value = Database.Value

Database.NULL = {}

local function open_provider(connection: Connection): DatabaseProvider
   assert(not connection._closed, "database connection is closed")
   assert(not connection._broken, "database connection is unusable after a rollback failure")
   local owner = connection._transaction_owner
   local running: thread | boolean | nil = coroutine.running() or false
   assert(owner == nil or owner == running, "database connection is in use by another transaction")
   return connection._provider
end

--- Run a statement that returns no rows.
--- @param sql SQL text with placeholders for parameters.
--- @param params Values to bind in order. If nil, bind no values.
--- @return Number of rows affected, or zero if no row count applies.
function Database.Connection:execute(sql: string, params?: Params): integer
   return open_provider(self):execute(sql, params or {})
end

--- Run a statement and collect its result rows.
--- @param sql SQL text with placeholders for parameters.
--- @param params Values to bind in order. If nil, bind no values.
--- @return An array of rows with column names as keys.
function Database.Connection:query(sql: string, params?: Params): {Row}
   return open_provider(self):query(sql, params or {})
end

--- Read up to one result row. Raise an error if the query returns several rows.
--- @param sql SQL text with placeholders for parameters.
--- @param params Values to bind in order. If nil, bind no values.
--- @return The result row, or nil if the query returns no rows.
function Database.Connection:one(sql: string, params?: Params): Row | nil
   local rows = self:query(sql, params)
   assert(#rows <= 1, "database query returned more than one row")
   return rows[1]
end

--- Read one column from a query that returns up to one row.
--- @param sql SQL text with placeholders for parameters.
--- @param column Result column name or alias. Raise an error if the row lacks this column.
--- @param params Values to bind in order. If nil, bind no values.
--- @return The column value, or nil if the query returns no rows.
function Database.Connection:scalar(sql: string, column: string, params?: Params): Value | nil
   local row = self:one(sql, params)
   if not row then return nil end
   local value = row[column]
   assert(value ~= nil, "database query has no result column " .. column)
   return value
end

--- Run a function in a transaction. Commit when the function returns. If the
--- function or commit fails, roll back and raise the error. If rollback
--- fails, report both errors and allow only `close()` on the connection.
--- @param body Function that receives this connection and returns a value.
---   Use this connection for all operations. The function must run without yielding.
--- @return The function's value after a successful commit.
function Database.Connection:transaction<T>(body: function(Connection): T): T
   local provider = open_provider(self)
   assert(self._transaction_owner == nil, "database transactions cannot be nested")
   provider:begin()
   -- Lua 5.1 returns nil from coroutine.running() on the main thread.
   self._transaction_owner = coroutine.running() or false
   local ok, result = pcall(function(): T
      local value = body(self)
      provider:commit()
      return value
   end)
   if not ok then
      local rolled_back, rollback_error = pcall(function(): nil
         provider:rollback()
         return nil
      end)
      self._transaction_owner = nil
      if not rolled_back then
         self._broken = true
         error("database rollback failed (" .. tostring(rollback_error) .. ") after " .. tostring(result), 0)
      end
      error(result, 0)
   end
   self._transaction_owner = nil
   return result as T
end

--- Close the connection. Repeat calls have no effect after a successful close.
--- Raise an error if a transaction is open.
function Database.Connection:close()
   if self._closed then return end
   assert(self._transaction_owner == nil, "cannot close a database connection during a transaction")
   self._provider:close()
   self._closed = true
end

--- Wrap a provider for an open database connection.
--- @param provider Provider to use and later close through the returned connection.
--- @return A connection with query and transaction methods.
function Database.connect(provider: DatabaseProvider): Connection
   assert(type(provider.execute) == "function" and type(provider.query) == "function" and
      type(provider.begin) == "function" and type(provider.commit) == "function" and
      type(provider.rollback) == "function" and type(provider.close) == "function",
      "database provider must implement execute, query, begin, commit, rollback, and close")
   return {
      _provider = provider,
      _broken = false,
      _closed = false,
      execute = Database.Connection.execute,
      query = Database.Connection.query,
      one = Database.Connection.one,
      scalar = Database.Connection.scalar,
      transaction = Database.Connection.transaction,
      close = Database.Connection.close,
   }
end

--- Quote one SQL identifier with double quotes. Double each quote inside
--- the name. For a qualified name, quote each part before joining with dots.
--- @param name Nonempty identifier without a NUL byte.
--- @return The quoted identifier for databases that use standard SQL quotes.
function Database.quote_identifier(name: string): string
   assert(name ~= "" and not name:find("%z"), "invalid SQL identifier")
   return '"' .. name:gsub('"', '""') .. '"'
end

--- Make a list of positional `?` placeholders, such as `?, ?, ?`.
--- @param count Number of placeholders, one or greater.
--- @return Placeholders with a comma and a space between them.
function Database.placeholders(count: integer): string
   assert(count >= 1 and count % 1 == 0, "placeholder count must be a positive integer")
   local slots: {string} = {}
   for index = 1, count do slots[index] = "?" end
   return table.concat(slots, ", ")
end

return Database
