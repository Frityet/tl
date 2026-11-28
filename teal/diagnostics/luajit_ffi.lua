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



local function c_declaration(n)
   local text = literal(n)
   if text then
      text = text:gsub("/%*.-%*/", " "):gsub("//[^\n]*", " ")
   end
   return text
end

local routes = {
   ["cdef-in-loop"] = { "ffi.cdef" },
   ["load-in-loop"] = { "ffi.load" },
   ["metatype-in-loop"] = { "ffi.metatype" },
   ["new-cdecl-in-loop"] = { "ffi.new" },
   ["vla-initializer-in-loop"] = { "ffi.new" },
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
local function add(id, severity, description,
   fn)
   local r = {
      id = "luajit-ffi/" .. id,
      severity = severity,
      description = description,
      kinds = { "op" },
      calls = routes[id],
      bindings = true,
      check = function(s, n, _t, _children)
         fn(s, n, n.e2)
      end,
   }
   if not r.calls then r.operators = { "@funcall" } end
   table.insert(rules, r)
end

local function in_loop(s, n, name, advice)
   if s.loop_depth > 0 then
      s:emit(n, "ffi." .. name .. " runs in a loop. " .. advice)
   end
end

add("cdef-in-loop", "warning", "Avoid parsing C declarations repeatedly in loops.", function(s, n, _a)
   in_loop(s, n, "cdef", "Move fixed declarations outside the loop.")
end)
add("load-in-loop", "warning", "Avoid repeatedly loading C libraries in loops.", function(s, n, _a)
   in_loop(s, n, "load", "Load the library once and reuse its namespace; access functions through that namespace instead of caching individual function cdata.")
end)
add("metatype-in-loop", "warning", "Avoid creating C metatypes repeatedly in loops.", function(s, n, _a)
   in_loop(s, n, "metatype", "Create the metatype once and reuse it.")
end)
add("new-cdecl-in-loop", "hint", "Cache C types used repeatedly in loops.", function(s, n, a)
   if s.loop_depth > 0 and literal(a[1]) then
      s:emit(n, "ffi.new parses this C declaration in a loop. Cache ffi.typeof(...) and call the resulting ctype; stable ctypes also avoid type guards changing across iterations")
   end
end)



add("vla-initializer-in-loop", "warning", "Avoid initialized variable-length FFI arrays in hot loops.", function(s, n, a)
   local decl = literal(a[1])
   if s.loop_depth > 0 and decl and decl:match("%[%s*%?%s*%]") and a[3] then
      s:emit(n, "LuaJIT cannot record this variable-length array initializer. Allocate the array with its length only and fill it separately, or reuse a typed buffer outside the loop")
   end
end)
add("string-in-loop", "hint", "Avoid unnecessary C-to-Lua string copies in hot loops.", function(s, n, _a)
   if s.loop_depth > 0 then
      s:emit(n, "ffi.string copies bytes into a Lua string. If possible, process the buffer directly or convert once outside the loop; keep its owner alive while using it")
   end
end)
add("gc-in-loop", "hint", "Avoid repeatedly attaching FFI finalizers in hot loops.", function(s, n, _a)
   if s.loop_depth > 0 then
      s:emit(n, "ffi.gc attaches or changes a finalizer. Consider reusing an owned buffer outside the loop and release it only after its last use")
   end
end)
add("typeof-in-loop", "hint", "Avoid repeatedly parsing fixed C type declarations.", function(s, n, a)
   if s.loop_depth > 0 and literal(a[1]) and #a == 1 then
      s:emit(n, "ffi.typeof parses this fixed declaration in a loop. Cache the ctype outside the loop")
   end
end)
add("anonymous-aggregate", "warning", "Avoid creating distinct anonymous C types on each allocation.", function(s, n, a)
   local decl = literal(a[1])
   if decl and (decl:match("%f[%w_]struct%s*{") or decl:match("%f[%w_]union%s*{")) then
      s:emit(n, "each ffi.new of an anonymous aggregate creates a distinct C type. Define a named type or reuse one ffi.typeof result")
   end
end)
add("cdef-preprocessor", "warning", "C declarations are not passed through a C preprocessor.", function(s, n, a)
   local decl = c_declaration(a[1])
   if not decl then return end
   for directive in ("\n" .. decl):gmatch("\n[ \t]*#[ \t]*([^\n]+)") do
      if not directive:match("^pragma[ \t]+pack[ \t]*%(") then
         s:emit(n, "Resolve C preprocessor directives and macros before passing the declarations to ffi.cdef.")
         return
      end
   end
end)
add("cdef-volatile", "warning", "LuaJIT compiled code ignores volatile qualifiers.", function(s, n, a)
   local decl = c_declaration(a[1])
   if decl and decl:match("%f[%w_]volatile%f[^%w_]") then
      s:emit(n, "LuaJIT compiled code ignores volatile qualifiers. Use a C wrapper when accesses must be volatile.")
   end
end)
add("cdef-long-double", "warning", "LuaJIT does not support long double operations.", function(s, n, a)
   local decl = c_declaration(a[1])
   if decl and decl:match("%f[%w_]long%s+double%f[^%w_]") then
      s:emit(n, "LuaJIT parses long double but does not support its conversions, accesses or arithmetic. Use a C wrapper")
   end
end)
add("negative-length", "error", "Reject negative literal FFI memory lengths.", function(s, n, a)
   local p = path(s, n.e1)
   local len
   if p == "ffi.copy" then len = a[3]
   elseif p == "ffi.fill" or p == "ffi.string" then len = a[2] end
   local value = len and model.number(len)
   if value and value < 0 then
      s:emit(len, p .. " requires a nonnegative byte length")
   end
end)
add("copy-string-overread", "error", "Detect literal string copies that exceed the source buffer.", function(s, n, a)
   if path(s, n.e1) == "ffi.copy" then
      local str, len = literal(a[2]), a[3] and model.number(a[3])
      if str and len and len > #str + 1 then
         s:emit(a[3], "ffi.copy length exceeds the literal string and its terminating zero byte")
      end
   end
end)
add("copy-missing-length", "error", "Require a length when copying a non-string literal source.", function(s, n, a)
   if path(s, n.e1) == "ffi.copy" and #a == 2 then
      local src = model.unwrap(a[2])
      if src and (src.kind == "number" or src.kind == "integer" or src.kind == "boolean" or src.kind == "nil" or src.kind == "literal_table") then
         s:emit(src, "the two-argument ffi.copy form requires a Lua string source. Pass a valid source and byte length")
      end
   end
end)
add("temporary-array-pointer", "warning", "Keep the owner of a pointer cast from a temporary C array alive.", function(s, n, a)
   local decl, value = literal(a[1]), model.unwrap(a[2])
   if path(s, n.e1) == "ffi.cast" and decl and decl:find("%*") and call_path(s, value) == "ffi.new" then
      local inner = call(value)
      local innerdecl = inner and literal(inner[1])
      if innerdecl and innerdecl:find("%[") then
         s:emit(n, "this pointer does not keep the temporary array alive. Retain the array separately for the entire pointer lifetime")
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
               s:emit(value, "If this initializes a pointer field, keep the array alive for as long as the field is used.")
            end
         end
      end
   end
end)
add("implicit-callback", "warning", "Avoid permanent implicit Lua-to-C callback conversions.", function(s, n, a)
   local p = path(s, n.e1)
   if p and p:match("^ffi%.C%.") then
      for _, argument in ipairs(a) do
         local value = model.unwrap(argument)
         if value and value.kind == "function" then
            s:emit(value, "an implicit FFI callback is permanent. Explicitly ffi.cast the callback and free it once C no longer uses it; for hot paths, batch work to reduce C-to-Lua crossings")
         end
      end
   end
end)
add("callback-vararg", "error", "Require fixed signatures for LuaJIT callbacks.", function(s, n, a)
   local decl, value = c_declaration(a[1]), model.unwrap(a[2])
   if path(s, n.e1) == "ffi.cast" and decl and decl:find("...", 1, true) and value and value.kind == "function" then
      s:emit(n, "LuaJIT does not support callbacks with C vararg function types. Use a fixed-signature C wrapper")
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
      s:emit(a[1], "Unrecognized ffi.abi parameter '" .. name .. "'. Check the target ABI name.")
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
            s:emit(value, "Lua numbers become double in C varargs. Use ffi.cast or ffi.new with the integer type required by this format")
         end
         arg_index = arg_index + 1
         pos = start + #full
      end
   end
end)
return rules
