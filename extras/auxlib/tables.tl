--#pragma strict_nil on
local record Tables end

--- Pipe a value into the first argument of a function or call.
--- For example, `value |> transform(extra)` calls `transform(value, extra)`.
--- @param value Expression to insert as the first argument; evaluated once.
--- @param target Function expression or call receiving the piped value.
--- @return The target call result.
macro Tables.(|>)!(value: Expression, target: Expression): Operator<infix, shift>
   if target.kind == "op_funcall" then
      local call = clone(target)
      table.insert(call[BLOCK_INDEXES.OP.E2], 1, clone(value))
      return call
   end
   return `($target)($value)`
end

--- Map an array to a new array in index order without changing the source.
--- The callback receives `(value, idx)` and returns one mapped value. Indices are
--- one-based. Input arrays are dense sequences traversed with ipairs.
--- @typearg TFrom Input element type.
--- @typearg TTo Output element type.
--- @param source Input array `{TFrom}`.
--- @param transform Function `(value: TFrom, idx: integer): TTo`, called once per element.
--- @return A new `{TTo}` with mapped values at the original indices; empty input gives an empty array.
function Tables.map<TFrom, TTo>(source: {TFrom}, transform: function(TFrom, integer): TTo): {TTo}
   local output: {TTo} = {}
   for idx, value in ipairs(source) do
      output[idx] = transform(value, idx)
   end
   return output
end

--- Sum numeric projections of table entries without modifying the source.
--- @param source Table to traverse with pairs; iteration order is unspecified.
--- @param project Function `(key, value): number` evaluated once per entry.
--- @return The total projection, or zero for an empty table.
function Tables.sum<K, V>(source: {K:V}, project: function(K, V): number): number
   local total: number = 0
   for key, value in pairs(source) do
      total = total + project(key, value)
   end
   return total
end

--- Fold table entries into an explicitly typed initial accumulator.
--- Traversal uses pairs, so reduction order is unspecified.
--- @param source Table to traverse without changing it.
--- @param accumulator Initial accumulator value.
--- @param step Function `(accumulator, key, value)` returning the next accumulator.
--- @return The final accumulator, or the initial value for an empty table.
function Tables.reduce<K, V, U>(source: {K:V}, accumulator: U, step: function(U, K, V): U): U
   for key, value in pairs(source) do
      accumulator = step(accumulator, key, value)
   end
   return accumulator
end

--- Copy matching entries into a new table without changing the source.
--- @param source Table to filter. Original keys are preserved, so array results may have gaps.
--- @param predicate Function `(key, value): boolean` deciding which entries to retain.
--- @return A new table containing matching entries under their original keys.
function Tables.filter<K, V>(source: {K:V}, predicate: function(K, V): boolean): {K:V}
   local output: {K:V} = {}
   for key, value in pairs(source) do
      if predicate(key, value) then output[key] = value end
   end
   return output
end

--- Test whether any entry matches, stopping at the first match.
--- @param source Table to traverse with pairs.
--- @param predicate Function `(key, value): boolean` deciding whether an entry matches.
--- @return True if any entry matches; false for an empty table.
function Tables.any<K, V>(source: {K:V}, predicate: function(K, V): boolean): boolean
   for key, value in pairs(source) do
      if predicate(key, value) then return true end
   end
   return false
end

--- Test whether every entry matches, stopping at the first failure.
--- @param source Table to traverse with pairs.
--- @param predicate Function `(key, value): boolean` deciding whether an entry matches.
--- @return True if every entry matches, including an empty table; otherwise false.
function Tables.all<K, V>(source: {K:V}, predicate: function(K, V): boolean): boolean
   for key, value in pairs(source) do
      if not predicate(key, value) then return false end
   end
   return true
end

--- Find the first matching value in pairs traversal order.
--- The result is explicitly nullable; test for nil rather than truthiness when V can be boolean.
--- @param source Table to search without changing it. Iteration order is unspecified.
--- @param predicate Function `(key, value): boolean` deciding which value to return.
--- @return A matching value of type `V`, or nil when no entry matches.
function Tables.find<K, V>(source: {K:V}, predicate: function(K, V): boolean): V | nil
   for key, value in pairs(source) do
      if predicate(key, value) then return value end
   end
   return nil
end

--- Group entries while retaining each original key inside its group.
--- @param source Table to group without changing it.
--- @param select_group Function `(key, value)` returning the group key.
--- @return A new table of groups, each containing the original keys and values.
function Tables.group_by<K, V, G>(source: {K:V}, select_group: function(K, V): G): {G:{K:V}}
   local groups: {G:{K:V}} = {}
   for key, value in pairs(source) do
      local group_key = select_group(key, value)
      local group: {K:V} | nil = groups[group_key]
      if not group then
         group = {}
         groups[group_key] = group
      end
      group[key] = value
   end
   return groups
end

--- Collect table keys into a new array.
--- @param source Table whose keys are collected without modifying it.
--- @return An array of keys in unspecified pairs traversal order.
function Tables.keys<K, V>(source: {K:V}): {K}
   local output: {K} = {}
   for key in pairs(source) do
      output[#output + 1] = key
   end
   return output
end

--- Collect table values into a new array.
--- @param source Table whose values are collected without modifying it.
--- @return An array of values in unspecified pairs traversal order.
function Tables.values<K, V>(source: {K:V}): {V}
   local output: {V} = {}
   for _, value in pairs(source) do
      output[#output + 1] = value
   end
   return output
end

--- Inspect a value once and return it for the next stage of a pipeline.
--- @param value Value to inspect.
--- @param inspect Callback receiving the value once; its return value is ignored.
--- @return The original value, preserving its type.
function Tables.tap<T>(value: T, inspect: function(T)): T
   inspect(value)
   return value
end

--- Map an array `{TFrom}` to a new array `{TTo}` in index order.
---
--- ```teal
--- local tables = require("auxlib.tables")
--- local macro (||>)! = tables.(||>)!
--- local values: {integer} = {3, 5}
--- local labels: {string} = values ||> |value, idx| -> tostring(idx) .. ":" .. tostring(value)
--- -- labels is {"1:3", "2:5"}
--- ```
---
--- The source and callback expressions are each evaluated once. The callback is
--- called once per element with `(value, idx)`, where idx is one-based, and returns
--- one mapped value. Input arrays are dense sequences traversed with ipairs.
--- @param source Input array `{TFrom}`; dictionaries are not supported.
--- @param transform Function `(value: TFrom, idx: integer): TTo`.
--- @return A new `{TTo}` containing the mapped values at their original indices.
macro Tables.(||>)!(source: Expression, transform: Expression): Operator<infix, shift>
   return `require("auxlib.tables").map($source, $transform)`
end

--- Sum projected entries, or reduce a table from an initial accumulator.
---
--- ```teal
--- local tables = require("auxlib.tables")
--- local macro (+=>)! = tables.(+=>)!
--- local scores: {string:integer} = {red = 4, blue = 6}
--- local total = scores +=> |_, value| -> value -- 10
--- local product = scores +=> {1, |acc, _, value| -> acc * value} -- 24
--- ```
---
--- A sum callback receives `(key, value)` and returns a number; an empty table
--- sums to zero. With `{initial, reducer}`, the reducer receives
--- `(accumulator, key, value)` and returns the next accumulator; an empty table
--- returns `initial`. Traversal uses `pairs`, so iteration order is unspecified.
--- @param source Table to traverse without modifying it.
--- @param reduction Sum callback, or `{initial, reducer}` for a general reduction.
--- @return The numeric sum, or the final accumulator.
macro Tables.(+=>)!(source: Expression, reduction: Expression): Operator<infix, shift>
   if reduction.kind == "literal_table" then
      local item = BLOCK_INDEXES.LITERAL_TABLE_ITEM
      local message = "+=> expects a sum callback or { initial, reducer }"
      assert(#reduction == 2, message)
      for _, entry in ipairs(reduction) do
         assert(entry.implicit_table_key, message)
      end
      local initial, reducer = reduction[1][item.VALUE], reduction[2][item.VALUE]
      return `require("auxlib.tables").reduce($source, $initial, $reducer)`
   end
   return `require("auxlib.tables").sum($source, $reduction)`
end

--- Filter a table while preserving the original keys and values.
---
--- ```teal
--- local tables = require("auxlib.tables")
--- local macro (?>)! = tables.(?>)!
--- local scores: {string:integer} = {red = 4, blue = 6}
--- local selected = scores ?> |_, value| -> value >= 5 -- {blue = 6}
--- ```
---
--- The predicate receives `(key, value)` for each entry. Entries with a true
--- result are copied to a new table; the source is unchanged. Array keys are
--- preserved rather than compacted, so filtering an array can leave gaps.
--- @param source Table to filter.
--- @param predicate Function `(key, value): boolean` deciding which entries to keep.
--- @return A new table containing the matching entries under their original keys.
macro Tables.(?>)!(source: Expression, predicate: Expression): Operator<infix, shift>
   return `require("auxlib.tables").filter($source, $predicate)`
end

--- Import named module fields, optionally renaming them with `as`.
--- Activate both import and from from auxlib.tables, then write
--- `import { function_name as alias } from some.module`.
--- @param fields Nonempty field selection, with optional `as` aliases.
--- @return A selection consumed by the from operator to declare local bindings.
macro Tables.(import)!(fields: Expression): Operator<prefix, unary>
   -- Tag an ordinary call block for the from operator to consume.
   local selection = `__tl_import_fields($fields)`
   selection.tk = "__tl_import_fields"
   return selection
end

--- Bind named fields from a source expression, evaluating it once.
--- For example, `{ name, count } from row` declares local bindings. This also
--- completes an import whose module name is dotted or quoted.
--- @param fields Nonempty field selection, or an import selection with optional aliases.
--- @param source Table expression, or module name for an import.
--- @return Statements declaring the selected local bindings.
macro Tables.(from)!(fields: Expression, source: Expression): Operator<infix, conditional>
   local B = BLOCK_INDEXES
   while fields.kind == "paren" do fields = fields[B.PAREN.EXP] end
   local importing = fields.kind == "op_funcall" and fields.tk == "__tl_import_fields"
   if importing then
      fields = fields[B.OP.E2][1]
      local function module_path(part)
         if part.kind == "identifier" then return part.tk end
         assert(part.kind == "op_dot" and not part.safe_navigation and part[B.OP.E2].kind == "identifier",
            "import expects a dotted module name or a string literal")
         return module_path(part[B.OP.E1]) .. "." .. part[B.OP.E2].tk
      end
      local module_name = source
      if source.kind ~= "string" then
         module_name = block("string")
         module_name.tk = string.format("%q", module_path(source))
      end
      source = `require($module_name)`
   end
   local operation = importing and "import" or "from"
   assert(fields.kind == "literal_table" and #fields > 0, operation .. " expects a nonempty list of field names in braces")

   -- Keep the source temporary inside an initializer so it cannot shadow a
   -- local in the surrounding scope. Evaluate the source before reading keys.
   local statements = ```
      local __from_value = (|| -> do
         local __from_source = $source
         return
      end)()
   ```
   local declaration = statements[1]
   local names = declaration[B.LOCAL_DECLARATION.VARS]
   local call = declaration[B.LOCAL_DECLARATION.EXPS][1]
   local initializer = call[B.OP.E1][B.PAREN.EXP]
   local result = initializer[B.FUNCTION.BODY][2][B.RETURN.EXPS]

   local seen = {}
   for i, item in ipairs(fields) do
      local field = item[B.LITERAL_TABLE_ITEM.VALUE]
      local name = field
      if importing and field.kind == "op_as" then
         local alias = field[B.OP.E2]
         field = field[B.OP.E1]
         if alias.kind == "map_type" and alias.tk == "table" then
            name = block("identifier")
            name.tk = alias.tk
         else
            assert(alias.kind == "nominal_type" and #alias == 1, "import alias must be a bare name")
            name = alias[B.NOMINAL_TYPE.NAME]
         end
      end
      assert(field.kind == "identifier" and item.implicit_table_key,
         importing and "import expects bare field names with optional 'as' aliases" or "from expects bare field names")
      assert(not seen[name.tk], operation .. " has duplicate binding '" .. name.tk .. "'")
      seen[name.tk] = true
      names[i] = clone(name)
      result[i] = `__from_source.$field`
   end
   return statements
end

return Tables
