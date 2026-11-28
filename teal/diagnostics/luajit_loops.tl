--#pragma strict_nil off
-- Source-level leads, not proof of hot exits: see LuaJIT's lj_record.c
-- (guarded type loads and branch recording) and luajit.org/running.html (-jv).
local model = require("teal.diagnostics.model")
local type Rule = model.Rule
local type State = model.State
local type Node = model.Node
local type Type = model.Type

local function is_call(s: State, n: Node, name: string): boolean
   n = model.unwrap(n)
   return n and n.op and n.op.op == "@funcall" and s:path(n.e1) == name
end

local function type_test(s: State, n: Node): boolean
   n = model.unwrap(n)
   if not n or not n.op or (n.op.op ~= "==" and n.op.op ~= "~=") then return false end
   local a, b = model.unwrap(n.e1), model.unwrap(n.e2)
   return (a and b and a.kind == "string" and is_call(s, b, "type")) or
          (a and b and b.kind == "string" and is_call(s, a, "type")) or false
end

local function parity_test(n: Node): boolean
   n = model.unwrap(n)
   if not n or not n.op or (n.op.op ~= "==" and n.op.op ~= "~=") then return false end
   local a, b = model.unwrap(n.e1), model.unwrap(n.e2)
   if model.number(a) ~= 0 then a, b = b, a end
   return model.number(a) == 0 and b and b.op and b.op.op == "%" and model.number(b.e2) == 2 or false
end

local rules: {Rule} = {
   {
      id = "luajit/loop-type-dispatch", severity = "hint",
      description = "Find runtime type dispatch inside loops.", kinds = {"if_block"}, bindings = true,
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 and type_test(s, n.exp) then
            s:emit(n.exp, "A type-dependent branch in a hot loop can take different guarded paths as values change. Profile exits with LuaJIT -jv; if this branch is costly, group values by type or move dispatch outside the loop.")
         end
      end,
   },
   {
      id = "luajit/loop-alternating-branch", severity = "hint",
      description = "Find parity branches that may alternate on successive iterations.", kinds = {"if_block"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 and parity_test(n.exp) then
            s:emit(n.exp, "This parity branch may alternate between paths in the loop. LuaJIT records guarded paths and may compile side traces; inspect -jv before considering processing pairs of items together.")
         end
      end,
   },
   {
      id = "luajit/loop-indexed-dispatch", severity = "hint",
      description = "Find dynamically indexed function calls inside loops.", kinds = {"op"}, operators = {"@funcall"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth == 0 then return end
         local callee = model.unwrap(n.e1)
         if callee and callee.op and callee.op.op == "@index" then
            local key = model.unwrap(callee.e2)
            if key and key.kind ~= "string" and key.kind ~= "number" and key.kind ~= "integer" then
               s:emit(callee, "The indexed call target may vary between iterations, causing function guards to fail. If profiling shows frequent exits, group work by target or select a stable function outside the loop.")
            end
         end
      end,
   },
   {
      id = "luajit/loop-array-hole", severity = "hint",
      description = "Find explicit deletion of indexed entries in loops.", kinds = {"assignment"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth == 0 or #n.vars ~= 1 or #n.exps ~= 1 then return end
         local dst, value = model.unwrap(n.vars[1]), model.unwrap(n.exps[1])
         if dst and dst.op and dst.op.op == "@index" and value and value.kind == "nil" then
            s:emit(dst, "Deleting an indexed entry can create holes if this table is used as a sequence. If profiling shows unstable lookups or iteration, consider a dense array with a separate count or a swap-remove scheme when order permits.")
         end
      end,
   },
   {
      id = "luajit/loop-table-allocation", severity = "hint",
      description = "Find table constructors inside loops.", kinds = {"literal_table"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            s:emit(n, "This table is constructed on each iteration. LuaJIT may eliminate some allocations; if GC profiling shows pressure, reuse storage when its lifetime and aliasing permit.")
         end
      end,
   },
}

return rules
