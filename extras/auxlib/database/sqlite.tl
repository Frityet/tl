--#pragma strict_nil on

local database = require("auxlib.database")
local type DatabaseProvider = database.DatabaseProvider

--- Open SQLite databases through the optional `lsqlite3` binding.
--- Use `?` for positional parameters. SQLite stores booleans as 0 or 1.
--- Pass one statement per call and give result columns distinct names.
--- Row counts include changes made by triggers.
---
--- ```teal
--- local db = sqlite.open(":memory:")
--- db:execute("CREATE TABLE people (name TEXT)")
--- db:execute("INSERT INTO people VALUES (?)", {"Ada"})
--- print(db:scalar("SELECT name FROM people WHERE name = ?", "name", {"Ada"}))
--- db:close()
--- ```
local record SQLiteAdapter end

-- Declare the part of the native binding that the adapter calls.
local type NativeValue = string | number | nil

local record Statement
   isopen: function(self): boolean
   bind_parameter_count: function(self): integer
   bind: function(self, integer, NativeValue): integer
   columns: function(self): integer
   get_names: function(self): {string}
   get_value: function(self, integer): NativeValue
   step: function(self): integer
   finalize: function(self): integer
end

local record Handle
   prepare: function(self, string): Statement | nil, string | integer
   errmsg: function(self): string
   total_changes: function(self): integer
   close: function(self): integer
end

local record LSQLite
   open: function(string): Handle | nil, integer | nil, string | nil
   OK: integer
   ROW: integer
   DONE: integer
end

local module_name = "lsqlite3"
local sqlite = require(module_name) as LSQLite

local record SQLite is DatabaseProvider where self.__name == "sqlitedb"
   __name: string
   _db: Handle
end

local function check_code(db: Handle, code: integer)
   if code ~= sqlite.OK then error(db:errmsg(), 0) end
end

local function has_only_trivia(tail: string): boolean
   local index = 1
   while true do
      local first = tail:find("[^%s;]", index)
      if not first then return true end
      local prefix = tail:sub(first, first + 1)
      if prefix == "--" then
         index = (tail:find("\n", first + 2, true) or #tail) + 1
      elseif prefix == "/*" then
         local _, last = tail:find("*/", first + 2, true)
         if not last then return false end
         index = last + 1
      else
         return false
      end
   end
end

local function bind(db: Handle, stmt: Statement, params: database.Params)
   local count = stmt:bind_parameter_count()
   assert(#params == count, "SQLite parameter count does not match the statement")
   for index = 1, count do
      local value: database.Value | nil = params[index]
      assert(value ~= nil, "use database.NULL to bind SQL null")
      local native: NativeValue
      if value is database.Null then
         assert(value == database.NULL, "use database.NULL to bind SQL null")
      elseif value is boolean then
         native = value and 1 or 0
      else
         native = value
      end
      check_code(db, stmt:bind(index, native))
   end
end

local function with_statement<T>(db: Handle, sql: string, params: database.Params, run: function(Statement): T): T
   assert(not sql:find("%z"), "SQLite statement contains a NUL byte")
   local stmt, tail = db:prepare(sql)
   if not stmt then return error(db:errmsg(), 0) end
   assert(stmt:isopen(), "SQLite requires one statement")
   local ok, result = pcall(function(): T
      assert(tail is string and has_only_trivia(tail), "SQLite accepts one statement per call")
      bind(db, stmt, params)
      return run(stmt)
   end)
   local code = stmt:finalize()
   if not ok then error(result, 0) end
   check_code(db, code)
   return result as T
end

function SQLite:execute(sql: string, params: database.Params): integer
   local db = self._db
   return with_statement(db, sql, params, function(stmt: Statement): integer
      assert(stmt:columns() == 0, "use query for SQL that returns rows")
      local before = db:total_changes()
      if stmt:step() ~= sqlite.DONE then error(db:errmsg(), 0) end
      return db:total_changes() - before
   end)
end

function SQLite:query(sql: string, params: database.Params): {database.Row}
   local db = self._db
   return with_statement(db, sql, params, function(stmt: Statement): {database.Row}
      local columns = stmt:columns()
      assert(columns > 0, "use execute for SQL that returns no rows")
      local names = stmt:get_names()
      local seen: {string: boolean} = {}
      for _, name in ipairs(names) do
         assert(not seen[name], "duplicate SQLite result column " .. name)
         seen[name] = true
      end
      local rows: {database.Row} = {}
      while true do
         local code = stmt:step()
         if code == sqlite.DONE then return rows end
         if code ~= sqlite.ROW then error(db:errmsg(), 0) end
         local row: database.Row = {}
         for index, name in ipairs(names) do
            row[name] = stmt:get_value(index - 1) or database.NULL
         end
         table.insert(rows, row)
      end
   end)
end

function SQLite:begin()
   self:execute("BEGIN", {})
end

function SQLite:commit()
   self:execute("COMMIT", {})
end

function SQLite:rollback()
   self:execute("ROLLBACK", {})
end

function SQLite:close()
   check_code(self._db, self._db:close())
end

--- Open a SQLite connection.
--- @param filename Database path, or `":memory:"` for an in-memory database.
--- @return A connection that owns the SQLite handle.
function SQLiteAdapter.open(filename: string): database.Connection
   assert(not filename:find("%z"), "SQLite filename contains a NUL byte")
   local handle, _, message = sqlite.open(filename)
   local provider: SQLite = {
      __name = "sqlitedb",
      _db = assert(handle, message),
      execute = SQLite.execute,
      query = SQLite.query,
      begin = SQLite.begin,
      commit = SQLite.commit,
      rollback = SQLite.rollback,
      close = SQLite.close,
   }
   return database.connect(provider)
end

return SQLiteAdapter
