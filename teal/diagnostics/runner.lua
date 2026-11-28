local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local model = require("teal.diagnostics.model")
local environment = require("teal.environment")
local util = require("teal.util")












local State = model.State

local runner = {}


local runtime_globals = {
   bit = true, jit = true, newproxy = true, gcinfo = true,
}
local legacy_globals = { setfenv = true, getfenv = true, loadstring = true, unpack = true }

local required_modules = {
   ffi = true, bit = true, jit = true, ["jit.opt"] = true,
   coroutine = true, debug = true, io = true, math = true, os = true,
   package = true, string = true, table = true, ["table.new"] = true, utf8 = true,
}

local function member_name(node)
   if node.op.op == "." then return node.e2.tk end
   if node.op.op == "@index" then
      local key = model.unwrap(node.e2)
      if key and key.kind == "string" and not key.conststr:find(".", 1, true) then
         return key.conststr
      end
   end
end

local function call_origin(state, n)
   local args = n.e2
   local name = #args == 1 and model.unwrap(args[1])
   if name and name.kind == "string" and required_modules[name.conststr] and state:path(n.e1) == "require" then
      return name.conststr
   end
   if state.ffi_origins and args[1] then
      local path = state:path(n.e1)
      if path == "ffi.load" then return "ffi.load()" end
      if path == "ffi.cast" then
         local value = model.unwrap(args[2])
         if value and value.kind == "function" then return "ffi.callback()" end
      end
   end
end

function State:path(node)
   node = model.unwrap(node)
   if not node then return nil end
   local path = self.paths[node]
   if not path and node.op then
      if node.op.op == "@funcall" then
         path = call_origin(self, node)
      else
         local field = member_name(node)
         if field then
            local owner = self:path(node.e1)
            if owner == "ffi.load()" and model.call_args(node.e1) then
               owner = "ffi.temporary()"
            end
            path = owner and (owner .. "." .. field)
         end
      end
   end
   if path and not self.modified_paths[path] then return path end
end

local function source_site(node)
   if not node.op or node.op.op ~= "@funcall" then return node end
   local callee = model.unwrap(node.e1)
   if callee and callee.op then
      local op = callee.op.op
      if op == "." or op == ":" or op == "@index" then return callee.e2 end
   end
   return callee or node
end

function State:emit(node, message)
   node = source_site(node)
   if node.f ~= self.filename or not node.y or not node.x then return end
   local finding = {
      filename = node.f,
      y = node.y,
      x = node.x,
      msg = message,
      code = self.current_rule.id,
      severity = self.current_rule.severity,
   }
   if node.kind == "string" and node.tk and node.tk:find("\n", 1, true) then
      local line, last = node.y, 0
      for pos in node.tk:gmatch("()\n") do
         line, last = line + 1, pos
      end
      finding.end_y, finding.end_x = line, #node.tk - last + 1
   elseif node.yend and node.xend and (node.yend > node.y or (node.yend == node.y and node.xend >= node.x)) then
      finding.end_y, finding.end_x = node.yend, node.xend + 1
   elseif node.op and node.op.op:sub(1, 1) ~= "@" then
      finding.end_y, finding.end_x = node.y, node.x + #node.op.op + (node.safe_navigation and 1 or 0)
   end
   self.results[#self.results + 1] = finding
end

local state_mt = { __index = State }

local function lexical_binding(ctx, name)
   for i = #ctx.st, 1, -1 do
      local var = ctx.st[i].vars[name]
      if var and (not var.is_specialized or var.is_specialized == "localizing") then return var end
   end
end

local function has_local_environment(ctx, state)
   if state.target == "5.1" or state.target == "luajit" then return false end
   return lexical_binding(ctx, "_ENV") ~= nil
end

local function bind_paths(ctx, state, hooks)
   local aliases = {}
   local alias_names = {}
   local writes = {}
   local stdlib = not ctx.env.opts.no_stdlib and environment.stdlib_globals or {}

   local variable = hooks["variable"]
   local after_variable = variable.after
   variable.after = function(c, n, children)
      local t = after_variable(c, n, children)
      local name = n.tk
      local builtin = stdlib[name]
      local runtime_global = (state.target == "luajit" and runtime_globals[name]) or
      ((state.is_lua or state.target == "luajit") and legacy_globals[name])
      if builtin or runtime_global or alias_names[name] then
         local var = lexical_binding(c, name)
         local declared = var and var.declared_at
         if declared and aliases[declared] then
            state.paths[n] = aliases[declared]
            if n.is_lvalue then writes[n] = declared end
         elseif ((builtin and var == builtin) or (runtime_global and not var)) and not has_local_environment(c, state) then
            state.paths[n] = name
         end
      end
      return t
   end

   local declaration = hooks["local_declaration"]
   local after_declaration = declaration.after
   declaration.after = function(c, n, children)
      local t = after_declaration(c, n, children)
      for i, value in ipairs(n.exps or {}) do
         local var = n.vars[i]
         if not var then break end
         if var.kind == "identifier" then
            local path = state:path(value)
            if path then
               aliases[var] = path
               alias_names[var.tk] = true
            end
         end
      end
      return t
   end

   local assignment = hooks["assignment"]
   local after_assignment = assignment.after
   assignment.after = function(c, n, children)
      local t = after_assignment(c, n, children)
      for _, dest in ipairs(n.vars) do
         local declared = writes[dest]
         if declared then
            aliases[declared], writes[dest] = nil, nil
         else
            local path = state:path(dest)
            if path then state.modified_paths[path] = true end
         end
      end
      return t
   end
end

local function run_rules(state, rules, n, t, children)
   for _, rule in ipairs(rules) do
      if (not rule.in_loop or state.loop_depth > 0) and not (state.is_lua and rule.teal_only) then
         state.current_rule = rule
         rule.check(state, n, t, children)
      end
   end
end

local function patch_rule_hook(callbacks, kind, plan, state)
   local by_kind = plan.by_kind[kind]
   local by_call = next(plan.by_call) and plan.by_call
   local by_hot_call = next(plan.by_hot_call) and plan.by_hot_call
   local c_symbols, hot_c_symbols = plan.c_symbols, plan.hot_c_symbols
   local after = callbacks.after
   callbacks.after = function(c, n, children)
      local t = after and after(c, n, children)
      state.strict_nil = c.feat_strict_nil
      if by_kind then run_rules(state, by_kind, n, t, children) end
      if kind == "op" and n.op then
         local op = n.op.op
         local operators = plan.by_operator[op]
         if operators then run_rules(state, operators, n, t, children) end
         if op == "@funcall" then
            local hot = state.loop_depth > 0
            if by_call or c_symbols or (hot and (by_hot_call or hot_c_symbols)) then
               local path = state:path(n.e1)
               local calls = by_call and by_call[path]
               local hot_calls = hot and by_hot_call and by_hot_call[path]
               local symbol = (c_symbols or (hot and hot_c_symbols)) and model.ffi_symbol(path)
               if calls or hot_calls or symbol then
                  state.called_path = path
               end
               if calls then run_rules(state, calls, n, t, children) end
               if hot_calls then run_rules(state, hot_calls, n, t, children) end
               if symbol then
                  if c_symbols then run_rules(state, c_symbols, n, t, children) end
                  if hot and hot_c_symbols then run_rules(state, hot_c_symbols, n, t, children) end
               end
            end
         end
      end
      return t
   end
end

local whole_loop = { ["while"] = true, ["repeat"] = true }
local loop_body = { ["forin"] = true, ["fornum"] = true }
local function_body = {
   ["function"] = true, ["local_function"] = true, ["global_function"] = true, ["record_function"] = true,
}

local function track_scopes(hooks, state)
   local loop_stack = {}
   for kind in pairs(whole_loop) do
      local callbacks = hooks[kind]
      local before = callbacks.before
      callbacks.before = function(c, n)
         state.loop_depth = state.loop_depth + 1
         if before then before(c, n) end
      end
   end
   for kind in pairs(loop_body) do
      local callbacks = hooks[kind]
      local before_statements = callbacks.before_statements
      callbacks.before_statements = function(c, n, children)
         state.loop_depth = state.loop_depth + 1
         before_statements(c, n, children)
      end
   end
   for kind in pairs(function_body) do
      local callbacks = hooks[kind]
      local before_statements = callbacks.before_statements
      callbacks.before_statements = function(c, n, children)
         local depth = state.function_depth + 1
         loop_stack[depth] = state.loop_depth
         state.function_depth, state.loop_depth = depth, 0
         if before_statements then before_statements(c, n, children) end
      end
   end
   for kind, callbacks in pairs(hooks) do
      local after = callbacks.after
      if whole_loop[kind] or loop_body[kind] then
         callbacks.after = function(c, n, children)
            state.loop_depth = state.loop_depth - 1
            return after(c, n, children)
         end
      elseif function_body[kind] then
         callbacks.after = function(c, n, children)
            local depth = state.function_depth
            state.loop_depth, state.function_depth = loop_stack[depth], depth - 1
            return after(c, n, children)
         end
      end
   end
end

function runner.attach(ctx, visitor)
   local plan = ctx.env.diagnostics_plan
   local opts = ctx.env.opts
   local gen_target = opts.gen_target or environment.DEFAULT_GEN_TARGET
   local state = setmetatable({
      target = opts.diagnostic_target or gen_target,
      is_lua = ctx.feat_lax,
      strict_nil = ctx.feat_strict_nil,
      loop_depth = 0,
      function_depth = 0,
      filename = ctx.filename,
      results = {},
      paths = {},
      modified_paths = {},
      ffi_origins = plan.ffi_origins,
   }, state_mt)

   local cbs = util.shallow_copy_table(visitor.cbs)
   local hooks = {}
   local uses_operators = next(plan.by_operator) ~= nil or next(plan.by_call) ~= nil or next(plan.by_hot_call) ~= nil or
   plan.c_symbols ~= nil or plan.hot_c_symbols ~= nil
   for kind, callbacks in pairs(cbs) do
      local has_rules = plan.by_kind[kind] ~= nil or (kind == "op" and uses_operators)
      local has_binding = plan.bindings and (kind == "variable" or kind == "local_declaration" or kind == "assignment")
      local tracks_scope = plan.track_loops and (whole_loop[kind] or loop_body[kind] or function_body[kind])
      if has_rules or has_binding or tracks_scope then
         local hook = util.shallow_copy_table(callbacks)
         hooks[kind], cbs[kind] = hook, hook
         if has_rules then patch_rule_hook(hook, kind, plan, state) end
      end
   end
   if plan.bindings then bind_paths(ctx, state, hooks) end
   if plan.track_loops then track_scopes(hooks, state) end

   local patched = util.shallow_copy_table(visitor)
   patched.cbs = cbs
   return patched, state
end

local function compare(a, b)
   if a.y ~= b.y then return a.y < b.y end
   if a.x ~= b.x then return a.x < b.x end
   if a.code ~= b.code then return a.code < b.code end
   return a.msg < b.msg
end

function runner.finish(state)
   local results = state.results
   if #results > 1 then
      table.sort(results, compare)
      local count = 1
      for i = 2, #results do
         if compare(results[count], results[i]) then
            count = count + 1
            results[count] = results[i]
         end
      end
      for i = #results, count + 1, -1 do results[i] = nil end
   end
   return results
end

return runner
