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

local pattern_message = "The recorder handles literal string.find searches. Lua patterns use the interpreter. Use true for a literal search. If the input stays the same, do the search before the loop."

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
      "LuaJIT can stitch a trace across string.match. For a literal search, use string.find(s, needle, 1, true). Measure the effect."),
   hot_call("luajit/hot-string-gmatch", "string.gmatch",
      "Find repeated pattern iterator creation inside loops.",
      "string.gmatch makes a pattern iterator. Move it before the loop if the iteration behavior stays correct."),
   hot_call("luajit/hot-string-gsub", "string.gsub",
      "Find substitutions inside loops that may be expensive.",
      "string.gsub makes a string with the replacement text. Profile the loop before you change it."),
   hot_call("luajit/hot-string-dump", "string.dump",
      "Find repeated function serialization inside loops.",
      "string.dump serializes a function. Cache the result if it stays valid."),
   hot_call("luajit/hot-load", "load",
      "Find repeated compilation of source inside loops.",
      "load compiles a chunk at runtime. Compile it before the loop if the source does not change."),
   hot_call("luajit/hot-loadstring", "loadstring",
      "Find repeated compilation of strings inside loops.",
      "loadstring compiles a chunk at runtime. Compile it before the loop if the source does not change."),
   hot_call("luajit/hot-loadfile", "loadfile",
      "Find repeated loading and compilation of files inside loops.",
      "loadfile reads and compiles a chunk. Load it before the loop if the file does not change."),
   hot_call("luajit/hot-dofile", "dofile",
      "Find repeated loading and execution of files inside loops.",
      "dofile loads and executes a file on each iteration. Check if each execution is necessary."),
   hot_call("luajit/hot-collectgarbage", "collectgarbage",
      "Find explicit garbage collector operations inside loops.",
      "collectgarbage can change GC scheduling. Measure the effect before you change GC settings or force collection."),
   hot_call("luajit/hot-setfenv", "setfenv",
      "Find environment mutation inside loops.",
      "setfenv changes a function environment and can interrupt a trace. Move setup before the loop if it does not change."),
   hot_call("luajit/hot-newproxy", "newproxy",
      "Find repeated proxy allocations inside loops.",
      "newproxy allocates userdata. Repeated allocations can increase GC pressure."),
   hot_call("luajit/hot-print", "print",
      "Find console output inside loops.",
      "print writes output on each iteration. If profiling shows a high cost, buffer the output or write less often."),
   hot_call("luajit/hot-coroutine-create", "coroutine.create",
      "Find repeated coroutine creation inside loops.",
      "coroutine.create allocates a coroutine. Reuse workers if their lifetime permits it."),
   hot_call("luajit/hot-coroutine-wrap", "coroutine.wrap",
      "Find repeated wrapped coroutine creation inside loops.",
      "coroutine.wrap creates a coroutine and a wrapper. Reuse workers if their lifetime permits it."),
   hot_call("luajit/hot-table-new", "table.new",
      "Find repeated allocation of presized tables in loops.",
      "table.new still allocates a table each iteration. If GC profiling shows pressure, reuse the table. Make sure its lifetime and aliases permit reuse."),
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
            s:emit(n, "The ordinary select recorder requires a constant numeric index. LuaJIT has a separate guarded path for single-result select(index, ...). If you need one result, pack the values before the loop. Then index the pack.")
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
            s:emit(n, "LuaJIT specializes the result count. It guards variable bounds, including the default table length. Changed bounds can exit the trace. Keep the range fixed if possible. Or process the table directly.")
         elseif first and last - first >= 16 then
            s:emit(n, "LuaJIT records each unpacked element separately. A large fixed range can grow the trace and hit its slot limit. Process the table directly if possible.")
         end
      end,
   },
   {
      id = "luajit/getfenv-recorder", severity = "hint", in_loop = true,
      description = "Find getfenv forms unsupported by the LuaJIT recorder.",
      kinds = {"op"}, bindings = true, calls = {"getfenv"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if #n.e2 == 0 or model.number(n.e2[1]) ~= 0 then
            s:emit(n, "LuaJIT's getfenv recorder supports only the constant getfenv(0) form. Cache the environment before the loop if it cannot change.")
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
         s:emit(n, "This call runs in the interpreter. LuaJIT may stitch the trace across it. Move inspection or setup before the loop if it does not change. Check the path with a profile.")
      end,
   },
   {
      id = "luajit/table-insert-position", severity = "hint", in_loop = true,
      description = "Find positioned inserts that the LuaJIT table.insert recorder cannot handle.",
      kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         if #n.e2 == 3 then
            s:emit(n, "LuaJIT records the two-argument append. A positioned insert takes the interpreter path. For an append, use table.insert(t, value).")
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
            s:emit(n, "LuaJIT's tonumber recorder accepts an omitted base or constant base 10. Move conversion before the loop if its inputs do not change. Or group inputs by conversion path.")
         end
      end,
   },
   {
      id = "luajit/jit-off-in-loop", severity = "warning", in_loop = true,
      description = "Find repeated JIT disabling in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.off"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, "jit.off changes JIT state on each iteration. Set the JIT state before the loop if possible.")
      end,
   },
   {
      id = "luajit/jit-flush-in-loop", severity = "warning", in_loop = true,
      description = "Find repeated trace flushing in a loop.", kinds = {"op"}, bindings = true, calls = {"jit.flush"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         s:emit(n, "jit.flush removes compiled traces. Each flush can make LuaJIT compile the same trace again. Move jit.flush before the loop.")
      end,
   },
   {
      id = "luajit/table-insert-front", severity = "hint", in_loop = true,
      description = "Find insertions at the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.insert"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = n.e2
         if #args == 3 and model.number(args[2]) == 1 then
            s:emit(n, "Inserting at index 1 shifts existing array elements. For large sequences, append and reverse the elements. Or use a deque.")
         end
      end,
   },
   {
      id = "luajit/table-remove-front", severity = "hint", in_loop = true,
      description = "Find removals from the front of a table inside loops.", kinds = {"op"}, bindings = true, calls = {"table.remove"},
      check = function(s: State, n: Node, _t: Type, _children: {Type})
         local args = n.e2
         if #args == 2 and model.number(args[2]) == 1 then
            s:emit(n, "Removing index 1 shifts following array elements. For a queue, track a head index.")
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
            s:emit(value, "Each append copies the growing string. Collect the fragments. Join them once with table.concat.")
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
               s:emit(callee.e2, "This string pattern operation runs inside a loop. Profile it. Move work before the loop if its inputs do not change.")
            end
         end
      end,
   },
}

return rules
