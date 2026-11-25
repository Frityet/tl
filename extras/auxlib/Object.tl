--- Interface for a record with a string type tag.
local interface Object
   --- Name used by a concrete record's `where` clause.
   __name: string
end

--- Tag a record with its declared name and use the record as its own `__index`.
---
--- ```teal
--- local Object = require("auxlib.Object")
--- local macro object! = Object.object!
--- local record A<object!> end
--- assert(A.__name == "A" and A.__index == A)
--- ```
macro Object.object!(declaration: Statement)
   local B = BLOCK_INDEXES
   local statement = declaration[1]
   assert(#declaration == 1 and (statement.kind == "local_type" or statement.kind == "global_type"),
      "object!: expected one record declaration")
   local name = statement[B.LOCAL_TYPE.VAR]
   local value = statement[B.LOCAL_TYPE.VALUE]
   local definition = value and value[B.NEWTYPE.TYPEDECL]
   local record_type = definition and definition[B.TYPEDECL.TYPE]
   if record_type and record_type.kind == "generic_type" then record_type = record_type[B.GENERIC_TYPE.BASE] end
   assert(record_type and record_type.kind == "record", "object!: expected a record")
   assert(not record_type[B.RECORD.WHERE_CLAUSE], "object!: the record already has a where clause")

   local base = block("identifier")
   base.tk = "@auxlib_object_" .. name.tk
   local import = (```local type $base = require("auxlib.Object")```)[1]
   local interface = block("nominal_type")
   interface.tk = base.tk
   interface[B.NOMINAL_TYPE.NAME] = clone(base)
   local interfaces = record_type[B.RECORD.INTERFACES] or block("interface_list")
   table.insert(interfaces, interface)
   record_type[B.RECORD.INTERFACES] = interfaces

   local tag = block("string")
   tag.tk = string.format("%q", name.tk)
   local where = block("macroexp")
   where[B.MACROEXP.EXP] = `self.__name == $tag`
   record_type[B.RECORD.WHERE_CLAUSE] = where

   local fields = record_type[B.RECORD.FIELDS]
   local template = (```local record ObjectIndex
      __index: ObjectIndex | nil
   end```)[1]
   local template_type = template[B.LOCAL_TYPE.VALUE][B.NEWTYPE.TYPEDECL][B.TYPEDECL.TYPE]
   local index_field = template_type[B.RECORD.FIELDS][1]
   index_field[B.RECORD_FIELD.TYPE][1] = clone(interface)
   table.insert(fields, index_field)

   local result = ```
      $name.__name = $tag
      $name.__index = $name
   ```
   table.insert(result, 1, statement)
   table.insert(result, 1, import)
   return result
end

return Object
