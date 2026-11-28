--#pragma strict_nil off
--------------------------------------------------------------------------------
-- Lua code generation
--------------------------------------------------------------------------------
local type attributes = require("teal.attributes")
local type Attribute = attributes.Attribute

local targets = require("teal.gen.targets")
local type GenTarget = targets.GenTarget

local types = require("teal.types")
local type Type = types.Type
local type TypeName = types.TypeName
local type TypeDeclType = types.TypeDeclType
local type GenericType = types.GenericType
local type NominalType = types.NominalType
local type RecordType = types.RecordType
local type RecordLikeType = types.RecordLikeType

local type ast_types = require("teal.ast")
local type Node = ast_types.Node
local type NodeKind = ast_types.NodeKind

local traversal = require("teal.traversal")
local type Visitor = traversal.Visitor
local type VisitorCallbacks = traversal.VisitorCallbacks

local record lua_generator
   record Options
      preserve_indent: boolean
      preserve_newlines: boolean
      preserve_hashbang: boolean
   end

   default_opts: Options
   fast_opts: Options
end

local type Options = lua_generator.Options

local tight_op: {integer:{string:boolean}} = {
   [1] = {
      ["-"] = true,
      ["~"] = true,
      ["#"] = true,
   },
   [2] = {
      ["."] = true,
      [":"] = true,
   },
}

local spaced_op: {integer:{string:boolean}} = {
   [1] = {
      ["not"] = true,
   },
   [2] = {
      ["or"] = true,
      ["and"] = true,
      ["<"] = true,
      [">"] = true,
      ["<="] = true,
      [">="] = true,
      ["~="] = true,
      ["=="] = true,
      ["|"] = true,
      ["~"] = true,
      ["&"] = true,
      ["<<"] = true,
      [">>"] = true,
      ["~>>"] = true,
      ["??"] = true,
      [".."] = true,
      ["+"] = true,
      ["-"] = true,
      ["*"] = true,
      ["/"] = true,
      ["//"] = true,
      ["%"] = true,
      ["^"] = true,
   },
}


local bit_compat_fns <const>: {string:string} = {
   ["&"] = "bit32.band",
   ["|"] = "bit32.bor",
   ["~"] = "bit32.bxor",
   [">>"] = "bit32.rshift",
   ["<<"] = "bit32.lshift",
}

lua_generator.default_opts = {
   preserve_indent = true,
   preserve_newlines = true,
   preserve_hashbang = false,
}

lua_generator.fast_opts = {
   preserve_indent = false,
   preserve_newlines = true,
   preserve_hashbang = false,
}

function lua_generator.generate(ast: Node, gen_target: GenTarget, opts?: Options): string
   local indent = 0

   opts = opts or lua_generator.default_opts

   local record Output
      {string}
      y: integer
      h: integer
   end

   local function increment_indent(_: nil, node: Node)
      local child = node.body or node[1]
      if not child then
         return
      end
      if not indent then
         indent = 1
      else
         indent = indent + 1
      end
   end

   local function decrement_indent()
      if not indent then
         indent = 0
      else
         indent = indent - 1
      end
   end

   if not opts.preserve_indent then
      increment_indent = nil
      decrement_indent = function() end
   end

   local function add_string(out: Output, s: string)
      table.insert(out, s)
      if string.find(s, "\n", 1, true) then
         for _nl in s:gmatch("\n") do
            out.h = out.h + 1
         end
      end
   end

   local function add_child(out: Output, child: Output, space?: string, current_indent?: integer)
      if #child == 0 then
         return
      end

      if child.y ~= -1 and child.y < out.y then
         out.y = child.y
      end

      if child.y > out.y + out.h and opts.preserve_newlines then
         local delta = child.y - (out.y + out.h)
         out.h = out.h + delta
         table.insert(out, ("\n"):rep(delta))
      else
         if space then
            if space ~= "" then
               table.insert(out, space)
            end
            current_indent = nil
         end
      end
      if current_indent and opts.preserve_indent then
         table.insert(out, ("   "):rep(current_indent))
      end
      table.insert(out, child as string)
      out.h = out.h + child.h
   end

   local function append_output(out: Output, parts: {string})
      for i = 1, #out do
         local s = out[i]
         if type(s) == "table" then
            append_output(s as Output, parts)
         else
            parts[#parts + 1] = s
         end
      end
   end

   local function first_output_character(out: Output): string
      for _, part in ipairs(out) do
         local first: string
         if type(part) == "table" then
            first = first_output_character(part as Output)
         else
            first = part:match("^%s*(.)")
         end
         if first then
            return first
         end
      end
   end

   local function print_record_def(typ: RecordLikeType): string
      local out: {string} = { "{" }
      local i = 0
      for fname, ftype in traversal.fields_of(typ) do
         if ftype is TypeDeclType then
            local def = ftype.def
            if def is GenericType then
               def = def.t
            end
            if def is RecordType then
               if i > 0 then
                  table.insert(out, ",")
               end
               i = i + 1
               table.insert(out, " ")
               table.insert(out, fname)
               table.insert(out, " = ")
               table.insert(out, print_record_def(def))
            end
         end
      end
      if i > 0 then
         table.insert(out, " ")
      end
      table.insert(out, "}")
      return table.concat(out)
   end

   local visit_node: Visitor<nil, NodeKind, Node, Output> = { skip_typeof_operands = true }
   local typeof_outputs: {Output}

   local lua_54_attribute <total>: {Attribute:string} = {
      ["const"] = " <const>",
      ["close"] = " <close>",
      ["total"] = " <const>",
   }

   local function emit_exactly(_: nil, node: Node, _children: {Output}): Output
      local out: Output = { y = node.y, h = 0 }
      add_string(out, node.tk)
      return out
   end

   local emit_exactly_visitor_cbs <const>: VisitorCallbacks<nil, Node, Output> = { after = emit_exactly }

   local emit_nothing_visitor_cbs <const>: VisitorCallbacks<nil, Node, Output> = {
      after = function(_: nil, node: Node, _children: {Output}): Output
         local out: Output = { y = node.y, h = 0 }
         return out
      end
   }

   local function starts_with_longstring(n: Node): boolean
      while n.e1 do n = n.e1 end
      return n.is_longstring
   end

   local tmp_id = 0
   local function next_tmp(prefix: string): string
      tmp_id = tmp_id + 1
      return prefix .. tostring(tmp_id)
   end

   local record MethodRecv
      recv: Output
      name: Output
      safe: boolean
   end

   local record ChainStep
      kind: string -- "field" | "index" | "call" | "method_call"
      safe: boolean
      safe_call: boolean
      name: Output
      key: Output
      args: Output
   end

   local record ChainInfo
      base: Output
      steps: {ChainStep}
      has_va: boolean
      y: integer
   end

   local record LhsParts
      kind: string -- "field" | "index"
      obj: Output
      key: Output
   end

   local record LoopCtx
      has_continue: boolean
      has_break: boolean
      brk_var: string
      is_repeat: boolean
      repeat_locals: {string}
   end

   local method_recvs: {Output: MethodRecv} = {}
   local opt_chains: {Output: ChainInfo} = {}
   local lhs_parts_map: {Output: LhsParts} = {}
   local loop_stack: {LoopCtx} = {}
   local loop_ctx_by_node: {Node: LoopCtx} = {}
   local repeat_hoist_skip: {Node: boolean} = {}

   local function contains_varargs(n: Node): boolean
      if not n then return false end
      local k = n.kind
      if k == "..." then return true end
      if k == "function" or k == "local_function" or k == "global_function" or k == "record_function" then
         return false
      end
      if contains_varargs(n.e1) or contains_varargs(n.e2) or contains_varargs(n.e3) or contains_varargs(n.exp) then
         return true
      end
      if n.vars and contains_varargs(n.vars) then return true end
      if n.exps and contains_varargs(n.exps) then return true end
      for i = 1, #n do
         if contains_varargs(n[i]) then return true end
      end
      return false
   end

   local function scan_loop_body(n: Node): boolean, boolean
      if not n then return false, false end
      local has_c, has_b = false, false
      local function walk(cur: Node)
         if not cur then return end
         local ck = cur.kind
         if ck == "continue" then
            has_c = true
            return
         elseif ck == "break" then
            has_b = true
            return
         elseif ck == "while" or ck == "fornum" or ck == "forin" or ck == "repeat"
            or ck == "function" or ck == "local_function" or ck == "global_function" or ck == "record_function" then
            return
         end
         if cur.body then walk(cur.body) end
         if cur.if_blocks then
            for _, ib in ipairs(cur.if_blocks) do walk(ib) end
         end
         for i = 1, #cur do walk(cur[i]) end
      end
      walk(n)
      return has_c, has_b
   end

   local function emit_arshift_call(y: integer, lhs_out: Output, rhs_out: Output): Output
      local out: Output = { y = y, h = 0 }
      table.insert(out, "(function(_tl_a, _tl_b) _tl_a = math.floor(_tl_a) % 4294967296; if _tl_a >= 2147483648 then _tl_a = _tl_a - 4294967296 end; return math.floor(_tl_a / (2 ^ (math.floor(_tl_b) % 32))) end)(")
      add_child(out, lhs_out)
      table.insert(out, ", ")
      add_child(out, rhs_out)
      table.insert(out, ")")
      return out
   end

   local function emit_binop_out(y: integer, op_str: string, lhs_out: Output, rhs_out: Output): Output
      if op_str == "~>>" then
         return emit_arshift_call(y, lhs_out, rhs_out)
      end
      local bf = gen_target == "5.1" and bit_compat_fns[op_str] or nil
      if bf then
         local out: Output = { y = y, h = 0 }
         table.insert(out, bf .. "(")
         add_child(out, lhs_out)
         table.insert(out, ", ")
         add_child(out, rhs_out)
         table.insert(out, ")")
         return out
      end
      local out: Output = { y = y, h = 0 }
      table.insert(out, "((")
      add_child(out, lhs_out)
      table.insert(out, ") " .. op_str .. " (")
      add_child(out, rhs_out)
      table.insert(out, "))")
      return out
   end

   local function materialize_chain(ch: ChainInfo): Output
      local out: Output = { y = ch.y, h = 0 }
      if ch.has_va then
         table.insert(out, "(function(...) ")
      else
         table.insert(out, "(function() ")
      end
      local cur = next_tmp("_tl_o")
      table.insert(out, "local " .. cur .. " = ")
      add_child(out, ch.base)
      table.insert(out, "; ")
      local nsteps = #ch.steps
      for idx, st in ipairs(ch.steps) do
         local is_last = idx == nsteps
         if st.kind == "method_call" then
            if st.safe then
               table.insert(out, "if " .. cur .. " == nil then return nil end; ")
            end
            local mvar = next_tmp("_tl_m")
            table.insert(out, "local " .. mvar .. " = " .. cur .. ".")
            add_child(out, st.name)
            table.insert(out, "; ")
            if st.safe_call then
               table.insert(out, "if " .. mvar .. " == nil then return nil end; ")
            end
            if is_last then
               table.insert(out, "return " .. mvar .. "(" .. cur)
               if #st.args > 0 then
                  table.insert(out, ", ")
                  add_child(out, st.args)
               end
               table.insert(out, ")")
            else
               local nxt = next_tmp("_tl_o")
               table.insert(out, "local " .. nxt .. " = " .. mvar .. "(" .. cur)
               if #st.args > 0 then
                  table.insert(out, ", ")
                  add_child(out, st.args)
               end
               table.insert(out, "); ")
               cur = nxt
            end
         else
            if st.safe then
               table.insert(out, "if " .. cur .. " == nil then return nil end; ")
            end
            local expr: Output = { y = ch.y, h = 0 }
            table.insert(expr, cur)
            if st.kind == "field" then
               table.insert(expr, ".")
               add_child(expr, st.name)
            elseif st.kind == "index" then
               table.insert(expr, "[")
               add_child(expr, st.key)
               table.insert(expr, "]")
            elseif st.kind == "call" then
               table.insert(expr, "(")
               add_child(expr, st.args)
               table.insert(expr, ")")
            end
            if is_last then
               table.insert(out, "return ")
               add_child(out, expr)
            else
               local nxt = next_tmp("_tl_o")
               table.insert(out, "local " .. nxt .. " = ")
               add_child(out, expr)
               table.insert(out, "; ")
               cur = nxt
            end
         end
      end
      if ch.has_va then
         table.insert(out, " end)(...)")
      else
         table.insert(out, " end)()")
      end
      return out
   end

   local function loop_before(_: nil, node: Node)
      if gen_target ~= "luajit" and node.body then
         local hc, hb = scan_loop_body(node.body)
         local ctx: LoopCtx = {
            has_continue = hc,
            has_break = hb,
            brk_var = (hc and hb) and next_tmp("_tl_brk") or nil,
            is_repeat = node.kind == "repeat",
            repeat_locals = nil,
         }
         if hc and node.kind == "repeat" then
            for i = 1, #node.body do
               local st = node.body[i]
               if st.kind == "local_declaration" then
                  if not ctx.repeat_locals then ctx.repeat_locals = {} end
                  for _, v in ipairs(st.vars) do
                     table.insert(ctx.repeat_locals, v.tk)
                  end
                  repeat_hoist_skip[st] = true
               elseif st.kind == "local_function" then
                  if not ctx.repeat_locals then ctx.repeat_locals = {} end
                  table.insert(ctx.repeat_locals, st.name.tk)
                  repeat_hoist_skip[st] = true
               end
            end
         end
         loop_ctx_by_node[node] = ctx
         table.insert(loop_stack, ctx)
      end
      if increment_indent then
         increment_indent(nil, node)
      end
   end

   local function wrap_loop_body(_node: Node, body_out: Output, parent_ctx: LoopCtx): Output
      if not parent_ctx or not parent_ctx.has_continue then
         return body_out
      end
      local out: Output = { y = body_out.y, h = 0 }
      if parent_ctx.repeat_locals and #parent_ctx.repeat_locals > 0 then
         table.insert(out, "local " .. table.concat(parent_ctx.repeat_locals, ", ") .. "; ")
      end
      if parent_ctx.brk_var then
         table.insert(out, "local " .. parent_ctx.brk_var .. " = false; ")
      end
      table.insert(out, "repeat ")
      add_child(out, body_out)
      table.insert(out, " until true")
      if parent_ctx.brk_var then
         table.insert(out, "; if " .. parent_ctx.brk_var .. " then break end")
      end
      return out
   end

   local function drop_initial_indentation(out: Output)
      if not out then
         return
      end
      local first = out[1]
      if first is string then
         if first:match("^ +$") then
            table.remove(out, 1)
            drop_initial_indentation(out)
         end
      else
         drop_initial_indentation(first as Output)
      end
   end

   local function add_block(out: Output, block_out: Output, top_node: Node)
      if not block_out then
         return
      end
      if block_out.y == top_node.y then
         drop_initial_indentation(block_out)
      end

      add_child(out, block_out, " ")
      decrement_indent()
   end

   local enum FunctionKind
      "anonymous"
      "record"
      "local"
      "global"
   end

   local function_indexes <total>: {FunctionKind:{integer, integer}} = {
      -- arguments, body
      ["anonymous"] = { 1, 3 },
      ["record"] = { 3, 5 },
      ["local"] = { 2, 4 },
      ["global"] = { 2, 4 },
   }

   local function after_function(kind: FunctionKind): function(nil, Node, {Output}): Output
      local arguments_index <const>, body_index <const> = table.unpack(function_indexes[kind])
      return function(_: nil, node: Node, children: {Output}): Output
         local out <const>: Output = { y = node.y, h = 0 }

         if kind == "local" then
            if repeat_hoist_skip[node] then
               add_child(out, children[1], "")
               table.insert(out, " = function(")
            else
               table.insert(out, node.lj_const and gen_target == "luajit" and "const " or "local ")
               table.insert(out, "function")
            end
         else
            table.insert(out, "function")
         end

         if kind == "record" then
            add_child(out, children[1], " ")
            table.insert(out, node.is_method and ":" or ".")
            add_child(out, children[2])
         elseif kind ~= "anonymous" and not (kind == "local" and repeat_hoist_skip[node]) then
            add_child(out, children[1], " ")
         end
         if not (kind == "local" and repeat_hoist_skip[node]) then
            table.insert(out, "(")
         end

         -- Remove self from methods
         local args <const> = children[arguments_index]
         if kind == "record" and node.is_method then
            table.remove(args, 1)
            if args[1] == "," then
               table.remove(args, 1)
               if args[1] == " " then
                  table.remove(args, 1)
               end
            end
         end
         add_child(out, args)

         table.insert(out, ")")

         add_block(out, children[body_index], node)
         add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
         return out
      end
   end

   visit_node.cbs = {
      ["macro_quote"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            assert(node.macro_quote_code, "unlowered macro quote")
            return { y = node.y, h = 0, node.macro_quote_code }
         end,
      },
      ["statements"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output
            if opts.preserve_hashbang and node.hashbang then
               out = { y = 1, h = 0 }
               table.insert(out, node.hashbang)
            else
               out = { y = node.y, h = 0 }
            end
            local space: string
            local previous_statement: Node
            for i, child in ipairs(children) do
               local statement = node[i]
               -- A macro can generate a leading parenthesis where the source
               -- began with a name or operator. Keep the statement boundary in Lua.
               if (statement.kind == "assignment" or first_output_character(child) == "(") and previous_statement and not previous_statement.semicolon
                  and opts.preserve_newlines and child.y > out.y + out.h and first_output_character(child) == "(" then
                  table.insert(out, ";")
               end
               add_child(out, child, space, indent)
               if #child > 0 then
                  if statement.semicolon then
                     table.insert(out, ";")
                     space = " "
                  else
                     space = "; "
                  end
                  previous_statement = statement
               end
            end
            return out
         end
      },
      ["local_declaration"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if repeat_hoist_skip[node] then
               if not children[3] then
                  return out
               end
               for i, var in ipairs(node.vars) do
                  if i > 1 then
                     add_string(out, ", ")
                  end
                  add_string(out, var.tk)
               end
               table.insert(out, " =")
               add_child(out, children[3], " ")
               return out
            end
            table.insert(out, node.lj_const and gen_target == "luajit" and "const " or "local ")
            for i, var in ipairs(node.vars) do
               if i > 1 then
                  add_string(out, ", ")
               end
               add_string(out, var.tk)
               if var.attribute and (gen_target == "5.4" or gen_target == "5.5") then
                  add_string(out, lua_54_attribute[var.attribute])
               end
            end
            if children[3] then
               table.insert(out, " =")
               add_child(out, children[3], " ")
            end
            return out
         end,
      },
      ["local_type"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if not node.var.elide_type then
               table.insert(out, "local")
               add_child(out, children[1], " ")
               table.insert(out, " =")
               add_child(out, children[2], " ")
            end
            return out
         end,
      },
      ["global_type"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if children[2] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[2], " ")
            end
            return out
         end,
      },
      ["global_declaration"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if children[3] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[3], " ")
            end
            return out
         end,
      },
      ["assignment"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local chain = gen_target ~= "luajit" and opt_chains[children[1]] or nil
            if chain then
               table.insert(out, "do local ")
               local cur = next_tmp("_tl_o")
               table.insert(out, cur .. " = ")
               add_child(out, chain.base)
               table.insert(out, "; ")
               local open_ifs = 0
               local nsteps = #chain.steps
               for idx = 1, nsteps - 1 do
                  local st = chain.steps[idx]
                  if st.safe then
                     table.insert(out, "if " .. cur .. " ~= nil then ")
                     open_ifs = open_ifs + 1
                  end
                  local nxt = next_tmp("_tl_o")
                  if st.kind == "method_call" then
                     local mvar = next_tmp("_tl_m")
                     table.insert(out, "local " .. mvar .. " = " .. cur .. ".")
                     add_child(out, st.name)
                     table.insert(out, "; ")
                     if st.safe_call then
                        table.insert(out, "if " .. mvar .. " ~= nil then ")
                        open_ifs = open_ifs + 1
                     end
                     table.insert(out, "local " .. nxt .. " = " .. mvar .. "(" .. cur)
                     if #st.args > 0 then
                        table.insert(out, ", ")
                        add_child(out, st.args)
                     end
                     table.insert(out, "); ")
                  else
                     table.insert(out, "local " .. nxt .. " = " .. cur)
                     if st.kind == "field" then
                        table.insert(out, ".")
                        add_child(out, st.name)
                     elseif st.kind == "index" then
                        table.insert(out, "[")
                        add_child(out, st.key)
                        table.insert(out, "]")
                     elseif st.kind == "call" then
                        table.insert(out, "(")
                        add_child(out, st.args)
                        table.insert(out, ")")
                     end
                     table.insert(out, "; ")
                  end
                  cur = nxt
               end
               local last = chain.steps[nsteps]
               if last.safe then
                  table.insert(out, "if " .. cur .. " ~= nil then ")
                  open_ifs = open_ifs + 1
               end
               local target_lhs: Output = { y = node.y, h = 0 }
               if last.kind == "field" then
                  table.insert(target_lhs, cur .. ".")
                  add_child(target_lhs, last.name)
               else
                  local kvar = next_tmp("_tl_k")
                  table.insert(out, "local " .. kvar .. " = ")
                  add_child(out, last.key)
                  table.insert(out, "; ")
                  table.insert(target_lhs, cur .. "[" .. kvar .. "]")
               end
               add_child(out, target_lhs)
               table.insert(out, " = ")
               if node.compound then
                  add_child(out, emit_binop_out(node.y, node.compound, target_lhs, children[3]))
               else
                  add_child(out, children[3])
               end
               for _ = 1, open_ifs do
                  table.insert(out, " end")
               end
               table.insert(out, " end")
               return out
            end

            if gen_target ~= "luajit" and node.compound then
               local parts = lhs_parts_map[children[1]]
               if parts and parts.kind == "field" then
                  local tvar = next_tmp("_tl_t")
                  table.insert(out, "do local " .. tvar .. " = ")
                  add_child(out, parts.obj)
                  local acc: Output = { y = node.y, h = 0, tvar, "." }
                  add_child(acc, parts.key)
                  table.insert(out, "; " .. tvar .. ".")
                  add_child(out, parts.key)
                  table.insert(out, " = ")
                  add_child(out, emit_binop_out(node.y, node.compound, acc, children[3]))
                  table.insert(out, " end")
                  return out
               elseif parts and parts.kind == "index" then
                  local tvar = next_tmp("_tl_t")
                  local kvar = next_tmp("_tl_k")
                  table.insert(out, "do local " .. tvar .. ", " .. kvar .. " = ")
                  add_child(out, parts.obj)
                  table.insert(out, ", ")
                  add_child(out, parts.key)
                  local acc: Output = { y = node.y, h = 0, tvar, "[", kvar, "]" }
                  table.insert(out, "; " .. tvar .. "[" .. kvar .. "] = ")
                  add_child(out, emit_binop_out(node.y, node.compound, acc, children[3]))
                  table.insert(out, " end")
                  return out
               else
                  -- Simple variable compound assignment
                  add_child(out, children[1])
                  table.insert(out, " = ")
                  add_child(out, emit_binop_out(node.y, node.compound, children[1], children[3]))
                  return out
               end
            end

            add_child(out, children[1])
            table.insert(out, " " .. (node.compound or "") .. "=")
            add_child(out, children[3], " ")
            return out
         end,
      },
      ["conditional"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            if gen_target ~= "luajit" then
               local out: Output = { y = node.y, h = 0 }
               local has_va = contains_varargs(node)
               table.insert(out, has_va and "(function(...) if " or "(function() if ")
               add_child(out, children[1])
               table.insert(out, " then return ")
               add_child(out, children[2])
               table.insert(out, " else return ")
               add_child(out, children[3])
               table.insert(out, has_va and " end end)(...)" or " end end)()")
               return out
            end
            local out: Output = { y = node.y, h = 0, "(" }
            add_child(out, children[1])
            table.insert(out, " ? (")
            add_child(out, children[2])
            table.insert(out, ") : ")
            add_child(out, children[3])
            table.insert(out, ")")
            return out
         end,
      },
      ["if"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            for i, child in ipairs(children) do
               add_child(out, child, i > 1 and " ", child.y ~= node.y and indent)
            end
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["if_block"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.if_block_n == 1 then
               table.insert(out, "if")
            elseif not node.exp then
               table.insert(out, "else")
            else
               table.insert(out, "elseif")
            end
            if node.exp then
               add_child(out, children[1], " ")
               table.insert(out, " then")
            end

            add_block(out, children[2], node)
            return out
         end,
      },
      ["while"] = {
         before = loop_before,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "while")
            add_child(out, children[1], " ")
            table.insert(out, " do")
            local ctx = gen_target ~= "luajit" and table.remove(loop_stack) or nil
            add_block(out, wrap_loop_body(node, children[2], ctx), node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["repeat"] = {
         before = loop_before,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "repeat")
            local ctx = gen_target ~= "luajit" and table.remove(loop_stack) or nil
            add_block(out, wrap_loop_body(node, children[1], ctx), node)
            add_child(out, { y = node.yend, h = 0, [1] = "until " }, " ", indent)
            add_child(out, children[2])
            return out
         end,
      },
      ["do"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "do")
            add_block(out, children[1], node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["forin"] = {
         before = loop_before,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "for")
            add_child(out, children[1], " ")
            table.insert(out, " in")
            add_child(out, children[2], " ")
            table.insert(out, " do")
            local ctx = gen_target ~= "luajit" and table.remove(loop_stack) or nil
            add_block(out, wrap_loop_body(node, children[3], ctx), node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["fornum"] = {
         before = loop_before,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "for")
            add_child(out, children[1], " ")
            table.insert(out, " =")
            add_child(out, children[2], " ")
            table.insert(out, ",")
            add_child(out, children[3], " ")
            if children[4] then
               table.insert(out, ",")
               add_child(out, children[4], " ")
            end
            table.insert(out, " do")
            local ctx = gen_target ~= "luajit" and table.remove(loop_stack) or nil
            add_block(out, wrap_loop_body(node, children[5], ctx), node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["return"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "return")
            if #children[1] > 0 then
               add_child(out, children[1], " ")
            end
            return out
         end,
      },
      ["break"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local ctx = gen_target ~= "luajit" and loop_stack[#loop_stack] or nil
            if ctx and ctx.brk_var then
               table.insert(out, "do " .. ctx.brk_var .. " = true; break end")
            else
               table.insert(out, "break")
            end
            return out
         end,
      },
      ["variable_list"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local space: string
            for i, child in ipairs(children) do
               if i > 1 then
                  table.insert(out, ",")
                  space = " "
               end
               add_child(out, child, space, child.y ~= node.y and indent)
            end
            if gen_target ~= "luajit" and #children == 1 then
               if opt_chains[children[1]] then
                  opt_chains[out] = opt_chains[children[1]]
               end
               if lhs_parts_map[children[1]] then
                  lhs_parts_map[out] = lhs_parts_map[children[1]]
               end
            end
            return out
         end,
      },
      ["literal_table"] = {
         before = increment_indent and function(_: nil, node: Node)
            if node[1] and node[1].y ~= node.y then
               increment_indent(_, node)
            end
         end,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if #children == 0 then
               table.insert(out, "{}")
               return out
            end
            table.insert(out, "{")
            local n = #children
            for i, child in ipairs(children) do
               add_child(out, child, " ", child.y ~= node.y and indent)
               if i < n or node.yend ~= node.y then
                  table.insert(out, ",")
               end
            end
            if increment_indent and node[1] and node[1].y ~= node.y then
               decrement_indent()
            end
            add_child(out, { y = node.yend, h = 0, [1] = "}" }, " ", indent)
            return out
         end,
      },
      ["literal_table_item"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.key_parsed ~= "implicit" then
               if node.key_parsed == "short" then
                  children[1][1] = children[1][1]:sub(2, -2)
                  add_child(out, children[1])
                  table.insert(out, " = ")
               else
                  table.insert(out, "[")
                  if node.key_parsed == "long" and node.key.is_longstring then
                     table.insert(children[1], 1, " ")
                     table.insert(children[1], " ")
                  end
                  add_child(out, children[1])
                  table.insert(out, "] = ")
               end
            end
            add_child(out, children[2])
            return out
         end,
      },
      ["local_macroexp"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, _children: {Output}): Output
            return { y = node.y, h = 0 }
         end,
      },
      ["local_function"] = {
         before = increment_indent,
         after = after_function("local"),
      },
      ["global_function"] = {
         before = increment_indent,
         after = after_function("global"),
      },
      ["record_function"] = {
         before = increment_indent,
         after = after_function("record")
      },
      ["function"] = {
         before = increment_indent,
         after = after_function("anonymous"),
      },
      ["paren"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "(")
            add_child(out, children[1], "", indent)
            table.insert(out, ")")
            return out
         end,
      },
      ["typeof_expression"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0, "nil" }
            if node.typeof_description then
               out[1] = require("teal.reflection").encode(node.typeof_description)
               typeof_outputs = typeof_outputs or {}
               typeof_outputs[#typeof_outputs + 1] = out
            end
            return out
         end,
      },
      ["op"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.compound_value then
               return children[3]
            end
            if gen_target ~= "luajit" then
               if node.op.op == "??" then
                  local has_va = contains_varargs(node.e2)
                  if has_va then
                     table.insert(out, "(function(...) local _tl_v = ")
                     add_child(out, children[1])
                     table.insert(out, "; if _tl_v ~= nil then return _tl_v end; return ")
                     add_child(out, children[3])
                     table.insert(out, " end)(...)")
                  else
                     table.insert(out, "(function(_tl_v) if _tl_v ~= nil then return _tl_v end; return ")
                     add_child(out, children[3])
                     table.insert(out, " end)(")
                     add_child(out, children[1])
                     table.insert(out, ")")
                  end
                  return out
               elseif node.op.op == "~>>" then
                  return emit_arshift_call(node.y, children[1], children[3])
               elseif node.optional_chain then
                  if node.op.op == ":" then
                     local mr: MethodRecv = { recv = children[1], name = children[3], safe = node.safe_navigation == true }
                     method_recvs[out] = mr
                     return out
                  end
                  local mr = node.op.op == "@funcall" and method_recvs[children[1]] or nil
                  local prev_base = mr and mr.recv or children[1]
                  local prev_chain = opt_chains[prev_base]
                  local steps: {ChainStep} = {}
                  local base_out = prev_chain and prev_chain.base or prev_base
                  local has_va = (prev_chain and prev_chain.has_va) or contains_varargs(node.e2)
                  if prev_chain then
                     for _, st in ipairs(prev_chain.steps) do
                        table.insert(steps, st)
                     end
                  end
                  if mr then
                     table.insert(steps, {
                        kind = "method_call",
                        safe = mr.safe,
                        safe_call = node.safe_navigation == true,
                        name = mr.name,
                        args = children[3],
                     })
                  elseif node.op.op == "@funcall" then
                     table.insert(steps, {
                        kind = "call",
                        safe = node.safe_navigation == true,
                        args = children[3],
                     })
                  elseif node.op.op == "@index" then
                     table.insert(steps, {
                        kind = "index",
                        safe = node.safe_navigation == true,
                        key = children[3],
                     })
                  else
                     -- "."
                     table.insert(steps, {
                        kind = "field",
                        safe = node.safe_navigation == true,
                        name = children[3],
                     })
                  end
                  local chain: ChainInfo = { base = base_out, steps = steps, has_va = has_va, y = node.y }
                  local mat = materialize_chain(chain)
                  opt_chains[mat] = chain
                  return mat
               end
            end
            if node.safe_navigation then
               table.insert(children[1], "?.")
            end
            if node.op.op == "@funcall" then
               add_child(out, children[1], "", indent)
               table.insert(out, "(")
               add_child(out, children[3], "", indent)
               table.insert(out, ")")
            elseif node.op.op == "@index" then
               add_child(out, children[1], "", indent)
               table.insert(out, "[")
               if starts_with_longstring(node.e2) then
                  table.insert(children[3], 1, " ")
                  table.insert(children[3], " ")
               end
               add_child(out, children[3], "", indent)
               table.insert(out, "]")
               if gen_target ~= "luajit" then
                  lhs_parts_map[out] = { kind = "index", obj = children[1], key = children[3] }
               end
            elseif node.op.op == "as" then
               add_child(out, children[1], "", indent)
            elseif node.op.op == "is" then
               local ct = node.e2.casttype
               while ct is NominalType and ct.resolved do
                  ct = ct.resolved
               end
               if ct.typename == "integer" then
                  table.insert(out, "math.type(")
                  add_child(out, children[1], "", indent)
                  table.insert(out, ") == \"integer\"")
               elseif ct.typename == "nil" then
                  add_child(out, children[1], "", indent)
                  table.insert(out, " == nil")
               else
                  table.insert(out, "type(")
                  add_child(out, children[1], "", indent)
                  table.insert(out, ") == \"")
                  add_child(out, children[3], "", indent)
                  table.insert(out, "\"")
               end
            elseif spaced_op[node.op.arity][node.op.op] or tight_op[node.op.arity][node.op.op] then
               local space = spaced_op[node.op.arity][node.op.op] and " " or ""
               if children[2] and node.op.prec > tonumber(children[2]) then
                  table.insert(children[1], 1, "(")
                  table.insert(children[1], ")")
               end
               if node.op.arity == 1 then
                  table.insert(out, node.op.op)
                  add_child(out, children[1], space, indent)
               elseif node.op.arity == 2 then
                  add_child(out, children[1], "", indent)
                  if space == " " then
                     table.insert(out, " ")
                  end
                  table.insert(out, node.safe_navigation and node.op.op == "." and "" or node.op.op)
                  if children[4] and node.op.prec > tonumber(children[4]) then
                     table.insert(children[3], 1, "(")
                     table.insert(children[3], ")")
                  end
                  add_child(out, children[3], space, indent)
                  if gen_target ~= "luajit" and node.op.op == ":" then
                     method_recvs[out] = { recv = children[1], name = children[3], safe = false }
                  elseif gen_target ~= "luajit" and node.op.op == "." then
                     lhs_parts_map[out] = { kind = "field", obj = children[1], key = children[3] }
                  end
               end
            else
               error("unknown node op " .. node.op.op)
            end
            return out
         end,
      },
      ["newtype"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local nt = node.newtype
            if nt is TypeDeclType then
               local def = nt.def
               if def is RecordLikeType then
                  table.insert(out, print_record_def(def))
               elseif def is NominalType then
                  table.insert(out, table.concat(def.names, "."))
               else
                  table.insert(out, "{}")
               end
            end
            return out
         end,
      },
      ["goto"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "goto ")
            table.insert(out, node.label)
            return out
         end,
      },
      ["label"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "::")
            table.insert(out, node.label)
            table.insert(out, "::")
            return out
         end,
      },
      ["string"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            -- translate escape sequences not supported by Lua 5.1
            -- in particular:
            --  - \z : removes trailing whitespace
            --  - \xXX : hex byte
            --  - \u{} : unicode

            if node.tk:sub(1, 1) == "[" or gen_target ~= "5.1" or not node.tk:find("\\", 1, true) then
               return emit_exactly(nil, node, children)
            end

            local str = node.tk
            local replaced: {string} = {}

            local i = 1
            local currstrstart = 1
            while true do
               local slashpos = str:find("\\", i)
               if not slashpos then break end
               local nextc = str:sub(slashpos + 1, slashpos + 1)
               if nextc == "z" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local wsend = str:find("%S", slashpos + 2) -- next non-whitespace
                  currstrstart = wsend
                  i = currstrstart
               elseif nextc == "x" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local digits <const> = str:sub(slashpos + 2, slashpos + 3)
                  local byte <const> = tonumber(digits, 16)
                  table.insert(replaced, string.format("\\%03d", byte))
                  currstrstart = slashpos + 4
                  i = currstrstart
               elseif nextc == "u" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local _, e, hex_digits = str:find("{(.-)}", slashpos + 2)
                  local codepoint <const> = tonumber(hex_digits, 16)
                  local sequence <const> = utf8.char(codepoint)
                  table.insert(replaced, (sequence:gsub(".", function(c: string): string
                     return ("\\%03d"):format(string.byte(c))
                  end)))
                  currstrstart = e + 1
                  i = currstrstart
               else
                  i = slashpos + 2
               end
            end
            if currstrstart <= #str then
               table.insert(replaced, str:sub(currstrstart))
            end

            local h = 0
            local finalstr = table.concat(replaced)
            for _ in finalstr:gmatch("\n") do
               h = h + 1
            end
            return {
               y = node.y,
               h = h,
               finalstr,
            }
         end,
      },

      ["continue"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            if gen_target ~= "luajit" then
               return { y = node.y, h = 0, "do break end" }
            end
            return { y = node.y, h = 0, node.tk }
         end,
      },
      ["variable"] = emit_exactly_visitor_cbs,
      ["identifier"] = emit_exactly_visitor_cbs,
      ["number"] = {
         after = function(_: nil, node: Node): Output
            local text = node.tk:gsub("_", "")
            if gen_target ~= "luajit" then
               text = text:gsub("[uU]?[lL][lL]$", ""):gsub("[iI]$", "")
               if text:match("^0[bB][01]+$") then
                  text = string.format("%.17g", tonumber(text:sub(3), 2))
               end
            end
            return { y = node.y, h = 0, text }
         end,
      },
      ["integer"] = {
         after = function(_: nil, node: Node): Output
            local text = node.tk:gsub("_", "")
            if gen_target ~= "luajit" then
               text = text:gsub("[uU]?[lL][lL]$", ""):gsub("[iI]$", "")
               if text:match("^0[bB][01]+$") then
                  text = string.format("%.17g", tonumber(text:sub(3), 2))
               end
            end
            return { y = node.y, h = 0, text }
         end,
      },
      ["nil"] = emit_exactly_visitor_cbs,
      ["boolean"] = emit_exactly_visitor_cbs,
      ["..."] = emit_exactly_visitor_cbs,
      ["argument"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            add_string(out, node.tk)
            if node.name and gen_target == "5.5" then
               add_string(out, node.name.tk)
            end
            return out
         end,
      },
      ["type_identifier"] = emit_exactly_visitor_cbs,

      ["cast"] = emit_nothing_visitor_cbs,
      ["pragma"] = emit_nothing_visitor_cbs,
   }

   local visit_type: Visitor<nil, TypeName, Type, Output> = {}
   visit_type.cbs = {}
   local default_type_visitor = {
      after = function(_: nil, typ: Type, _children: {Output}): Output
         local out: Output = { y = typ.y or -1, h = 0 }
         local r = typ is NominalType and typ.resolved or typ
         local lua_type = types.lua_primitives[r.typename] or "table"
         if r is RecordLikeType and r.is_userdata then
            lua_type = "userdata"
         end
         table.insert(out, lua_type)
         return out
      end,
   }

   visit_type.cbs["string"] = default_type_visitor
   visit_type.cbs["typedecl"] = default_type_visitor
   visit_type.cbs["typevar"] = default_type_visitor
   visit_type.cbs["typearg"] = default_type_visitor
   visit_type.cbs["function"] = default_type_visitor
   visit_type.cbs["thread"] = default_type_visitor
   visit_type.cbs["array"] = default_type_visitor
   visit_type.cbs["map"] = default_type_visitor
   visit_type.cbs["tupletable"] = default_type_visitor
   visit_type.cbs["record"] = default_type_visitor
   visit_type.cbs["enum"] = default_type_visitor
   visit_type.cbs["boolean"] = default_type_visitor
   visit_type.cbs["nil"] = default_type_visitor
   visit_type.cbs["number"] = default_type_visitor
   visit_type.cbs["integer"] = default_type_visitor
   visit_type.cbs["union"] = default_type_visitor
   visit_type.cbs["nominal"] = default_type_visitor
   visit_type.cbs["typeof"] = default_type_visitor
   visit_type.cbs["emptytable"] = default_type_visitor
   visit_type.cbs["literal_table_item"] = default_type_visitor
   visit_type.cbs["unresolved_emptytable_value"] = default_type_visitor
   visit_type.cbs["tuple"] = default_type_visitor
   visit_type.cbs["poly"] = default_type_visitor
   visit_type.cbs["any"] = default_type_visitor
   visit_type.cbs["unknown"] = default_type_visitor
   visit_type.cbs["invalid"] = default_type_visitor
   visit_type.cbs["none"] = default_type_visitor

   visit_node.cbs["expression_list"] = visit_node.cbs["variable_list"]
   visit_node.cbs["argument_list"] = visit_node.cbs["variable_list"]

   local out = traversal.traverse_nodes(nil, ast, visit_node, visit_type)

   local code: Output
   if opts.preserve_newlines then
      code = { y = 1, h = 0 }
      add_child(code, out)
   else
      code = out
   end
   local parts: {string} = {}
   append_output(code, parts)
   if typeof_outputs then
      local body = table.concat(parts)
      local name = "__tl_typeof"
      local suffix = 0
      while body:find(name, 1, true) do
         suffix = suffix + 1
         name = "__tl_typeof_" .. tostring(suffix)
      end
      for _, output in ipairs(typeof_outputs) do
         output[1] = output[1]:gsub("%z", name)
      end
      parts = {}
      append_output(code, parts)
      body = table.concat(parts)
      local factory = require("teal.reflection").factory
      if ast.kind ~= "statements" then
         if contains_varargs(ast) then
            body = "(function(" .. name .. ", ...) return " .. body .. " end)(" .. factory .. ", ...)"
         else
            body = "(function(" .. name .. ") return " .. body .. " end)(" .. factory .. ")"
         end
      else
         local init = "local " .. name .. " = " .. factory .. "; "
         if opts.preserve_hashbang and ast.hashbang then
            local start = #ast.hashbang + 1
            if body:sub(start, start) == "\n" then start = start + 1 end
            body = ast.hashbang .. "\n" .. init .. body:sub(start)
         else
            body = init .. body
         end
      end
      return (body:gsub(" *\n", "\n"))
   end
   return (table.concat(parts):gsub(" *\n", "\n"))
end

return lua_generator
