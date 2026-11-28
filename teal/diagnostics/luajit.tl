--#pragma strict_nil off
-- LuaJIT-specific profiling leads. These are deliberately limited to operations
-- identifiable from the source. Profiling determines which paths run hot. See https://luajit.org/running.html and src/lib_*.c.
local model = require("teal.diagnostics.model")
local type Rule = model.Rule
local type State = model.State
local type Node = model.Node
local type Type = model.Type

local function hot_call(id: string, name: string, description: string, message: string): Rule
   return {
      id = id, severity = "hint", description = description,
      kinds = {"op"}, bindings = true, calls = {name},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            s:emit(n, message)
         end
      end,
   }
end

local rules: {Rule} = {
   hot_call("luajit/hot-string-match", "string.match",
      "Find pattern matching inside loops that may cross a trace boundary.",
      "string.match is not recorded by LuaJIT's fast-function recorder; the trace can stitch across the call. If only literal presence is needed, try string.find(s, needle, 1, true), then check traces and benchmark"),
   hot_call("luajit/hot-string-gmatch", "string.gmatch",
      "Find repeated pattern iterator creation inside loops.",
      "string.gmatch creates a pattern iterator. Consider moving creation out of the loop when iteration semantics permit"),
   hot_call("luajit/hot-string-gsub", "string.gsub",
      "Find substitutions inside loops that may be expensive.",
      "string.gsub in a loop performs pattern substitution and creates a result string. Profile before restructuring"),
   hot_call("luajit/hot-string-dump", "string.dump",
      "Find repeated function serialization inside loops.",
      "string.dump serializes a function and is unlikely to belong in a hot loop. Cache the result if it remains valid"),
   hot_call("luajit/hot-load", "load",
      "Find repeated compilation of source inside loops.",
      "load compiles a chunk at runtime. If the source is invariant, compile it outside the loop"),
   hot_call("luajit/hot-loadstring", "loadstring",
      "Find repeated compilation of strings inside loops.",
      "loadstring compiles a chunk at runtime. If the source is invariant, compile it outside the loop"),
   hot_call("luajit/hot-loadfile", "loadfile",
      "Find repeated loading and compilation of files inside loops.",
      "loadfile reads and compiles a chunk. If the file is invariant, load it outside the loop"),
   hot_call("luajit/hot-dofile", "dofile",
      "Find repeated loading and execution of files inside loops.",
      "dofile loads and executes a file on each iteration. Check whether that repeated work is needed"),
   hot_call("luajit/hot-collectgarbage", "collectgarbage",
      "Find explicit garbage collector operations inside loops.",
      "collectgarbage in a loop may disrupt normal GC scheduling. Measure the effect before forcing collection or changing GC settings"),
   hot_call("luajit/hot-setfenv", "setfenv",
      "Find environment mutation inside loops.",
      "setfenv changes a function environment and can interrupt a trace. Move invariant setup out of the loop when possible."),
   hot_call("luajit/hot-newproxy", "newproxy",
      "Find repeated proxy allocations inside loops.",
      "newproxy allocates userdata. Repeated allocations can increase GC pressure in a hot loop"),
   hot_call("luajit/hot-print", "print",
      "Find console output inside loops.",
      "print performs output on every iteration. Buffer or sample logging if profiling shows it dominates the loop"),
   hot_call("luajit/hot-coroutine-create", "coroutine.create",
      "Find repeated coroutine creation inside loops.",
      "coroutine.create allocates a coroutine. Consider reusing workers when its lifecycle permits"),
   hot_call("luajit/hot-coroutine-wrap", "coroutine.wrap",
      "Find repeated wrapped coroutine creation inside loops.",
      "coroutine.wrap creates a coroutine and wrapper. Consider reusing workers when its lifecycle permits"),
   {
      id = "luajit/unrecorded-library-call", severity = "hint",
      description = "Find library calls that LuaJIT does not record as fast functions.",
      kinds = {"op"}, bindings = true,
      calls = {"table.sort", "table.maxn", "coroutine.status", "coroutine.running", "coroutine.resume", "coroutine.yield",
         "debug.getregistry", "debug.setmetatable", "debug.getfenv", "debug.setfenv", "debug.getinfo", "debug.getlocal",
         "debug.setlocal", "debug.getupvalue", "debug.setupvalue", "debug.sethook", "debug.gethook", "debug.traceback",
         "jit.on", "jit.status", "jit.attach", "jit.opt.start", "gcinfo"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            s:emit(n, "This LuaJIT library call has no fast-function recorder. The current trace may stitch across it or return to the interpreter; move invariant inspection or setup out of the loop, and use -jv to check the actual path")
         end
      end,
   },
   {
      id = "luajit/table-insert-position", severity = "hint",
      description = "Find positioned inserts that the LuaJIT table.insert recorder cannot handle.",
      kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 and #n.e2 == 3 then
            s:emit(n, "LuaJIT's table.insert recorder handles the two-argument append, but not a positioned insert. If the operation is an append, use table.insert(t, value) or t[#t + 1] = value; preserve insertion semantics otherwise")
         end
      end,
   },
   {
      id = "luajit/tonumber-base", severity = "hint",
      description = "Find explicit tonumber bases unsupported by the LuaJIT recorder.",
      kinds = {"op"}, bindings = true, calls = {"tonumber"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 and #n.e2 >= 2 then
            local base = model.number(n.e2[2])
            if base and base ~= 10 then
               s:emit(n, "LuaJIT does not record tonumber with this base. If input is invariant, convert it before the loop; otherwise profile the interpreter or stitched call")
            end
         end
      end,
   },
   {
      id = "luajit/jit-off-in-loop", severity = "warning",
      description = "Find repeated JIT disabling in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.off"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            s:emit(n, "jit.off inside a loop repeatedly changes JIT state. Configure it outside the loop when possible.")
         end
      end,
   },
   {
      id = "luajit/jit-flush-in-loop", severity = "warning",
      description = "Find repeated trace flushing in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.flush"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            s:emit(n, "jit.flush discards compiled traces. Repeated flushing can prevent useful compilation.")
         end
      end,
   },
   {
      id = "luajit/table-insert-front", severity = "hint",
      description = "Find insertions at the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            local args = n.e2
            if #args == 3 and model.number(args[2]) == 1 then
               s:emit(n, "Inserting at index 1 shifts existing array elements. For large sequences, consider appending and reversing or using a deque.")
            end
         end
      end,
   },
   {
      id = "luajit/table-remove-front", severity = "hint",
      description = "Find removals from the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.remove"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth > 0 then
            local args = n.e2
            if #args == 2 and model.number(args[2]) == 1 then
               s:emit(n, "Removing index 1 shifts following array elements. For a queue, consider tracking a head index.")
            end
         end
      end,
   },
   {
      id = "luajit/string-accumulation-in-loop", severity = "hint",
      description = "Find string accumulators that copy the growing prefix on each iteration.", kinds = {"assignment"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth == 0 or #n.vars ~= 1 or #n.exps ~= 1 then return end
         local dst, value = n.vars[1], model.unwrap(n.exps[1])
         if dst.kind ~= "variable" or not value.op or value.op.op ~= ".." or value.op.meta_on_operand then return end
         local left = model.unwrap(value.e1)
         if left.kind == "variable" and left.tk == dst.tk then
            s:emit(value, "Appending to a growing string repeatedly copies the prefix. Collect fragments and join them once with table.concat.")
         end
      end,
   },
   {
      id = "luajit/hot-string-pattern-method", severity = "hint",
      description = "Find repeated pattern operations written as string method calls.", kinds = {"op"}, operators = {"@funcall"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if s.loop_depth == 0 then return end
         local callee = n.e1
         if callee.op and callee.op.op == ":" and callee.receiver and
            (callee.receiver.typename == "string" or callee.receiver.typename == "enum") then
            local member = callee.e2.tk
            if member == "match" or member == "gmatch" or member == "gsub" then
               s:emit(callee.e2, "This string pattern operation runs inside a loop. Profile it and hoist invariant work where possible.")
            end
         end
      end,
   },
}

return rules
