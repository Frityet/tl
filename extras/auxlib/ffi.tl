--#pragma strict_nil on

local ffi = require("ffi")

--- Declare typed bindings to C libraries through LuaJIT FFI.
--- The macro converts C types to Teal types. The module registers the C
--- declarations with LuaJIT when it loads the library.
local record Bindings end

local registered: {string:string | nil} = {}
local next_namespace = 0

--- Load a library and attach its C symbols to a record.
--- @param namespace Record to receive the C symbols.
--- @param definition C declarations from the macro, with `$` marking private names.
--- @param names Library names to try in order.
function Bindings.bind<T>(namespace: T, definition: string, names: {string})
   local failures: {string} = {}
   for _, name in ipairs(names) do
      local ok, library = pcall(ffi.load, name)
      if ok then
         local prefix = registered[definition]
         if not prefix then
            -- LuaJIT shares declarations across libraries. Give each layout
            -- and signature its own lookup names.
            next_namespace = next_namespace + 1
            prefix = "tl_auxlib_ffi_" .. tostring(next_namespace) .. "_"
            ffi.cdef((definition:gsub("%$", prefix)))
            registered[definition] = prefix
         end
         local symbol_prefix = assert(prefix)
         local proxy: {string:any} = {
            __index = function(_: T, symbol: string): any
               return library[symbol_prefix .. symbol]
            end,
            __newindex = function(_: T, symbol: string, value: any)
               library[symbol_prefix .. symbol] = value
            end,
         }
         setmetatable(namespace, proxy as metatable<T>)
         return
      end
      table.insert(failures, name .. " (" .. tostring(library) .. ")")
   end
   error("ffi: could not load a library: " .. table.concat(failures, ", "), 2)
end

--- Copy a C character buffer into a Lua string.
--- @param value Pointer to readable characters.
--- @param length Number of bytes to copy. If nil, stop at the first NUL byte.
--- @return A Lua string with the copied bytes.
function Bindings.string(value: userdata, length?: integer): string
   if length then return ffi.string(value, length) end
   return ffi.string(value)
end

--- Define C structs and load a C library. Use one `CLib` record. List library
--- names in the order to try them. Use a nested `CStruct` record for each
--- C struct. Put C functions and exported variables in the outer record.
--- Use the field order and types from the C declarations. Give each function
--- a fixed parameter list.
---
--- ```teal
--- ffi!(
---    local record MyLib is CLib where lib == "mylib" or lib == "libmylib"
---       record SomeStruct is CStruct
---          a: int
---          str: ptr<const<char>>
---       end
---       my_func: function(int): SomeStruct
---    end
--- )
--- local result: MyLib.SomeStruct = MyLib.my_func(42)
--- print(result.a)
--- ```
---
--- Use `ptr<T>` for a pointer and `const<T>` for a const type. Use `CString`
--- for `ptr<const<char>>`. A pointer parameter accepts userdata or nil.
--- A CString parameter also accepts Lua strings. Pointer fields and return
--- values have type `userdata`.
--- @param declaration One local record marked `is CLib`.
--- @return A typed record with access to the C symbols.
macro Bindings.ffi!(declaration: Statement): Statement
   local B = BLOCK_INDEXES
   local R = B.RECORD
   local F = B.RECORD_FIELD

   if declaration.kind == "statements" then
      assert(#declaration == 1, "ffi: expected one local record")
      declaration = declaration[1]
   end
   local function unpack_record(statement, marker)
      assert(statement.kind == "local_type", "ffi: expected a record marked is " .. marker)
      local name = statement[B.LOCAL_TYPE.VAR]
      local value = statement[B.LOCAL_TYPE.VALUE]
      local def = value and value[B.NEWTYPE.TYPEDECL]
      local layout = def and def[B.TYPEDECL.TYPE]
      assert(layout and layout.kind == "record", "ffi: expected a record marked is " .. marker)
      local interfaces = layout[R.INTERFACES]
      assert(interfaces and #interfaces == 1 and
         interfaces[1][B.NOMINAL_TYPE.NAME].tk == marker and #interfaces[1] == 1,
         "ffi: expected " .. name.tk .. " to use is " .. marker)
      assert(not layout[R.ARRAY_TYPE] and not layout[R.META_FIELDS], "ffi: C records cannot have array or metamethod fields")
      layout[R.INTERFACES] = nil
      return name, layout
   end

   local name, library = unpack_record(declaration, "CLib")
   local where = assert(library[R.WHERE_CLAUSE], "ffi: expected where lib == \"library name\"")
   local names = `{}`
   local function add_names(condition)
      if condition.kind == "paren" then
         add_names(condition[B.PAREN.EXP])
         return
      end
      local left, right = condition[B.OP.E1], condition[B.OP.E2]
      if condition.kind == "op_or" then
         add_names(left)
         add_names(right)
         return
      end
      assert(condition.kind == "op_eq" and left.kind == "identifier" and left.tk == "lib" and right.kind == "string",
         "ffi: use where lib == \"name\", with or between fallback names")
      local item = (`{$right}`)[1]
      item[B.LITERAL_TABLE_ITEM.KEY].tk = tostring(#names + 1)
      table.insert(names, item)
   end
   add_names(where[B.MACROEXP.EXP])
   library[R.WHERE_CLAUSE] = nil

   local function c_identifier(node)
      assert(node.tk:match("^[A-Za-z_][A-Za-z_0-9]*$"), "ffi: invalid C name " .. node.tk)
      return node.tk
   end

   local structs, order, definitions = {}, {}, {}
   for _, field in ipairs(library[R.FIELDS]) do
      if field.kind == "local_type" then
         local key, layout = unpack_record(field, "CStruct")
         local struct = c_identifier(key)
         assert(not structs[struct], "ffi: duplicate C struct " .. struct)
         assert(not layout[R.WHERE_CLAUSE], "ffi: a CStruct cannot have a where clause")
         local tag = "struct $" .. struct
         structs[struct] = { layout = layout, tag = tag }
         table.insert(order, struct)
         table.insert(definitions, tag .. ";")
         table.insert(layout, block("userdata"))
      end
   end

   local scalars = {
      char = {"char", "integer"}, schar = {"signed char", "integer"}, uchar = {"unsigned char", "integer"},
      short = {"short", "integer"}, ushort = {"unsigned short", "integer"},
      int = {"int", "integer"}, uint = {"unsigned int", "integer"},
      long = {"long", "integer | userdata"}, ulong = {"unsigned long", "integer | userdata"},
      longlong = {"long long", "userdata"}, ulonglong = {"unsigned long long", "userdata"},
      int8_t = {"int8_t", "integer"}, uint8_t = {"uint8_t", "integer"},
      int16_t = {"int16_t", "integer"}, uint16_t = {"uint16_t", "integer"},
      int32_t = {"int32_t", "integer"}, uint32_t = {"uint32_t", "integer"},
      int64_t = {"int64_t", "userdata"}, uint64_t = {"uint64_t", "userdata"},
      size_t = {"size_t", "integer | userdata"}, ptrdiff_t = {"ptrdiff_t", "integer | userdata"},
      float = {"float", "number"}, double = {"double", "number"}, bool = {"_Bool", "boolean"},
   }
   local function type_node(text)
      return parse_expression("nil as " .. text)[B.OP.E2]
   end

   local function pointer_type(parameter, is_string)
      if not parameter then return type_node("userdata") end
      return type_node(is_string and "string | userdata | nil" or "userdata | nil")
   end

   -- Return the C spelling, Teal type and any struct needed by value.
   local function convert(typ, allow_void, parameter)
      assert(typ and typ.kind == "nominal_type", "ffi: expected a C type name")
      local key = typ[B.NOMINAL_TYPE.NAME].tk
      if key == "ptr" or key == "const" then
         local args = typ[2]
         assert(#typ == 2 and args.kind ~= "identifier" and #args == 1,
            "ffi: " .. key .. " expects one C type")
         local inner = args[1]
         local c, tl, dependency = convert(inner, key == "ptr" or allow_void, parameter)
         if key == "const" then return c .. " const", tl, dependency end
         return c .. " *", pointer_type(parameter, c == "char const")
      end
      assert(#typ == 1, "ffi: expected a bare C type name")
      if key == "void" then
         assert(allow_void, "ffi: void is only valid as a pointer target or return type")
         return "void"
      elseif key == "CString" then
         return "char const *", pointer_type(parameter, true)
      elseif scalars[key] then
         local tl = scalars[key][2]
         return scalars[key][1], type_node(parameter and tl == "userdata" and "integer | userdata" or tl)
      elseif structs[key] then
         return structs[key].tag, clone(typ), key
      end
      error("ffi: unknown C type " .. key)
   end

   local state = {}
   local function emit_struct(key)
      if state[key] == "done" then return end
      assert(not state[key], "ffi: cyclic by-value struct dependency at " .. key)
      state[key] = "visiting"
      local struct = structs[key]
      local result = {}
      local seen = {}
      for _, field in ipairs(struct.layout[R.FIELDS]) do
         if field.kind ~= "comment" then
            assert(field.kind == "record_field", "ffi: CStruct only accepts data fields")
            local member = c_identifier(field[F.NAME])
            assert(not seen[member], "ffi: duplicate struct field " .. member)
            seen[member] = true
            local c, tl, dependency = convert(field[F.TYPE])
            if dependency then emit_struct(dependency) end
            table.insert(result, "   " .. c .. " " .. member .. ";")
            field[F.TYPE] = tl
         end
      end
      assert(#result > 0, "ffi: CStruct " .. key .. " needs at least one field")
      table.insert(definitions, struct.tag .. " {\n" .. table.concat(result, "\n") .. "\n};")
      state[key] = "done"
   end
   for _, key in ipairs(order) do emit_struct(key) end

   local seen = {}
   for _, field in ipairs(library[R.FIELDS]) do
      if field.kind == "record_field" then
         local symbol = c_identifier(field[F.NAME])
         -- Resolve the actual exported name through an assembler label.
         local exported = ' __asm__("' .. symbol .. '");'
         assert(not seen[symbol] and not structs[symbol], "ffi: duplicate library member " .. symbol)
         seen[symbol] = true
         local typ = field[F.TYPE]
         if typ.kind == "function" then
            assert(not typ[B.FUNCTION_TYPE.MACROEXP], "ffi: C functions cannot have a macro expression")
            local args = typ[B.FUNCTION_TYPE.ARGS][1]
            local args_c = {}
            for _, arg in ipairs(args) do
               local A = B.ARGUMENT_TYPE
               assert(not arg[A.VARARG] and not arg[A.OPTIONAL], "ffi: C functions need fixed, required parameters")
               local c, tl = convert(arg[A.TYPE], false, true)
               arg[A.TYPE] = tl
               table.insert(args_c, c)
            end
            local result = typ[B.FUNCTION_TYPE.RETS][1]
            assert(#result <= 1, "ffi: C functions return at most one value")
            local c_result = "void"
            if result[1] then
               local c, tl = convert(result[1], true)
               c_result, result[1] = c, tl
            end
            table.insert(definitions, c_result .. " $" .. symbol .. "(" ..
               (#args_c == 0 and "void" or table.concat(args_c, ", ")) .. ")" .. exported)
         else
            local c, tl = convert(typ)
            field[F.TYPE] = tl
            table.insert(definitions, "extern " .. c .. " $" .. symbol .. exported)
         end
      else
         assert(field.kind == "local_type" or field.kind == "comment", "ffi: unsupported CLib member")
      end
   end
   assert(#definitions > 0, "ffi: no C declarations")

   local cdef = block("string")
   cdef.tk = string.format("%q", table.concat(definitions, "\n"))
   local out = block("statements")
   table.insert(out, declaration)
   table.insert(out, `require("auxlib.ffi").bind($name, $cdef, $names)`)
   return out
end

return Bindings
