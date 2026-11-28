




local model = require("teal.diagnostics.model")





local function is_call(s, n, name)
   n = model.unwrap(n)
   return n and n.op and n.op.op == "@funcall" and s:path(n.e1) == name
end

local function type_test(s, n)
   n = model.unwrap(n)
   if not n or not n.op or (n.op.op ~= "==" and n.op.op ~= "~=") then return false end
   local a, b = model.unwrap(n.e1), model.unwrap(n.e2)
   return (a and b and a.kind == "string" and is_call(s, b, "type")) or
   (a and b and b.kind == "string" and is_call(s, a, "type")) or false
end

local function parity_test(n)
   n = model.unwrap(n)
   if not n or not n.op or (n.op.op ~= "==" and n.op.op ~= "~=") then return false end
   local a, b = model.unwrap(n.e1), model.unwrap(n.e2)
   if model.number(a) ~= 0 then a, b = b, a end
   return model.number(a) == 0 and b and b.op and b.op.op == "%" and model.number(b.e2) == 2 or false
end

local function literal_type(n)
   n = model.unwrap(n)
   if not n then return nil end
   if n.kind == "number" or n.kind == "integer" then return "number" end
   if n.kind == "string" or n.kind == "boolean" or n.kind == "nil" then return n.kind end
end

local rules = {
   {
      id = "luajit/loop-closure", severity = "hint", in_loop = true,
      description = "Find function definitions created inside loops.",
      kinds = { "function", "local_function", "global_function" },
      check = function(s, n, _t, _children)
         s:emit(n, "Upstream LuaJIT 2.1 stops recording at FNEW. The compiler can also emit UCLO for captured locals. Move the function before the loop if its identity and captures permit it. Use loop values as parameters.")
      end,
   },
   {
      id = "luajit/loop-branch-value-type", severity = "hint", in_loop = true,
      description = "Find branches assigning different literal types to the same variable inside a loop.",
      kinds = { "if" },
      check = function(s, n, _t, _children)
         if #n.if_blocks ~= 2 then return end
         local first, second = n.if_blocks[1], n.if_blocks[2]
         if second.exp or not first.body or not second.body or #first.body ~= 1 or #second.body ~= 1 then return end
         local a, b = first.body[1], second.body[1]
         if a.kind ~= "assignment" or b.kind ~= "assignment" or #a.vars ~= 1 or #b.vars ~= 1 or #a.exps ~= 1 or #b.exps ~= 1 then return end
         local av, bv = model.unwrap(a.vars[1]), model.unwrap(b.vars[1])
         local at, bt = literal_type(a.exps[1]), literal_type(b.exps[1])
         if av and bv and av.kind == "variable" and bv.kind == "variable" and av.tk == bv.tk and at and bt and at ~= bt then
            s:emit(n, "These branches assign different value types to the same variable. If both paths run and the value persists, type-specialized traces may exit or need separate traces. Keep the representation stable if possible. Check -jv before you change the code.")
         end
      end,
   },
   {
      id = "luajit/loop-type-dispatch", severity = "hint", in_loop = true,
      description = "Find runtime type dispatch inside loops.", kinds = { "if_block" }, bindings = true,
      check = function(s, n, _t, _children)
         if type_test(s, n.exp) then
            s:emit(n.exp, "A type change can cause a side exit. Check for frequent exits with a profile. If necessary, group values by type. You can also select the operation before the loop.")
         end
      end,
   },
   {
      id = "luajit/loop-alternating-branch", severity = "hint", in_loop = true,
      description = "Find parity branches that may alternate on successive iterations.", kinds = { "if_block" },
      check = function(s, n, _t, _children)
         if parity_test(n.exp) then
            s:emit(n.exp, "This parity branch can alternate between guarded paths. LuaJIT can compile a side trace. If exits are frequent, process one pair of items per iteration.")
         end
      end,
   },
   {
      id = "luajit/loop-indexed-dispatch", severity = "hint", in_loop = true,
      description = "Find dynamically indexed function calls inside loops.", kinds = { "op" }, operators = { "@funcall" }, bindings = true, ffi_origins = true,
      check = function(s, n, _t, _children)
         local callee = model.unwrap(n.e1)
         if callee and callee.op and callee.op.op == "@index" and not model.ffi_namespace(s:path(callee.e1)) then
            local key = model.unwrap(callee.e2)
            if key and key.kind ~= "string" and key.kind ~= "number" and key.kind ~= "integer" then
               s:emit(callee, "The indexed call target can change between iterations. This can cause function guards to fail. Check for frequent exits with a profile. Group the work by function if necessary. You can also select the function before the loop.")
            end
         end
      end,
   },
   {
      id = "luajit/loop-array-hole", severity = "hint", in_loop = true,
      description = "Find explicit deletion of indexed entries in loops.", kinds = { "assignment" },
      check = function(s, n, _t, _children)
         if #n.vars ~= 1 or #n.exps ~= 1 then return end
         local dst, value = model.unwrap(n.vars[1]), model.unwrap(n.exps[1])
         if dst and dst.op and dst.op.op == "@index" and value and value.kind == "nil" then
            s:emit(dst, "Deleting an indexed entry can create holes in a sequence. Profile the lookups and iteration. If necessary, use a dense array with a separate count. Or use swap-remove if order does not matter.")
         end
      end,
   },
   {
      id = "luajit/loop-table-allocation", severity = "hint", in_loop = true,
      description = "Find table constructors inside loops.", kinds = { "literal_table" },
      check = function(s, n, _t, _children)
         s:emit(n, "Each iteration makes a table. LuaJIT can remove the allocation. If garbage collection takes too much time, use the same table when it is safe.")
      end,
   },
   {
      id = "luajit/loop-vararg", severity = "hint", in_loop = true,
      description = "Find multi-result vararg expressions inside loops.",
      kinds = { "op", "literal_table", "return" }, operators = { "@funcall" }, bindings = true,
      check = function(s, n, _t, _children)
         local varg
         if n.kind == "op" and n.op and n.op.op == "@funcall" then
            if s:path(n.e1) == "select" then return end
            local args = n.e2
            if args and #args > 0 then
               local last = model.unwrap(args[#args])
               if last and last.kind == "..." then varg = last end
            end
         elseif n.kind == "literal_table" then
            if #n > 0 then
               local item = n[#n]
               if item.key_parsed == "implicit" then
                  local val = model.unwrap(item.value)
                  if val and val.kind == "..." then varg = val end
               end
            end
         elseif n.kind == "return" then
            local exps = n.exps
            if exps and #exps > 0 then
               local last = model.unwrap(exps[#exps])
               if last and last.kind == "..." then varg = last end
            end
         end
         if varg then
            s:emit(varg, "Upstream LuaJIT 2.1 stops recording at multi-result varargs. Pack the arguments into a table before the loop. Then index the table inside the loop.")
         end
      end,
   },
}

return rules
