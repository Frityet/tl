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
