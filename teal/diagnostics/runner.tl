--#pragma strict_nil off
local model = require("teal.diagnostics.model")
local environment = require("teal.environment")
local util = require("teal.util")
local type ast = require("teal.ast")
local type context = require("teal.check.context")
local type errors = require("teal.errors")
local type traversal = require("teal.traversal")
local type variables = require("teal.variables")

local type Context = context.Context
local type Node = model.Node
local type NodeKind = ast.NodeKind
local type Type = model.Type
local type Visitor = traversal.Visitor
local type Callbacks = traversal.VisitorCallbacks
local State = model.State

local record runner
end

local runtime_globals: {string: boolean} = {
   bit = true, jit = true, newproxy = true,
}
local legacy_globals: {string: boolean} = { setfenv = true, getfenv = true, loadstring = true, unpack = true }

local required_modules: {string: boolean} = {
   ffi = true, bit = true, jit = true, ["jit.opt"] = true,
   coroutine = true, debug = true, io = true, math = true, os = true,
   package = true, string = true, table = true, utf8 = true,
}

local function member_name(node: Node): string
   if node.op.op == "." then return node.e2.tk end
   if node.op.op == "@index" then
      local key = model.unwrap(node.e2)
      if key and key.kind == "string" and not key.conststr:find(".", 1, true) then
         return key.conststr
      end
   end
end

local function required_module(state: State, n: Node): string
   local args = n.e2
   local name = #args == 1 and model.unwrap(args[1])
   if name and name.kind == "string" and required_modules[name.conststr] and state:path(n.e1) == "require" then
      return name.conststr
   end
end

function State:path(node: Node): string
   node = model.unwrap(node)
   if not node then return nil end
   local path = self.paths[node]
   if not path and node.op then
      if node.op.op == "@funcall" then
         path = required_module(self, node)
      else
         local field = member_name(node)
         if field then
            local owner = self:path(node.e1)
            path = owner and (owner .. "." .. field)
         end
      end
   end
   if path and not self.modified_paths[path] then return path end
end

local function source_site(node: Node): Node
   if not node.op or node.op.op ~= "@funcall" then return node end
   local callee = model.unwrap(node.e1)
   if callee and callee.op then
      local op = callee.op.op
      if op == "." or op == ":" or op == "@index" then return callee.e2 end
   end
   return callee or node
end

function State:emit(node: Node, message: string)
   node = source_site(node)
   if node.f ~= self.filename or not node.y or not node.x then return end
   local finding: errors.Error = {
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

local state_mt: metatable<State> = { __index = State }

local function lexical_binding(ctx: Context, name: string): variables.Variable
   for i = #ctx.st, 1, -1 do
      local var = ctx.st[i].vars[name]
      if var and (not var.is_specialized or var.is_specialized == "localizing") then return var end
   end
end

local function has_local_environment(ctx: Context, state: State): boolean
   if state.target == "5.1" or state.target == "luajit" then return false end
   return lexical_binding(ctx, "_ENV") ~= nil
end

local function bind_paths(ctx: Context, state: State, hooks: {NodeKind: Callbacks<Context, Node, Type>})
   local aliases: {Node: string} = {}
   local alias_names: {string: boolean} = {}
   local writes: {Node: Node} = {}
   local stdlib = not ctx.env.opts.no_stdlib and environment.stdlib_globals or {}

   local variable = hooks["variable"]
   local after_variable = variable.after
   variable.after = function(c: Context, n: Node, children: {Type}): Type
      local t = after_variable(c, n, children)
      local name = n.tk
      local builtin = stdlib[name]
      local runtime_global = (state.target == "luajit" and runtime_globals[name])
         or ((state.is_lua or state.target == "luajit") and legacy_globals[name])
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
   declaration.after = function(c: Context, n: Node, children: {Type}): Type
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
   assignment.after = function(c: Context, n: Node, children: {Type}): Type
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

local function run_rules(state: State, rules: {model.EnabledRule}, n: Node, t: Type, children: {Type})
   for _, rule in ipairs(rules) do
      if not (state.is_lua and rule.teal_only) then
         state.current_rule = rule
         rule.check(state, n, t, children)
      end
   end
end

local function patch_rule_hook(callbacks: Callbacks<Context, Node, Type>, kind: NodeKind, plan: model.Plan, state: State)
   local by_kind = plan.by_kind[kind]
   local by_call = next(plan.by_call) and plan.by_call
   local after = callbacks.after
   callbacks.after = function(c: Context, n: Node, children: {Type}): Type
      local t = after and after(c, n, children)
      state.strict_nil = c.feat_strict_nil
      if by_kind then run_rules(state, by_kind, n, t, children) end
      if kind == "op" and n.op then
         local op = n.op.op
         local operators = plan.by_operator[op]
         if operators then run_rules(state, operators, n, t, children) end
         if by_call and op == "@funcall" then
            local calls = by_call[state:path(n.e1)]
            if calls then run_rules(state, calls, n, t, children) end
         end
      end
      return t
   end
end

local whole_loop: {NodeKind: boolean} = { ["while"] = true, ["repeat"] = true }
local loop_body: {NodeKind: boolean} = { ["forin"] = true, ["fornum"] = true }
local function_body: {NodeKind: boolean} = {
   ["function"] = true, ["local_function"] = true, ["global_function"] = true, ["record_function"] = true,
}

local function track_scopes(hooks: {NodeKind: Callbacks<Context, Node, Type>}, state: State)
   local loop_stack: {integer} = {}
   for kind in pairs(whole_loop) do
      local callbacks = hooks[kind]
      local before = callbacks.before
      callbacks.before = function(c: Context, n: Node)
         state.loop_depth = state.loop_depth + 1
         if before then before(c, n) end
      end
   end
   for kind in pairs(loop_body) do
      local callbacks = hooks[kind]
      local before_statements = callbacks.before_statements
      callbacks.before_statements = function(c: Context, n: Node, children: {Type})
         state.loop_depth = state.loop_depth + 1
         before_statements(c, n, children)
      end
   end
   for kind in pairs(function_body) do
      local callbacks = hooks[kind]
      local before_statements = callbacks.before_statements
      callbacks.before_statements = function(c: Context, n: Node, children: {Type})
         local depth = state.function_depth + 1
         loop_stack[depth] = state.loop_depth
         state.function_depth, state.loop_depth = depth, 0
         if before_statements then before_statements(c, n, children) end
      end
   end
   for kind, callbacks in pairs(hooks) do
      local after = callbacks.after
      if whole_loop[kind] or loop_body[kind] then
         callbacks.after = function(c: Context, n: Node, children: {Type}): Type
            state.loop_depth = state.loop_depth - 1
            return after(c, n, children)
         end
      elseif function_body[kind] then
         callbacks.after = function(c: Context, n: Node, children: {Type}): Type
            local depth = state.function_depth
            state.loop_depth, state.function_depth = loop_stack[depth], depth - 1
            return after(c, n, children)
         end
      end
   end
end

function runner.attach(ctx: Context, visitor: Visitor<Context, NodeKind, Node, Type>): Visitor<Context, NodeKind, Node, Type>, State
   local plan = ctx.env.diagnostics_plan
   local opts = ctx.env.opts
   local gen_target = opts.gen_target or environment.DEFAULT_GEN_TARGET
   local state: State = setmetatable({
      target = opts.diagnostic_target or gen_target,
      is_lua = ctx.feat_lax,
      strict_nil = ctx.feat_strict_nil,
      loop_depth = 0,
      function_depth = 0,
      filename = ctx.filename,
      results = {},
      paths = {},
      modified_paths = {},
   }, state_mt)

   local cbs = util.shallow_copy_table(visitor.cbs)
   local hooks: {NodeKind: Callbacks<Context, Node, Type>} = {}
   local uses_operators = next(plan.by_operator) ~= nil or next(plan.by_call) ~= nil
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

local function compare(a: errors.Error, b: errors.Error): boolean
   if a.y ~= b.y then return a.y < b.y end
   if a.x ~= b.x then return a.x < b.x end
   if a.code ~= b.code then return a.code < b.code end
   return a.msg < b.msg
end

function runner.finish(state: State): {errors.Error}
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
