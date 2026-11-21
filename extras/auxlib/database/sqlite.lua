

local database = require("auxlib.database")






local SQLiteAdapter = {}





























local module_name = "lsqlite3"
local sqlite = require(module_name)

local SQLite = {}




local function check_code(db, code)
   if code ~= sqlite.OK then error(db:errmsg(), 0) end
end

local function has_only_trivia(tail)
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

local function bind(db, stmt, params)
   local count = stmt:bind_parameter_count()
   assert(#params == count, "SQLite parameter count does not match the statement")
   for index = 1, count do
      local value = params[index]
      assert(value ~= nil, "use database.NULL to bind SQL null")
      local native
      if type(value) == "table" then
         assert(value == database.NULL, "use database.NULL to bind SQL null")
      elseif type(value) == "boolean" then
         native = value and 1 or 0
      else
         native = value
      end
      check_code(db, stmt:bind(index, native))
   end
end

local function with_statement(db, sql, params, run)
   assert(not sql:find("%z"), "SQLite statement contains a NUL byte")
   local stmt, tail = db:prepare(sql)
   if not stmt then return error(db:errmsg(), 0) end
   assert(stmt:isopen(), "SQLite requires one statement")
   local ok, result = pcall(function()
      assert(type(tail) == "string" and has_only_trivia(tail), "SQLite accepts one statement per call")
      bind(db, stmt, params)
      return run(stmt)
   end)
   local code = stmt:finalize()
   if not ok then error(result, 0) end
   check_code(db, code)
   return result
end

function SQLite:execute(sql, params)
   local db = self._db
   return with_statement(db, sql, params, function(stmt)
      assert(stmt:columns() == 0, "use query for SQL that returns rows")
      local before = db:total_changes()
      if stmt:step() ~= sqlite.DONE then error(db:errmsg(), 0) end
      return db:total_changes() - before
   end)
end

function SQLite:query(sql, params)
   local db = self._db
   return with_statement(db, sql, params, function(stmt)
      local columns = stmt:columns()
      assert(columns > 0, "use execute for SQL that returns no rows")
      local names = stmt:get_names()
      local seen = {}
      for _, name in ipairs(names) do
         assert(not seen[name], "duplicate SQLite result column " .. name)
         seen[name] = true
      end
      local rows = {}
      while true do
         local code = stmt:step()
         if code == sqlite.DONE then return rows end
         if code ~= sqlite.ROW then error(db:errmsg(), 0) end
         local row = {}
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




function SQLiteAdapter.open(filename)
   assert(not filename:find("%z"), "SQLite filename contains a NUL byte")
   local handle, _, message = sqlite.open(filename)
   local provider = {
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
