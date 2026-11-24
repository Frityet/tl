--#pragma strict on
local type parser = require("teal.parser")
local parse = require("teal.parser").parse
local decode_string = require("teal.gen.c_ffi").decode_string
local type Node = parser.Node

local record c_bootstrap
   generate: function(string, string, string): string | nil, string | nil
end

local record Slot
   table_index: string
   index: integer
end

local record Frame
   locals: integer
   parameters: integer
   temporary: integer
   indent: integer
   lines: {string}
   captures: {Slot}
   capture_names: {string:Slot}
end

local record Program
   functions: {string}
   next_function: integer
end

local record Scope
   program: Program
   frame: Frame
   parent: Scope | nil
   locals: {string:Slot}
end

local function child(s: Scope): Scope
   return { program = s.program, frame = s.frame, parent = s, locals = {} }
end

local function line(s: Scope, code: string)
   local f = s.frame
   table.insert(f.lines, ("   "):rep(f.indent) .. code)
end

local function open_block(s: Scope, prefix?: string)
   line(s, (prefix and prefix .. " " or "") .. "{")
   s.frame.indent = s.frame.indent + 1
end

local function close_block(s: Scope)
   s.frame.indent = s.frame.indent - 1
   line(s, "}")
end

local function save_top(s: Scope): string
   local f = s.frame
   f.temporary = f.temporary + 1
   local name = "top" .. tostring(f.temporary)
   line(s, "int " .. name .. " = tl_gettop(L);")
   return name
end

local function reset_top(s: Scope, top: string)
   line(s, "tl_settop(L, " .. top .. ");")
end

local function fail(n: Node, problem: string)
   error(("%s:%d:%d: C bootstrap: %s"):format(n.f or "<input>", n.y, n.x, problem), 0)
end

local function c_string(value: string): string
   return '"' .. value:gsub(
      '[%z\1-\31\127-\255"\\?]', function(c: string): string
         local byte = c:byte()
         if byte is nil then return "" end
         return ("\\%03o"):format(byte)
      end) .. '"'
end

local function push_string(s: Scope, value: string)
   line(s, ("tl_pushliteral(L, %s, %d);"):format(c_string(value), #value))
end

local function new_slot(s: Scope, name: string, value: string)
   s.frame.locals = s.frame.locals + 1
   local slot: Slot = { table_index = "frame", index = s.frame.locals }
   s.locals[name] = slot
   line(s, ("tl_local(L, frame, %d, %s);"):format(slot.index, value))
end

local function resolve(s: Scope, name: string): Slot
   local slot = s.locals[name]
   local parent = s.parent
   if slot or not parent then
      return slot
   end
   if s.frame == parent.frame then
      return resolve(parent, name)
   end
   local f = s.frame
   slot = f.capture_names[name]
   if not slot then
      local outer = resolve(parent, name)
      if outer then
         table.insert(f.captures, outer)
         slot = { table_index = "TL_CAPTURES", index = #f.captures }
         f.capture_names[name] = slot
      end
   end
   return slot
end

local function get_slot(s: Scope, name: string)
   local slot = resolve(s, name)
   if slot then
      line(s, ("tl_get(L, %s, %d);"):format(slot.table_index, slot.index))
   else
      line(s, ("tl_getliteral(L, TL_GLOBALS, %s, %d);"):format(c_string(name), #name))
   end
end

local function set_slot(s: Scope, name: string, value: string)
   local slot = resolve(s, name)
   if slot then
      line(s, ("tl_set(L, %s, %d, %s);"):format(slot.table_index, slot.index, value))
   else
      line(s, "tl_pushvalue(L, " .. value .. ");")
      line(s, ("tl_setliteral(L, TL_GLOBALS, %s, %d);"):format(c_string(name), #name))
   end
end

local record emit
   expr: function(Scope, Node, integer)
   statements: function(Scope, Node)
   closure: function(Scope, Node)
end

local function emit_list(s: Scope, nodes: Node, wanted: integer)
   local count = nodes and #nodes or 0
   for i = 1, count do
      local n = wanted < 0 and -1 or math.max(0, wanted - i + 1)
      if i < count then n = n == 0 and 0 or 1 end
      emit.expr(s, nodes[i], n)
   end
   if count == 0 then
      for _ = 1, wanted do line(s, "tl_pushnil(L);") end
   end
end

local function emit_call(s: Scope, node: Node, wanted: integer)
   open_block(s)
   local top = save_top(s)
   local callee = node.e1
   if callee.op and callee.op.op == ":" then
      emit.expr(s, callee.e1, 1)
      line(s, ("tl_getliteral(L, -1, %s, %d);"):format(c_string(callee.e2.tk), #callee.e2.tk))
      line(s, "tl_insert(L, -2);")
   else
      emit.expr(s, callee, 1)
   end
   emit_list(s, node.e2, -1)
   line(s, ("tl_call(L, tl_gettop(L) - %s - 1, %d);"):format(top, wanted))
   close_block(s)
end

local operations: {string:string} = {
   ["+"] = "TL_ADD", ["-"] = "TL_SUB", ["*"] = "TL_MUL",
   ["/"] = "TL_DIV", ["%"] = "TL_MOD", ["^"] = "TL_POW",
   ["=="] = "TL_EQ", ["~="] = "TL_NE", ["<"] = "TL_LT",
   ["<="] = "TL_LE", [">"] = "TL_GT", [">="] = "TL_GE",
   ["#"] = "TL_LEN",
}

local function emit_op(s: Scope, n: Node)
   local op = n.op.op
   emit.expr(s, n.e1, 1)
   if op == "." then
      line(s, ("tl_getliteral(L, -1, %s, %d);"):format(c_string(n.e2.tk), #n.e2.tk))
      line(s, "tl_remove(L, -2);")
   elseif op == "@index" then
      emit.expr(s, n.e2, 1)
      line(s, "tl_gettable(L, -2);")
      line(s, "tl_remove(L, -2);")
   elseif op == "and" or op == "or" then
      open_block(s, ("if (%stl_toboolean(L, -1))"):format(op == "or" and "!" or ""))
      line(s, "tl_pop(L, 1);")
      emit.expr(s, n.e2, 1)
      close_block(s)
   elseif op == ".." then
      emit.expr(s, n.e2, 1)
      line(s, "tl_concat(L, 2);")
   elseif op == "not" then
      line(s, "tl_pushboolean(L, !tl_test(L));")
   elseif operations[op] then
      local operation = operations[op]
      if n.op.arity == 2 then
         emit.expr(s, n.e2, 1)
      elseif op == "-" then
         operation = "TL_NEG"
      end
      line(s, ("tl_op(L, %s, %d);"):format(operation, n.op.arity))
   else
      fail(n, "unsupported operator " .. op)
   end
end

local function emit_table(s: Scope, n: Node)
   if #n == 0 then
      line(s, "tl_newtable(L);")
      return
   end
   open_block(s)
   local top = save_top(s)
   line(s, "tl_newtable(L);")
   for i, item in ipairs(n) do
      if i == #n and item.key_parsed == "implicit" then
         emit.expr(s, item.value, -1)
         line(s, ("tl_array_tail(L, %s + 1, %s);"):format(top, item.key.tk))
      else
         emit.expr(s, item.key, 1)
         emit.expr(s, item.value, 1)
         line(s, "tl_rawset(L, " .. top .. " + 1);")
      end
   end
   close_block(s)
end

function emit.expr(s: Scope, n: Node, wanted: integer)
   if n.kind == "op" and n.op.op == "@funcall" then
      emit_call(s, n, wanted)
      return
   elseif n.kind == "..." then
      line(s, ("tl_vararg(L, argc, %d, %d);"):format(s.frame.parameters, wanted))
      return
   end

   if n.kind == "variable" or n.kind == "identifier" or n.kind == "type_identifier" then
      get_slot(s, n.tk)
   elseif n.kind == "nil" then
      line(s, "tl_pushnil(L);")
   elseif n.kind == "boolean" then
      line(s, "tl_pushboolean(L, " .. (n.tk == "true" and "1" or "0") .. ");")
   elseif n.kind == "integer" or n.kind == "number" then
      if n.luajit_literal or not n.constnum then fail(n, "unsupported numeric literal " .. n.tk) end
      local value = n.constnum
      local expression = value == math.huge and "HUGE_VAL" or ("%.17g"):format(value)
      line(s, "tl_pushnumber(L, " .. expression .. ");")
   elseif n.kind == "string" then
      local value, problem = decode_string(n.tk)
      if not value then fail(n, problem) end
      push_string(s, value)
   elseif n.kind == "paren" then
      emit.expr(s, n.e1, 1)
   elseif n.kind == "literal_table" then
      emit_table(s, n)
   elseif n.kind == "function" then
      emit.closure(s, n)
   elseif n.kind == "op" then
      emit_op(s, n)
   else
      fail(n, "unsupported expression " .. n.kind)
   end

   if wanted == 0 then
      line(s, "tl_pop(L, 1);")
   else
      for _ = 2, wanted do line(s, "tl_pushnil(L);") end
   end
end

local function emit_branch(s: Scope, branches: {Node}, i: integer)
   local branch = branches[i]
   if branch.exp then
      emit.expr(s, branch.exp, 1)
      open_block(s, "if (tl_test(L))")
   else
      open_block(s)
   end
   emit.statements(child(s), branch.body)
   close_block(s)
   if branches[i + 1] then
      open_block(s, "else")
      emit_branch(s, branches, i + 1)
      close_block(s)
   end
end

local function emit_fornum(s: Scope, n: Node)
   open_block(s)
   emit.expr(s, n.from, 1)
   emit.expr(s, n.to, 1)
   if n.step then
      emit.expr(s, n.step, 1)
   else
      line(s, "tl_pushinteger(L, 1);")
   end
   line(s, "double initial = tl_checknumber(L, -3);")
   line(s, "double limit = tl_checknumber(L, -2);")
   line(s, "double step = tl_checknumber(L, -1);")
   line(s, "tl_pop(L, 3);")
   open_block(s, "for (double i = initial; step >= 0 ? i <= limit : i >= limit; i += step)")
   local loop = child(s)
   line(s, "tl_pushnumber(L, i);")
   new_slot(loop, n.var.tk, "-1")
   line(s, "tl_pop(L, 1);")
   emit.statements(loop, n.body)
   close_block(s)
   close_block(s)
end

local function emit_forin(s: Scope, n: Node)
   open_block(s)
   local top = save_top(s)
   emit_list(s, n.exps, 3)
   open_block(s, "for (;;)")
   for i = 1, 3 do line(s, ("tl_pushvalue(L, %s + %d);"):format(top, i)) end
   line(s, ("tl_call(L, 2, %d);"):format(#n.vars))
   line(s, ("if (tl_isnil(L, %s + 4)) break;"):format(top))
   line(s, "tl_pushvalue(L, " .. top .. " + 4);")
   line(s, "tl_replace(L, " .. top .. " + 3);")
   local loop = child(s)
   for i, var in ipairs(n.vars) do
      new_slot(loop, var.tk, ("%s + %d"):format(top, i + 3))
   end
   reset_top(s, top .. " + 3")
   emit.statements(loop, n.body)
   close_block(s)
   reset_top(s, top)
   close_block(s)
end

local function emit_assignment(s: Scope, n: Node)
   open_block(s)
   local start = save_top(s)
   local indices: {integer:integer} = {}
   local keys = 0
   if n.kind == "assignment" then
      for i, var in ipairs(n.vars) do
         if var.kind == "op" then
            emit.expr(s, var.e1, 1)
            if var.op.op == "." then
               push_string(s, var.e2.tk)
            else
               emit.expr(s, var.e2, 1)
            end
            indices[i] = keys + 1
            keys = keys + 2
         end
      end
   end
   emit_list(s, n.exps, #n.vars)
   if n.kind == "local_declaration" then
      for i, var in ipairs(n.vars) do
         new_slot(s, var.tk, ("%s + %d"):format(start, i))
      end
   else
      for i = #n.vars, 1, -1 do
         local var = n.vars[i]
         local value = ("%s + %d"):format(start, keys + i)
         local index = indices[i]
         if index then
            line(s, ("tl_pushvalue(L, %s + %d);"):format(start, index + 1))
            line(s, ("tl_pushvalue(L, %s);"):format(value))
            line(s, ("tl_settable(L, %s + %d);"):format(start, index))
         else
            set_slot(s, var.tk, value)
         end
      end
   end
   reset_top(s, start)
   close_block(s)
end

local function emit_statement(s: Scope, n: Node)
   local kind = n.kind
   if kind == "local_declaration" or kind == "assignment" then
      emit_assignment(s, n)
   elseif kind == "local_function" or kind == "global_function" then
      if kind == "local_function" then new_slot(s, n.name.tk, "0") end
      emit.closure(s, n)
      set_slot(s, n.name.tk, "-1")
      line(s, "tl_pop(L, 1);")
   elseif kind == "record_function" then
      emit.expr(s, n.fn_owner, 1)
      emit.closure(s, n)
      line(s, ("tl_setliteral(L, -2, %s, %d);"):format(c_string(n.name.tk), #n.name.tk))
      line(s, "tl_pop(L, 1);")
   elseif kind == "op" then
      emit.expr(s, n, 0)
   elseif kind == "return" then
      open_block(s)
      local start = save_top(s)
      emit_list(s, n.exps, -1)
      line(s, "return tl_gettop(L) - " .. start .. ";")
      close_block(s)
   elseif kind == "do" then
      open_block(s)
      emit.statements(child(s), n.body)
      close_block(s)
   elseif kind == "if" then
      emit_branch(s, n.if_blocks, 1)
   elseif kind == "while" or kind == "repeat" then
      open_block(s, "for (;;)")
      local loop = child(s)
      if kind == "while" then
         emit.expr(s, n.exp, 1)
         line(s, "if (!tl_test(L)) break;")
      end
      emit.statements(loop, n.body)
      if kind == "repeat" then
         emit.expr(loop, n.exp, 1)
         line(s, "if (tl_test(L)) break;")
      end
      close_block(s)
   elseif kind == "fornum" then
      emit_fornum(s, n)
   elseif kind == "forin" then
      emit_forin(s, n)
   elseif kind == "break" then
      line(s, "break;")
   else
      fail(n, "unsupported statement " .. kind)
   end
end

function emit.statements(s: Scope, body: Node)
   for _, n in ipairs(body) do emit_statement(s, n) end
end

local function compile_function(p: Program, parent: Scope | nil, body: Node, args: Node | nil): string, Frame
   p.next_function = p.next_function + 1
   local id = p.next_function
   local f: Frame = {
      locals = 0, parameters = 0, temporary = 0, indent = 1,
      lines = {}, captures = {}, capture_names = {},
   }
   local s: Scope = { program = p, frame = f, parent = parent, locals = {} }
   for i, parameter in ipairs(args or {}) do
      if parameter.tk ~= "..." then
         f.parameters = i
         new_slot(s, parameter.tk, ("%d <= argc ? %d : 0"):format(i, i))
      end
   end
   emit.statements(s, body)
   line(s, "return 0;")
   local name = id == 1 and "TL_MODULE" or ("tl_fn_%d"):format(id)
   table.insert(p.functions, ("%sint %s(tl_State *L) {\n"):format(id == 1 and "" or "static ", name) ..
      "   int argc = tl_gettop(L);\n" ..
      "   int frame = argc + 1;\n" ..
      ("   tl_frame(L, %d);\n"):format(f.locals) ..
      "   (void)frame;\n" ..
      table.concat(f.lines, "\n") .. "\n}\n")
   return name, f
end

function emit.closure(s: Scope, n: Node)
   local name, f = compile_function(s.program, s, n.body, n.args)
   if #f.captures == 0 then
      line(s, ("tl_pushcfunction(L, %s);"):format(name))
      return
   end
   line(s, ("tl_createtable(L, %d, 0);"):format(#f.captures))
   for i, slot in ipairs(f.captures) do
      line(s, ("tl_capture(L, %s, %d);"):format(slot.table_index, slot.index))
      line(s, ("tl_rawseti(L, -2, %d);"):format(i))
   end
   line(s, ("tl_pushcclosure(L, %s, 1);"):format(name))
end

function c_bootstrap.generate(source: string, filename: string, symbol: string): string | nil, string | nil
   assert(symbol:match("^[%a_][%w_]*$"))
   local ast, errors = parse(source, filename, "lua")
   if #errors > 0 then
      local first = errors[1]
      return nil, ("%s:%d:%d: C bootstrap: %s"):format(filename, first.y, first.x, first.msg)
   end
   if not (ast is Node) then return nil, filename .. ": missing Lua syntax tree" end
   local p: Program = { functions = {}, next_function = 0 }
   local ok, problem = pcall(compile_function, p, nil, ast, nil)
   if not ok then return nil, tostring(problem) end
   return "#define TL_MODULE " .. symbol .. '\n#include "tl_runtime.h"\n\n' ..
      table.concat(p.functions, "\n")
end

return c_bootstrap
