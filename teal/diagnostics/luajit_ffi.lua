local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table


local model = require("teal.diagnostics.model")





local function call(n)
   return model.call_args(model.unwrap(n))
end

local function path(s, n)
   n = model.unwrap(n)
   return n and s:path(n)
end

local function call_path(s, n)
   n = model.unwrap(n)
   if call(n) then return path(s, n.e1) end
end

local function literal(n)
   n = model.unwrap(n)
   if n and n.kind == "string" then return n.conststr end
end

local routes = {
   ["cdef-in-loop"] = { "ffi.cdef" },
   ["load-in-loop"] = { "ffi.load" },
   ["metatype-in-loop"] = { "ffi.metatype" },
   ["new-cdecl-in-loop"] = { "ffi.new" },
   ["vla-initializer-in-loop"] = { "ffi.new" },
   ["array-table-initializer-in-loop"] = { "ffi.new" },
   ["large-byte-array-initializer-in-loop"] = { "ffi.new" },
   ["callback-cast-in-loop"] = { "ffi.cast" },
   ["ctype-choice-in-loop"] = { "ffi.new", "ffi.cast", "ffi.istype", "ffi.sizeof", "ffi.alignof", "ffi.offsetof" },
   ["sizeof-variable-length-in-loop"] = { "ffi.sizeof" },
   ["int64-tonumber"] = { "tonumber" },
   ["string-in-loop"] = { "ffi.string" },
   ["gc-in-loop"] = { "ffi.gc" },
   ["typeof-in-loop"] = { "ffi.typeof" },
   ["anonymous-aggregate"] = { "ffi.new" },
   ["cdef-preprocessor"] = { "ffi.cdef" },
   ["cdef-volatile"] = { "ffi.cdef" },
   ["cdef-long-double"] = { "ffi.cdef" },
   ["negative-length"] = { "ffi.copy", "ffi.fill", "ffi.string" },
   ["copy-string-overread"] = { "ffi.copy" },
   ["copy-missing-length"] = { "ffi.copy" },
   ["temporary-array-pointer"] = { "ffi.cast" },
   ["temporary-array-initializer"] = { "ffi.new" },
   ["callback-vararg"] = { "ffi.cast" },
   ["unknown-abi"] = { "ffi.abi" },
   ["printf-integer-vararg"] = { "ffi.C.printf", "ffi.C.fprintf", "ffi.C.sprintf", "ffi.C.snprintf" },
}
local rules = {}
local loop_rules = {
   ["cdef-in-loop"] = true, ["load-in-loop"] = true,
   ["metatype-in-loop"] = true, ["new-cdecl-in-loop"] = true,
   ["typeof-in-loop"] = true, ["vla-initializer-in-loop"] = true,
   ["array-table-initializer-in-loop"] = true,
   ["large-byte-array-initializer-in-loop"] = true,
   ["callback-cast-in-loop"] = true, ["string-in-loop"] = true,
   ["gc-in-loop"] = true, ["ctype-choice-in-loop"] = true,
   ["sizeof-variable-length-in-loop"] = true,
}
local function add(id, severity, description,
   fn)
   local r = {
      id = "luajit-ffi/" .. id,
      severity = severity,
      description = description,
      kinds = { "op" },
      calls = routes[id],
      bindings = true,
      in_loop = loop_rules[id],
      c_symbols = id == "implicit-callback",
      check = function(s, n, _t, _children)
         fn(s, n, n.e2)
      end,
   }
   table.insert(rules, r)
end

add("cdef-in-loop", "warning", "Find repeated parsing of C declarations in loops.", function(s, n, _a)
   s:emit(n, "ffi.cdef parses declarations in the interpreter. Move fixed declarations into setup before the loop.")
end)
add("load-in-loop", "warning", "Find repeated loading of C libraries in loops.", function(s, n, _a)
   s:emit(n, "ffi.load makes a namespace in the interpreter. Load the library once. Call named members on the cached namespace.")
end)
add("metatype-in-loop", "warning", "Find repeated creation of C metatypes in loops.", function(s, n, _a)
   s:emit(n, "ffi.metatype installs the type's metatable in the interpreter. Make the metatype before the loop. Use its constructor in the loop.")
end)
add("new-cdecl-in-loop", "hint", "Find C types used repeatedly in loops.", function(s, n, a)
   if literal(a[1]) then
      s:emit(n, "The interpreter parses this C declaration. The recorder specializes to the string. Call ffi.typeof before the loop. Use the same ctype constructor.")
   end
end)
local function literal_choices(n)
   n = model.unwrap(n)
   if not n then return nil, nil end
   if n.kind == "conditional" then return literal(n.e2), literal(n.e3) end
   if n.op and n.op.op == "or" then
      local left = model.unwrap(n.e1)
      if left and left.op and left.op.op == "and" then
         return literal(left.e2), literal(n.e2)
      end
   end
end
add("ctype-choice-in-loop", "hint", "Find a loop call that selects between distinct C declaration strings.", function(s, _n, a)
   local first, second = literal_choices(a[1])
   if first and second and first ~= second then
      s:emit(a[1], "LuaJIT guards the C declaration string it observed. A different string can cause a trace exit, even for the same type. Choose a stable ctype before the loop. You can also group the work by type.")
   end
end)
add("sizeof-variable-length-in-loop", "warning", "Find sizeof calls on literal variable-length array types inside loops.", function(s, n, a)
   local decl = literal(a[1])
   if decl and not decl:find("(", 1, true) and decl:match("%[%s*%?%s*%]%s*$") then
      s:emit(n, "LuaJIT's ffi.sizeof recorder rejects variable-length types. For a plain array, find the element size before the loop. Multiply it by the element count. If the length does not change, calculate the full size before the loop.")
   end
end)



add("vla-initializer-in-loop", "warning", "Find initialized variable-length FFI arrays in loops.", function(s, n, a)
   local decl = literal(a[1])
   if decl and not decl:find("(", 1, true) and decl:match("%[%s*%?%s*%]%s*$") and a[3] then
      s:emit(n, "LuaJIT cannot record this variable-length array initializer. Allocate the array with its length only. Then fill the array. You can also use the same typed buffer for each iteration.")
   end
end)
add("array-table-initializer-in-loop", "warning", "Find table initialization of fixed C arrays in loops.", function(s, n, a)
   local decl, init = literal(a[1]), model.unwrap(a[2])
   if decl and not decl:find("(", 1, true) and decl:match("%[%s*%d+%s*%]%s*$") and #a == 2 and init and init.kind == "literal_table" then
      s:emit(n, "LuaJIT's FFI recorder cannot convert this table initializer to C array elements. Initialize a typed buffer before the loop. You can also assign its elements separately.")
   end
end)
add("large-byte-array-initializer-in-loop", "warning", "Find initialized large byte arrays in loops.", function(s, n, a)
   local decl = literal(a[1])
   if not decl or not a[2] then return end
   local size = decl:match("^%s*char%s*%[%s*(%d+)%s*%]%s*$") or
   decl:match("^%s*unsigned%s+char%s*%[%s*(%d+)%s*%]%s*$") or
   decl:match("^%s*signed%s+char%s*%[%s*(%d+)%s*%]%s*$")
   if size and tonumber(size) > 128 then
      s:emit(n, "LuaJIT's FFI recorder cannot initialize this array larger than 128 bytes. Allocate it without an initializer. Then fill the array. You can also use the same buffer for each iteration.")
   end
end)
add("callback-cast-in-loop", "hint", "Find repeated creation of FFI callbacks in loops.", function(s, n, a)
   local decl, value = literal(a[1]), model.unwrap(a[2])
   if decl and decl:match("%(%s*%*%s*%)") and value and value.kind == "function" then
      s:emit(n, "Each iteration makes a C callback. Use the same callback when it is safe. Free the callback after C no longer uses it. Group calls to decrease C-to-Lua transitions.")
   end
end)
add("int64-tonumber", "warning", "Find 64-bit cdata conversions that can lose precision.", function(s, n, a)
   local value = model.unwrap(a[1])
   local p = call_path(s, value)
   if p ~= "ffi.new" and p ~= "ffi.cast" then return end
   local args = call(value)
   local decl = args and literal(args[1])
   if decl and (decl:match("^%s*int64_t%s*$") or decl:match("^%s*uint64_t%s*$") or decl:match("^%s*unsigned%s+long%s+long%s*$") or decl:match("^%s*long%s+long%s*$")) then
      s:emit(n, "tonumber can lose precision for 64-bit integers outside the exact Lua number range. Keep cdata for integer arithmetic. You can also use a string that keeps the full value.")
   end
end)
add("string-in-loop", "hint", "Find C-to-Lua string copies in loops.", function(s, n, _a)
   s:emit(n, "ffi.string copies bytes into a Lua string. Use the buffer directly if possible. Keep a reference to its owner while you use the buffer. You can also convert it before the loop.")
end)
add("gc-in-loop", "hint", "Find repeated FFI finalizer changes in loops.", function(s, n, _a)
   s:emit(n, "ffi.gc attaches or changes a finalizer. Allocate the buffer before the loop if you can use it again. Release the buffer after its last use.")
end)
add("typeof-in-loop", "hint", "Find string-based ffi.typeof calls that the recorder cannot handle.", function(s, n, a)
   if literal(a[1]) then
      s:emit(n, "LuaJIT records ffi.typeof with cdata inputs. A declaration string uses the interpreter. Make the ctype before the loop. Use the same ctype in the loop.")
   end
end)
add("anonymous-aggregate", "warning", "Find anonymous C types created for each allocation.", function(s, n, a)
   local decl = literal(a[1])
   if decl and (decl:match("%f[%w_]struct%s*{") or decl:match("%f[%w_]union%s*{")) then
      s:emit(n, "Each ffi.new of an anonymous aggregate makes a different C type. Use a named C type. You can also use the same ffi.typeof result.")
   end
end)
add("cdef-preprocessor", "warning", "C declarations are not passed through a C preprocessor.", function(s, n, a)
   local decl = model.c_declaration(s, a[1])
   if not decl then return end
   for directive in ("\n" .. decl):gmatch("\n[ \t]*#[ \t]*([^\n]+)") do
      if not directive:match("^pragma[ \t]+pack[ \t]*%(") then
         s:emit(n, "Use a C preprocessor on the declarations. Give its result to ffi.cdef.")
         return
      end
   end
end)
add("cdef-volatile", "warning", "LuaJIT compiled code ignores volatile qualifiers.", function(s, n, a)
   local decl = model.c_declaration(s, a[1])
   if decl and decl:match("%f[%w_]volatile%f[^%w_]") then
      s:emit(n, "LuaJIT compiled code ignores volatile qualifiers. Use a C wrapper when accesses must be volatile.")
   end
end)
add("cdef-long-double", "warning", "LuaJIT does not support long double operations.", function(s, n, a)
   local decl = model.c_declaration(s, a[1])
   if decl and decl:match("%f[%w_]long%s+double%f[^%w_]") then
      s:emit(n, "LuaJIT parses long double. It does not support conversions, access, or arithmetic for this type. Use a C wrapper.")
   end
end)
add("negative-length", "error", "Reject negative literal FFI memory lengths.", function(s, n, a)
   local p = path(s, n.e1)
   local len
   if p == "ffi.copy" then len = a[3]
   elseif p == "ffi.fill" or p == "ffi.string" then len = a[2] end
   local value = len and model.number(len)
   if value and value < 0 then
      s:emit(len, p .. " requires a byte length of zero or more.")
   end
end)
add("copy-string-overread", "error", "Detect literal string copies that exceed the source buffer.", function(s, n, a)
   if path(s, n.e1) == "ffi.copy" then
      local str, len = literal(a[2]), a[3] and model.number(a[3])
      if str and len and len > #str + 1 then
         s:emit(a[3], "ffi.copy reads past the string and its final zero byte. Use a byte length that fits in the source buffer.")
      end
   end
end)
add("copy-missing-length", "error", "Require a length when copying a non-string literal source.", function(s, n, a)
   if path(s, n.e1) == "ffi.copy" and #a == 2 then
      local src = model.unwrap(a[2])
      if src and (src.kind == "number" or src.kind == "integer" or src.kind == "boolean" or src.kind == "nil" or src.kind == "literal_table") then
         s:emit(src, "The two-argument ffi.copy form requires a Lua string source. Pass a valid source and byte length.")
      end
   end
end)
add("temporary-array-pointer", "warning", "Keep the owner of a pointer cast from a temporary C array alive.", function(s, n, a)
   local decl, value = literal(a[1]), model.unwrap(a[2])
   if path(s, n.e1) == "ffi.cast" and decl and decl:find("%*") and call_path(s, value) == "ffi.new" then
      local inner = call(value)
      local innerdecl = inner and literal(inner[1])
      if innerdecl and innerdecl:find("%[") then
         s:emit(n, "The garbage collector can free the temporary array while you use this pointer. Keep a reference to the array.")
      end
   end
end)
add("temporary-array-initializer", "hint", "Check temporary C array ownership when initializing named C aggregates.", function(s, _n, a)
   local decl = literal(a[1])
   if decl and decl:match("^%s*%a+%s+[%w_]+%s*$") and (decl:match("^%s*struct%s") or decl:match("^%s*union%s")) then
      for i = 2, #a do
         local value = model.unwrap(a[i])
         if call_path(s, value) == "ffi.new" then
            local inner = call(value)
            local innerdecl = inner and literal(inner[1])
            if innerdecl and innerdecl:find("%[") then
               s:emit(value, "If this value sets a pointer field, keep a reference to the array while you use the field.")
            end
         end
      end
   end
end)
add("implicit-callback", "warning", "Avoid permanent implicit Lua-to-C callback conversions.", function(s, _n, a)
   for _, argument in ipairs(a) do
      local value = model.unwrap(argument)
      if value and value.kind == "function" then
         s:emit(value, "An implicit FFI callback is permanent. Cast it explicitly. Free it after C stops using it. For hot paths, group work to reduce C-to-Lua crossings.")
      end
   end
end)
add("callback-vararg", "error", "Require fixed signatures for LuaJIT callbacks.", function(s, n, a)
   local decl, value = model.c_declaration(s, a[1]), model.unwrap(a[2])
   if path(s, n.e1) == "ffi.cast" and decl and decl:find("...", 1, true) and value and value.kind == "function" then
      s:emit(n, "LuaJIT does not support callbacks with C vararg function types. Use a C wrapper with a fixed signature.")
   end
end)
local known_abi = {
   ["32bit"] = true, ["64bit"] = true, le = true, be = true, fpu = true,
   softfp = true, hardfp = true, eabi = true, win = true, pauth = true,
   uwp = true, gc64 = true, dualnum = true,
}
add("unknown-abi", "warning", "Detect unrecognized literal ffi.abi queries.", function(s, _n, a)
   local name = literal(a[1])
   if name and not known_abi[name] then
      s:emit(a[1], "LuaJIT does not recognize this ABI name. Use a name from the ffi.abi reference.")
   end
end)
add("printf-integer-vararg", "warning", "Pass explicitly typed integers to printf-family C varargs.", function(s, n, a)
   local p = path(s, n.e1)
   local format_index = p == "ffi.C.printf" and 1 or (p == "ffi.C.snprintf" and 3 or 2)
   local format = literal(a[format_index])
   if not format then return end
   local pos, arg_index = 1, format_index + 1
   while true do
      local start = format:find("%", pos, true)
      if not start then break end
      if format:sub(start + 1, start + 1) == "%" then
         pos = start + 2
      else


         local tail = format:sub(start)
         local full, conversion = tail:match("^(%%[-+ #0]*%d*%.?%d*[hljztL]*([diouxXcfeEgGaAspn]))")
         if not full then break end
         local value = model.unwrap(a[arg_index])
         if conversion:match("[diouxXc]") and model.number(value) then
            s:emit(value, "Lua numbers become double in C varargs. Use ffi.cast or ffi.new with the integer type required by this format.")
         end
         arg_index = arg_index + 1
         pos = start + #full
      end
   end
end)
local function warn_boxed_operand(s, operand)
   local p = call_path(s, operand)
   if p == "ffi.new" or p == "ffi.cast" then
      local args = call(operand)
      local decl = args and literal(args[1])
      if decl and (decl:match("^%s*int64_t%s*$") or decl:match("^%s*uint64_t%s*$")) then
         s:emit(operand, "This arithmetic creates 64-bit cdata in a loop. Use Lua numbers if their range and precision are sufficient. For 64-bit arithmetic, keep a consistent cdata type. Profile to see if the recorder removes boxing.")
      end
   end
end

local boxed_scalar_rule = {
   id = "luajit-ffi/boxed-scalar-arithmetic", severity = "hint", in_loop = true,
   description = "Find explicit scalar cdata construction in hot arithmetic.",
   kinds = { "op" }, operators = { "+", "-", "*", "/", "%", "^" }, bindings = true,
   check = function(s, n, _t, _children)
      warn_boxed_operand(s, n.e1)
      if n.e2 then warn_boxed_operand(s, n.e2) end
   end,
}
table.insert(rules, boxed_scalar_rule)
return rules
