--#pragma strict_nil on

--- Process tables and arrays. Use operators to pass values and bind fields.
--- Array operations read dense sequences with indices that start at 1.
--- Operations that use `pairs` have no specified order.
local record Tables end

--- Pass a value as the first argument of a call.
--- `value |> transform(extra)` calls `transform(value, extra)`.
--- `value |> (factory())` calls the function that `factory()` returns.
--- A chain of pipes runs from left to right. Pipes bind more tightly than
--- comparisons.
--- @param value Expression to evaluate once and pass to the call.
--- @param target Function or call that receives the value.
--- @return The result of the call.
macro Tables.(|>)!(value: Expression, target: Expression): Operator<infix, shift>
   if target.kind == "op_funcall" then
      local call = clone(target)
      table.insert(call[BLOCK_INDEXES.OP.E2], 1, clone(value))
      return call
   end
   return `($target)($value)`
end

--- Map the array in index order.
--- @param source Dense input array.
--- @param transform Function that receives `(value, index)` and returns the new value.
--- @return A new array with each result at its input index.
function Tables.map<TFrom, TTo>(source: {TFrom}, transform: function(TFrom, integer): TTo): {TTo}
   local output: {TTo} = {}
   for idx, value in ipairs(source) do
      output[idx] = transform(value, idx)
   end
   return output
end

--- Add the numbers that a function calculates for the entries in a table.
--- @param source Table to read with `pairs`.
--- @param project Function that receives `(value, key)` and returns a number.
--- @return The sum, or zero for an empty table.
function Tables.sum<K, V>(source: {K:V}, project: function(V, K): number): number
   local total: number = 0
   for key, value in pairs(source) do
      total = total + project(value, key)
   end
   return total
end

--- Update an accumulator once for each entry in a table.
--- @param source Table to read with `pairs`.
--- @param accumulator Initial value.
--- @param step Function that receives `(accumulator, value, key)` and returns the next value.
--- @return The final accumulator, or the initial value for an empty table.
function Tables.reduce<K, V, U>(source: {K:V}, accumulator: U, step: function(U, V, K): U): U
   for key, value in pairs(source) do
      accumulator = step(accumulator, value, key)
   end
   return accumulator
end

--- Copy the entries that pass a test. Keep their keys. An array result can have gaps.
--- @param source Table to read with `pairs`.
--- @param predicate Function that receives `(value, key)` and returns true to keep the entry.
--- @return A new table with the matching entries.
function Tables.filter<K, V>(source: {K:V}, predicate: function(V, K): boolean): {K:V}
   local output: {K:V} = {}
   for key, value in pairs(source) do
      if predicate(value, key) then output[key] = value end
   end
   return output
end

--- Test entries until one matches.
--- @param source Table to read with `pairs`.
--- @param predicate Function that receives `(value, key)` and returns true for a match.
--- @return True if an entry matches. Return false for an empty table.
function Tables.any<K, V>(source: {K:V}, predicate: function(V, K): boolean): boolean
   for key, value in pairs(source) do
      if predicate(value, key) then return true end
   end
   return false
end

--- Test entries until one fails to match.
--- @param source Table to read with `pairs`.
--- @param predicate Function that receives `(value, key)` and returns true for a match.
--- @return True if all entries match or the table is empty.
function Tables.all<K, V>(source: {K:V}, predicate: function(V, K): boolean): boolean
   for key, value in pairs(source) do
      if not predicate(value, key) then return false end
   end
   return true
end

--- Find the first matching entry in `pairs` order.
--- Test for nil if a matching value can be false.
--- @param source Table to search.
--- @param predicate Function that receives `(value, key)` and returns true for a match.
--- @return The matching value, or nil if no entry matches.
function Tables.find<K, V>(source: {K:V}, predicate: function(V, K): boolean): V | nil
   for key, value in pairs(source) do
      if predicate(value, key) then return value end
   end
   return nil
end

--- Group entries by the key that a function gives each entry.
--- @param source Table to read with `pairs`.
--- @param select_group Function that receives `(value, key)` and returns a group key.
--- @return A table of groups. Each group keeps the original keys and values.
function Tables.group_by<K, V, G>(source: {K:V}, select_group: function(V, K): G): {G:{K:V}}
   local groups: {G:{K:V}} = {}
   for key, value in pairs(source) do
      local group_key = select_group(value, key)
      local group: {K:V} | nil = groups[group_key]
      if not group then
         group = {}
         groups[group_key] = group
      end
      group[key] = value
   end
   return groups
end

--- Collect the keys of a table.
--- @param source Table to read with `pairs`.
--- @return A new array of keys in `pairs` order.
function Tables.keys<K, V>(source: {K:V}): {K}
   local output: {K} = {}
   for key in pairs(source) do
      output[#output + 1] = key
   end
   return output
end

--- Collect the values of a table.
--- @param source Table to read with `pairs`.
--- @return A new array of values in `pairs` order.
function Tables.values<K, V>(source: {K:V}): {V}
   local output: {V} = {}
   for _, value in pairs(source) do
      output[#output + 1] = value
   end
   return output
end

--- Call a function with a value, then pass the value on.
--- `21 |> tables.tap(print)` prints 21 and returns 21.
--- @param value Value to pass to the function.
--- @param inspect Function that receives the value once.
--- @return The input value.
function Tables.tap<T>(value: T, inspect: function(T)): T
   inspect(value)
   return value
end

--- Map an array in index order.
---
--- ```teal
--- local values: {integer} = {3, 5}
--- local labels = values ||> |value, index| -> tostring(index) .. ":" .. tostring(value)
--- -- labels is {"1:3", "2:5"}
--- ```
---
--- The generated code evaluates each operand once.
--- @param source Dense input array.
--- @param transform Function that receives `(value, index)` and returns the new value.
--- @return A new array with each result at its input index.
macro Tables.(||>)!(source: Expression, transform: Expression): Operator<infix, shift>
   return `require("auxlib.tables").map($source, $transform)`
end

--- Sum projected entries or update an accumulator for each entry.
---
--- ```teal
--- local scores: {string:integer} = { red = 4, blue = 6 }
--- local total = scores +=> |value, _| -> value -- 10
--- local product = scores +=> { 1, |acc, value, _| -> acc * value } -- 24
--- ```
---
--- A sum function receives `(value, key)` and returns a number. A reducer
--- receives `(accumulator, value, key)` and returns the next accumulator.
--- @param source Table to read with `pairs`.
--- @param reduction Sum function, or `{ initial, reducer }`.
--- @return The sum or the final accumulator. For an empty table, return zero or the initial value.
macro Tables.(+=>)!(source: Expression, reduction: Expression): Operator<infix, shift>
   if reduction.kind == "literal_table" then
      local item = BLOCK_INDEXES.LITERAL_TABLE_ITEM
      local message = "+=> expects a sum callback or { initial, reducer }"
      assert(#reduction == 2, message)
      for _, entry in ipairs(reduction) do
         assert(entry[item.IMPLICIT_KEY], message)
      end
      local initial, reducer = reduction[1][item.VALUE], reduction[2][item.VALUE]
      return `require("auxlib.tables").reduce($source, $initial, $reducer)`
   end
   return `require("auxlib.tables").sum($source, $reduction)`
end

--- Filter a table and keep the keys of the matching entries.
---
--- ```teal
--- local scores: {string:integer} = { red = 4, blue = 6 }
--- local selected = scores ?> |value, _| -> value >= 5 -- { blue = 6 }
--- ```
---
--- @param source Table to read with `pairs`.
--- @param predicate Function that receives `(value, key)` and returns true to keep the entry.
--- @return A new table with the matching entries. An array result can have gaps.
macro Tables.(?>)!(source: Expression, predicate: Expression): Operator<infix, shift>
   return `require("auxlib.tables").filter($source, $predicate)`
end

--- Bind fields to const locals. Evaluate the source once. Read the fields
--- in the order in the list. Use `as` to change the name of a local.
---
--- ```teal
--- local row = { width = 3, height = 4 };
--- { width as w, height } from row
--- print(w * height)
---
--- { some_function as fn, version } from require "module.name"
--- ```
---
--- Add `;` if the previous statement can take the opening brace as an argument.
--- @param fields One or more field names in braces, with optional aliases.
--- @param source Table expression.
--- @return Statements that declare the const locals.
macro Tables.(from)!(fields: Expression, source: Expression): Operator<infix, conditional>
   local B = BLOCK_INDEXES
   while fields.kind == "paren" do fields = fields[B.PAREN.EXP] end
   assert(fields.kind == "literal_table" and #fields > 0, "from expects a nonempty list of field names in braces")

   -- Keep the source temporary inside an initializer so it cannot shadow a
   -- local in the surrounding scope. Evaluate the source before reading keys.
   local statements = ```
      local __from_value <const> = (|| -> do
         local __from_source = $source
         return
      end)()
   ```
   local declaration = statements[1]
   local names = declaration[B.LOCAL_DECLARATION.VARS]
   local annotation = names[1][1]
   local call = declaration[B.LOCAL_DECLARATION.EXPS][1]
   local initializer = call[B.OP.E1][B.PAREN.EXP]
   local result = initializer[B.FUNCTION.BODY][2][B.RETURN.EXPS]

   local seen = {}
   for i, item in ipairs(fields) do
      local field = item[B.LITERAL_TABLE_ITEM.VALUE]
      local name = field
      if field.kind == "op_as" then
         local alias = field[B.OP.E2]
         field = field[B.OP.E1]
         -- The type parser represents the bare name `table` as a map type.
         if alias.kind == "map_type" and alias.tk == "table" then
            name = block("identifier")
            name.tk = alias.tk
         else
            assert(alias.kind == "nominal_type" and #alias == 1, "from alias must be a bare name")
            name = alias[B.NOMINAL_TYPE.NAME]
         end
      end
      assert(field.kind == "identifier" and item[B.LITERAL_TABLE_ITEM.IMPLICIT_KEY],
         "from expects bare field names with optional 'as' aliases")
      assert(not seen[name.tk], "from has duplicate binding '" .. name.tk .. "'")
      seen[name.tk] = true
      names[i] = clone(name)
      table.insert(names[i], clone(annotation))
      result[i] = `__from_source.$field`
   end
   return statements
end

return Tables
