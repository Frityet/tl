--#pragma strict_nil on
local record Utilities end

macro Utilities.(|>)!(value: Expression, target: Expression): Operator<infix, shift>
   if target.kind == "op_funcall" then
      local call = clone(target)
      table.insert(call[BLOCK_INDEXES.OP.E2], 1, clone(value))
      return call
   end
   return `($target)($value)`
end

function Utilities.map<K, V, UK, UV>(source: {K:V}, transform: function(K, V): (UK, UV)): {UK:UV}
   local output: {UK:UV} = {}
   for key, value in pairs(source) do
      local mapped_key, mapped_value = transform(key, value)
      output[mapped_key] = mapped_value
   end
   return output
end

function Utilities.sum<K, V>(source: {K:V}, project: function(K, V): number): number
   local total: number = 0
   for key, value in pairs(source) do
      total = total + project(key, value)
   end
   return total
end

function Utilities.reduce<K, V, U>(source: {K:V}, accumulator: U, step: function(U, K, V): U): U
   for key, value in pairs(source) do
      accumulator = step(accumulator, key, value)
   end
   return accumulator
end

function Utilities.filter<K, V>(source: {K:V}, predicate: function(K, V): boolean): {K:V}
   local output: {K:V} = {}
   for key, value in pairs(source) do
      if predicate(key, value) then output[key] = value end
   end
   return output
end

function Utilities.any<K, V>(source: {K:V}, predicate: function(K, V): boolean): boolean
   for key, value in pairs(source) do
      if predicate(key, value) then return true end
   end
   return false
end

function Utilities.all<K, V>(source: {K:V}, predicate: function(K, V): boolean): boolean
   for key, value in pairs(source) do
      if not predicate(key, value) then return false end
   end
   return true
end

function Utilities.find<K, V>(source: {K:V}, predicate: function(K, V): boolean): V | nil
   for key, value in pairs(source) do
      if predicate(key, value) then return value end
   end
   return nil
end

function Utilities.group_by<K, V, G>(source: {K:V}, select_group: function(K, V): G): {G:{K:V}}
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

function Utilities.keys<K, V>(source: {K:V}): {K}
   local output: {K} = {}
   for key in pairs(source) do
      output[#output + 1] = key
   end
   return output
end

function Utilities.values<K, V>(source: {K:V}): {V}
   local output: {V} = {}
   for _, value in pairs(source) do
      output[#output + 1] = value
   end
   return output
end

function Utilities.tap<T>(value: T, inspect: function(T)): T
   inspect(value)
   return value
end

macro Utilities.(||>)!(source: Expression, transform: Expression): Operator<infix, shift>
   return `require("extra.macros.utilities").map($source, $transform)`
end

macro Utilities.(+=>)!(source: Expression, reduction: Expression): Operator<infix, shift>
   if reduction.kind == "literal_table" then
      local item = BLOCK_INDEXES.LITERAL_TABLE_ITEM
      local message = "+=> expects a sum callback or { initial, reducer }"
      assert(#reduction == 2, message)
      for _, entry in ipairs(reduction) do
         local key = entry[item.KEY]
         assert(key.kind == "integer" and key.x == entry.x and key.y == entry.y, message)
      end
      local initial, reducer = reduction[1][item.VALUE], reduction[2][item.VALUE]
      return `require("extra.macros.utilities").reduce($source, $initial, $reducer)`
   end
   return `require("extra.macros.utilities").sum($source, $reduction)`
end

macro Utilities.(?>)!(source: Expression, predicate: Expression): Operator<infix, shift>
   return `require("extra.macros.utilities").filter($source, $predicate)`
end

macro Utilities.(import)!(fields: Expression): Operator<prefix, unary>
   error("import expects { fields } from a module name", 0)
end

macro Utilities.(from)!(fields: Expression, source: Expression): Operator<infix, conditional>
   local B = BLOCK_INDEXES
   local importing = fields.kind == "macro_invocation" and fields.operator_use and fields.tk == "import"
   if importing then
      fields = fields[B.MACRO_INVOCATION.ARGS][1]
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
      local key = item[B.LITERAL_TABLE_ITEM.KEY]
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
      -- Implicit array keys share their source position with the value.
      assert(field.kind == "identifier" and key.kind == "integer" and key.x == field.x and key.y == field.y,
         importing and "import expects bare field names with optional 'as' aliases" or "from expects bare field names")
      assert(not seen[name.tk], operation .. " has duplicate binding '" .. name.tk .. "'")
      seen[name.tk] = true
      names[i] = clone(name)
      result[i] = `__from_source.$field`
   end
   return statements
end

return Utilities
