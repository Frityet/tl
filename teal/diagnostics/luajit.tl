--#pragma strict_nil off
-- LuaJIT-specific profiling leads. These are deliberately limited to operations
-- identifiable from the source. Profiling determines which paths run hot. See https://luajit.org/running.html and src/lib_*.c.
local model = require("teal.diagnostics.model")
local type Rule = model.Rule
local type State = model.State
local type Node = model.Node
local type Type = model.Type

local function uses_pattern(pattern: Node, plain: Node): boolean
   pattern, plain = model.unwrap(pattern), model.unwrap(plain)
   if not pattern or pattern.kind ~= "string" then return false end
   if plain and (plain.kind == "string" or plain.kind == "number" or plain.kind == "integer" or
      plain.kind == "literal_table" or plain.kind == "function" or (plain.kind == "boolean" and plain.tk == "true")) then
      return false
   end
   return pattern.conststr:find("[%^%$%*%+%?%.%(%[%%%-]") ~= nil
end

local pattern_message = "The recorder handles literal string.find searches. A Lua pattern stays on the interpreter path. Pass true for plain mode if you want literal matching, or move invariant matching outside the loop."

local function hot_call(id: string, name: string, description: string, message: string): Rule
   return {
      id = id, severity = "hint", description = description, in_loop = true,
      kinds = {"op"}, bindings = true, calls = {name},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, message)
      end,
   }
end

local rules: {Rule} = {
   hot_call("luajit/hot-string-match", "string.match",
      "Find pattern matching inside loops that may cross a trace boundary.",
      "The fast-function recorder can stitch around string.match. If you only need literal presence, use string.find(s, needle, 1, true) and measure the effect."),
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
   hot_call("luajit/hot-table-new", "table.new",
      "Find repeated allocation of presized tables in loops.",
      "table.new still allocates a table each iteration. If GC profiling shows pressure, reuse a presized table when its lifetime and aliasing permit."),
   {
      id = "luajit/string-find-pattern", severity = "hint", in_loop = true,
      description = "Find literal patterns that the LuaJIT string.find recorder cannot handle.",
      kinds = {"op"}, bindings = true, calls = {"string.find"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if uses_pattern(n.e2[2], n.e2[4]) then
            s:emit(n, pattern_message)
         end
      end,
   },
   {
      id = "luajit/select-dynamic-index", severity = "hint", in_loop = true,
      description = "Find dynamic select indices that may prevent recording.",
      kinds = {"op"}, bindings = true, calls = {"select"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local index = model.unwrap(n.e2[1])
         if index and not model.number(index) and index.kind ~= "string" then
            s:emit(n, "The ordinary select recorder requires a constant numeric index. LuaJIT has a separate guarded path for single-result select(index, ...). If you only need one result, consider packing the values once before the loop and indexing the pack.")
         end
      end,
   },
   {
      id = "luajit/unpack-bounds", severity = "hint", in_loop = true,
      description = "Find unpack calls whose result count can vary or grow large.",
      kinds = {"op"}, bindings = true, calls = {"unpack", "table.unpack"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = n.e2
         local start = model.unwrap(args[2])
         local first = (not start or start.kind == "nil") and 1 or model.number(start)
         local last = model.number(args[3])
         if not last or not first then
            s:emit(n, "LuaJIT specializes the result count and guards variable bounds, including the default table length. Changing the bounds can exit the trace. Keep the range fixed or process the table directly.")
         elseif first and last - first >= 16 then
            s:emit(n, "LuaJIT records each unpacked element separately. A large fixed range can grow the trace and hit its slot limit. Consider processing the table directly.")
         end
      end,
   },
   {
      id = "luajit/getfenv-recorder", severity = "hint", in_loop = true,
      description = "Find getfenv forms unsupported by the LuaJIT recorder.",
      kinds = {"op"}, bindings = true, calls = {"getfenv"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if #n.e2 == 0 or model.number(n.e2[1]) ~= 0 then
            s:emit(n, "LuaJIT's getfenv recorder supports only the constant getfenv(0) form. Cache an invariant environment outside the loop if it cannot change")
         end
      end,
   },
   {
      id = "luajit/unrecorded-library-call", severity = "hint", in_loop = true,
      description = "Find library calls that LuaJIT does not record as fast functions.",
      kinds = {"op"}, bindings = true,
      calls = {"table.sort", "table.maxn", "coroutine.status", "coroutine.running", "coroutine.resume", "coroutine.yield",
         "debug.getregistry", "debug.setmetatable", "debug.getfenv", "debug.setfenv", "debug.getinfo", "debug.getlocal",
         "debug.setlocal", "debug.getupvalue", "debug.setupvalue", "debug.sethook", "debug.gethook", "debug.traceback",
         "jit.on", "jit.status", "jit.attach", "jit.opt.start", "gcinfo"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, "This call runs in the interpreter. LuaJIT may stitch the trace across it. Move invariant inspection or setup outside the loop and check the path with a profile.")
      end,
   },
   {
      id = "luajit/table-insert-position", severity = "hint", in_loop = true,
      description = "Find positioned inserts that the LuaJIT table.insert recorder cannot handle.",
      kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if #n.e2 == 3 then
            s:emit(n, "LuaJIT records the two-argument append. A positioned insert takes the interpreter path. If you are appending, use table.insert(t, value).")
         end
      end,
   },
   {
      id = "luajit/tonumber-base", severity = "hint", in_loop = true,
      description = "Find explicit tonumber bases unsupported by the LuaJIT recorder.",
      kinds = {"op"}, bindings = true, calls = {"tonumber"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local base = model.unwrap(n.e2[2])
         if base and base.kind ~= "nil" and model.number(base) ~= 10 then
            s:emit(n, "LuaJIT's tonumber recorder accepts an omitted base or constant base 10. Hoist invariant conversion or group inputs by conversion path before the loop.")
         end
      end,
   },
   {
      id = "luajit/jit-off-in-loop", severity = "warning", in_loop = true,
      description = "Find repeated JIT disabling in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.off"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, "jit.off inside a loop repeatedly changes JIT state. Configure it outside the loop when possible.")
      end,
   },
   {
      id = "luajit/jit-flush-in-loop", severity = "warning", in_loop = true,
      description = "Find repeated trace flushing in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.flush"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, "jit.flush discards compiled traces. Repeated flushing can prevent useful compilation.")
      end,
   },
   {
      id = "luajit/table-insert-front", severity = "hint", in_loop = true,
      description = "Find insertions at the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = n.e2
         if #args == 3 and model.number(args[2]) == 1 then
            s:emit(n, "Inserting at index 1 shifts existing array elements. For large sequences, consider appending and reversing or using a deque.")
         end
      end,
   },
   {
      id = "luajit/table-remove-front", severity = "hint", in_loop = true,
      description = "Find removals from the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.remove"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = n.e2
         if #args == 2 and model.number(args[2]) == 1 then
            s:emit(n, "Removing index 1 shifts following array elements. For a queue, consider tracking a head index.")
         end
      end,
   },
   {
      id = "luajit/string-accumulation-in-loop", severity = "hint", in_loop = true,
      description = "Find string accumulators that copy the growing prefix on each iteration.", kinds = {"assignment"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if #n.vars ~= 1 or #n.exps ~= 1 then return end
         local dst, value = n.vars[1], model.unwrap(n.exps[1])
         if dst.kind ~= "variable" or not value.op or value.op.op ~= ".." or value.op.meta_on_operand then return end
         local left = model.unwrap(value.e1)
         if left.kind == "variable" and left.tk == dst.tk then
            s:emit(value, "Appending to a growing string repeatedly copies the prefix. Collect fragments and join them once with table.concat.")
         end
      end,
   },
   {
      id = "luajit/hot-string-pattern-method", severity = "hint", in_loop = true,
      description = "Find repeated pattern operations written as string method calls.", kinds = {"op"}, operators = {"@funcall"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local callee = n.e1
         if callee.op and callee.op.op == ":" and callee.receiver and
            (callee.receiver.typename == "string" or callee.receiver.typename == "enum") then
            local member = callee.e2.tk
            if member == "find" and uses_pattern(n.e2[1], n.e2[3]) then
               s:emit(callee.e2, pattern_message)
            elseif member == "match" or member == "gmatch" or member == "gsub" then
               s:emit(callee.e2, "This string pattern operation runs inside a loop. Profile it and hoist invariant work where possible.")
            end
         end
      end,
   },
}

return rules
