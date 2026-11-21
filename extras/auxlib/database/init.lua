





local Database = { Null = {}, Connection = {} }













































Database.NULL = {}

local function open_provider(connection)
   assert(not connection._closed, "database connection is closed")
   assert(not connection._broken, "database connection is unusable after a rollback failure")
   local owner = connection._transaction_owner
   local running = coroutine.running() or false
   assert(owner == nil or owner == running, "database connection is in use by another transaction")
   return connection._provider
end





function Database.Connection:execute(sql, params)
   return open_provider(self):execute(sql, params or {})
end





function Database.Connection:query(sql, params)
   return open_provider(self):query(sql, params or {})
end





function Database.Connection:one(sql, params)
   local rows = self:query(sql, params)
   assert(#rows <= 1, "database query returned more than one row")
   return rows[1]
end






function Database.Connection:scalar(sql, column, params)
   local row = self:one(sql, params)
   if not row then return nil end
   local value = row[column]
   assert(value ~= nil, "database query has no result column " .. column)
   return value
end







function Database.Connection:transaction(body)
   local provider = open_provider(self)
   assert(self._transaction_owner == nil, "database transactions cannot be nested")
   provider:begin()

   self._transaction_owner = coroutine.running() or false
   local ok, result = pcall(function()
      local value = body(self)
      provider:commit()
      return value
   end)
   if not ok then
      local rolled_back, rollback_error = pcall(function()
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
   return result
end



function Database.Connection:close()
   if self._closed then return end
   assert(self._transaction_owner == nil, "cannot close a database connection during a transaction")
   self._provider:close()
   self._closed = true
end




function Database.connect(provider)
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





function Database.quote_identifier(name)
   assert(name ~= "" and not name:find("%z"), "invalid SQL identifier")
   return '"' .. name:gsub('"', '""') .. '"'
end




function Database.placeholders(count)
   assert(count >= 1 and count % 1 == 0, "placeholder count must be a positive integer")
   local slots = {}
   for index = 1, count do slots[index] = "?" end
   return table.concat(slots, ", ")
end

return Database
