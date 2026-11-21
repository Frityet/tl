local database = require('auxlib.database')
local tl = require('teal.api.v2')

local function fails_with(body, message)
   local ok, err = pcall(body)
   assert.is_false(ok)
   assert.matches(message, err, 1, true)
end

local function connect_fake(provider)
   local function unexpected() error('unexpected provider call', 0) end
   for _, name in ipairs({'execute', 'query', 'begin', 'commit', 'rollback', 'close'}) do
      provider[name] = provider[name] or unexpected
   end
   return database.connect(provider)
end

describe('auxlib database', function()
   it('accepts a typed provider with its own connection state', function()
      local source = [[
         local db = require("auxlib.database")
         local type Provider = db.DatabaseProvider
         local record Memory is Provider where self.__name == "memory"
            __name: string
            value: db.Value
         end

         function Memory:execute(_: string, params: db.Params): integer
            self.value = params[1]
            return 1
         end

         function Memory:query(_: string, _: db.Params): {db.Row}
            return {{value = self.value}}
         end

         function Memory:begin() end
         function Memory:commit() end
         function Memory:rollback() end
         function Memory:close() end

         local driver: Memory = {
            __name = "memory",
            value = db.NULL,
            execute = Memory.execute,
            query = Memory.query,
            begin = Memory.begin,
            commit = Memory.commit,
            rollback = Memory.rollback,
            close = Memory.close,
         }
         local connection = db.connect(driver)
         assert(connection:scalar("SELECT value", "value") == db.NULL)
         assert(connection:execute("UPDATE data SET value = ?", {false}) == 1)
         local value = connection:transaction(function(tx: db.Connection): db.Value | nil
            return tx:scalar("SELECT value", "value")
         end)
         connection:close()
         return value
      ]]
      local ast, syntax_errors = tl.parse(source, 'database-fixture.tl')
      assert.same({}, syntax_errors)
      local result = tl.check(ast, 'database-fixture.tl', {
         gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
      })
      assert.same({}, result.type_errors)
      local output, err = tl.generate(result.ast, '5.1')
      assert.is_nil(err)
      assert.is_false(assert((loadstring or load)(output), output)())
   end)

   it('requires all provider methods', function()
      fails_with(function() database.connect({}) end, 'database provider must implement')
   end)

   it('distinguishes a missing row, a missing column, and SQL null', function()
      local rows = {}
      local connection = connect_fake({
         query = function() return rows end,
         close = function() end,
      })
      assert.is_nil(connection:one('SELECT value'))
      assert.is_nil(connection:scalar('SELECT value', 'value'))
      rows = {{value = database.NULL}}
      assert.equals(database.NULL, connection:scalar('SELECT value', 'value'))
      fails_with(function() connection:scalar('SELECT value', 'unknown') end, 'no result column unknown')
      rows[2] = {value = 0}
      fails_with(function() connection:one('SELECT value') end, 'more than one row')
      connection:close()
   end)

   it('rolls back a failed commit and preserves the error', function()
      local order = {}
      local connection = connect_fake({
         begin = function() table.insert(order, 'begin') end,
         commit = function()
            table.insert(order, 'commit')
            error('commit failed', 0)
         end,
         rollback = function() table.insert(order, 'rollback') end,
         close = function() table.insert(order, 'close') end,
      })
      assert.has_error(function()
         connection:transaction(function() table.insert(order, 'body') end)
      end, 'commit failed')
      connection:close()
      connection:close()
      assert.same({'begin', 'body', 'commit', 'rollback', 'close'}, order)
   end)

   it('allows closing a connection whose rollback failed', function()
      local closed = false
      local connection = connect_fake({
         begin = function() end,
         rollback = function() error('rollback error', 0) end,
         close = function() closed = true end,
      })
      fails_with(function()
         connection:transaction(function() error('body error', 0) end)
      end, 'rollback failed (rollback error) after body error')
      fails_with(function() connection:query('SELECT 1') end, 'unusable after a rollback failure')
      connection:close()
      assert.is_true(closed)
   end)

   it('quotes identifiers and makes a positional placeholder list', function()
      assert.equals('"last""name"', database.quote_identifier('last"name'))
      assert.equals('"schema.table"', database.quote_identifier('schema.table'))
      assert.equals('?, ?, ?', database.placeholders(3))
      fails_with(function() database.quote_identifier('with\0nul') end, 'invalid SQL identifier')
      fails_with(function() database.placeholders(0) end, 'positive integer')
   end)
end)

describe('auxlib SQLite provider', function()
   local function open()
      if not pcall(require, 'lsqlite3') then
         pending('lsqlite3 is unavailable')
         return
      end
      local connection = require('auxlib.database.sqlite').open(':memory:')
      finally(function() connection:close() end)
      return connection
   end

   it('binds values and returns rows without losing nulls or quoted text', function()
      local connection = open()
      connection:execute('CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, active INTEGER)')
      local label = "O'Reilly"
      assert.equals(1, connection:execute('INSERT INTO items VALUES (?, ?, ?)', {1, label, false}))
      assert.equals(1, connection:execute('INSERT INTO items VALUES (?, ?, ?)', {2, database.NULL, true}))
      assert.equals(0, connection:execute('CREATE TABLE extra (id INTEGER)'))
      local query = 'SELECT label, active FROM items WHERE id IN (' .. database.placeholders(2) .. ') ORDER BY id'
      local rows = connection:query(query, {1, 2})
      assert.same({{label = label, active = 0}, {label = database.NULL, active = 1}}, rows)
      assert.equals(database.NULL, rows[2].label)
      assert.equals(label, connection:scalar('SELECT label FROM items WHERE id = ?; -- comment', 'label', {1}))
   end)

   it('commits successful work and rolls back errors', function()
      local connection = open()
      connection:execute('CREATE TABLE items (id INTEGER PRIMARY KEY)')
      local count = connection:transaction(function(tx)
         assert.equals(connection, tx)
         return tx:execute('INSERT INTO items VALUES (?)', {1})
      end)
      assert.equals(1, count)
      assert.has_error(function()
         connection:transaction(function(tx)
            tx:execute('INSERT INTO items VALUES (?)', {2})
            error('abort', 0)
         end)
      end, 'abort')
      assert.equals(1, connection:scalar('SELECT COUNT(*) AS count FROM items', 'count'))
      connection:close()
      fails_with(function() connection:query('SELECT 1') end, 'connection is closed')
   end)

   it('finalizes statements that fail and leaves the connection usable', function()
      local connection = open()
      fails_with(function() connection:query('SELECT ?') end, 'parameter count')
      fails_with(function() connection:query('SELECT 1; SELECT 2') end, 'one statement per call')
      fails_with(function() connection:query('SELECT 1 AS x, 2 AS x') end, 'duplicate SQLite result column')
      assert.equals(42, connection:scalar('SELECT 42 AS value', 'value'))
      connection:close()
   end)
end)
