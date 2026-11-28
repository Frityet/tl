




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
         s:emit(n, "Upstream LuaJIT 2.1 aborts recording at FNEW when it creates this closure. Captures may also emit UCLO. Hoist the function and pass changing values as parameters when closure identity and capture semantics permit.")
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
            s:emit(n, "These branches assign different value types to the same variable. If both paths occur in a hot loop and the value is used across iterations, type-specialized traces may exit or need separate traces. Consider keeping its representation stable, and check -jv before changing the code.")
         end
      end,
   },
   {
      id = "luajit/loop-type-dispatch", severity = "hint", in_loop = true,
      description = "Find runtime type dispatch inside loops.", kinds = { "if_block" }, bindings = true,
      check = function(s, n, _t, _children)
         if type_test(s, n.exp) then
            s:emit(n.exp, "Changing value types can take a different guarded path. If profiling shows frequent exits, group values by type or choose the operation before the loop.")
         end
      end,
   },
   {
      id = "luajit/loop-alternating-branch", severity = "hint", in_loop = true,
      description = "Find parity branches that may alternate on successive iterations.", kinds = { "if_block" },
      check = function(s, n, _t, _children)
         if parity_test(n.exp) then
            s:emit(n.exp, "This parity branch may alternate between guarded paths. LuaJIT can compile a side trace. If exits are frequent, consider handling one pair of items per iteration.")
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
               s:emit(callee, "The indexed call target may vary between iterations, causing function guards to fail. If profiling shows frequent exits, group work by target or select a stable function outside the loop.")
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
            s:emit(dst, "Deleting an indexed entry can create holes if this table is used as a sequence. If profiling shows unstable lookups or iteration, consider a dense array with a separate count or a swap-remove scheme when order permits.")
         end
      end,
   },
   {
      id = "luajit/loop-table-allocation", severity = "hint", in_loop = true,
      description = "Find table constructors inside loops.", kinds = { "literal_table" },
      check = function(s, n, _t, _children)
         s:emit(n, "This table is constructed on each iteration. LuaJIT may eliminate the allocation. If a profile shows GC pressure, reuse storage where its lifetime and aliasing permit.")
      end,
   },
}

return rules
