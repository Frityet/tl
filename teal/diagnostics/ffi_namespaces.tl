--#pragma strict_nil off
local model = require("teal.diagnostics.model")
local type Rule = model.Rule
local type State = model.State
local type Node = model.Node
local type Type = model.Type

local function aggregate_type(declaration: string, parameter: boolean): boolean
   declaration = declaration:match("^%s*(.-)%s*$")
   declaration = declaration:gsub("^extern%s+", ""):gsub("^const%s+", "")
   local category, rest = declaration:match("^(%a+)%s+(.+)$")
   if category ~= "struct" and category ~= "union" then return false end
   return rest:match("^[_%a][_%w]*$") ~= nil or
          (parameter and rest:match("^[_%a][_%w]*%s+[_%a][_%w]*$") ~= nil)
end

local function remember_prototypes(s: State, argument: Node)
   local decl = model.unwrap(argument)
   if not decl or decl.kind ~= "string" or #decl.conststr > 64 * 1024 then return end
   local text = model.c_declaration(s, decl)
   for statement in text:gmatch("[^;]+") do
      -- Match short, plain prototypes and leave typedefs and nested
      -- declarators to the C parser.
      local result, name, parameters: string, string, string
      if #statement <= 512 then
         local head, args = statement:match("^([^()]*)%(([^()]*)%)%s*$")
         if head then
            result, name = head:match("^%s*(.-)%s+([_%a][_%w]*)%s*$")
            parameters = args
         end
      end
      if name and not result:match("^typedef%s") then
         local aggregate: string
         if aggregate_type(result, false) then
            aggregate = "returns a C aggregate by value"
         else
            for parameter in parameters:gmatch("[^,]+") do
               if aggregate_type(parameter, true) then
                  aggregate = "takes a C aggregate by value"
                  break
               end
            end
         end
         if aggregate then
            s.ffi_aggregate_prototypes = s.ffi_aggregate_prototypes or {}
            s.ffi_aggregate_prototypes[name] = aggregate
         end
      end
   end
end

-- These checks follow local aliases of ffi.C and ffi.load results. The runtime
-- specializes to both the namespace object and the symbol name. See the C
-- library namespaces and callbacks sections of LuaJIT's FFI semantics.
local rules: {Rule} = {
   {
      id = "luajit-ffi/cached-symbol-call", severity = "hint",
      description = "Find calls through a cached C function object inside a loop.",
      kinds = {"op"}, c_symbols = true, in_loop = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local callee = model.unwrap(n.e1)
         if callee.kind == "variable" and not model.ffi_temporary_symbol(s.called_path) then
            s:emit(callee, "Keep the C library namespace in a local variable. Call the function by name on that namespace. LuaJIT can remove the lookup from the trace.")
         end
      end,
   },
   {
      id = "luajit-ffi/dynamic-symbol-call", severity = "hint",
      description = "Find runtime C symbol selection inside a loop.",
      kinds = {"op"}, operators = {"@funcall"}, bindings = true, ffi_origins = true, in_loop = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local callee = model.unwrap(n.e1)
         if not callee.op or callee.op.op ~= "@index" then return end
         local key = model.unwrap(callee.e2)
         if key.kind ~= "string" and model.ffi_namespace(s:path(callee.e1)) then
            s:emit(key, "LuaJIT makes a guard for the C symbol name. A different name can cause a side exit. Select the symbol before the loop. If names change, use a different loop for each symbol.")
         end
      end,
   },
   {
      id = "luajit-ffi/temporary-library-symbol", severity = "warning",
      description = "Find calls through function aliases taken from a temporary library namespace.",
      kinds = {"op"}, c_symbols = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local callee = model.unwrap(n.e1)
         if callee.kind == "variable" and model.ffi_temporary_symbol(s.called_path) then
            s:emit(callee, "This symbol comes from a temporary C library namespace. Put the ffi.load result in a local variable. Keep that variable in scope while you use the symbol.")
         end
      end,
   },
   {
      id = "luajit-ffi/aggregate-by-value-call", severity = "hint",
      description = "Find C calls whose visible prototypes pass a struct or union by value.",
      kinds = {"op"}, calls = {"ffi.cdef"}, c_symbols = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.called_path == "ffi.cdef" then
            remember_prototypes(s, n.e2[1])
         elseif s.ffi_aggregate_prototypes then
            local name = s.called_path:match("([_%a][_%w]*)$")
            local aggregate = name and s.ffi_aggregate_prototypes[name]
            if aggregate then
               s:emit(n, "This prototype " .. aggregate .. ". LuaJIT cannot record this call. For hot paths, use a C wrapper with pointer or scalar types.")
            end
         end
      end,
   },
   {
      id = "luajit-ffi/callback-call-in-loop", severity = "warning",
      description = "Find loop calls that pass a known Lua callback to C.",
      kinds = {"op"}, c_symbols = true, in_loop = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         for _, argument in ipairs(n.e2) do
            if s:path(argument) == "ffi.callback()" then
               s:emit(argument, "A compiled FFI call cannot run a Lua callback before it returns. Use a pull API for hot paths. If the callback is necessary, put the C call in a Lua wrapper. Use jit.off on the wrapper before the loop.")
               return
            end
         end
      end,
   },
}

return rules
