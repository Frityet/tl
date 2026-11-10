-- module teal.ast from teal/ast.lua
package.preload["teal.ast"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table


local reader = require("teal.block")


local errors = require("teal.errors")



local types = require("teal.types")




























local a_type = types.a_type
local raw_type = types.raw_type
local simple_types = types.simple_types

local lexer = require("teal.lexer")





























































local parse_type
local parse_type_list
local parse_typeargs_if_any


































































































































































local ast = {}
















local attributes = {
   ["const"] = true,
   ["close"] = true,
   ["total"] = true,
}
local is_attribute = attributes

local precedences = {
   [1] = {
      ["not"] = 11,
      ["#"] = 11,
      ["-"] = 11,
      ["~"] = 11,
   },
   [2] = {
      ["??"] = 1,
      ["or"] = 1,
      ["and"] = 2,
      ["is"] = 3,
      ["<"] = 3,
      [">"] = 3,
      ["<="] = 3,
      [">="] = 3,
      ["~="] = 3,
      ["=="] = 3,
      ["|"] = 4,
      ["~"] = 5,
      ["&"] = 6,
      ["<<"] = 7,
      [">>"] = 7,
      ["~>>"] = 7,
      [".."] = 8,
      ["+"] = 9,
      ["-"] = 9,
      ["*"] = 10,
      ["/"] = 10,
      ["//"] = 10,
      ["%"] = 10,
      ["^"] = 12,
      ["as"] = 50,
      ["@funcall"] = 100,
      ["@index"] = 100,
      ["."] = 100,
      [":"] = 100,
   },
}




local op_kinds = {
   op_not = { op = "not", arity = 1 },
   op_len = { op = "#", arity = 1 },
   op_unm = { op = "-", arity = 1 },
   op_bnot = { op = "~", arity = 1 },
   op_or = { op = "or", arity = 2 },
   op_and = { op = "and", arity = 2 },
   op_is = { op = "is", arity = 2 },
   op_lt = { op = "<", arity = 2 },
   op_gt = { op = ">", arity = 2 },
   op_le = { op = "<=", arity = 2 },
   op_ge = { op = ">=", arity = 2 },
   op_ne = { op = "~=", arity = 2 },
   op_eq = { op = "==", arity = 2 },
   op_bor = { op = "|", arity = 2 },
   op_bxor = { op = "~", arity = 2 },
   op_band = { op = "&", arity = 2 },
   op_shl = { op = "<<", arity = 2 },
   op_shr = { op = ">>", arity = 2 },
   op_sar = { op = "~>>", arity = 2 },
   op_coalesce = { op = "??", arity = 2 },
   op_concat = { op = "..", arity = 2 },
   op_add = { op = "+", arity = 2 },
   op_sub = { op = "-", arity = 2 },
   op_mul = { op = "*", arity = 2 },
   op_div = { op = "/", arity = 2 },
   op_idiv = { op = "//", arity = 2 },
   op_mod = { op = "%", arity = 2 },
   op_pow = { op = "^", arity = 2 },
   op_as = { op = "as", arity = 2 },
   op_funcall = { op = "@funcall", arity = 2 },
   op_index = { op = "@index", arity = 2 },
   op_dot = { op = ".", arity = 2 },
   op_colon = { op = ":", arity = 2 },
}













local node_mt = {
   __tostring = function(n)
      return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
   end,
}

function ast.lang_heuristic(filename, input)
   if filename then
      local pattern = "(.*)%.([a-z]+)$"
      local _, extension = filename:match(pattern)
      extension = extension and extension:lower()

      if extension == "tl" then
         return "tl"
      elseif extension == "lua" then
         return "lua"
      end
   end
   if input then
      return (input:match("^#![^\n]*lua[^\n]*\n")) and "lua" or "tl"
   end
   return "tl"
end


local function end_at(node, block)
   if block then
      if block.yend then
         node.yend = block.yend
      end
      if block.xend then
         node.xend = block.xend
      end
   end
end

local function block_number_value(b)
   if b and (b.kind == "integer" or b.kind == "number") then
      local text = b.tk:gsub("_", "")
      if text:match("^0[bB][01]+$") then return tonumber(text:sub(3), 2) end
      return tonumber(text)
   end
   return nil
end

local function new_node(state, block, kind)
   if not block then
      return nil
   end

   local bkind = block.kind
   if bkind == "error_block" then
      bkind = "error_node"
   end

   local node = setmetatable({
      f = state.filename,
      y = block.y,
      x = block.x,
      tk = block.tk,
      kind = kind or (bkind),
   }, node_mt)
   end_at(node, block)
   return node
end

local function fail(state, block, msg)
   table.insert(state.errs, {
      filename = state.filename,
      y = block and block.y or 1,
      x = block and block.x or 1,
      msg = assert(msg, "syntax error, but no error message provided"),
   })
   return false
end

local parse_block
local parse_expression

local function parse_list(state, block, node, parse_fn)
   if not block then return node end
   for _, item_block in ipairs(block) do
      local parsed_item = parse_fn(state, item_block)
      if parsed_item then
         table.insert(node, parsed_item)
      end
   end
   return node
end

local function parse_expression_list(state, block)
   if not block then

      local dummy_block = { kind = "expression_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      return new_node(state, dummy_block, "expression_list")
   end
   local node = new_node(state, block, "expression_list")
   if not node then
      local dummy_block = { kind = "expression_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "expression_list")
   end
   return parse_list(state, block, node, parse_expression)
end

local function parse_variable_list(state, block, as_expression)
   if not block then

      local dummy_block = { kind = "variable_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      return new_node(state, dummy_block, "variable_list")
   end
   local node = new_node(state, block, "variable_list")
   if not node then
      local dummy_block = { kind = "variable_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "variable_list")
   end
   for _, var_block in ipairs(block) do
      local var_node
      if not as_expression and var_block.kind == "identifier" then
         var_node = new_node(state, var_block)
         if var_block[reader.BLOCK_INDEXES.VARIABLE.ANNOTATION] then
            local annotation = var_block[reader.BLOCK_INDEXES.VARIABLE.ANNOTATION]
            if is_attribute[annotation.tk] and var_node then
               var_node.attribute = annotation.tk
            end
         end
      else

         var_node = parse_expression(state, var_block)
      end

      if var_node then
         table.insert(node, var_node)
      end
   end
   return node
end

local function parse_argument_list(state, block)
   if not block then
      local dummy_block = { kind = "argument_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      return new_node(state, dummy_block, "argument_list")
   end

   local node = new_node(state, block, "argument_list")
   if not node then
      local dummy_block = { kind = "argument_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "argument_list")
   end

   local min_arity = 0
   local has_varargs = false

   for _, arg_block in ipairs(block) do
      local arg_node = new_node(state, arg_block, "argument")
      if not arg_node then
         fail(state, arg_block, "invalid argument")
      else
         local type_block = arg_block[reader.BLOCK_INDEXES.ARGUMENT.TYPE]
         if type(type_block) == "table" and type_block.kind then
            arg_node.argtype = parse_type(state, type_block)
         end

         local is_optional = false
         local vararg_name
         for _, child in ipairs(arg_block) do
            if type(child) == "table" then
               if child.kind == "question" then
                  is_optional = true
               elseif not vararg_name and child.kind == "identifier" then
                  vararg_name = new_node(state, child, "identifier")
               end
            end
         end

         if arg_node.tk == "..." then
            arg_node.name = vararg_name
            has_varargs = true
            is_optional = true
         else
            if not is_optional and not has_varargs then
               min_arity = min_arity + 1
            end
         end

         arg_node.opt = is_optional

         table.insert(node, arg_node)
      end
   end

   return node, min_arity
end

local comment_node_kinds = {
   ["local_declaration"] = true,
   ["global_declaration"] = true,
   ["local_function"] = true,
   ["global_function"] = true,
   ["record_function"] = true,
   ["local_type"] = true,
   ["global_type"] = true,
   ["local_macroexp"] = true,
   ["local_macro"] = true,
}

local function comment_block_to_comment(cb)
   return {
      x = cb.x,
      y = cb.y,
      text = cb.tk or "",
   }
end

local function comment_block_end_y(cb)
   if cb.yend then
      return cb.yend
   end
   local text = cb.tk or ""
   local _, newlines = string.gsub(text, "\n", "")
   return cb.y + newlines
end

local function is_long_comment_block(cb)
   local text = cb.tk or ""
   return text:match("^%-%-%[(=*)%[") ~= nil
end

local function extract_attached_comments(pending, target)
   if #pending == 0 then
      return nil
   end

   local last = pending[#pending]
   if is_long_comment_block(last) then
      local diff_y = target.y - comment_block_end_y(last)

      if diff_y >= 0 and diff_y <= 1 then
         table.remove(pending, #pending)
         return { comment_block_to_comment(last) }
      else
         return nil
      end
   end

   local diff_y = target.y - last.y
   if diff_y < 0 or diff_y > 1 then
      return nil
   end

   local first = 1
   for i = #pending, 2, -1 do
      local prev = pending[i - 1]
      if is_long_comment_block(prev) then
         first = i
         break
      end

      if pending[i].y - prev.y > 1 then
         first = i
         break
      end
   end

   local attached_blocks = {}
   for i = first, #pending do
      table.insert(attached_blocks, pending[i])
   end
   for i = #pending, first, -1 do
      table.remove(pending, i)
   end

   local comments = {}
   for _, cb in ipairs(attached_blocks) do
      table.insert(comments, comment_block_to_comment(cb))
   end
   return comments
end

local function flush_unattached_comments(node, pending)
   if #pending == 0 then
      return
   end
   if not node.unattached_comments then
      node.unattached_comments = {}
   end
   for _, cb in ipairs(pending) do
      table.insert(node.unattached_comments, comment_block_to_comment(cb))
   end
   for i = #pending, 1, -1 do
      table.remove(pending, i)
   end
end

local function parse_statements(state, block, toplevel)
   if not block then
      local dummy_block = { kind = "statements", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      return new_node(state, dummy_block, "statements")
   end

   local node = new_node(state, block, "statements")
   local pending_comments = {}

   if block[1] and block[1].kind == "hashbang" then
      node.hashbang = block[1].tk
   end

   local parsed_item
   for _, item_block in ipairs(block) do
      if item_block.kind == "comment" then
         table.insert(pending_comments, item_block)
      elseif item_block.kind == ";" then
         if #node > 0 then
            node[#node].semicolon = true
         end
      elseif item_block.kind ~= "hashbang" then
         parsed_item = parse_block(state, item_block)
         if parsed_item then
            if comment_node_kinds[item_block.kind] then
               local attached = extract_attached_comments(pending_comments, item_block)
               if attached then
                  parsed_item.comments = attached
               end
            end

            if toplevel and #pending_comments > 0 then
               flush_unattached_comments(node, pending_comments)
            else
               for i = #pending_comments, 1, -1 do
                  table.remove(pending_comments, i)
               end
            end


            if parsed_item.kind == "statements" then
               for _, c in ipairs(parsed_item) do
                  table.insert(node, c)
               end
            else
               table.insert(node, parsed_item)
            end
         end
      end
   end

   if toplevel and #pending_comments > 0 then
      flush_unattached_comments(node, pending_comments)
   end

   return node
end

local function node_is_require_call(n)
   if n.kind == "op" and n.op.op == "." then

      return node_is_require_call(n.e1)
   elseif n.kind == "op" and n.op.op == "@funcall" and
      n.e1.kind == "variable" and n.e1.tk == "require" and
      n.e2.kind == "expression_list" and #n.e2 == 1 and
      n.e2[1].kind == "string" then


      return n.e2[1].conststr
   end
   return nil
end

local block_to_constructor

parse_expression = function(state, block)
   if not block then return nil end

   local kind = block.kind
   local op_info = op_kinds[kind]

   if op_info then
      local node = new_node(state, block, "op")
      node.tk = nil
      node.op = {
         y = block.y,
         x = block.x,
         arity = op_info.arity,
         op = op_info.op,
         prec = precedences[op_info.arity][op_info.op],
      }
      node.e1 = parse_expression(state, block[reader.BLOCK_INDEXES.OP.E1])
      if not node.e1 then

         local dummy_block = { kind = "error_block", y = block.y or 1, x = block.x or 1, tk = "", yend = block.yend or 1, xend = block.xend or 1 }
         node.e1 = new_node(state, dummy_block, "error_node")
      end
      if op_info.arity == 2 then
         if op_info.op == "@funcall" then
            node.e2 = parse_expression_list(state, block[reader.BLOCK_INDEXES.OP.E2])
            local r = node_is_require_call(node)
            if not r and node.kind == "op" and node.op and node.e1.kind == "variable" and node.e1.tk == "pcall" then
               if node.e2 and #node.e2 == 2 then
                  local arg1 = node.e2[1]
                  local arg2 = node.e2[2]
                  if arg1.kind == "variable" and arg1.tk == "require" and arg2.kind == "string" and arg2.conststr then
                     r = arg2.conststr
                  end
               end
            end
            if r then
               table.insert(state.required_modules, r)
            end
         elseif op_info.op == "as" or op_info.op == "is" then
            node.e2 = new_node(state, block[reader.BLOCK_INDEXES.OP.E2], "cast")
            if node.e2 and block[reader.BLOCK_INDEXES.OP.E2] and block[reader.BLOCK_INDEXES.OP.E2] then
               local ct_block = block[reader.BLOCK_INDEXES.OP.E2]
               if ct_block.kind == "tuple_type" then
                  local ct
                  ct = parse_type_list(state, ct_block, "casttype")
                  node.e2.casttype = ct
               else
                  node.e2.casttype = parse_type(state, ct_block)
               end
            end
         elseif op_info.op == "." or op_info.op == ":" then

            node.e2 = new_node(state, block[reader.BLOCK_INDEXES.OP.E2], "identifier")
            if not node.e2 then
               local dummy_block = { kind = "identifier", y = block.y or 1, x = block.x or 1, tk = "", yend = block.yend or 1, xend = block.xend or 1 }
               node.e2 = new_node(state, dummy_block, "identifier")
            end
         else
            node.e2 = parse_expression(state, block[reader.BLOCK_INDEXES.OP.E2])
            if not node.e2 then
               local dummy_block = { kind = "error_block", y = block.y or 1, x = block.x or 1, tk = "", yend = block.yend or 1, xend = block.xend or 1 }
               node.e2 = new_node(state, dummy_block, "error_node")
            end
         end
      end
      node.safe_navigation = block[reader.BLOCK_INDEXES.OP.SAFE] ~= nil
      node.optional_chain = node.safe_navigation or
      ((op_info.op == "." or op_info.op == ":" or op_info.op == "@index" or op_info.op == "@funcall") and node.e1.optional_chain)
      return node
   end

   local node = new_node(state, block)

   if kind == "conditional" then
      node.e1 = parse_expression(state, block[1]) or new_node(state, block, "error_node")
      node.e2 = parse_expression(state, block[2]) or new_node(state, block, "error_node")
      node.e3 = parse_expression(state, block[3]) or new_node(state, block, "error_node")
   elseif kind == "string" then
      node.conststr = reader.string_value(block)
      node.is_longstring = reader.is_long_string(block)
   elseif kind == "number" or kind == "integer" then
      node.kind = kind
      node.constnum = block_number_value(block)
      local normalized = block.tk:gsub("_", ""):lower()
      node.luajit_literal = normalized:sub(-2) == "ll" or normalized:sub(-1) == "i"
   elseif kind == "boolean" then
      node.kind = kind
   elseif kind == "identifier" then
      node.kind = "variable"
   elseif kind == "macro_var" then
      if not state.in_macro_quote then
         fail(state, block, "macro variables can only appear in macro quotes")
      end
      node.kind = "macro_var"
   elseif kind == "paren" then
      node.e1 = parse_expression(state, block[reader.BLOCK_INDEXES.PAREN.EXP])
   elseif kind == "literal_table" then
      for _, item_block in ipairs(block) do
         local item_node = new_node(state, item_block, "literal_table_item")
         if item_node then
            if item_block.tk == "[" then
               item_node.key_parsed = "long"
               item_node.key = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY])
               item_node.value = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE])
            elseif item_block.tk == "..." then
               item_node.key_parsed = "implicit"
               item_node.key = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY])
               item_node.value = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE])
            else
               if item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] and item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].kind == "integer" then
                  item_node.key_parsed = "implicit"
                  item_node.key = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY])
                  item_node.value = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE])
               else
                  item_node.key_parsed = "short"
                  item_node.key = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY])
                  if item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.TYPED_VALUE] then
                     item_node.itemtype = parse_type(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE])
                     item_node.value = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.TYPED_VALUE])
                  else
                     item_node.value = parse_expression(state, item_block[reader.BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE])
                  end
               end
            end
            table.insert(node, item_node)
         end
      end
   elseif kind == "function" then
      node.short_function = block[reader.BLOCK_INDEXES.FUNCTION.SHORT] ~= nil
      local rets_block = block[reader.BLOCK_INDEXES.FUNCTION.RETS]
      node.has_return_annotation = rets_block and rets_block.tk == ":"
      node.typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.FUNCTION.TYPEARGS])
      local args, min_arity = parse_argument_list(state, block[reader.BLOCK_INDEXES.FUNCTION.ARGS])
      node.args = args
      if node.short_function then
         for _, argument in ipairs(args) do argument.short_function = true end
      end
      node.min_arity = min_arity
      local r = parse_type_list(state, block[reader.BLOCK_INDEXES.FUNCTION.RETS], "rets")
      node.rets = r
      node.body = parse_statements(state, block[reader.BLOCK_INDEXES.FUNCTION.BODY])
   elseif kind == "macro_invocation" then
      if state.in_local_macro then
         fail(state, block, "macro invocations cannot appear inside macro bodies")
      end




      node.kind = "error_node"
   elseif kind == "macro_quote" then
      if state.in_macro_quote then
         fail(state, block, "cannot nest macro quotes")
      end
      if not block[reader.BLOCK_INDEXES.MACRO_QUOTE.BLOCK] then
         return new_node(state, block, "literal_table")
      end
      local inner = block[reader.BLOCK_INDEXES.MACRO_QUOTE.BLOCK]
      state.in_macro_quote = true
      local res = block_to_constructor(state, inner)
      state.in_macro_quote = false
      return res
   end
   return node
end

local function new_type(state, block, typename)
   return raw_type(state.filename, block.y, block.x, typename)
end

local function new_typedecl(state, block, def)
   local t = new_type(state, block, "typedecl")
   t.def = def
   return t
end

local function set_declname(def, declname)
   if def.typename == "generic" then
      def = def.t
   end

   if def.typename == "record" or def.typename == "interface" or def.typename == "enum" then
      if not def.declname then
         def.declname = declname
      end
   end
end

local function parse_newtype(state, block)
   local node = new_node(state, block, "newtype")
   if not node then
      local dummy_block = { kind = "newtype", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "newtype")
   end


   local default_type = new_type(state, block, "any")
   node.newtype = new_typedecl(state, block, default_type)


   if block[reader.BLOCK_INDEXES.NEWTYPE.TYPEDECL] then
      local def_block = block[reader.BLOCK_INDEXES.NEWTYPE.TYPEDECL]
      if def_block.kind == "typedecl" and def_block[reader.BLOCK_INDEXES.TYPEDECL.TYPE] then

         local inner_type = def_block[reader.BLOCK_INDEXES.TYPEDECL.TYPE]
         local typename = inner_type.kind
         if typename == "enum" then
            local enum_type = new_type(state, inner_type, "enum")
            enum_type.enumset = {}
            enum_type.value_comments = {}
            local pending_comments = {}
            for _, value_block in ipairs(inner_type) do
               if value_block.kind == "comment" then
                  table.insert(pending_comments, value_block)
               elseif value_block and value_block.tk then
                  local value_str = value_block.tk
                  if value_block.kind == "string" then
                     value_str = reader.string_value(value_block) or value_str
                  elseif value_str:match('^".*"$') or value_str:match("^'.*'$") then
                     value_str = value_str:sub(2, -2)
                  end
                  enum_type.enumset[value_str] = true
                  local comments = extract_attached_comments(pending_comments, value_block)
                  if comments then
                     enum_type.value_comments[value_str] = comments
                  else
                     for i = #pending_comments, 1, -1 do
                        table.remove(pending_comments, i)
                     end
                  end
               end
            end
            node.newtype = new_typedecl(state, def_block, enum_type)
         else
            local type_node = parse_type(state, inner_type)
            if type_node then
               node.newtype = new_typedecl(state, def_block, type_node)
               if type_node.typename == "nominal" then
                  node.newtype.is_alias = true
               elseif type_node.typename == "generic" then
                  local deft = (type_node).t
                  if deft and deft.typename == "nominal" then
                     node.newtype.is_alias = true
                  end
               end
            end
         end
      else
         local type_node = parse_type(state, def_block)
         if type_node then
            node.newtype = new_typedecl(state, block, type_node)
            if type_node.typename == "nominal" then
               node.newtype.is_alias = true
            elseif type_node.typename == "generic" then
               local deft = (type_node).t
               if deft and deft.typename == "nominal" then
                  node.newtype.is_alias = true
               end
            end
         end
      end
   end

   return node
end


local parse_fns = {}

parse_fns.local_declaration = function(state, block)
   assert(block)
   local node = new_node(state, block)
   node.vars = parse_variable_list(state, block[reader.BLOCK_INDEXES.LOCAL_DECLARATION.VARS], false)
   node.lj_const = block[reader.BLOCK_INDEXES.LOCAL_DECLARATION.CONST] ~= nil
   if node.lj_const then
      for _, var in ipairs(node.vars) do
         var.attribute = "const"
         var.lj_const = true
      end
   end

   if node.vars then
      for _, var_node in ipairs(node.vars) do
         if var_node.kind == "variable" then
            var_node.is_lvalue = true
         elseif var_node.kind == "op" and var_node.op and (var_node.op.op == "@index" or var_node.op.op == ".") then
            var_node.is_lvalue = true
         end
      end
   end
   local next_child = reader.BLOCK_INDEXES.LOCAL_DECLARATION.DECL
   if block[next_child] and block[next_child].kind == "tuple_type" then
      local dt
      dt = parse_type_list(state, block[next_child], "decltuple")
      node.decltuple = dt
      next_child = reader.BLOCK_INDEXES.LOCAL_DECLARATION.EXPS
   else
      local dummy_block = { kind = "tuple_type", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      dummy_block[1] = { kind = "type_list", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      local dt
      dt = parse_type_list(state, dummy_block, "decltuple")
      node.decltuple = dt

      next_child = reader.BLOCK_INDEXES.LOCAL_DECLARATION.EXPS
   end
   if block[next_child] and block[next_child].kind == "expression_list" then
      node.exps = parse_expression_list(state, block[next_child])
   end
   return node
end
parse_fns.global_declaration = parse_fns.local_declaration

parse_fns.assignment = function(state, block)
   assert(block)
   local node = new_node(state, block)
   node.vars = parse_variable_list(state, block[reader.BLOCK_INDEXES.ASSIGNMENT.VARS], true)
   if block[reader.BLOCK_INDEXES.ASSIGNMENT.EXPS] and block[reader.BLOCK_INDEXES.ASSIGNMENT.EXPS].kind == "expression_list" then
      node.exps = parse_expression_list(state, block[reader.BLOCK_INDEXES.ASSIGNMENT.EXPS])
   end

   local operator = block[reader.BLOCK_INDEXES.ASSIGNMENT.OPERATOR]
   if operator then
      node.compound = operator.tk:sub(1, -2)
   end
   if node.compound and node.exps and node.exps[1] then
      local rhs = node.exps[1]
      node.exps[1] = setmetatable({
         kind = "op", f = rhs.f, y = rhs.y, x = rhs.x, yend = rhs.yend, xend = rhs.xend,
         op = ast.operator(node, 2, node.compound),
         e1 = node.vars[1], e2 = rhs, compound_value = true,
      }, node_mt)
   end
   if node.vars then
      for _, var_node in ipairs(node.vars) do
         if var_node.kind == "variable" then
            var_node.is_lvalue = true
         elseif var_node.kind == "op" and var_node.op and (var_node.op.op == "@index" or var_node.op.op == ".") then
            var_node.is_lvalue = true
         end
      end
   end
   return node
end

parse_fns["if"] = function(state, block)
   assert(block)
   local node = new_node(state, block)

   node.if_blocks = {}

   for i, if_block_block in ipairs(block) do
      local if_block_node = new_node(state, if_block_block, "if_block")
      if not if_block_node then
         fail(state, if_block_block, "invalid if block")
      else
         if_block_node.if_parent = node
         if_block_node.if_block_n = i

         local cond = if_block_block[reader.BLOCK_INDEXES.IF_BLOCK.COND]
         local body = if_block_block[reader.BLOCK_INDEXES.IF_BLOCK.BODY]

         if cond then

            if_block_node.exp = parse_expression(state, cond)
            if not if_block_node.exp then
               fail(state, cond, "invalid condition expression")
            end
         end

         if_block_node.body = parse_statements(state, body)

         if not if_block_node.body then
            fail(state, if_block_block, "invalid block body")
         end

         table.insert(node.if_blocks, if_block_node)
      end
   end

   if #node.if_blocks == 0 then
      fail(state, block, "if statement has no blocks")
   end

   return node
end

parse_fns["while"] = function(state, block)
   local node = new_node(state, block)
   if not node then
      local dummy_block = { kind = "while", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "while")
   end

   if not block[reader.BLOCK_INDEXES.WHILE.COND] then
      fail(state, block, "while statement missing condition")
      return node
   end
   if not block[reader.BLOCK_INDEXES.WHILE.BODY] then
      fail(state, block, "while statement missing body")
      return node
   end

   node.exp = parse_expression(state, block[reader.BLOCK_INDEXES.WHILE.COND])
   if not node.exp then
      fail(state, block[reader.BLOCK_INDEXES.WHILE.COND], "invalid while condition")
   end

   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.WHILE.BODY])
   if not node.body then
      fail(state, block[reader.BLOCK_INDEXES.WHILE.BODY], "invalid while body")
   end

   return node
end

parse_fns.fornum = function(state, block)
   assert(block)
   local node = new_node(state, block)

   node.var = new_node(state, block[reader.BLOCK_INDEXES.FORNUM.VAR], "identifier")

   node.from = parse_expression(state, block[reader.BLOCK_INDEXES.FORNUM.FROM]) or new_node(state, block, "error_node")
   node.to = parse_expression(state, block[reader.BLOCK_INDEXES.FORNUM.TO]) or new_node(state, block, "error_node")

   if block[reader.BLOCK_INDEXES.FORNUM.STEP] then
      node.step = parse_expression(state, block[reader.BLOCK_INDEXES.FORNUM.STEP])
   end

   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.FORNUM.BODY])

   return node
end

parse_fns["forin"] = function(state, block)
   local node = new_node(state, block, "forin")
   if not node then
      local dummy_block = { kind = "forin", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "forin")
   end
   node.vars = parse_variable_list(state, block[reader.BLOCK_INDEXES.FORIN.VARS], false)
   node.exps = parse_expression_list(state, block[reader.BLOCK_INDEXES.FORIN.EXPS])
   if node.exps and #node.exps < 1 then
      fail(state, block[reader.BLOCK_INDEXES.FORIN.EXPS], "missing iterator expression in generic for")
   elseif node.exps and #node.exps > 3 then
      fail(state, block[reader.BLOCK_INDEXES.FORIN.EXPS], "too many expressions in generic for")
   end
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.FORIN.BODY])
   return node
end

parse_fns["repeat"] = function(state, block)
   local node = new_node(state, block)
   if not node then
      local dummy_block = { kind = "repeat", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "repeat")
   end
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.REPEAT.BODY])
   if node.body then
      node.body.is_repeat = true
   end
   node.exp = parse_expression(state, block[reader.BLOCK_INDEXES.REPEAT.COND])
   return node
end

parse_fns["do"] = function(state, block)
   local node = new_node(state, block)
   if not node then
      local dummy_block = { kind = "do", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "do")
   end
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.DO.BODY])
   return node
end

parse_fns["return"] = function(state, block)
   local node = new_node(state, block)
   if not node then
      local dummy_block = { kind = "return", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "return")
   end
   node.exps = parse_expression_list(state, block[reader.BLOCK_INDEXES.RETURN.EXPS])
   return node
end

parse_fns["continue"] = function(state, block)
   return new_node(state, block)
end

parse_fns["break"] = function(state, block)
   return new_node(state, block)
end

parse_fns["goto"] = function(state, block)
   local node = new_node(state, block)
   if not node then
      local dummy_block = { kind = "goto", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
      node = new_node(state, dummy_block, "goto")
   end
   if block[reader.BLOCK_INDEXES.GOTO.LABEL] then
      node.label = block[reader.BLOCK_INDEXES.GOTO.LABEL].tk
   end
   return node
end

parse_fns.label = function(state, block)
   assert(block)
   local node = new_node(state, block)
   if block[reader.BLOCK_INDEXES.LABEL.NAME] then
      node.label = block[reader.BLOCK_INDEXES.LABEL.NAME].tk
   end
   return node
end

parse_fns.local_function = function(state, block)
   assert(block)
   local node = new_node(state, block, "local_function")
   node.lj_const = block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.CONST] ~= nil

   if not block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.NAME] then
      fail(state, block, "local function missing name")
      return node
   end
   if not block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.ARGS] then
      fail(state, block, "local function missing argument list")
      return node
   end
   if not block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.BODY] then
      fail(state, block, "local function missing body")
      return node
   end

   node.name = new_node(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.NAME], "identifier")
   if not node.name then
      fail(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.NAME], "invalid function name")
      return node
   end

   node.typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.TYPEARGS])
   local args, min_arity = parse_argument_list(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.ARGS])
   node.args = args
   node.min_arity = min_arity
   local r
   r = parse_type_list(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.RETS], "rets")
   node.rets = r
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.BODY])

   if not node.body then
      fail(state, block[reader.BLOCK_INDEXES.LOCAL_FUNCTION.BODY], "invalid function body")
   end

   return node
end

parse_fns.local_macro = function(state, block)
   assert(block)
   if not block[reader.BLOCK_INDEXES.LOCAL_MACRO.NAME] then
      fail(state, block, "local macro missing name")
      return
   end
   if not block[reader.BLOCK_INDEXES.LOCAL_MACRO.ARGS] then
      fail(state, block, "local macro missing argument list")
      return
   end
   if not block[reader.BLOCK_INDEXES.LOCAL_MACRO.BODY] then
      fail(state, block, "local macro missing body")
      return
   end

   local name_node = new_node(state, block[reader.BLOCK_INDEXES.LOCAL_MACRO.NAME], "identifier")
   local typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.LOCAL_MACRO.TYPEARGS])
   local args, min_arity = parse_argument_list(state, block[reader.BLOCK_INDEXES.LOCAL_MACRO.ARGS])
   local r
   r = parse_type_list(state, block[reader.BLOCK_INDEXES.LOCAL_MACRO.RETS], "rets")
   local prev_local = state.in_local_macro
   local prev_quote = state.in_macro_quote
   state.in_local_macro = true
   state.in_macro_quote = false
   local body_stmts = parse_statements(state, block[reader.BLOCK_INDEXES.LOCAL_MACRO.BODY])
   state.in_local_macro = prev_local
   state.in_macro_quote = prev_quote
   local fn = new_node(state, block, "local_function")
   fn.name = name_node
   fn.typeargs = typeargs
   fn.args = args
   fn.min_arity = min_arity
   fn.rets = r
   fn.body = body_stmts
   fn[1] = body_stmts[1]
   return fn
end

function block_to_constructor(state, block)
   if not block then return nil end

   if block.kind == "macro_invocation" then
      fail(state, block, "macro invocations cannot appear inside macro quotes")
      return new_node(state, block, "error_node")
   end

   if block.kind == "macro_var" then
      local call = new_node(state, block, "op")
      call.tk = nil
      call.op = {
         y = block.y,
         x = block.x,
         arity = 2,
         op = "@funcall",
         prec = precedences[2]["@funcall"],
      }
      call.e1 = new_node(state, block, "variable")
      call.e1.tk = "clone"
      call.e2 = new_node(state, block, "expression_list")
      call.e2[1] = new_node(state, block[reader.BLOCK_INDEXES.MACRO_VAR.NAME], "variable")
      call.e2[1].tk = block[reader.BLOCK_INDEXES.MACRO_VAR.NAME] and block[reader.BLOCK_INDEXES.MACRO_VAR.NAME].tk or ""
      call.e2[2] = new_node(state, block, "string")
      call.e2[2].tk = string.format("%q", call.e2[1].tk)
      return call
   end

   local function add_string_field(tbl, owner, keyname, value)
      local it = new_node(state, owner, "literal_table_item")
      it.key_parsed = "short"
      it.key = new_node(state, owner, "identifier")
      it.key.tk = string.format("%q", keyname)
      it.value = new_node(state, owner, "string")
      it.value.tk = string.format("%q", value)
      it.value.conststr = value
      table.insert(tbl, it)
   end

   local function add_number_field(tbl, owner, keyname, value)
      local it = new_node(state, owner, "literal_table_item")
      it.key_parsed = "short"
      it.key = new_node(state, owner, "identifier")
      it.key.tk = string.format("%q", keyname)
      it.value = new_node(state, owner, "number")
      it.value.tk = tostring(value)
      it.value.constnum = value
      table.insert(tbl, it)
   end

   local node = new_node(state, block, "literal_table")
   if not node.yend then
      node.yend = block.yend or block.y
   end

   add_string_field(node, block, "kind", block.kind)

   if block.tk and block.tk ~= "" then
      add_string_field(node, block, "tk", block.tk)
   end

   if block.y then
      add_number_field(node, block, "y", block.y)
   end
   if block.x then
      add_number_field(node, block, "x", block.x)
   end
   if block.yend then
      add_number_field(node, block, "yend", block.yend)
   end
   if block.xend then
      add_number_field(node, block, "xend", block.xend)
   end

   local numeric_keys = {}
   for k, v in pairs(block) do
      if math.type(k) == "integer" and v and v.kind ~= nil then
         table.insert(numeric_keys, k)
      end
   end
   table.sort(numeric_keys)
   for _, i in ipairs(numeric_keys) do
      local child = block[i]
      local item = new_node(state, child, "literal_table_item")
      item.key_parsed = "long"
      item.key = new_node(state, child, "integer")
      item.key.tk = tostring(i)
      item.key.constnum = i
      item.value = block_to_constructor(state, child)
      table.insert(node, item)
   end

   return node
end

parse_fns.macro_var = function(state, block)
   assert(block)
   if not state.in_macro_quote then
      fail(state, block, "macro variables can only appear in macro quotes")
      return
   end
   local node = new_node(state, block, "macro_var")
   if block[reader.BLOCK_INDEXES.MACRO_VAR.NAME] then
      node.name = new_node(state, block[reader.BLOCK_INDEXES.MACRO_VAR.NAME], "identifier")
   end
   return node
end

parse_fns.global_function = function(state, block)
   assert(block)
   local node = new_node(state, block, "global_function")

   if not block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.NAME] then
      fail(state, block, "global function missing name")
      return node
   end
   if not block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.ARGS] then
      fail(state, block, "global function missing argument list")
      return node
   end
   if not block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.BODY] then
      fail(state, block, "global function missing body")
      return node
   end

   node.name = new_node(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.NAME], "identifier")
   if not node.name then
      fail(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.NAME], "invalid function name")
      return node
   end

   node.typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.TYPEARGS])
   node.has_return_annotation = block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.RETS] and block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.RETS].tk == ":"
   local args, min_arity = parse_argument_list(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.ARGS])
   node.args = args
   node.min_arity = min_arity
   local r
   r = parse_type_list(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.RETS], "rets")
   node.rets = r
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.BODY])

   if not node.body then
      fail(state, block[reader.BLOCK_INDEXES.GLOBAL_FUNCTION.BODY], "invalid function body")
   end

   return node
end

parse_fns.record_function = function(state, block)
   assert(block)
   local node = new_node(state, block, "record_function")
   if node then
      node.tk = "function"
   end

   if not block[reader.BLOCK_INDEXES.RECORD_FUNCTION.OWNER] then
      fail(state, block, "record function missing owner")
      return node
   end
   if not block[reader.BLOCK_INDEXES.RECORD_FUNCTION.NAME] then
      local gblock = {
         f = block.f,
         kind = "global_function",
         tk = block.tk,
         y = block.y,
         x = block.x,
         yend = block.yend,
         xend = block.xend,
         [reader.BLOCK_INDEXES.GLOBAL_FUNCTION.NAME] = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.OWNER],
         [reader.BLOCK_INDEXES.GLOBAL_FUNCTION.TYPEARGS] = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.TYPEARGS],
         [reader.BLOCK_INDEXES.GLOBAL_FUNCTION.ARGS] = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.ARGS],
         [reader.BLOCK_INDEXES.GLOBAL_FUNCTION.RETS] = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.RETS],
         [reader.BLOCK_INDEXES.GLOBAL_FUNCTION.BODY] = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.BODY],
      }
      local gnode = parse_fns.global_function(state, gblock)
      gnode.implicit_global_function = true
      return gnode
   end
   if not block[reader.BLOCK_INDEXES.RECORD_FUNCTION.ARGS] then
      fail(state, block, "record function missing argument list")
      return node
   end
   if not block[reader.BLOCK_INDEXES.RECORD_FUNCTION.BODY] then
      fail(state, block, "record function missing body")
      return node
   end

   local owner_block = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.OWNER]
   local name_block = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.NAME]

   node.fn_owner = parse_expression(state, owner_block)
   if not node.fn_owner then
      fail(state, owner_block, "invalid function owner")
      return node
   end


   local left = node.fn_owner
   while left.kind == "op" and left.op.op == "." do
      left = left.e1
   end
   if left and left.kind == "variable" then
      left.kind = "type_identifier"
   end

   node.name = new_node(state, name_block, "identifier")
   if not node.name then
      fail(state, name_block, "invalid function name")
      return node
   end

   node.typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.TYPEARGS])
   node.has_return_annotation = block[reader.BLOCK_INDEXES.RECORD_FUNCTION.RETS] and block[reader.BLOCK_INDEXES.RECORD_FUNCTION.RETS].tk == ":"

   node.is_method = block.tk == ":"
   local args, min_arity = parse_argument_list(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.ARGS])
   node.args = args
   node.min_arity = min_arity
   if node.is_method and node.args then
      local self_node = new_node(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.ARGS], "identifier")
      if self_node then
         self_node.tk = "self"
         self_node.is_self = true
         table.insert(node.args, 1, self_node)
         node.min_arity = node.min_arity + 1
      end
   end
   local r
   r = parse_type_list(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.RETS], "rets")
   node.rets = r
   node.body = parse_statements(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.BODY])

   if not node.body then
      fail(state, block[reader.BLOCK_INDEXES.RECORD_FUNCTION.BODY], "invalid function body")
   end

   return node
end

parse_fns.pragma = function(state, block)
   assert(block)
   local node = new_node(state, block)
   if block[reader.BLOCK_INDEXES.PRAGMA.KEY] then
      node.pkey = block[reader.BLOCK_INDEXES.PRAGMA.KEY].tk
   end
   if block[reader.BLOCK_INDEXES.PRAGMA.VALUE] then
      node.pvalue = block[reader.BLOCK_INDEXES.PRAGMA.VALUE].tk
   end
   return node
end

parse_fns.local_type = function(state, block)
   assert(block)
   local node = new_node(state, block)
   if block[reader.BLOCK_INDEXES.LOCAL_TYPE.VAR] then
      node.var = new_node(state, block[reader.BLOCK_INDEXES.LOCAL_TYPE.VAR])
   end
   if block[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE] then
      if block[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE].kind == "newtype" then
         node.value = parse_newtype(state, block[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE])
         if node.value and node.value.newtype and node.var and node.var.tk then
            local def = node.value.newtype.def
            if def and def.typename == "generic" and def.t.typename == "generic" then
               fail(state, block[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE], "cannot declare type arguments twice in type declaration")
            end
            set_declname(node.value.newtype.def, node.var.tk)
         end
      else
         node.value = parse_expression(state, block[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE])
      end
   end
   return node
end
parse_fns.global_type = function(state, block)
   assert(block)
   local node = new_node(state, block)
   if block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VAR] then
      node.var = new_node(state, block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VAR])
   end
   if block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VALUE] then
      if block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VALUE].kind == "newtype" then
         node.value = parse_newtype(state, block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VALUE])
         if node.value and node.value.newtype and node.var and node.var.tk then
            local def = node.value.newtype.def
            if def and def.typename == "generic" and (def).t and (def).t.typename == "generic" then
               fail(state, block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VALUE], "cannot declare type arguments twice in type declaration")
            end
            set_declname(node.value.newtype.def, node.var.tk)
         end
      else
         node.value = parse_expression(state, block[reader.BLOCK_INDEXES.GLOBAL_TYPE.VALUE])
      end
   end
   return node
end
parse_fns.interface = function(state, block)
   assert(block)
   return new_node(state, block)
end
parse_fns.local_macroexp = function(state, block)
   assert(block)
   local node = new_node(state, block, "local_macroexp")

   if block[reader.BLOCK_INDEXES.LOCAL_MACROEXP.NAME] then
      node.name = new_node(state, block[reader.BLOCK_INDEXES.LOCAL_MACROEXP.NAME], "identifier")
   end

   if block[reader.BLOCK_INDEXES.LOCAL_MACROEXP.EXP] then
      node.macrodef = parse_fns.macroexp(state, block[reader.BLOCK_INDEXES.LOCAL_MACROEXP.EXP])
   end

   return node
end
parse_fns.macroexp = function(state, block)
   assert(block)
   local node = new_node(state, block, "macroexp")

   local idx = 1
   if block[idx] and block[idx].kind == "type_list" then
      node.typeargs = parse_typeargs_if_any(state, block[idx])
      idx = idx + 1
   end

   node.args, node.min_arity = parse_argument_list(state, block[idx])
   local r
   r = parse_type_list(state, block[idx + 1], "rets")
   node.rets = r
   node.exp = parse_expression(state, block[idx + 2])

   return node
end




parse_block = function(state, block)
   if not block then return nil end

   local kind = block.kind
   if kind == "statements" then
      return parse_statements(state, block)
   end
   local f = parse_fns[block.kind]
   if f then
      return f(state, block)
   else
      return parse_expression(state, block)
   end
end

function ast.parse_blocks(input, filename, parse_lang)
   filename = filename or "input"
   if not input then
      return nil, { { filename = filename, y = 1, x = 1, msg = "input is nil" } }, {}
   end

   local state = {
      block = input,
      errs = {},
      filename = filename,
      end_alignment_hint = nil,
      required_modules = {},
      parse_lang = parse_lang or "tl",
      in_local_macro = false,
      in_macro_quote = false,
   }

   local nodes = parse_statements(state, input, true)

   errors.clear_redundant_errors(state.errs)
   return nodes, state.errs, state.required_modules
end

function ast.parse(input, filename, parse_lang)
   return ast.parse_blocks(input, filename, parse_lang)
end

function ast.parse_program_block(input, filename, parse_lang)
   return ast.parse_blocks(input, filename, parse_lang)
end

local function new_generic(state, block, typeargs, typ)
   local gt = new_type(state, block, "generic")
   gt.typeargs = typeargs
   gt.t = typ
   return gt
end

local function new_tuple(state, block, typelist, is_va)
   local t = new_type(state, block, "tuple")
   t.is_va = is_va
   t.tuple = typelist or {}
   return t, t.tuple
end

local function new_nominal(state, block, name)
   local t = new_type(state, block, "nominal")
   if name then
      t.names = { name }
   end
   return t
end

local parse_base_type
local parse_simple_type_or_nominal
local parse_function_type
local parse_record_like_type
local parse_where_clause

parse_typeargs_if_any = function(state, block)
   if not block or block.kind ~= "type_list" then
      return nil
   end

   local out = {}

   for _, ta_block_item in ipairs(block) do
      if ta_block_item.kind == "typeargs" then
         local ta = new_type(state, ta_block_item, "typearg")
         local ok = true

         local name_block = ta_block_item[reader.BLOCK_INDEXES.TYPEARG.NAME]
         if name_block and name_block.kind == "identifier" then
            ta.typearg = name_block.tk
         else
            fail(state, ta_block_item, "expected type argument name")
            ok = false
         end

         if ok then
            local constraint_block = ta_block_item[reader.BLOCK_INDEXES.TYPEARG.CONSTRAINT]
            if constraint_block then
               local constraint_type = parse_type(state, constraint_block)
               if constraint_type then
                  ta.constraint = constraint_type
               else
                  fail(state, constraint_block, "invalid type constraint")

               end
            end

            table.insert(out, ta)
         end
      end
   end

   return out
end

parse_function_type = function(state, block)
   local typ = new_type(state, block, "function")

   local args, maybemet, min_arity = parse_type_list(state, block[reader.BLOCK_INDEXES.FUNCTION_TYPE.ARGS], "decltuple")
   typ.args = args
   typ.maybe_method = maybemet
   typ.min_arity = min_arity
   local rets
   rets = parse_type_list(state, block[reader.BLOCK_INDEXES.FUNCTION_TYPE.RETS], "rets")
   typ.rets = rets
   typ.is_method = false

   if block[reader.BLOCK_INDEXES.FUNCTION_TYPE.MACROEXP] then
      typ.macroexp = parse_fns.macroexp(state, block[reader.BLOCK_INDEXES.FUNCTION_TYPE.MACROEXP])
   end

   return typ
end

parse_where_clause = function(state, block, def)
   local node = new_node(state, block, "macroexp")
   node.is_method = true
   node.args = new_node(state, block[reader.BLOCK_INDEXES.MACROEXP.ARGS] or block, "argument_list")
   node.args[1] = new_node(state, block[reader.BLOCK_INDEXES.MACROEXP.ARGS] and block[reader.BLOCK_INDEXES.MACROEXP.ARGS][1] or block, "argument")
   node.args[1].tk = "self"
   local selftype = new_type(state, block, "self")
   selftype.display_type = def
   node.args[1].argtype = selftype
   node.min_arity = 1
   local ret_tuple = new_tuple(state, block, { new_type(state, block, "boolean") })
   node.rets = ret_tuple
   node.exp = parse_expression(state, block[reader.BLOCK_INDEXES.MACROEXP.EXP])
   return node
end

local function store_field_in_record(state, block, name, newt, def, meta, comments)
   local fields
   local order
   local field_comments
   local field_locations
   if meta then
      if not def.meta_fields then
         def.meta_fields = {}
         def.meta_field_order = {}
      end
      fields = def.meta_fields
      order = def.meta_field_order
      field_comments = def.meta_field_comments
      field_locations = def.meta_field_locations
      if not field_comments then
         field_comments = {}
         def.meta_field_comments = field_comments
      end
      if not field_locations then
         field_locations = {}
         def.meta_field_locations = field_locations
      end
   else
      if not def.field_comments then
         def.field_comments = {}
      end
      fields = def.fields
      order = def.field_order
      field_comments = def.field_comments
      field_locations = def.field_locations
      if not field_locations then
         field_locations = {}
         def.field_locations = field_locations
      end
   end

   if comments and not field_comments then
      field_comments = {}
      if meta then
         def.meta_field_comments = field_comments
      else
         def.field_comments = field_comments
      end
   end

   if not fields[name] then
      if newt.typename == "typedecl" then
         set_declname(newt.def, name)
      end
      fields[name] = newt
      field_locations[name] = { f = state.filename, y = block.y, x = block.x }
      field_comments[name] = field_comments[name] or {}
      if comments then
         field_comments[name] = { comments }
      end
      table.insert(order, name)
      return
   end

   local oldt = fields[name]
   local function basetype(t)
      if t.typename == "generic" then
         return t.t
      else
         return t
      end
   end
   local oldf = basetype(oldt)
   local newf = basetype(newt)

   local function store_comment_for_poly(poly)
      if not field_comments then
         return
      end
      if comments then
         if not field_comments[name] then
            field_comments[name] = {}
         end
         while #field_comments[name] < (#poly.types - 1) do
            table.insert(field_comments[name], {})
         end
         table.insert(field_comments[name], comments)
      elseif field_comments and field_comments[name] then
         table.insert(field_comments[name], {})
      end
   end

   if newf.typename == "function" then
      if oldf.typename == "function" then
         local p = new_type(state, block, "poly")
         p.types = { oldt, newt }
         fields[name] = p
         store_comment_for_poly(p)
      elseif oldt.typename == "poly" then
         table.insert((oldt).types, newt)
         store_comment_for_poly(oldt)
      else
         fail(state, block, "attempt to redeclare field '" .. name .. "' (only functions can be overloaded)")
      end
   else
      fail(state, block, "attempt to redeclare field '" .. name .. "' (only functions can be overloaded)")
   end
end

parse_record_like_type = function(state, block, typename)
   local decl = new_type(state, block, typename)
   decl.fields = {}
   decl.field_order = {}
   decl.field_comments = {}
   decl.meta_field_comments = {}

   if typename == "interface" then
      decl.interface_list = {}
   end

   if block[reader.BLOCK_INDEXES.RECORD.ARRAY_TYPE] then
      if block[reader.BLOCK_INDEXES.RECORD.ARRAY_TYPE].kind == "array_type" then
         local atype = parse_base_type(state, block[reader.BLOCK_INDEXES.RECORD.ARRAY_TYPE])
         decl.elements = atype.elements
         decl.interface_list = { atype }
      elseif block[reader.BLOCK_INDEXES.RECORD.ARRAY_TYPE].kind == "type_list" then
         local atype = parse_base_type(state, block[reader.BLOCK_INDEXES.RECORD.ARRAY_TYPE])
         decl.types = atype.types
         decl.interface_list = { atype }
      end
   end

   if block[reader.BLOCK_INDEXES.RECORD.INTERFACES] and block[reader.BLOCK_INDEXES.RECORD.INTERFACES].kind == "interface_list" then
      decl.interface_list = decl.interface_list or {}
      for _, iface in ipairs(block[reader.BLOCK_INDEXES.RECORD.INTERFACES]) do
         table.insert(decl.interface_list, parse_type(state, iface))
      end
   end

   local userdata_seen = false
   for _, child in ipairs(block) do
      if child.kind == "userdata" then
         if userdata_seen then
            fail(state, child, "duplicated 'userdata' declaration")
         end
         decl.is_userdata = true
         userdata_seen = true
      end
   end

   local function parse_field_list(list_block, meta)
      if not list_block then return end
      local pending_field_comments = {}
      for _, fld in ipairs(list_block) do
         if fld.kind == "comment" then
            table.insert(pending_field_comments, fld)
         elseif fld.kind == "record_field" then
            local name_node = fld[reader.BLOCK_INDEXES.RECORD_FIELD.NAME]
            local comments = extract_attached_comments(pending_field_comments, name_node or fld)
            local field_name
            if name_node and name_node.kind == "string" then
               field_name = reader.string_value(name_node) or name_node.tk or ""
            else
               field_name = name_node and name_node.tk or ""
            end
            local t = parse_type(state, fld[reader.BLOCK_INDEXES.RECORD_FIELD.TYPE])
            if t.typename == "function" and t.maybe_method then
               t.is_method = true
            end
            store_field_in_record(state, name_node or fld, field_name, t, decl, meta, comments)
            for i = #pending_field_comments, 1, -1 do
               table.remove(pending_field_comments, i)
            end
         elseif fld.kind == "local_type" then
            local target = fld[reader.BLOCK_INDEXES.LOCAL_TYPE.VAR] or fld
            local comments = extract_attached_comments(pending_field_comments, target)
            if fld[reader.BLOCK_INDEXES.LOCAL_TYPE.VAR] and fld[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE] then
               local vname = fld[reader.BLOCK_INDEXES.LOCAL_TYPE.VAR].tk
               local nt_node = parse_newtype(state, fld[reader.BLOCK_INDEXES.LOCAL_TYPE.VALUE])
               if nt_node and nt_node.newtype then
                  store_field_in_record(state, fld, vname, nt_node.newtype, decl, meta, comments)
               end
            end
            for i = #pending_field_comments, 1, -1 do
               table.remove(pending_field_comments, i)
            end
         else
            for i = #pending_field_comments, 1, -1 do
               table.remove(pending_field_comments, i)
            end
         end
      end
   end

   parse_field_list(block[reader.BLOCK_INDEXES.RECORD.FIELDS], false)
   parse_field_list(block[reader.BLOCK_INDEXES.RECORD.META_FIELDS], true)

   if block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE] then
      local where_macroexp = parse_where_clause(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], decl)
      local typ = new_type(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], "function")
      typ.is_method = true
      typ.min_arity = 1
      local self_arg = a_type(where_macroexp, "self", { display_type = decl })
      typ.args = new_tuple(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], { self_arg })
      typ.rets = new_tuple(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], { new_type(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], "boolean") })
      typ.macroexp = where_macroexp
      store_field_in_record(state, block[reader.BLOCK_INDEXES.RECORD.WHERE_CLAUSE], "__is", typ, decl, true)
   end

   return decl
end

parse_simple_type_or_nominal = function(state, block)
   local tk = block.tk
   local st = simple_types[tk]
   local rest = block[reader.BLOCK_INDEXES.NOMINAL_TYPE.NAME + 1]
   if st and not (rest and rest.kind == "identifier") then
      return new_type(state, block, tk)
   elseif tk == "table" and block.kind ~= "nominal_type" then
      local typ = new_type(state, block, "map")
      typ.keys = new_type(state, block, "any")
      typ.values = new_type(state, block, "any")
      return typ
   end

   if block.kind == "nominal_type" then
      local name_block = block[reader.BLOCK_INDEXES.NOMINAL_TYPE.NAME] or block[1]
      if name_block and name_block.kind == "nominal_type" then
         return parse_simple_type_or_nominal(state, name_block)
      end

      local typ = new_nominal(state, block)
      typ.names = {}
      local current_block_idx = 1

      if block[current_block_idx] and block[current_block_idx].kind == "identifier" then
         table.insert(typ.names, block[current_block_idx].tk)
         current_block_idx = current_block_idx + 1
      elseif block.tk and block.tk ~= "" then
         table.insert(typ.names, block.tk)
      else
         if name_block and name_block.kind == "identifier" then
            table.insert(typ.names, name_block.tk)
            if block[1] == name_block then
               current_block_idx = current_block_idx + 1
            end
         else
            fail(state, block, "Nominal type block has no initial name part in tk or first child.")
            table.insert(typ.names, "unknown_nominal_type")
            return typ
         end
      end


      while block[current_block_idx] and block[current_block_idx].kind == "identifier" do
         table.insert(typ.names, block[current_block_idx].tk)
         current_block_idx = current_block_idx + 1
      end


      if block[current_block_idx] and block[current_block_idx].kind == "type_list" then
         typ.typevals = {}
         for _, tv_block in ipairs(block[current_block_idx]) do
            local parsed_tv = parse_type(state, tv_block)
            if parsed_tv then
               table.insert(typ.typevals, parsed_tv)
            else
               fail(state, tv_block, "Invalid type argument in nominal type.")
            end
         end
      end
      if #typ.names == 0 then
         fail(state, block, "Nominal type ended up with no name parts.")
         table.insert(typ.names, block.tk or "unknown_nominal_final")
      end
      return typ
   end

   return new_nominal(state, block, tk)
end

parse_base_type = function(state, block)
   if not block then
      fail(state, { y = 1, x = 1 }, "expected a type")
      return new_type(state, { y = 1, x = 1 }, "any")
   end

   local tk = block.tk

   if block.kind == "identifier" or block.kind == "nominal_type" or simple_types[tk] then
      return parse_simple_type_or_nominal(state, block)
   elseif block.kind == "function" then
      return parse_function_type(state, block)
   elseif block.kind == "generic_type" then
      local typeargs = parse_typeargs_if_any(state, block[reader.BLOCK_INDEXES.GENERIC_TYPE.TYPEARGS])
      local base = parse_base_type(state, block[reader.BLOCK_INDEXES.GENERIC_TYPE.BASE])
      return new_generic(state, block, typeargs, base)
   elseif block.kind == "record" then
      return parse_record_like_type(state, block, "record")
   elseif block.kind == "interface" then
      return parse_record_like_type(state, block, "interface")
   elseif block.kind == "array_type" then
      local decl = new_type(state, block, "array")
      decl.elements = parse_type(state, block[reader.BLOCK_INDEXES.ARRAY_TYPE.ELEMENT])
      end_at(decl, block)
      return decl
   elseif block.kind == "map_type" then
      local decl = new_type(state, block, "map")
      decl.keys = parse_type(state, block[reader.BLOCK_INDEXES.MAP_TYPE.KEYS])
      decl.values = parse_type(state, block[reader.BLOCK_INDEXES.MAP_TYPE.VALUES])
      end_at(decl, block)
      return decl
   elseif block.kind == "type_list" and block.tk == "{" then
      local decl = new_type(state, block, "tupletable")
      decl.types = {}
      for _, t in ipairs(block) do
         table.insert(decl.types, parse_type(state, t))
      end
      end_at(decl, block)
      return decl
   elseif block.kind == "union_type" then
      local u = new_type(state, block, "union")
      u.types = {}
      for _, t in ipairs(block) do
         table.insert(u.types, parse_type(state, t))
      end
      end_at(u, block)
      return u
   elseif block.kind == "string" then
      local decl = new_type(state, block, "string")
      decl.literal = reader.string_value(block)
      end_at(decl, block)
      return decl
   elseif block.kind == "number" then
      local decl = new_type(state, block, "number")
      decl.literal = block_number_value(block)
      end_at(decl, block)
      return decl
   elseif block.kind == "integer" then
      local decl = new_type(state, block, "integer")
      decl.literal = block_number_value(block)
      end_at(decl, block)
      return decl
   elseif block.kind == "boolean" then
      local decl = new_type(state, block, "boolean")
      decl.literal = block.tk == "true"
      end_at(decl, block)
      return decl
   elseif block.kind == "nil" then
      return new_type(state, block, "nil")
   end

   fail(state, block, "expected a type")
   return new_type(state, block, "any")
end

parse_type = function(state, block)
   if not block then
      return new_type(state, { y = 1, x = 1 }, "any")
   end

   if block.kind == "paren" then
      if not block[reader.BLOCK_INDEXES.PAREN.EXP] then
         fail(state, block, "empty parentheses in type")
         return new_type(state, block, "any")
      end
      return parse_type(state, block[reader.BLOCK_INDEXES.PAREN.EXP])
   end

   if block.kind == "union_type" then
      local u = new_type(state, block, "union")
      u.types = {}
      for _, t in ipairs(block) do
         table.insert(u.types, parse_base_type(state, t))
      end
      return u
   end

   if block.kind == "type_list" and block.tk == "{" then
      return parse_base_type(state, block)
   end

   local bt = parse_base_type(state, block)
   if not bt then
      fail(state, block, "failed to parse type")
      return new_type(state, block, "any")
   end

   return bt
end

parse_type_list = function(state, block, mode)
   local t, list = new_tuple(state, block or { y = 1, x = 1, tk = "", kind = "type_list" })
   local maybe_method = false
   local min_arity = 0


   if not block then
      return t, maybe_method, min_arity
   end

   assert(block.kind == "tuple_type")
   local type_list_block = block[1]
   assert(type_list_block.kind == "type_list")
   assert(not block[2])

   for idx, item in ipairs(type_list_block) do
      if item.kind == "argument_type" then
         local arg_name = item[reader.BLOCK_INDEXES.ARGUMENT_TYPE.NAME]
         local arg_type = item[reader.BLOCK_INDEXES.ARGUMENT_TYPE.TYPE]
         local arg_va = item[reader.BLOCK_INDEXES.ARGUMENT_TYPE.VARARG]
         local arg_opt = item[reader.BLOCK_INDEXES.ARGUMENT_TYPE.OPTIONAL]

         if arg_name and arg_name.kind == "identifier" and arg_name.tk == "self" and #list == 0 then
            maybe_method = true
         end

         local typ = parse_type(state, arg_type)
         if typ then
            table.insert(list, typ)
         else
            fail(state, item, "invalid type in list")
         end

         if arg_va and idx < #type_list_block then
            local msg = "'...' can only be last in a type list"
            if mode == "decltuple" then
               msg = "'...' can only be last argument"
            end
            fail(state, item, msg)
         end

         if arg_va then
            t.is_va = true
         end
         if not arg_opt and not arg_va then
            min_arity = min_arity + 1
         end
      elseif item.kind == "..." then
         if idx == #type_list_block then
            t.is_va = true
         else
            local msg = "'...' can only be last in a type list"
            if mode == "decltuple" then
               msg = "'...' can only be last argument"
            end
            fail(state, item, msg)
         end
      else
         local parsed_type = parse_type(state, item)
         if parsed_type then
            table.insert(list, parsed_type)
         else
            fail(state, item, "invalid type in list")
         end
      end
   end

   return t, maybe_method, min_arity
end

function ast.parse_type(state, block)
   return parse_type(state, block)
end

function ast.parse_type_list(state, block, mode)
   return parse_type_list(state, block, mode)
end

function ast.operator(node, arity, op)
   return { y = node.y, x = node.x, arity = arity, op = op, prec = precedences[arity][op] }
end

function ast.node_is_funcall(node)
   return node.kind == "op" and node.op.op == "@funcall"
end

function ast.node_is_require_call(n)
   if n.kind == "op" and n.op.op == "." then

      return ast.node_is_require_call(n.e1)
   elseif n.kind == "op" and n.op.op == "@funcall" and
      n.e1.kind == "variable" and n.e1.tk == "require" and
      n.e2.kind == "expression_list" and #n.e2 == 1 and
      n.e2[1].kind == "string" then


      return n.e2[1].conststr
   end
   return nil
end

function ast.node_at(w, n)
   n.f = assert(w.f)
   n.x = w.x
   n.y = w.y
   return n
end

return ast

end

-- module teal.block from teal/block.lua
package.preload["teal.block"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string
local errors = require("teal.errors")


local block = { Block = {} }













































































































































local BLOCK_INDEXES = {
   PRAGMA = {
      KEY = 1,
      VALUE = 2,
   },
   IF_BLOCK = {
      COND = 1,
      BODY = 2,
   },
   WHILE = {
      COND = 1,
      BODY = 2,
   },
   FORNUM = {
      VAR = 1,
      FROM = 2,
      TO = 3,
      STEP = 4,
      BODY = 5,
   },
   FORIN = {
      VARS = 1,
      EXPS = 2,
      BODY = 3,
   },
   REPEAT = {
      BODY = 1,
      COND = 2,
   },
   DO = {
      BODY = 1,
   },
   GOTO = {
      LABEL = 1,
   },
   LABEL = {
      NAME = 1,
   },
   RETURN = {
      EXPS = 1,
   },
   FUNCTION = {
      SHORT = 1,
      TYPEARGS = 2,
      ARGS = 3,
      RETS = 4,
      BODY = 5,
   },
   LOCAL_FUNCTION = {
      NAME = 1,
      TYPEARGS = 2,
      ARGS = 3,
      RETS = 4,
      BODY = 5,
      CONST = 6,
   },
   GLOBAL_FUNCTION = {
      NAME = 1,
      TYPEARGS = 2,
      ARGS = 3,
      RETS = 4,
      BODY = 5,
   },
   RECORD_FUNCTION = {
      OWNER = 1,
      NAME = 2,
      TYPEARGS = 3,
      ARGS = 4,
      RETS = 5,
      BODY = 6,
   },
   LOCAL_MACRO = {
      NAME = 1,
      TYPEARGS = 2,
      ARGS = 3,
      RETS = 4,
      BODY = 5,
      OWNER = 6,
      IMPORT_ALIAS = 7,
      TARGET = 8,
      OPERATOR = 9,
   },
   LOCAL_MACROEXP = {
      NAME = 1,
      EXP = 2,
   },
   LOCAL_DECLARATION = {
      VARS = 1,
      DECL = 2,
      EXPS = 3,
      CONST = 4,
   },
   GLOBAL_DECLARATION = {
      VARS = 1,
      DECL = 2,
      EXPS = 3,
   },
   LOCAL_TYPE = {
      VAR = 1,
      VALUE = 2,
   },
   GLOBAL_TYPE = {
      VAR = 1,
      VALUE = 2,
   },
   ASSIGNMENT = {
      VARS = 1,
      OPERATOR = 2,
      EXPS = 3,
   },
   VARIABLE = {
      ANNOTATION = 1,
   },
   ARGUMENT = {
      TYPE = 1,
   },
   LITERAL_TABLE_ITEM = {
      KEY = 1,
      VALUE = 2,
      TYPED_VALUE = 3,
      IMPLICIT_KEY = 4,
   },
   OP = {
      E1 = 1,
      E2 = 2,
      SAFE = 3,
   },
   PAREN = {
      EXP = 1,
      OPERATOR_GROUPING = 2,
   },
   MACRO_QUOTE = {
      BLOCK = 1,
   },
   MACRO_VAR = {
      NAME = 1,
   },
   MACRO_INVOCATION = {
      MACRO = 1,
      ARGS = 2,
      OPERATOR = 3,
   },
   OPERATOR_SPEC = {
      BINDING = 1,
      FIXITY = 2,
      PRECEDENCE = 3,
      ASSOCIATIVITY = 4,
   },
   CAST = {
      TYPE = 1,
   },
   NEWTYPE = {
      TYPEDECL = 1,
   },
   TYPEDECL = {
      TYPE = 1,
   },
   FUNCTION_TYPE = {
      ARGS = 1,
      RETS = 2,
      MACROEXP = 4,
   },
   MACROEXP = {
      ARGS = 1,
      RETS = 2,
      EXP = 3,
   },
   RECORD = {
      ARRAY_TYPE = 1,
      INTERFACES = 2,
      FIELDS = 3,
      META_FIELDS = 4,
      WHERE_CLAUSE = 5,
   },
   INTERFACE = {
      ARRAY_TYPE = 1,
      INTERFACES = 2,
      FIELDS = 3,
   },
   RECORD_BODY = {
      FIELDS = 1,
      META_FIELDS = 2,
   },
   RECORD_FIELD = {
      NAME = 1,
      TYPE = 2,
      VAL = 3,
      METHOD = 4,
      DEFAULT_VAL = 5,
   },
   ARGUMENT_TYPE = {
      NAME = 1,
      TYPE = 2,
      VARARG = 3,
      OPTIONAL = 4,
   },
   TYPEARG = {
      NAME = 1,
      CONSTRAINT = 2,
   },
   GENERIC_TYPE = {
      TYPEARGS = 1,
      BASE = 2,
   },
   NOMINAL_TYPE = {
      NAME = 1,
   },
   ARRAY_TYPE = {
      ELEMENT = 1,
   },
   MAP_TYPE = {
      KEYS = 1,
      VALUES = 2,
   },
}

local BLOCK_KINDS = {
   ["nil"] = true,
   ["string"] = true,
   ["number"] = true,
   ["integer"] = true,
   ["boolean"] = true,
   ["literal_table"] = true,
   ["literal_table_item"] = true,
   ["function"] = true,
   ["expression_list"] = true,
   ["if"] = true,
   ["if_block"] = true,
   ["while"] = true,
   ["fornum"] = true,
   ["forin"] = true,
   ["goto"] = true,
   ["label"] = true,
   ["repeat"] = true,
   ["do"] = true,
   ["continue"] = true,
   ["conditional"] = true,
   ["break"] = true,
   ["return"] = true,
   ["newtype"] = true,
   ["argument"] = true,
   ["type_identifier"] = true,
   ["variable_list"] = true,
   ["statements"] = true,
   ["assignment"] = true,
   ["argument_list"] = true,
   ["local_function"] = true,
   ["global_function"] = true,
   ["local_type"] = true,
   ["global_type"] = true,
   ["record_function"] = true,
   ["local_declaration"] = true,
   ["global_declaration"] = true,
   ["identifier"] = true,
   ["cast"] = true,
   ["..."] = true,
   [":"] = true,
   [";"] = true,
   ["comment"] = true,
   ["hashbang"] = true,
   ["paren"] = true,
   ["macroexp"] = true,
   ["local_macroexp"] = true,
   ["local_macro"] = true,
   ["macro_quote"] = true,
   ["macro_var"] = true,
   ["macro_invocation"] = true,
   ["operator_spec"] = true,
   ["operator_use"] = true,
   ["operator_grouping"] = true,
   ["implicit_table_key"] = true,
   ["short_function"] = true,
   ["native_const"] = true,
   ["safe_navigation"] = true,
   ["compound_operator"] = true,
   ["record"] = true,
   ["interface"] = true,
   ["enum"] = true,
   ["pragma"] = true,
   ["error_block"] = true,
   ["userdata"] = true,

   ["op_not"] = true,
   ["op_len"] = true,
   ["op_unm"] = true,
   ["op_bnot"] = true,
   ["op_or"] = true,
   ["op_and"] = true,
   ["op_is"] = true,
   ["op_lt"] = true,
   ["op_gt"] = true,
   ["op_le"] = true,
   ["op_ge"] = true,
   ["op_ne"] = true,
   ["op_eq"] = true,
   ["op_bor"] = true,
   ["op_bxor"] = true,
   ["op_band"] = true,
   ["op_shl"] = true,
   ["op_shr"] = true,
   ["op_sar"] = true,
   ["op_coalesce"] = true,
   ["op_concat"] = true,
   ["op_add"] = true,
   ["op_sub"] = true,
   ["op_mul"] = true,
   ["op_div"] = true,
   ["op_idiv"] = true,
   ["op_mod"] = true,
   ["op_pow"] = true,
   ["op_as"] = true,
   ["op_funcall"] = true,
   ["op_index"] = true,
   ["op_dot"] = true,
   ["op_colon"] = true,

   ["typeargs"] = true,
   ["type_list"] = true,
   ["generic_type"] = true,
   ["typedecl"] = true,
   ["tuple_type"] = true,
   ["nominal_type"] = true,
   ["map_type"] = true,
   ["array_type"] = true,
   ["union_type"] = true,
   ["argument_type"] = true,
   ["interface_list"] = true,
   ["record_body"] = true,
   ["record_field"] = true,
   ["question"] = true,
}

block.BLOCK_INDEXES = BLOCK_INDEXES
block.BLOCK_KINDS = BLOCK_KINDS

local fixed_child_limits = {}
for kind, slots in pairs(block.BLOCK_INDEXES) do
   local last = 0
   for _, index in pairs(slots) do
      last = math.max(last, index)
   end
   fixed_child_limits[kind:lower()] = last
end


function block.child_limit(b)
   local kind = b.kind
   local fixed = fixed_child_limits[kind] or
   (kind:sub(1, 3) == "op_" and fixed_child_limits.op) or 0
   return math.max(#b, fixed)
end

function block.is_long_string(b)
   return b.kind == "string" and b.tk and b.tk:match("^%[=*%[") ~= nil
end

function block.string_value(b)
   if not b or b.kind ~= "string" or not b.tk then
      return nil
   end
   local text = b.tk
   local first = text:sub(1, 1)
   if first == '"' or first == "'" then
      return text:sub(2, -2)
   end
   local opening = text:match("^%[=*%[")
   if opening then
      local start = #opening + 1
      return text:sub(start, -start)
   end
   return text
end

return block

end

-- module teal.check.check from teal/check/check.lua
package.preload["teal.check.check"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string
local context = require("teal.check.context")
local Context = context.Context
local c_ffi = require("teal.gen.c_ffi")

local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG

local environment = require("teal.environment")



local errors = require("teal.errors")






local traversal = require("teal.traversal")


local traverse_nodes = traversal.traverse_nodes

local types = require("teal.types")


local a_type = types.a_type

local util = require("teal.util")
local shallow_copy_table = util.shallow_copy_table

local variables = require("teal.variables")

local visitors = require("teal.check.visitors")
local visit_node = visitors.visit_node
local visit_type = visitors.visit_type

local check = {}



local function extension_type_after(fn)
   return function(self, node, children, t)
      t = fn and fn(self, node, children, t) or t
      if self.env.opts.gen_target ~= "luajit" and
         (node.kind == "conditional" or node.kind == "continue" or node.safe_navigation or node.compound or node.luajit_literal or
         (node.op and (node.op.op == "??" or node.op.op == "~>>"))) then
         self.errs:add(node, "this extension requires the luajit generation target")
      end
      if node.optional_chain then node.chain_value_type = t end
      if node.optional_chain and not node.is_lvalue then
         if t.typename == "tuple" then
            local tuple = {}
            for i, member in ipairs(t.tuple) do
               tuple[i] = types.unite(node, { member, a_type(node, "nil", {}) }, true, false)
            end
            return a_type(node, "tuple", { tuple = tuple, is_va = t.is_va })
         end
         return types.unite(node, { t, a_type(node, "nil", {}) }, true, false)
      end
      return t
   end
end



local function internal_compiler_check(fn)
   return function(s, n, children, t)
      t = fn and fn(s, n, children, t) or t

      if type(t) ~= "table" then
         error(((n).kind or (n).typename) .. " did not produce a type")
      end
      if type(t.typename) ~= "string" then
         error(((n).kind or (n).typename) .. " type does not have a typename")
      end

      return t
   end
end

local function store_type_after(fn)
   return function(self, n, children, t)
      t = fn and fn(self, n, children, t) or t

      local w = n

      if w.y then
         self.collector.store_type(w.y, w.x, t)
         local node = n
         if node.macro_expansion then
            self.collector.store_macro_expansion(w.y, w.x, node.macro_expansion)
         end
      end

      return t
   end
end

local function debug_type_after(fn)
   return function(s, node, children, t)
      t = fn and fn(s, node, children, t) or t

      node.debug_type = t
      return t
   end
end

local function patch_visitors(my_visit_node,
   after_node,
   my_visit_type,
   after_type)


   if my_visit_node == visit_node then
      my_visit_node = shallow_copy_table(my_visit_node)
   end
   my_visit_node.after = after_node(my_visit_node.after)
   if my_visit_type then
      if my_visit_type == visit_type then
         my_visit_type = shallow_copy_table(my_visit_type)
      end
      my_visit_type.after = after_type(my_visit_type.after)
   else
      my_visit_type = visit_type
   end
   return my_visit_node, my_visit_type
end

function check.check(ast, env, filename, dependency)
   assert(filename)

   local strict_pragma
   for _, stmt in ipairs(ast) do
      if stmt.kind == "pragma" then
         if stmt.pkey == "strict" and stmt.pvalue == "on" then
            strict_pragma = stmt
            break
         end
      else
         break
      end
   end
   local self = Context.new(env, filename, strict_pragma)
   ast.native_checked = nil
   ast.native_ffi = nil
   if env.opts.gen_target == "c" and not dependency then
      if not strict_pragma then
         self.errs:add(ast, "the C generation target requires '--#pragma strict on'")
      end
      if filename:match("%.lua$") or filename:match("%.d%.tl$") then
         self.errs:add(ast, "the C generation target expects a Teal source file")
      end
      self.native_ffi = c_ffi.new(ast)
      ast.native_ffi = self.native_ffi
      for _, stmt in ipairs(ast) do stmt.native_top_level = true end
   end

   local visit_node, visit_type = patch_visitors(visit_node, extension_type_after)
   if env.opts.run_internal_compiler_checks then
      visit_node, visit_type = patch_visitors(
      visit_node, internal_compiler_check,
      visit_type, internal_compiler_check)

   end
   if self.collector then
      visit_node, visit_type = patch_visitors(
      visit_node, store_type_after,
      visit_type, store_type_after)

   end
   if TL_DEBUG then
      visit_node, visit_type = patch_visitors(
      visit_node, debug_type_after)

   end

   assert(ast.kind == "statements")
   traverse_nodes(self, ast, visit_node, visit_type)

   local global_scope = self.st[1]
   variables.close_types(global_scope)
   self.errs:check_var_usage(global_scope)

   errors.clear_redundant_errors(self.errs.errors)
   if self.native_ffi then ast.native_checked = #self.errs.errors == 0 end

   local result = {
      ast = ast,
      env = env,
      type = self.module_type or a_type(ast, "boolean", {}),
      filename = filename,
      warnings = self.errs.warnings,
      type_errors = self.errs.errors,
      dependencies = self.dependencies,
      needs_compat = self.needs_compat,
   }

   environment.register(env, filename, result)

   if self.collector then
      env.reporter:store_result(self.collector, env.globals)
   end

   return result
end

return check

end

-- module teal.check.context from teal/check/context.lua
package.preload["teal.check.context"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local type = type













local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG





local errors = require("teal.errors")




local facts = require("teal.facts")

local FactDatabase = facts.FactDatabase
local eval_fact = facts.eval_fact
local facts_and = facts.facts_and
local facts_not = facts.facts_not

local macroexps = require("teal.macroexps")

local types = require("teal.types")



































local a_type = types.a_type
local a_function = types.a_function
local a_vararg = types.a_vararg
local drop_constant_value = types.drop_constant_value
local drop_constant_values = types.drop_constant_values
local ensure_not_method = types.ensure_not_method
local is_unknown = types.is_unknown
local is_valid_union = types.is_valid_union
local shallow_copy_new_type = types.shallow_copy_new_type
local show_type_base = types.show_type_base
local show_type = types.show_type
local simple_types = types.simple_types
local unite = types.unite
local untuple = types.untuple
local type_at = types.type_at
local typedecl_to_nominal = types.typedecl_to_nominal
local wrap_generic_if_typeargs = types.wrap_generic_if_typeargs

local parser = require("teal.parser")


local node_is_funcall = parser.node_is_funcall

local relations = require("teal.check.relations")

local special_functions = require("teal.check.special_functions")

local traversal = require("teal.traversal")


local traverse_nodes = traversal.traverse_nodes
local fields_of = traversal.fields_of

local type_reporter = require("teal.type_reporter")


local type_errors = require("teal.type_errors")
local Errors = type_errors.Errors
local ensure_not_abstract = type_errors.ensure_not_abstract

local util = require("teal.util")
local sorted_keys = util.sorted_keys
local shallow_copy_table = util.shallow_copy_table

local variables = require("teal.variables")



local has_var_been_used = variables.has_var_been_used

























local context = { Context = {} }




































local Context = context.Context



function Context:contains_dynamic(t, receiver)
   local seen = {}
   local function has_dynamic(typ)
      if not typ or seen[typ] then return false end
      seen[typ] = true
      if typ.typename == "any" or typ.typename == "unknown" then return true end
      if typ.typename == "tuple" or typ.typename == "union" then
         local members = typ.typename == "tuple" and typ.tuple or (typ).types
         for _, member in ipairs(members) do
            if has_dynamic(member) then return true end
         end
      elseif typ.typename == "typedecl" then
         return has_dynamic(typ.def)
      elseif typ.typename == "nominal" then
         for _, typearg in ipairs(typ.typevals or {}) do
            if has_dynamic(typearg) then return true end
         end
         return has_dynamic(typ.resolved or (typ.found and typ.found.def))
      elseif typ.typename == "generic" then
         for _, typearg in ipairs(typ.typeargs) do
            if has_dynamic(typearg.constraint) then return true end
         end
         return has_dynamic(typ.t)
      elseif typ.typename == "typevar" or typ.typename == "typearg" then
         return has_dynamic(typ.constraint)
      elseif not receiver then
         if typ.typename == "function" then
            return has_dynamic(typ.args) or has_dynamic(typ.rets)
         elseif typ.typename == "map" then
            return has_dynamic(typ.keys) or has_dynamic(typ.values)
         elseif typ.fields then
            for _, fields in ipairs({ typ.fields, typ.meta_fields or {} }) do
               for _, member in pairs(fields) do
                  if has_dynamic(member) then return true end
               end
            end
            for _, member in ipairs(typ.types or {}) do
               if has_dynamic(member) then return true end
            end
            return has_dynamic(typ.elements)
         elseif typ.typename == "array" then
            return has_dynamic(typ.elements)
         elseif typ.types then
            for _, member in ipairs(typ.types) do
               if has_dynamic(member) then return true end
            end
         end
      end
      return false
   end
   return has_dynamic(t)
end

function context.block_returns(body)
   local last = body[#body]
   if not last then return false end
   if last.kind == "return" then return true end
   if last.kind == "do" then return context.block_returns(last.body) end
   if last.kind == "if" and not last.if_blocks[#last.if_blocks].exp then
      for _, branch in ipairs(last.if_blocks) do
         if not context.block_returns(branch.body) then return false end
      end
      return true
   end
   return false
end



function Context:add_error(w, msg, t, ...)
   self.errs:add(w, msg, t, ...)
end

function Context:invalid_at(w, msg, ...)
   return self.errs:invalid_at(w, msg, ...)
end

function Context:add_errors_prefixing(w, src, prefix, dst)
   self.errs:add_prefixing(w, src, prefix, dst)
end

function Context:add_warning(tag, w, fmt, ...)
   self.errs:add_warning(tag, w, fmt, ...)
end

do
   local function get_real_var_from_lower_scope(st, i, name)
      for j = i - 1, 1, -1 do
         local scope = st[j]
         local sv = scope.vars[name]
         if sv and ((not sv.is_specialized) or (sv.specialized_from)) then
            return sv
         end
      end
   end

   function Context:find_var(name, use)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         local var = scope.vars[name]
         if var then
            if use == "lvalue" and var.is_specialized and var.is_specialized ~= "localizing" then
               if var.specialized_from then
                  var.has_been_written_to = true
                  return { t = var.specialized_from, attribute = var.attribute }, i, var.attribute
               end
            else
               if i == 1 and var.needs_compat then
                  self.needs_compat[name] = true
               end

               local real_var = var
               if var.is_specialized and var.is_specialized ~= "localizing" then
                  real_var = get_real_var_from_lower_scope(self.st, i, name) or real_var
               end
               if use == "use_type" then

                  real_var.used_as_type = true
               elseif use ~= "check_only" then
                  if use == "lvalue" then

                     real_var.has_been_written_to = true
                  else

                     real_var.has_been_read_from = true
                  end
               end

               return var, i, var.attribute
            end
         end
      end
   end
end

function Context:simulate_g()

   local globals = {}
   for k, v in pairs(self.st[1].vars) do
      if k:sub(1, 1) ~= "@" then
         globals[k] = v.t
      end
   end
   return {
      typeid = types.globals_typeid,
      typename = "record",
      field_order = sorted_keys(globals),
      fields = globals,
   }, nil
end

do
   local function unwrap_for_find_type(typ)
      if typ.typename == "nominal" and typ.found then
         return unwrap_for_find_type(typ.found)
      elseif typ.typename == "typedecl" then
         return unwrap_for_find_type(typ.def)
      elseif typ.typename == "generic" then
         return unwrap_for_find_type(typ.t)
      end
      return typ
   end

   function Context:find_type(names)
      local typ = self:find_var_type(names[1], "use_type")
      if not typ then
         if #names == 1 and names[1] == "metatable" then
            return self:find_type({ "_metatable" })
         end
         return nil
      end
      for i = 2, #names do
         typ = unwrap_for_find_type(typ)
         if typ == nil then
            return nil
         end

         local fields = typ.fields and typ.fields
         if not fields then
            return nil
         end

         typ = fields[names[i]]
         if typ == nil then
            return nil
         end
      end


      if typ and typ.typename == "nominal" then
         typ = typ.found
      end
      if typ == nil then
         return nil
      end

      if typ.typename == "typedecl" then
         return typ
      elseif typ.typename == "typearg" then
         return nil, typ
      end
   end
end

function Context:assert_resolved_typevars_at(w, t)
   local ret, errs = self:resolve_typevars(t)
   if errs then
      assert(w.y)
      self.errs:add_prefixing(w, errs, "")
   end


   if ret.typeid ~= t.typeid then
      return self:assert_resolved_typevars_at(w, ret)
   end

   if ret == t or t.typename == "typevar" then
      ret = shallow_copy_new_type(ret)
   end
   return type_at(w, ret)
end

function Context:infer_at(w, t)
   local ret = self:assert_resolved_typevars_at(w, t)
   if ret.typename == "invalid" then
      ret = t
   end

   if ret == t or t.typename == "typevar" then
      ret = shallow_copy_new_type(ret)
   end
   assert(w.f)
   ret.inferred_at = w
   return ret
end

function Context:infer_emptytable(emptytable, fresh_t)
   local nst = emptytable.is_global and 1 or #self.st
   for i = nst, 1, -1 do
      local scope = self.st[i]
      if scope.vars[emptytable.assigned_to] then
         scope.vars[emptytable.assigned_to] = { t = fresh_t }
      end
   end
end

function Context:infer_emptytable_from_unresolved_value(w, u, values)
   local et = u.emptytable_type
   assert(et.typename == "emptytable", u.typename)
   local keys = et.keys
   if not (values.typename == "emptytable" or values.typename == "unresolved_emptytable_value") then
      local infer_to = is_numeric_type(keys) and
      a_type(w, "array", { elements = values }) or
      a_type(w, "map", { keys = keys, values = values })
      self:infer_emptytable(et, self:infer_at(w, infer_to))
   end
end

function Context:check_if_redeclaration(new_name, node, t)
   local old
   if simple_types[new_name] then
      if t.typename ~= "typedecl" then
         return
      end
   else
      old = self:find_var(new_name, "check_only")
      if not old then
         return
      end
   end
   local var_name = node.tk
   local var_kind = "variable"
   if node.kind == "local_function" or node.kind == "record_function" then
      var_kind = "function"
      var_name = node.name.tk
   end
   self.errs:redeclaration_warning(node, var_name, var_kind, old)
end

do






   local resolve_typevar_fns = {
      ["typevar"] = function(s, t)
         local rt = s.ctx:find_var_type(t.typevar)
         if not rt then
            return t, false
         end

         if not s.keep_literals[t.typevar] then
            rt = drop_constant_value(rt)
         end
         s.resolved[t.typevar] = rt

         return rt, true
      end,
   }

   local function clear_resolved_typeargs(copy, resolved)
      for i = #copy.typeargs, 1, -1 do
         local r = resolved[copy.typeargs[i].typearg]
         if r then
            table.remove(copy.typeargs, i)
         end
      end
      if not copy.typeargs[1] then
         return copy.t
      end
      return copy
   end

   function Context:resolve_typevars(t, keep_literals)
      local state = {
         ctx = self,
         resolved = {},
         keep_literals = keep_literals or {},
      }
      local rt, errs = types.map(state, t, resolve_typevar_fns)
      if errs then
         return rt, errs
      end

      if rt.typename == "generic" then
         rt = clear_resolved_typeargs(rt, state.resolved)
      end

      return rt
   end
end

do
   local function specialize_var(scope, node, name, t, attribute, specialization)
      local var = scope.vars[name]
      if var then
         if var.is_specialized then
            var.t = t
            return var
         end

         var.is_specialized = specialization
         var.specialized_from = var.t
         var.t = t
      else
         var = { t = t, attribute = attribute, is_specialized = specialization, declared_at = node }
         scope.vars[name] = var
      end

      if specialization == "widen" then
         scope.widens = scope.widens or {}
         scope.widens[name] = true
      else
         scope.narrows = scope.narrows or {}
         scope.narrows[name] = true
      end

      return var
   end

   function Context:add_var(node, name, t, attribute, specialization, keep_literal)
      if self.feat_lax and node and is_unknown(t) and (name ~= "self" and name ~= "...") and not specialization then
         self.errs:add_unknown(node, name)
      end
      if not attribute and not keep_literal then
         t = drop_constant_values(t, false)
      end

      if self.collector and node then
         self.collector.add_to_symbol_list(node, name, t)
      end

      local scope = self.st[#self.st]
      if specialization then
         return specialize_var(scope, node, name, t, attribute, specialization)
      end

      if node then
         for i = #self.st, 1, -1 do
            local previous = self.st[i].vars[name]
            if previous and previous.declared_at and previous.declared_at.lj_const then
               self.errs:add(node, "cannot re-declare const variable '" .. name .. "'")
               break
            end
         end
         if name ~= "self" and name ~= "..." and name:sub(1, 1) ~= "@" then
            self:check_if_redeclaration(name, node, t)
         end
         if not ensure_not_abstract(t) then
            node.elide_type = true
         end
      end

      local var = scope.vars[name]
      if var and not has_var_been_used(var) then


         self.errs:unused_warning(name, var)
      end

      var = { t = t, attribute = attribute, declared_at = node }
      scope.vars[name] = var

      return var
   end

   function Context:add_implied_var(name, t)
      self:add_var(nil, name, t)
   end
end

function Context:fresh_typeargs(g)
   local newg, errs = types.fresh_typeargs(g)
   if newg.typename == "invalid" then
      self.errs:collect(errs)
      return g
   end
   return newg
end

function Context:find_var_type(name, use)
   local var = self:find_var(name, use)
   if var then
      local t = var.t
      if t.typename == "unresolved_typearg" then
         return nil, nil, t.constraint
      end

      if t.typename == "generic" then
         t = self:fresh_typeargs(t)
      end

      return t, var.attribute
   end
end

do
   local function unresolved_typeargs_for(g)
      local ts = {}
      for _, ta in ipairs(g.typeargs) do
         table.insert(ts, a_type(ta, "unresolved_typearg", {
            constraint = ta.constraint,
         }))
      end
      return ts
   end

   function Context:apply_generic(w, g, typeargs)
      if not g.fresh then
         g = self:fresh_typeargs(g)
      end

      if not typeargs then
         typeargs = unresolved_typeargs_for(g)
      end

      assert(#g.typeargs == #typeargs)

      for i, ta in ipairs(g.typeargs) do

         self:add_var(nil, ta.typearg, typeargs[i], nil, nil, true)
      end
      local keep_literals = {}
      if typeargs then
         for _, ta in ipairs(g.typeargs) do
            keep_literals[ta.typearg] = true
         end
      end
      local applied, errs = self:resolve_typevars(g, keep_literals)
      if errs then
         self.errs:add_prefixing(w, errs, "")
         return nil
      end

      if applied.typename == "generic" then
         return applied.t, g.typeargs
      else
         return applied, g.typeargs
      end
   end
end

function Context:add_self_type(w, def)
   self:add_var(nil, "@self", a_type(w, "typedecl", { def = def }))
end

function Context:widen_in_scope(n, var)
   local scope = self.st[n]
   local v = scope.vars[var]
   assert(v, "no " .. var .. " in scope")
   local specialization = scope.vars[var].is_specialized
   if (not specialization) or
      not (specialization == "narrow" or
      specialization == "narrowed_declaration") then

      return false
   end

   local top = #self.st
   if n ~= top then
      local t = v.specialized_from
      if not t then
         local old
         for i = n - 1, 1, -1 do
            old = self.st[i].vars[var]
            if old then
               if old.specialized_from then
                  t = old.specialized_from
                  break
               elseif old.is_specialized == "localizing" or not old.is_specialized then
                  t = old.t
                  break
               end
            end
         end


         if not t then
            return false
         end
      end
      self:add_var(nil, var, t, nil, "widen")
      return true
   end

   if v.specialized_from then
      v.t = v.specialized_from
      v.specialized_from = nil
      v.is_specialized = nil
   else
      scope.vars[var] = nil
   end

   if scope.narrows then
      scope.narrows[var] = nil
   end

   return true
end


function Context:widen_back_var(name)
   local widened = false
   for i = #self.st, 1, -1 do
      local scope = self.st[i]
      if scope.vars[name] then
         if self:widen_in_scope(i, name) then
            widened = true
         else
            break
         end
      end
   end
   return widened
end

function Context:collect_if_widens(widens)
   local st = self.st
   local scope = st[#st]
   if scope.widens then
      widens = widens or {}
      for k, _ in pairs(scope.widens) do
         widens[k] = true
      end
      scope.widens = nil
   end
   return widens
end

function Context:widen_all(widens, widen_types)
   for name, _ in pairs(widens) do
      local curr = self:find_var(name, "check_only")
      local prev = widen_types[name]
      if (not prev) or (curr and not self:same_type(curr.t, prev)) then
         self:widen_back_var(name)
      end
   end
end

function Context:begin_scope(node)
   table.insert(self.st, { vars = {} })

   if self.collector and node then
      self.collector.begin_symbol_list_scope(node)
   end
end

function Context:begin_implied_scope()
   self:begin_scope(nil)
end

function Context:end_scope(node)
   local st = self.st
   local scope = st[#st]

   local widen_types
   if scope.widens then
      widen_types = {}
      for name, _ in pairs(scope.widens) do
         local var = self:find_var(name, "check_only")
         widen_types[name] = var.t
      end
   end

   table.remove(st)
   local next_scope = st[#st]

   assert(not scope.is_transaction)

   variables.close_types(scope)
   self.errs:check_var_usage(scope)

   if scope.widens then
      self:widen_all(scope.widens, widen_types)
   end

   if self.collector and node then
      self.collector.end_symbol_list_scope(node)
   end

   if not next_scope then
      return
   end

   if scope.pending_labels then
      if next_scope.pending_labels then
         for name, nodes in pairs(scope.pending_labels) do
            for _, n in ipairs(nodes) do
               next_scope.pending_labels[name] = next_scope.pending_labels[name] or {}
               table.insert(next_scope.pending_labels[name], n)
            end
         end
      else
         next_scope.pending_labels = scope.pending_labels
      end
   end

   if scope.pending_nominals then
      if next_scope.pending_nominals then
         for name, typs in pairs(scope.pending_nominals) do
            for _, typ in ipairs(typs) do
               next_scope.pending_nominals[name] = next_scope.pending_nominals[name] or {}
               table.insert(next_scope.pending_nominals[name], typ)
            end
         end
      else
         next_scope.pending_nominals = scope.pending_nominals
      end
   end
end

function Context:end_implied_scope()
   self:end_scope(nil)
end

function Context:begin_scope_transaction(node)
   self:begin_scope(node)
   local st = self.st
   st[#st].is_transaction = true
end

function Context:rollback_scope_transaction()
   local st = self.st
   local scope = st[#st]
   assert(scope.is_transaction)

   local vars = scope.vars
   for k, _ in pairs(vars) do
      vars[k] = nil
   end

   if self.collector then
      self.collector.rollback_symbol_list_scope()
   end
end

function Context:commit_scope_transaction(node)
   local st = self.st
   local scope = st[#st]
   local next_scope = st[#st - 1]

   assert(scope.is_transaction)
   assert(not scope.pending_labels)
   assert(not scope.pending_nominals)

   for name, var in pairs(scope.vars) do
      local t = var.t
      next_scope.vars[name] = var
      assert(t)
   end

   table.remove(st)

   if self.collector and node then
      self.collector.end_symbol_list_scope(node)
   end
end

do
   local function find_nominal_type_decl(self, t)
      if t.resolved then
         return t.resolved
      end

      local found = t.found or self:find_type(t.names)
      if not found then
         return self.errs:invalid_at(t, "unknown type %s", t)
      end

      if found.typename == "typedecl" and found.is_alias then
         local def = found.def
         if def.typename == "nominal" then
            found = def.found
         end

      end

      if not found then
         return self.errs:invalid_at(t, table.concat(t.names, ".") .. " is not a resolved type")
      end

      if not (found.typename == "typedecl") then
         return self.errs:invalid_at(t, table.concat(t.names, ".") .. " is not a type")
      end

      local def = found.def
      if def.typename == "circular_require" then

         return def
      end

      assert(not (def.typename == "nominal"))

      t.found = found

      if self.collector then
         self.env.reporter:set_ref(t, found)
      end

      return nil, found
   end

   local resolve_decl_in_nominal
   do
      local function check_metatable_contract(self, tv, ret)
         if not ret or not (tv.typename == "nominal") then
            return
         end
         local found = tv.found
         if not found then
            return
         end
         local rec = found.def
         if not (rec.fields and rec.meta_fields and ret.fields) then
            return
         end
         for fname, ftype in pairs(rec.meta_fields) do
            if ret.fields[fname] then
               if not self:is_a(ftype, ret.fields[fname]) then
                  self.errs:add(ftype, fname .. " does not follow metatable contract: got %s, expected %s", ftype, ret.fields[fname])
               end
            end
            ret.fields[fname] = ftype
         end
      end

      local function match_typevals(self, t, def)
         if not t.typevals then

            local deft = def.t
            if (not (deft.typename == "function")) and (not (deft.typename == "poly")) then
               self.errs:add(t, "missing type arguments in %s", def)
               return nil
            end
         elseif #t.typevals ~= #def.typeargs then
            self.errs:add(t, "mismatch in number of type arguments")
            return nil
         end

         self:begin_implied_scope()

         local ret = self:apply_generic(t, def, t.typevals)
         if def == self.cache_std_metatable_type then
            check_metatable_contract(self, t.typevals[1], ret)
         end

         self:end_implied_scope()

         return ret
      end

      resolve_decl_in_nominal = function(self, t, found)
         local def = found.def
         local resolved
         if def.typename == "generic" then
            resolved = match_typevals(self, t, def)
            if not resolved then
               resolved = a_type(t, "invalid", {})
            end
         elseif t.typevals then
            resolved = self.errs:invalid_at(t, "unexpected type argument")
         else
            resolved = def
         end

         t.resolved = resolved

         return resolved
      end
   end

   function Context:resolve_nominal(t)
      local immediate, found = find_nominal_type_decl(self, t)
      if immediate then
         return immediate
      end

      return resolve_decl_in_nominal(self, t, found)
   end

   function Context:resolve_typealias(ta)
      local def = ta.def

      local nom = def
      if def.typename == "generic" then
         nom = def.t
      end

      if not (nom.typename == "nominal") then
         return ta
      end


      local immediate, found = find_nominal_type_decl(self, nom)

      if immediate and (immediate.typename == "invalid" or immediate.typename == "typedecl") then
         return immediate
      end


      if not nom.typevals then
         nom.resolved = found
         return found
      end




      local struc = resolve_decl_in_nominal(self, nom, found or nom.found)

      if def.typename == "generic" then
         struc = wrap_generic_if_typeargs(def.typeargs, struc)
      end


      local td = a_type(ta, "typedecl", { def = struc })
      nom.resolved = td


      return td
   end
end

function Context:arg_check(w, all_errs, a, b, v, mode, n)
   local ok, err, errs

   if v == "covariant" then
      ok, errs = self:is_a(a, b)
   elseif v == "contravariant" then
      ok, errs = self:is_a(b, a)
   elseif v == "bivariant" then
      ok, errs = self:is_a(a, b)
      if ok then
         return true
      end
      ok = self:is_a(b, a)
      if ok then
         return true
      end
   elseif v == "invariant" then
      ok, errs = self:same_type(a, b)
   end

   if ok and b.typename == "nominal" then
      local rb = self:resolve_nominal(b)
      ok, err = ensure_not_abstract(rb)
      if not ok then
         errs = { errors.at(w, err) }
      end
   end

   if not ok then
      self.errs:add_prefixing(w, errs, mode .. (n and " " .. n or "") .. ": ", all_errs)
      return false
   end
   return true
end

function Context:to_structural(t)
   assert(not (t.typename == "tuple"))
   if t.typename == "typevar" and t.constraint then
      t = t.constraint
   end
   if t.typename == "nominal" then
      t = self:resolve_nominal(t)
   end
   return t
end

function Context:arraytype_from_list(w, typelist)

   local element_type = unite(w, typelist, true, not self.feat_strict_nil)
   local valid = (not (element_type.typename == "union")) and true or is_valid_union(element_type)
   if valid then
      return a_type(w, "array", { elements = element_type }), true
   end


   local arr_type = a_type(w, "array", { elements = typelist[1] })
   for i = 2, #typelist do
      local expanded = self:expand_type(w, arr_type, a_type(w, "array", { elements = typelist[i] }))
      if not (expanded.typename == "array") then
         return nil, false
      end
      arr_type = expanded
   end
   return arr_type, true
end

function Context:arraytype_from_tuple(w, tupletype)
   local arr_type, valid = self:arraytype_from_list(w, tupletype.types)
   if not valid then
      return nil, { types.error("unable to convert tuple %s to array", tupletype) }
   end
   return arr_type
end

function Context:type_of_self(w)
   local t = self:find_var_type("@self")
   if not t then
      return a_type(w, "invalid", {}), nil
   end
   assert(t.typename == "typedecl")
   return t.def, t
end


function Context:is_a(t1, t2)
   return relations.compare_types(self, self.type_priorities, self.subtype_relations, t1, t2)
end


function Context:same_type(t1, t2)


   return relations.compare_types(self, self.type_priorities, self.eqtype_relations, t1, t2)
end

if TL_DEBUG then
   local orig_is_a = Context.is_a
   Context.is_a = function(self, t1, t2)
      assert(type(t1) == "table")
      assert(type(t2) == "table")

      if t1.typeid == t2.typeid then
         local st1, st2 = show_type_base(t1, false, {}), show_type_base(t2, false, {})
         assert(st1 == st2, st1 .. " ~= " .. st2)
         return true
      end

      return orig_is_a(self, t1, t2)
   end
end

function Context:same_in_all_union_entries(u, check)
   assert(#u.types > 0)

   local t1, f = check(u.types[1])
   if not t1 then
      return nil
   end
   for i = 2, #u.types do
      local t2 = check(u.types[i])
      if not t2 or not self:same_type(t1, t2) then
         return nil
      end
   end
   return f
end

function Context:same_call_mt_in_all_union_entries(u)
   return self:same_in_all_union_entries(u, function(t)
      t = self:to_structural(t)
      if t.fields then
         local call_mt = t.meta_fields and t.meta_fields["__call"]
         if call_mt.typename == "function" then
            local args_tuple = a_type(u, "tuple", { tuple = {} })
            for i = 2, #call_mt.args.tuple do
               table.insert(args_tuple.tuple, call_mt.args.tuple[i])
            end
            return args_tuple, call_mt
         end
      end
   end)
end

function Context:resolve_for_call(func, args, is_method)

   if self.feat_lax and is_unknown(func) then
      local unk = func
      func = a_function(func, {
         min_arity = 0,
         args = a_vararg(func, { unk }),
         rets = a_vararg(func, { unk }),
      })
   end

   func = self:to_structural(func)

   if func.typename == "generic" then
      func = self:apply_generic(func, func)
   end

   if func.typename == "function" or func.typename == "poly" then
      return func, is_method
   end


   if func.typename == "union" then
      local r = self:same_call_mt_in_all_union_entries(func)
      if r then
         table.insert(args.tuple, 1, func.types[1])
         return r, true
      end

   elseif func.typename == "typedecl" then
      return self:resolve_for_call(func.def, args, is_method)

   elseif func.fields and func.meta_fields and func.meta_fields["__call"] then
      local interface_type = func
      table.insert(args.tuple, 1, func)
      func = func.meta_fields["__call"]
      func = self:to_structural(func)

      func = types.map(interface_type, func, {
         ["self"] = function(iface, _typ)
            return iface, true
         end,
      })
      is_method = true
   end

   if func.typename == "generic" then
      func = self:apply_generic(func, func)
   end

   return func, is_method
end

do
   local function mark_invalid_typeargs(self, typeargs)
      for _, a in ipairs(typeargs) do
         if not self:find_var_type(a.typearg) then
            if a.constraint then
               self:add_var(nil, a.typearg, a.constraint)
            else
               self:add_var(nil, a.typearg, self.feat_lax and a_type(a, "unknown", {}) or a_type(a, "unresolvable_typearg", {
                  typearg = a.typearg,
               }))
            end
         end
      end
   end

   local function infer_emptytables(self, w, wheres, xs, ys, delta)
      local xt, yt = xs.tuple, ys.tuple
      local n_xs = #xt
      local n_ys = #yt

      for i = 1, n_xs do
         local x = xt[i]
         if x.typename == "emptytable" then
            local y = yt[i] or (ys.is_va and yt[n_ys])
            if y then
               local iw = wheres and wheres[i + delta] or w
               local inferred_y = self:infer_at(iw, y)
               self:infer_emptytable(x, inferred_y)
               xt[i] = inferred_y
            end
         end
      end
   end







   local check_call
   do
      local check_args_rets
      do

         local function check_func_type_list(self, w, wheres, xs, ys, from, delta, v, mode)
            local errs = {}
            local xt, yt = xs.tuple, ys.tuple
            local n_xs = #xt
            local n_ys = #yt

            for i = from, math.max(n_xs, n_ys) do
               local pos = i + delta
               local x = xt[i] or (xs.is_va and xt[n_xs]) or a_type(w, "nil", {})
               local y = yt[i] or (ys.is_va and yt[n_ys])
               if y then
                  local iw = wheres and wheres[pos] or w
                  if not self:arg_check(iw, errs, x, y, v, mode, pos) then
                     return nil, errs
                  end
               end
            end

            return true
         end

         check_args_rets = function(self, w, wargs, f, args, expected_rets, argdelta, or_args, or_rets)
            local rets_ok = true
            local args_ok, args_errs = true, nil

            local fargs = or_args or f.args
            local frets = or_rets or f.rets

            local from = 1
            if argdelta == -1 then
               from = 2
               local errs = {}
               local first = fargs.tuple[1]
               if (not (first.typename == "self")) and not self:arg_check(w, errs, first, args.tuple[1], "contravariant", "self") then
                  return nil, errs
               end
            end

            if expected_rets then
               expected_rets = self:infer_at(w, expected_rets)
               infer_emptytables(self, w, nil, expected_rets, frets, 0)

               rets_ok = check_func_type_list(self, w, nil, frets, expected_rets, 1, 0, "covariant", "return")
            end

            args_ok, args_errs = check_func_type_list(self, w, wargs, fargs, args, from, argdelta, "contravariant", "argument")
            if (not args_ok) or (not rets_ok) then
               return nil, args_errs or {}
            end

            infer_emptytables(self, w, wargs, args, fargs, argdelta)

            return true
         end
      end

      local function is_method_mismatch(self, w, arg1, farg1, cm)
         if cm == "method" or not farg1 then
            return false
         end
         if not (arg1 and self:is_a(arg1, farg1)) then
            self.errs:add(w, "invoked method as a regular function: use ':' instead of '.'")
            return true
         end
         if cm == "plain" then
            self.errs:add_warning("hint", w, "invoked method as a regular function: consider using ':' instead of '.'")
         end
         return false
      end

      check_call = function(self, w, wargs, f, args, expected_rets, cm, argdelta, or_args, or_rets)
         local arg1 = args.tuple[1]
         if cm == "method" and arg1 then
            local selftype = arg1
            if selftype.typename == "self" then
               selftype = self:type_of_self(selftype)
            end
            self:add_self_type(w, selftype)
         end

         local fargs = (or_args or f.args).tuple
         if f.is_method and is_method_mismatch(self, w, arg1, fargs[1], cm) then
            return false
         end

         local given = #args.tuple
         local wanted = #fargs
         local min_arity = self.feat_arity and f.min_arity or 0

         if given < min_arity or (given > wanted and not (or_args or f.args).is_va) then
            return nil, { errors.at(w, "wrong number of arguments (given " .. given .. ", expects " .. types.show_arity(f) .. ")") }
         end

         return check_args_rets(self, w, wargs, f, args, expected_rets, argdelta, or_args, or_rets)
      end
   end

   function Context:iterate_poly(p)
      local i = 0
      return function()
         i = i + 1
         local fg = p.types[i]
         if not fg then
            return
         elseif fg.typename == "function" then
            return i, fg
         elseif fg.typename == "generic" then
            return i, self:apply_generic(p, fg)
         end
      end
   end

   local check_poly_call
   do
      local function fail_poly_call_arity(self, w, p, given)
         local expects = {}
         for _, f in self:iterate_poly(p) do
            table.insert(expects, types.show_arity(f))
         end
         table.sort(expects)
         for i = #expects, 1, -1 do
            if expects[i] == expects[i + 1] then
               table.remove(expects, i)
            end
         end
         return { errors.at(w, "wrong number of arguments (given " .. given .. ", expects " .. table.concat(expects, " or ") .. ")") }
      end

      check_poly_call = function(self, w, wargs, p, args, expected_rets, cm, argdelta, or_args, or_rets)
         local given = #args.tuple

         local tried = {}
         local first_rets
         local first_errs

         for pass = 1, 3 do
            for i, f in self:iterate_poly(p) do
               assert(f.typename == "function", f.typename)
               assert(f.args)
               first_rets = first_rets or or_rets or f.rets

               local wanted = #f.args.tuple
               local min_arity = self.feat_arity and f.min_arity or 0

               if (not tried[i]) and

                  ((pass == 1 and given == wanted) or

                  (pass == 2 and (given < wanted and given >= min_arity)) or

                  (pass == 3 and (f.args.is_va and given > wanted))) then

                  local ok, errs = check_call(self, w, wargs, f, args, expected_rets, cm, argdelta, or_args, or_rets)
                  if ok then
                     return f, or_rets or f.rets
                  elseif expected_rets then

                     infer_emptytables(self, w, wargs, or_rets or f.rets, or_rets or f.rets, argdelta)
                  end

                  self:rollback_scope_transaction()

                  first_errs = first_errs or errs
                  tried[i] = true
               end
            end
         end

         if not first_errs then
            return nil, first_rets, fail_poly_call_arity(self, w, p, given)
         end

         return nil, first_rets, first_errs
      end
   end

   local function should_warn_dot(node, e1, is_method)
      if is_method then
         return "method"
      end
      if node_is_funcall(node) and e1 and e1.receiver then
         local receiver = e1.receiver
         if receiver.typename == "nominal" then
            local resolved = receiver.resolved
            if resolved and resolved.typename == "typedecl" then
               return "type_dot"
            end
         end
      end
      return "plain"
   end

   function Context:type_check_function_call(node, func, args, argdelta, or_args, or_rets, e1, e2)
      e1 = e1 or node.e1
      e2 = e2 or node.e2

      local expected = node.expected
      local expected_rets
      if expected and expected.typename == "tuple" then
         expected_rets = expected
      else
         expected_rets = a_type(node, "tuple", { tuple = { node.expected } })
      end

      self:begin_scope_transaction(node)

      local g
      local typeargs
      if func.typename == "generic" then
         g = func
         func, typeargs = self:apply_generic(node, func)
      end

      local is_method = (argdelta == -1)

      if not (func.typename == "function" or func.typename == "poly") then
         func, is_method = self:resolve_for_call(func, args, is_method)
         if is_method then
            argdelta = -1
         end
      end

      local cm = should_warn_dot(node, e1, is_method)

      local errs
      local f, ret

      if func.typename == "poly" then
         f, ret, errs = check_poly_call(self, node, e2, func, args, expected_rets, cm, argdelta, or_args, or_rets)
      elseif func.typename == "function" then
         local _
         _, errs = check_call(self, node, e2, func, args, expected_rets, cm, argdelta, or_args, or_rets)
         f, ret = func, or_rets or func.rets
      else
         ret = self.errs:invalid_at(node, "not a function: %s", func)
      end

      if errs then
         self.errs:collect(errs)
      end

      if g then
         mark_invalid_typeargs(self, typeargs)
      end

      self:commit_scope_transaction(node)

      ret = self:assert_resolved_typevars_at(node, ret)

      if self.collector then
         self.collector.store_type(e1.y, e1.x, f)
      end

      if f and f.macroexp then
         local argexps
         if is_method then
            argexps = {}
            if e1.kind == "op" then
               table.insert(argexps, e1.e1)
            else
               table.insert(argexps, e1)
            end
            for _, e in ipairs(e2) do
               table.insert(argexps, e)
            end
         else
            argexps = e2
         end
         macroexps.expand(node, argexps, f.macroexp)
         if self.collector and node.macro_expansion then
            self.collector.store_macro_expansion(node.y, node.x, node.macro_expansion)
         end
      end

      return ret, f
   end
end

function Context:resolve_self(t, resolve_interface)
   local selftype, selfdecl = self:type_of_self(t)
   local checktype = selftype
   if selftype.typename == "generic" then
      checktype = selftype.t
   end

   if (resolve_interface and checktype.typename == "interface") or checktype.typename == "record" then
      return types.map(self, t, {
         ["self"] = function(_, typ)
            return typedecl_to_nominal(typ, checktype.declname, selfdecl)
         end,
      })
   else
      return t
   end
end

do
   local function add_interface_fields(self, fields, field_order, resolved, named, list)
      for fname, ftype in fields_of(resolved, list) do
         if fields[fname] then
            if not self:is_a(fields[fname], ftype) then
               local what = list == "meta" and "metamethod" or "field"
               self.errs:add(fields[fname], what .. " '" .. fname .. "' does not match definition in interface %s", named)
            end
         else
            if not (ftype.typename == "typedecl") then
               table.insert(field_order, fname)
               fields[fname] = self:resolve_self(ftype)
            end
         end
      end
   end

   local function collect_interfaces(self, list, t, seen)
      local is_userdata = t.is_userdata
      if t.interface_list then
         for _, iface in ipairs(t.interface_list) do
            if iface.typename == "nominal" then
               local ri = self:resolve_nominal(iface)
               if ri.typename == "interface" then
                  if not seen[ri] then
                     seen[ri] = true
                     table.insert(list, iface)
                     if ri.interfaces_expanded then
                        local _, ud = collect_interfaces(self, list, ri, seen)
                        is_userdata = is_userdata or ud
                     end
                  end
               else
                  self.errs:add(iface, "attempted to use %s as interface, but its type is %s", iface, ri)
               end
            else
               if not seen[iface] then
                  seen[iface] = true
                  table.insert(list, iface)
               end
            end
         end
      end
      return list, is_userdata
   end

   function Context:expand_interfaces(t)
      if t.interfaces_expanded then
         return
      end
      t.interfaces_expanded = true

      t.interface_list, t.is_userdata = collect_interfaces(self, {}, t, {})

      local has_array_interface = false
      local has_tuple_interface = false

      for _, iface in ipairs(t.interface_list) do
         if iface.typename == "nominal" then
            local ri = self:resolve_nominal(iface)
            assert(ri.typename == "interface")
            add_interface_fields(self, t.fields, t.field_order, ri, iface)
            if ri.meta_fields then
               t.meta_fields = t.meta_fields or {}
               t.meta_field_order = t.meta_field_order or {}
               add_interface_fields(self, t.meta_fields, t.meta_field_order, ri, iface, "meta")
            end
         elseif iface.typename == "array" then
            has_array_interface = true
            if not t.elements then
               t.elements = iface.elements
            else
               if not self:same_type(iface.elements, t.elements) then
                  self.errs:add(t, "incompatible array interfaces")
               end
            end
         elseif iface.typename == "tupletable" then
            has_tuple_interface = true
            if not t.types then
               t.types = {}
               for i, element_type in ipairs(iface.types) do
                  table.insert(t.types, element_type)
               end
            else
               local existing_type_count = #t.types
               for i, element_type in ipairs(iface.types) do
                  if i <= existing_type_count then

                     if not self:same_type(element_type, t.types[i]) then
                        self.errs:add(t, "incompatible tuple interfaces")
                     end
                  else

                     table.insert(t.types, element_type)
                  end
               end
            end
         end
      end

      if has_array_interface and has_tuple_interface and #t.types > 0 then

         local incompatible_tuple_array = false
         for _, element_type in ipairs(t.types) do
            if not self:is_a(element_type, t.elements) then
               incompatible_tuple_array = true
               break
            end
         end


         local array_type_str = string.format("{%s}", show_type(t.elements))
         local tuple_types = {}
         for _, element_type in ipairs(t.types) do
            table.insert(tuple_types, show_type(element_type))
         end
         local tuple_type_str = string.format("{%s}", table.concat(tuple_types, ", "))


         if incompatible_tuple_array then

            self.errs:add(t, string.format("inherits incompatible array %s and tuple %s", array_type_str, tuple_type_str))
         else

            self.errs:add_warning("inheritance", t, "inherits overlapping array %s and tuple %s", array_type_str, tuple_type_str)
         end
      end
   end
end

function Context:begin_temporary_record_types(typ)
   self:add_self_type(typ, typ)

   for fname, ftype in fields_of(typ) do
      if ftype.typename == "typedecl" then
         local def = ftype.def
         if def.typename == "nominal" then
            assert(ftype.is_alias)
            self:resolve_nominal(def)
         end
         self:add_var(nil, fname, ftype, nil, nil, true)
      end
   end
end

function Context:end_temporary_record_types(typ)


   local scope = self.st[#self.st]
   scope.vars["@self"] = nil
   for fname, ftype in fields_of(typ) do
      if ftype.typename == "typedecl" then
         scope.vars[fname] = nil
      end
   end
end

function Context:check_metamethod(node, method_name, a, b, orig_a, orig_b, flipped)
   if self.feat_lax and ((a and is_unknown(a)) or (b and is_unknown(b))) then
      return a_type(node, "unknown", {}), nil
   end

   if self.env.opts.gen_target == "luajit" and
      (method_name == "__bnot" or method_name == "__band" or method_name == "__bor" or
      method_name == "__bxor" or method_name == "__shl" or method_name == "__shr" or method_name == "__sar") then
      return nil, nil
   end
   local ameta = a.fields and a.meta_fields
   local bmeta = b and b.fields and b.meta_fields

   if not ameta and not bmeta then
      return nil, nil
   end

   local meta_on_operator = 1
   local metamethod
   if method_name ~= "__is" then
      metamethod = ameta and ameta[method_name or ""]
   end
   if (not metamethod) and b and method_name ~= "__index" then
      metamethod = bmeta and bmeta[method_name or ""]
      meta_on_operator = 2
   end

   if metamethod then
      local e2 = { node.e1 }
      local args = a_type(node, "tuple", { tuple = { orig_a } })
      if b and method_name ~= "__is" then
         e2[2] = node.e2
         args.tuple[2] = orig_b
      end
      if flipped then
         e2[2], e2[1] = e2[1], e2[2]
      end

      local mtdelta = metamethod.typename == "function" and metamethod.is_method and -1 or 0
      local ret_call = self:type_check_function_call(node, metamethod, args, mtdelta, nil, nil, node, e2)
      local ret_unary = untuple(ret_call)
      local ret = self:to_structural(ret_unary)
      return ret, meta_on_operator
   else
      return nil, nil
   end
end

function Context:match_record_key(t, rec, key)
   t = self:to_structural(t)

   if not self.feat_strict_nil and t.typename == "union" then
      local members = {}
      for _, member in ipairs(t.types) do
         if not (member.typename == "nil") then table.insert(members, member) end
      end
      if #members > 0 then t = self:to_structural(unite(rec, members, true, false)) end
   end

   if t.typename == "self" then
      t = self:type_of_self(t)
   end

   if t.typename == "string" or t.typename == "enum" then

      t = self.env.modules["string"]
      self.needs_compat["string"] = true
   end

   if t.typename == "typedecl" then
      if t.is_nested_alias then
         return nil, "cannot use a nested type alias as a concrete value"
      end
      local def = t.def
      if def.typename == "nominal" then
         assert(t.is_alias)
         t = self:resolve_nominal(def)
      else
         t = def
      end
   end

   if t.typename == "generic" then
      t = self:apply_generic(t, t)
   end

   if t.typename == "union" then
      local ty = self:same_in_all_union_entries(t, function(typ)
         local v = self:match_record_key(typ, rec, key)
         return v, v
      end)
      if ty then
         return ty
      end
   end

   if (t.typename == "typevar" or t.typename == "typearg") and t.constraint then
      local ty = self:match_record_key(t.constraint, rec, key)
      if ty then
         return ty
      end
   end

   local keyg = key:gsub("%%", "%%%%")

   if t.fields then
      assert(t.fields, "record has no fields!?")

      if t.fields[key] then
         local ft = t.fields[key]
         if ft.typename == "function" then
            ft = types.map(nil, ft, {
               ["self"] = function(_, _typ)
                  return t, true
               end,
            })
         end
         return ft
      end

      local str = a_type(rec, "string", {})
      local meta_t = self:check_metamethod(rec, "__index", t, str, t, str)
      if meta_t then
         return meta_t
      end

      if rec.kind == "variable" then
         if t.typename == "interface" then
            return nil, "invalid key '" .. keyg .. "' in '" .. rec.tk .. "' of interface type %s"
         else
            return nil, "invalid key '" .. keyg .. "' in record '" .. rec.tk .. "' of type %s"
         end
      else
         return nil, "invalid key '" .. keyg .. "' in type %s"
      end
   elseif t.typename == "emptytable" or is_unknown(t) then
      if self.feat_lax then
         return a_type(rec, "unknown", {})
      end
      return nil, "cannot index a value of unknown type"
   end

   if rec.kind == "variable" then
      return nil, "cannot index key '" .. keyg .. "' in variable '" .. rec.tk .. "' of type %s"
   else
      return nil, "cannot index key '" .. keyg .. "' in type %s"
   end
end

do
   local function assigned_anywhere(name, root)
      local visit_node = {
         cbs = {
            ["assignment"] = {
               after = function(_, node, _children)
                  for _, v in ipairs(node.vars) do
                     if v.kind == "variable" and v.tk == name then
                        return true
                     end
                  end
                  return false
               end,
            },
         },
         after = function(_, _node, children, ret)
            ret = ret or false
            for _, c in ipairs(children) do
               local ca = c
               if type(ca) == "boolean" then
                  ret = ret or c
               end
            end
            return ret
         end,
      }

      local visit_type = {
         after = function()
            return false
         end,
      }

      return traverse_nodes(nil, root, visit_node, visit_type)
   end

   function Context:widen_all_unions(node)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         if scope.narrows then
            for name, _ in pairs(scope.narrows) do
               if not node or assigned_anywhere(name, node) then
                  self:widen_in_scope(i, name)
               end
            end
         end
      end
   end
end

function Context:add_global(node, varname, valtype, is_assigning)
   if self.feat_lax and is_unknown(valtype) and (varname ~= "self" and varname ~= "...") then
      self.errs:add_unknown(node, varname)
   end

   local is_const = node.attribute ~= nil
   local existing, scope, existing_attr = self:find_var(varname)
   if existing then
      if scope > 1 then
         self.errs:add(node, "cannot define a global when a local with the same name is in scope")
      elseif is_assigning and existing_attr then
         self.errs:add(node, "cannot reassign to <" .. existing_attr .. "> global: " .. varname)
      elseif existing_attr and not is_const then
         self.errs:add(node, "global was previously declared as <" .. existing_attr .. ">: " .. varname)
      elseif (not existing_attr) and is_const then
         self.errs:add(node, "global was previously declared as not <" .. node.attribute .. ">: " .. varname)
      elseif valtype and not self:same_type(existing.t, valtype) then
         self.errs:add(node, "cannot redeclare global with a different type: previous type of " .. varname .. " is %s", existing.t)
      end
      return nil
   end

   local var = { t = valtype, attribute = is_const and node.attribute or nil, declared_at = node, is_global = true }
   self.st[1].vars[varname] = var

   return var
end

function Context:add_internal_function_variables(node, args, keep_literal)
   self:add_var(nil, "@is_va", a_type(node, args.is_va and "any" or "nil", {}))
   self:add_var((node.short_function or node.infer_returns) and node or nil, "@return", node.rets or a_type(node, "tuple", { tuple = {} }), nil, nil, keep_literal)

   if node.typeargs then
      for _, t in ipairs(node.typeargs) do
         local v = self:find_var(t.typearg, "check_only")
         if not v or not v.used_as_type then
            self.errs:add(t, "type argument '%s' is not used in function signature", t)
         end
      end
   end
end

function Context:add_function_definition_for_recursion(node, fnargs, feat_arity, keep_literal)
   self:add_var(node.lj_const and node or nil, node.name.tk, wrap_generic_if_typeargs(node.typeargs, a_function(node, {
      min_arity = feat_arity and node.min_arity or 0,
      args = fnargs,
      rets = self.get_rets(node.rets),
   })), node.lj_const and "const" or nil, nil, keep_literal)
end

function Context:end_function_scope(node)
   local rets = node.rets
   if self.strict_pragma and node.body and rets and #rets.tuple > 0 and
      not context.block_returns(node.body) then
      local nil_type = a_type(node, "nil", {})
      for _, ret in ipairs(rets.tuple) do
         if not self:is_a(nil_type, ret) then
            self.errs:add(node, "strict mode: function may end without returning a non-nil result")
            break
         end
      end
   end
   if self.native_ffi and rets and rets.tuple[1] then
      node.native_return_type = self:to_structural(rets.tuple[1])
   end
   self.errs:fail_unresolved_labels(self.st[#self.st])
   self:end_scope(node)
end

function Context:match_all_record_field_names(node, a, field_names, errmsg)
   local t
   for _, k in ipairs(field_names) do
      local f = a.fields[k]
      if not t then
         t = f
      else
         if not self:same_type(f, t) then
            errmsg = errmsg .. string.format(" (types of fields '%s' and '%s' do not match)", field_names[1], k)
            t = nil
            break
         end
      end
   end
   if t then
      return t
   else
      return self.errs:invalid_at(node, errmsg)
   end
end

function Context:type_check_index(anode, bnode, a, b)
   assert(not (a.typename == "tuple"))
   assert(not (b.typename == "tuple"))

   local ra = self:to_structural(a)
   local rb = self:to_structural(b)


   if not self.feat_strict_nil and ra.typename == "union" then
      local members = {}
      for _, member in ipairs(ra.types) do
         if not (member.typename == "nil") then table.insert(members, member) end
      end
      if #members > 0 then
         ra = self:to_structural(unite(anode, members, true, false))
      end
   end

   if self.feat_lax and is_unknown(a) then
      return a
   end

   local errm
   local erra
   local errb

   if ra.typename == "typedecl" then
      ra = ra.def
   end

   if ra.types and rb.typename == "integer" then
      if bnode.constnum then
         if bnode.constnum >= 1 and bnode.constnum <= #ra.types and bnode.constnum == math.floor(bnode.constnum) then
            return ra.types[bnode.constnum]
         elseif ra.fields and ra.elements then
            return (ra).elements
         end

         errm, erra = "index " .. tostring(bnode.constnum) .. " out of range for tuple %s", ra
      else
         local type_list = ra.types
         if ra.fields and ra.elements then
            type_list = { ra.elements }
            for _, child in ipairs(ra.types) do
               table.insert(type_list, child)
            end
         end
         local array_type, valid = self:arraytype_from_list(bnode, type_list)
         if array_type and valid then
            return array_type.elements
         end

         errm = "cannot index this tuple with a variable because it would produce a union type that cannot be discriminated at runtime"
      end
   elseif ra.typename == "self" then
      return self:type_check_index(anode, bnode, self:type_of_self(a), b)
   elseif ra.elements and rb.typename == "integer" then
      return ra.elements
   elseif ra.typename == "emptytable" then
      if ra.keys == nil then
         ra.keys = self:infer_at(bnode, b)
      end

      if self:is_a(b, ra.keys) then
         return a_type(anode, "unresolved_emptytable_value", {
            emptytable_type = ra,
         })
      end

      errm, erra, errb = "inconsistent index type: got %s, expected %s" .. types.inferred_msg(ra.keys, "type of keys "), b, ra.keys
   elseif ra.typename == "unresolved_emptytable_value" then
      local et = a_type(ra, "emptytable", { keys = b })
      self:infer_emptytable_from_unresolved_value(a, ra, et)
      return a_type(anode, "unresolved_emptytable_value", {
         emptytable_type = et,
      })
   elseif ra.typename == "map" then
      if self:is_a(b, ra.keys) then
         return ra.values
      end

      errm, erra, errb = "wrong index type: got %s, expected %s", b, ra.keys
   elseif rb.typename == "string" and rb.literal then
      local t, e = self:match_record_key(a, anode, rb.literal)
      if t then

         if t.typename == "function" and t.is_method then
            local t2 = shallow_copy_new_type(t)
            t2.args = shallow_copy_new_type(t.args)
            t2.args.tuple = shallow_copy_table(t2.args.tuple)
            for i, p in ipairs(t2.args.tuple) do
               if p.typename == "self" then
                  t2.args.tuple[i] = a
               end
            end
            return t2
         end

         return t
      end

      errm, erra = e, a
   elseif ra.fields then
      if rb.typename == "enum" then
         local field_names = sorted_keys(rb.enumset)
         for _, k in ipairs(field_names) do
            if not ra.fields[k] then
               errm, erra = "enum value '" .. k:gsub("%%", "%%%%") .. "' is not a field in %s", ra
               break
            end
         end
         if not errm then
            return self:match_all_record_field_names(bnode, ra, field_names,
            "cannot index, not all enum values map to record fields of the same type")
         end
      elseif rb.typename == "string" then
         errm, erra = "cannot index object of type %s with a string, consider using an enum", a
      else
         errm, erra, errb = "cannot index object of type %s with %s", a, b
      end
   else
      errm, erra, errb = "cannot index object of type %s with %s", a, b
   end

   local meta_t = self:check_metamethod(anode, "__index", ra, b, a, b)
   if meta_t then
      return meta_t
   end

   return self.errs:invalid_at(bnode, errm, erra, errb)
end

function Context:expand_type(w, old, new, flatten_constants)
   if flatten_constants == nil then
      flatten_constants = true
   end
   if not old or old.typename == "nil" then
      return new
   end
   if self:is_a(new, old) then
      return old
   end

   if new.fields and (old.typename == "map" or old.fields) then
      local keys
      local values
      if old.typename == "map" then
         keys = old.keys
         if not (keys.typename == "string") then
            self.errs:add(w, "cannot determine table literal type")
            return old
         end
         values = old.values
      elseif old.fields then
         keys = a_type(w, "string", {})
         for _, ftype in fields_of(old) do
            values = self:expand_type(w, values, ftype)
         end
      end

      for _, ftype in fields_of(new) do
         values = self:expand_type(w, values, ftype)
      end

      return a_type(w, "map", { keys = keys, values = values })
   end

   return unite(w, { old, new }, flatten_constants, not self.feat_strict_nil)
end

function Context:find_record_to_extend(exp)

   if exp.kind == "type_identifier" then
      local v = self:find_var(exp.tk)
      if not v then
         return nil, nil, exp.tk
      end

      local t = v.t
      if t.typename == "typedecl" then
         if t.closed then
            return nil, nil, exp.tk
         end

         return t.def, v, exp.tk
      end

      return t, v, exp.tk

   elseif exp.kind == "op" then
      local t, v, rname = self:find_record_to_extend(exp.e1)
      local fname = exp.e2.tk
      local dname = rname .. "." .. fname
      if not t then
         return nil, nil, dname
      end
      if not t.fields then
         return nil, nil, dname
      end
      t = t.fields[fname]
      if not t then return nil, nil, dname end

      if t.typename == "typedecl" then
         local def = t.def
         if def.typename == "nominal" then
            assert(t.is_alias)
            t = def.resolved
         else
            t = def
         end
      end

      return t, v, dname
   end
end

function Context:get_self_type(exp)

   if exp.kind == "type_identifier" then
      local t = self:find_var_type(exp.tk)
      if not t then
         return nil
      end

      if t.typename == "typedecl" then
         return typedecl_to_nominal(exp, exp.tk, t)
      else
         return t
      end

   elseif exp.kind == "op" then
      local t = self:get_self_type(exp.e1)
      if not t then
         return nil
      end

      if t.typename == "nominal" then
         local found = t.found
         if found then
            if found.typename == "typedecl" then
               local def = found.def
               if def.fields and def.fields[exp.e2.tk] then
                  table.insert(t.names, exp.e2.tk)
                  local ft = def.fields[exp.e2.tk]
                  if ft.typename == "typedecl" then
                     t.found = ft
                  else
                     return nil
                  end
               end
            end
         end
      elseif t.fields then
         return t.fields and t.fields[exp.e2.tk]
      end
      return t
   end
end

function Context:apply_facts(w, known)
   if not known then
      return
   end

   local fcts = eval_fact(self, known)

   for v, f in pairs(fcts) do
      if f.typ.typename == "invalid" then
         self.errs:add(w, "cannot resolve a type for " .. v .. " here")
      end
      local t = f.no_infer and f.typ or self:infer_at(w, f.typ)
      if f.no_infer then
         t.inferred_at = nil
      end
      self:add_var(nil, v, t, "const", "narrow")
   end
end

function Context:apply_facts_from(w, from)
   self:apply_facts(w, self.fdb:get(from or w))
end

function Context:dismiss_unresolved(name)
   for i = #self.st, 1, -1 do
      local scope = self.st[i]
      local uses = scope.pending_nominals and scope.pending_nominals[name]
      if uses then
         for _, t in ipairs(uses) do
            self:resolve_nominal(t)
         end
         scope.pending_nominals[name] = nil
         return
      end
   end
end

function Context:type_check_funcall(node, a, b, argdelta)
   if node.e1.op and node.e1.op.op == ":" then
      table.insert(b.tuple, 1, node.e1.receiver)
      argdelta = -1
   else
      argdelta = argdelta or 0
   end

   local sa = types.resolve_for_special_function(a)
   if sa then
      local special_tyck = special_functions[sa.special_function_handler]
      if special_tyck then
         return special_tyck(self, node, a, b, argdelta)
      end
   end

   return (self:type_check_function_call(node, a, b, argdelta))
end

function Context:missing_initializer(node, i, name)
   if self.feat_lax then
      return a_type(node, "unknown", {})
   else
      if node.exps then
         return self.errs:invalid_at(node.vars[i], "assignment in declaration did not produce an initial value for variable '" .. name .. "'")
      else
         return self.errs:invalid_at(node.vars[i], "variable '" .. name .. "' has no type or initial value")
      end
   end
end

function Context:infer_negation_of_if_blocks(w, ifnode, n)
   local f = facts_not(w, self.fdb:get(ifnode.if_blocks[1].exp))
   for e = 2, n do
      local b = ifnode.if_blocks[e]
      if b.exp then
         f = facts_and(w, f, facts_not(w, self.fdb:get(b.exp)))
      end
   end
   self:apply_facts(w, f)
end

function Context:determine_declaration_type(var, node, infertypes, i)
   local ok = true
   local name = var.tk
   local infertype = infertypes and infertypes.tuple[i]
   if self.feat_lax and infertype and infertype.typename == "nil" then
      infertype = nil
   end

   local decltype = node.decltuple and node.decltuple.tuple[i]
   if decltype then
      local rdecltype = self:to_structural(decltype)
      if rdecltype.typename == "invalid" then
         decltype = rdecltype
      end

      if infertype then
         local w = node.exps and node.exps[i] or node.vars[i]

         local errs
         ok, errs = self:is_a(infertype, decltype)
         if not ok then
            self.errs:add_prefixing(w, errs, self.errs:get_context(node, name))
         end
      elseif self.strict_pragma and not self:is_a(a_type(var, "nil", {}), decltype) then
         self.errs:add(var, "strict mode: non-nil variable '" .. name .. "' requires an initializer")
         ok = false
      end
   else
      if infertype then
         if infertype.typename == "unresolvable_typearg" then
            ok = false
            infertype = self.errs:invalid_at(node.vars[i], "cannot infer declaration type; an explicit type annotation is necessary")
         else



            infertype = ensure_not_method(infertype)
         end
      end
   end

   if var.attribute == "total" then
      local rd = decltype and self:to_structural(decltype)
      if rd and (not (rd.typename == "map")) and (not (rd.typename == "record")) then
         self.errs:add(var, "attribute <total> only applies to maps and records")
         ok = false
      elseif not infertype then
         self.errs:add(var, "variable declared <total> does not declare an initialization value")
         ok = false
      else
         local valnode = node.exps[i]
         if not valnode or valnode.kind ~= "literal_table" then
            self.errs:add(var, "attribute <total> only applies to literal tables")
            ok = false
         else
            if not valnode.is_total then
               local missing = ""
               if valnode.missing then
                  missing = " (missing: " .. table.concat(valnode.missing, ", ") .. ")"
               end
               local ri = self:to_structural(infertype)
               if ri.typename == "map" then
                  self.errs:add(var, "map variable declared <total> does not declare values for all possible keys" .. missing)
                  ok = false
               elseif ri.typename == "record" then
                  self.errs:add(var, "record variable declared <total> does not declare values for all fields" .. missing)
                  ok = false
               end
            end
         end
      end
   end

   local t = decltype or infertype
   if t == nil then
      t = self:missing_initializer(node, i, name)
   elseif t.typename == "emptytable" then
      t.is_global = node.kind == "global_declaration"
      t.assigned_to = name
   elseif t.elements then
      t.inferred_len = nil
   elseif t.typename == "nominal" then
      self:resolve_nominal(t)
      local rt = t.resolved
      if rt and rt.typename == "typedecl" then
         t.resolved = rt.def
      end
   end

   return ok, t, infertype ~= nil
end





function Context:check_assignment(varnode, vartype, valtype)
   local varname = varnode.tk
   local attr = varnode.attribute

   if varname then
      if self:widen_back_var(varname) then
         vartype, attr = self:find_var_type(varname)
         if not vartype then
            self.errs:add(varnode, "unknown variable")
            return nil
         end
      end
   end
   if attr == "close" or attr == "const" or attr == "total" then
      self.errs:add(varnode, "cannot assign to <" .. attr .. "> variable")
      return nil
   end

   local var = self:to_structural(vartype)
   if var.typename == "typedecl" then
      self.errs:add(varnode, "cannot reassign a type")
      return nil
   end

   if not valtype then
      self.errs:add(varnode, "variable is not being assigned a value")
      return nil, nil, "missing"
   end

   if vartype.typename == "emptytable" then
      vartype = type_at(varnode, vartype)
   end

   local ok, errs = self:is_a(valtype, vartype)
   if not ok then
      self.errs:add_prefixing(varnode, errs, "in assignment: ")
   end

   local val = self:to_structural(valtype)

   return var, val
end

do
   local function aliasing_variable(self, def)
      if def.typename == "nominal" then
         return (self:find_var(def.names[1], "use_type"))
      end

      if def.typename == "generic" then
         local nom = def.t
         if nom.typename == "nominal" then
            return (self:find_var(nom.names[1], "use_type"))
         end
      end
   end

   local function recurse_type_declaration(self, n)
      if n.kind == "op" then
         if self.native_ffi or self.strict_pragma then n.type_require = true end

         if n.op.op == "." then
            local ty = recurse_type_declaration(self, n.e1)
            if not (ty.typename == "typedecl") then
               return ty
            end
            local def = ty.def
            if not (def.typename == "record") then
               return self.errs:invalid_at(n.e1, "type is not a record")
            end
            local t = def.fields[n.e2.tk]
            if t and t.typename == "typedecl" then
               return t
            end
            return self.errs:invalid_at(n.e2, "nested type '" .. n.e2.tk .. "' not found in record")

         elseif n.op.op == "@funcall" and
            n.e1.kind == "variable" and
            n.e1.tk == "require" then

            local ty = untuple(
            special_functions["require"](
            self, n, self:find_var_type("require"),
            a_type(n.e2, "tuple", { tuple = { a_type(n.e2[1], "string", {}) } })))


            if not (ty.typename == "typedecl") then
               return self.errs:invalid_at(n.e1, "'require' did not return a type, got %s", ty)
            end
            if ty.is_alias then
               return self:resolve_typealias(ty)
            end
            return ty
         end
      end

      local newtype = n.newtype
      if newtype.is_alias then
         return self:resolve_typealias(newtype), aliasing_variable(self, newtype.def)
      end
      return newtype, nil
   end

   function Context:get_typedecl(value)
      local resolved, aliasing = recurse_type_declaration(self, value)
      local nt = value.newtype
      if nt and nt.is_alias and resolved.typename == "typedecl" then
         local ntdef = nt.def
         local rdef = resolved.def
         if ntdef.typename == "generic" and rdef.typename == "generic" then



            ntdef.typeargs = rdef.typeargs
         end
      end
      return resolved, aliasing
   end
end

function Context:is_pending_global(name)
   local global_scope = self.st[1]
   return not not global_scope.pending_global_types[name]
end

do
   local function set_feat(feat, default)
      if feat then
         return (feat == "on")
      else
         return default
      end
   end

   function Context.new(env, filename, strict_pragma)
      local self = {
         filename = filename,
         env = env,
         strict_pragma = strict_pragma,
         st = {
            {
               vars = env.globals,
               pending_global_types = {},
            },
         },
         fdb = FactDatabase.new(),
         errs = Errors.new(filename),
         needs_compat = {},
         dependencies = {},
         subtype_relations = relations.subtype_relations,
         eqtype_relations = relations.eqtype_relations,
         type_priorities = relations.type_priorities,
      }

      if env.report_types then
         env.reporter = env.reporter or type_reporter.new()
         self.collector = env.reporter:get_collector(filename)
      end

      self.cache_std_metatable_type = env.globals["metatable"] and (env.globals["metatable"].t).def

      self.feat_arity = strict_pragma ~= nil or set_feat(env.opts.feat_arity, true)
      self.feat_strict_nil = strict_pragma ~= nil or set_feat(env.opts.feat_strict_nil, true)
      self.feat_lax = not strict_pragma and not not filename:match("%.lua$")

      if self.feat_lax then
         self.feat_arity = false
         self.type_priorities = relations.lax_type_priorities()
         self.subtype_relations = relations.lax_subtype_relations()
         self.get_rets = function(rets)
            if #rets.tuple == 0 then
               return a_vararg(rets, { a_type(rets, "unknown", {}) })
            end
            return rets
         end
      else
         self.get_rets = function(rets)
            return rets
         end
      end

      setmetatable(self, {
         __index = Context,
         __tostring = function() return "Context" end,
      })

      return self
   end
end



return context

end

-- module teal.check.relations from teal/check/relations.lua
package.preload["teal.check.relations"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local errors = require("teal.errors")


local types = require("teal.types")





























local a_type = types.a_type
local show_arity = types.show_arity
local show_type = types.show_type
local untuple = types.untuple




local util = require("teal.util")
local shallow_copy_table = util.shallow_copy_table

local relations = {}















local function compare_true(_, _, _)
   return true
end

local function compare_string_literals(_ck, a, b)
   if b.literal == nil then
      return true
   end
   if a.literal == nil then
      return false
   end
   return a.literal == b.literal
end

local function same_string_literals(_ck, a, b)
   return a.literal == b.literal
end

local function compare_number_literals(_ck, a, b)
   if b.literal == nil then
      return true
   end
   if a.literal == nil then
      return false
   end
   return a.literal == b.literal
end

local function same_number_literals(_ck, a, b)
   return a.literal == b.literal
end

local function compare_integer_literals(_ck, a, b)
   if b.literal == nil then
      return true
   end
   if a.literal == nil then
      return false
   end
   return a.literal == b.literal
end

local function same_integer_literals(_ck, a, b)
   return a.literal == b.literal
end

local function compare_boolean_literals(_ck, a, b)
   if b.literal == nil then
      return true
   end
   if a.literal == nil then
      return false
   end
   return a.literal == b.literal
end

local function same_boolean_literals(_ck, a, b)
   return a.literal == b.literal
end

local function nil_subtype(ck, _a, b)
   if not ck.feat_strict_nil then
      return true
   end

   local function accepts_nil(t)
      if t.typename == "typedecl" then
         return accepts_nil(t.def)
      elseif t.typename == "nominal" then
         local resolved = ck:resolve_nominal(t)
         return resolved and accepts_nil(resolved)
      elseif t.typename == "union" then
         for _, ut in ipairs(t.types) do
            if accepts_nil(ut) then
               return true
            end
         end
         return false
      end

      return t.typename == "nil" or
      t.typename == "any" or
      t.typename == "unknown" or
      t.typename == "boolean_context"
   end

   return accepts_nil(b)
end

local function compare_map(ck, ak, bk, av, bv, no_hack)
   local ok1, errs_k = ck:is_a(bk, ak)
   local ok2, errs_v = ck:is_a(av, bv)


   if bk.typename == "any" and not no_hack then
      ok1, errs_k = true, nil
   end
   if bv.typename == "any" and not no_hack then
      ok2, errs_v = true, nil
   end

   if ok1 and ok2 then
      return true
   end


   for i = 1, errs_k and #errs_k or 0 do
      errs_k[i].msg = "in map key: " .. errs_k[i].msg
   end
   for i = 1, errs_v and #errs_v or 0 do
      errs_v[i].msg = "in map value: " .. errs_v[i].msg
   end
   if errs_k and errs_v then
      for i = 1, #errs_v do
         table.insert(errs_k, errs_v[i])
      end
      return false, errs_k
   end
   return false, errs_k or errs_v
end

local function compare_or_infer_typevar(ck, typevar, a, b, cmp)



   local vt, _, constraint = ck:find_var_type(typevar)
   if vt then

      return cmp(ck, a or vt, b or vt)
   else

      local other = a or b


      if constraint then
         if not ck:is_a(other, constraint) then
            return false, { types.error("given type %s does not satisfy %s constraint in type variable " .. types.show_typevar(typevar, "typevar"), other, constraint) }
         end

         if ck:same_type(other, constraint) then



            return true
         end
      end

      local r, errs = ck:resolve_typevars(other)
      if errs then
         return false, errs
      end


      if r.typename == "boolean_context" then
         return true
      end

      if r.typename == "typevar" and r.typevar == typevar then
         return true
      end
      ck:add_implied_var(typevar, r)
      return true
   end
end

local function subtype_record(ck, a, b)
   if (a.native_pointer or b.native_pointer) and a.native_pointer ~= b.native_pointer then
      return false, { types.error("%s is not compatible with %s", a, b) }
   end
   if a.elements and b.elements then
      if not ck:is_a(a.elements, b.elements) then
         return false, { errors.new("array parts have incompatible element types") }
      end
   end

   if a.types and b.types then
      local size = math.min(#a.types, #b.types)
      for i = 1, size do
         if not ck:is_a(a.types[i], b.types[i]) then
            return false, { errors.new("tuple parts have incompatible element types") }
         end
      end
   end

   if a.is_userdata ~= b.is_userdata then
      return false, { errors.new(a.is_userdata and "userdata is not a record" or
      "record is not a userdata"), }
   end

   local errs = {}
   for _, k in ipairs(a.field_order) do
      local ak = a.fields[k]
      local bk = b.fields[k]
      if bk then
         local ok, fielderrs = ck:is_a(ak, bk)
         if not ok then
            ck:add_errors_prefixing(nil, fielderrs, "record field doesn't match: " .. k .. ": ", errs)
         end
      elseif b.typename == "record" then
         table.insert(errs, errors.new("record field doesn't exist: " .. k))
      end
   end
   if #errs > 0 then
      for _, err in ipairs(errs) do
         err.msg = show_type(a) .. " is not a " .. show_type(b) .. ": " .. err.msg
      end
      return false, errs
   end

   return true
end

local function eqtype_record(ck, a, b)

   if (a.elements ~= nil) ~= (b.elements ~= nil) then
      return false, { errors.new("types do not have the same array interface") }
   end
   if a.elements then
      local ok, errs = ck:same_type(a.elements, b.elements)
      if not ok then
         return ok, errs
      end
   end

   local ok, errs = subtype_record(ck, a, b)
   if not ok then
      return ok, errs
   end
   ok, errs = subtype_record(ck, b, a)
   if not ok then
      return ok, errs
   end
   return true
end


local function compare_true_inferring_emptytable(ck, a, b)
   ck:infer_emptytable(b, ck:infer_at(b, a))
   return true
end

local function compare_true_inferring_emptytable_if_not_userdata(ck, a, b)
   if a.is_userdata then
      return false, { types.error("{} cannot be used with userdata type %s", a) }
   end
   return compare_true_inferring_emptytable(ck, a, b)
end

local function is_in_interface_list(ck, r, iface)
   if not r.interface_list then
      return false
   end

   for _, t in ipairs(r.interface_list) do
      if ck:is_a(t, iface) then
         return true
      end
   end

   return false
end

local function a_is_interface_b(ck, a, b)
   if (not a.found) or (not b.found) then
      return false
   end

   local af = a.found.def
   if af.typename == "generic" then
      af = ck:apply_generic(a, af, a.typevals)
   end

   if af.fields then
      if is_in_interface_list(ck, af, b) then
         return true
      end
   end

   return ck:is_a(a, ck:resolve_nominal(b))
end

local are_same_nominals
do
   local function are_same_unresolved_global_type(ck, t1, t2)

      if t1.names[1] == t2.names[1] then
         if ck:is_pending_global(t1.names[1]) then
            return true
         end
      end
      return false
   end

   local function fail_nominals(ck, t1, t2)
      local t1name = show_type(t1)
      local t2name = show_type(t2)
      if t1name == t2name then
         ck:resolve_nominal(t1)
         if t1.found then
            t1name = t1name .. " (defined in " .. t1.found.f .. ":" .. t1.found.y .. ")"
         end
         ck:resolve_nominal(t2)
         if t2.found then
            t2name = t2name .. " (defined in " .. t2.found.f .. ":" .. t2.found.y .. ")"
         end
      end
      return false, { errors.new(t1name .. " is not a " .. t2name) }
   end

   local function nominal_found_type(ck, nom)
      local typedecl = nom.found
      if not typedecl then
         typedecl = ck:find_type(nom.names)
         if not typedecl then
            return nil
         end
      end
      local t = typedecl.def

      if t.typename == "generic" then
         t = t.t
      end

      return t
   end

   are_same_nominals = function(ck, t1, t2)
      local t1f = nominal_found_type(ck, t1)
      local t2f = nominal_found_type(ck, t2)
      if (not t1f or not t2f) then
         if are_same_unresolved_global_type(ck, t1, t2) then
            return true
         end

         if not t1f then
            ck:add_error(t1, "unknown type %s", t1)
         end
         if not t2f then
            ck:add_error(t2, "unknown type %s", t2)
         end
         return false, {}
      end

      if t1f.typeid ~= t2f.typeid then
         return fail_nominals(ck, t1, t2)
      end

      if t1.typevals == nil and t2.typevals == nil then
         return true
      end

      if t1.typevals and t2.typevals and #t1.typevals == #t2.typevals then
         local errs = {}
         for i = 1, #t1.typevals do
            local _, typeval_errs = ck:same_type(t1.typevals[i], t2.typevals[i])
            ck:add_errors_prefixing(nil, typeval_errs, "type parameter <" .. show_type(t2.typevals[i]) .. ">: ", errs)
         end
         return errors.any(errs)
      end


      return true
   end
end

local function has_all_types_of(ck, t1s, t2s)
   for _, t1 in ipairs(t1s) do
      local found = false
      for _, t2 in ipairs(t2s) do
         if ck:same_type(t2, t1) then
            found = true
            break
         end
      end
      if not found then
         return false
      end
   end
   return true
end


local emptytable_relations = {
   ["emptytable"] = compare_true,
   ["array"] = compare_true,
   ["map"] = compare_true,
   ["tupletable"] = compare_true,
   ["interface"] = function(_ck, _a, b)
      return not b.is_userdata
   end,
   ["record"] = function(_ck, _a, b)
      return not b.is_userdata
   end,
}

relations.eqtype_relations = {


   ["nil"] = {
      ["typevar"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, b.typevar, a, nil, ck.same_type)
      end,
   },
   ["typevar"] = {
      ["nil"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, a.typevar, nil, b, ck.same_type)
      end,
      ["typevar"] = function(ck, a, b)
         if a.typevar == b.typevar then
            return true
         end

         return compare_or_infer_typevar(ck, b.typevar, a, nil, ck.same_type)
      end,
      ["*"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, a.typevar, nil, b, ck.same_type)
      end,
   },
   ["string"] = {
      ["string"] = function(_ck, a, b)
         return same_string_literals(_ck, a, b)
      end,
   },
   ["number"] = {
      ["number"] = function(_ck, a, b)
         return same_number_literals(_ck, a, b)
      end,
   },
   ["integer"] = {
      ["integer"] = function(_ck, a, b)
         return same_integer_literals(_ck, a, b)
      end,
   },
   ["boolean"] = {
      ["boolean"] = function(_ck, a, b)
         return same_boolean_literals(_ck, a, b)
      end,
   },
   ["emptytable"] = emptytable_relations,
   ["tupletable"] = {
      ["tupletable"] = function(ck, a, b)
         for i = 1, math.min(#a.types, #b.types) do
            if not ck:same_type(a.types[i], b.types[i]) then
               return false, { types.error("in tuple entry " .. tostring(i) .. ": got %s, expected %s", a.types[i], b.types[i]) }
            end
         end
         if #a.types ~= #b.types then
            return false, { types.error("tuples have different size", a, b) }
         end
         return true
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["array"] = {
      ["array"] = function(ck, a, b)
         return ck:same_type(a.elements, b.elements)
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["map"] = {
      ["map"] = function(ck, a, b)
         return compare_map(ck, a.keys, b.keys, a.values, b.values, true)
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["union"] = {
      ["union"] = function(ck, a, b)
         return (has_all_types_of(ck, a.types, b.types) and
         has_all_types_of(ck, b.types, a.types))
      end,
   },
   ["nominal"] = {
      ["nominal"] = are_same_nominals,
      ["typedecl"] = function(ck, a, b)

         return ck:same_type(ck:resolve_nominal(a), b.def)
      end,
   },
   ["record"] = {
      ["record"] = eqtype_record,
      ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
   },
   ["interface"] = {
      ["interface"] = function(_ck, a, b)
         return a.typeid == b.typeid
      end,
      ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
   },
   ["function"] = {
      ["function"] = function(ck, a, b)
         local argdelta = a.is_method and 1 or 0
         local naargs, nbargs = #a.args.tuple, #b.args.tuple
         if naargs ~= nbargs then
            if (not not a.is_method) ~= (not not b.is_method) then
               return false, { errors.new("different number of input arguments: method and non-method are not the same type") }
            end
            return false, { errors.new("different number of input arguments: got " .. naargs - argdelta .. ", expected " .. nbargs - argdelta) }
         end
         local narets, nbrets = #a.rets.tuple, #b.rets.tuple
         if narets ~= nbrets then
            return false, { errors.new("different number of return values: got " .. narets .. ", expected " .. nbrets) }
         end
         local errs = {}
         for i = 1, naargs do
            ck:arg_check(a, errs, a.args.tuple[i], b.args.tuple[i], "invariant", "argument", i - argdelta)
         end
         for i = 1, narets do
            ck:arg_check(a, errs, a.rets.tuple[i], b.rets.tuple[i], "invariant", "return", i)
         end
         return errors.any(errs)
      end,
   },
   ["self"] = {
      ["self"] = function(_ck, _a, _b)
         return true
      end,
      ["*"] = function(ck, a, b)
         return ck:same_type(ck:type_of_self(a), b)
      end,
   },
   ["boolean_context"] = {
      ["boolean"] = compare_true,
   },
   ["generic"] = {
      ["generic"] = function(ck, a, b)
         if #a.typeargs ~= #b.typeargs then
            return false
         end
         for i = 1, #a.typeargs do
            if not ck:same_type(a.typeargs[i], b.typeargs[i]) then
               return false
            end
         end
         return ck:same_type(a.t, b.t)
      end,
   },
   ["*"] = {
      ["boolean_context"] = compare_true,
      ["self"] = function(ck, a, b)
         return ck:same_type(a, (ck:type_of_self(b)))
      end,
      ["typevar"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, b.typevar, a, nil, ck.same_type)
      end,
   },
}


local function exists_supertype_in(ck, t, xs)
   for _, x in ipairs(xs.types) do
      if ck:is_a(t, x) then
         return x
      end
   end
end


local function forall_are_subtype_of(ck, xs, t)
   for _, x in ipairs(xs.types) do
      if not ck:is_a(x, t) then
         return false
      end
   end
   return true
end

local function subtype_nominal(ck, a, b)
   local ra = a.typename == "nominal" and ck:resolve_nominal(a) or a
   local rb = b.typename == "nominal" and ck:resolve_nominal(b) or b
   local ok, errs = ck:is_a(ra, rb)
   if errs and #errs == 1 and errs[1].msg:match("^got ") then
      return false
   end
   return ok, errs
end

local function subtype_array(ck, a, b)
   local elements_ok = a.elements and ck:is_a(a.elements, b.elements)

   if a.consttypes and #a.consttypes > 1 then

      for _, e in ipairs(a.consttypes) do
         if not ck:is_a(e, b.elements) then
            return false, { types.error("%s is not a member of %s", e, b.elements) }
         end
      end
      return true
   end

   if not elements_ok then
      return false
   end
   return true
end

relations.subtype_relations = {
   ["nil"] = {
      ["*"] = nil_subtype,
   },
   ["tuple"] = {
      ["tuple"] = function(ck, a, b)
         local at, bt = a.tuple, b.tuple
         if #at ~= #bt then
            return false
         end
         for i = 1, #at do
            if not ck:is_a(at[i], bt[i]) then
               return false
            end
         end
         return true
      end,
      ["*"] = function(ck, a, b)
         return ck:is_a(untuple(a), b)
      end,
   },
   ["typevar"] = {
      ["typevar"] = function(ck, a, b)
         if a.typevar == b.typevar then
            return true
         end

         return compare_or_infer_typevar(ck, b.typevar, a, nil, ck.is_a)
      end,
      ["*"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, a.typevar, nil, b, ck.is_a)
      end,
   },
   ["union"] = {
      ["nominal"] = function(ck, a, b)

         local rb = ck:resolve_nominal(b)
         if rb.typename == "union" then
            return ck:is_a(a, rb)
         end

         return forall_are_subtype_of(ck, a, b)
      end,
      ["union"] = function(ck, a, b)
         local used = {}
         for _, t in ipairs(a.types) do
            ck:begin_implied_scope()
            local u = exists_supertype_in(ck, t, b)
            ck:end_implied_scope()
            if not u then
               return false
            end
            if not used[u] then
               used[u] = t
            end
         end
         for u, t in pairs(used) do
            ck:is_a(t, u)
         end
         return true
      end,
      ["*"] = forall_are_subtype_of,
   },
   ["poly"] = {



      ["*"] = function(ck, a, b)
         if exists_supertype_in(ck, b, a) then
            return true
         end
         return false, { errors.new("cannot match against any alternatives of the polymorphic type") }
      end,
   },
   ["nominal"] = {
      ["nominal"] = function(ck, a, b)
         local ok, errs = are_same_nominals(ck, a, b)
         if ok then
            return true
         end

         local ra = ck:resolve_nominal(a)
         local rb = ck:resolve_nominal(b)


         local union_a = ra.typename == "union"
         local union_b = rb.typename == "union"
         if union_a or union_b then
            return ck:is_a(union_a and ra or a, union_b and rb or b)
         end


         if rb.typename == "interface" then
            return a_is_interface_b(ck, a, b)
         end


         return ok, errs
      end,
      ["union"] = function(ck, a, b)

         local ra = ck:resolve_nominal(a)
         if ra.typename == "union" then
            return ck:is_a(ra, b)
         end

         return not not exists_supertype_in(ck, a, b)
      end,
      ["*"] = subtype_nominal,
   },
   ["enum"] = {
      ["string"] = compare_true,
   },
   ["string"] = {
      ["string"] = function(_ck, a, b)
         return compare_string_literals(_ck, a, b)
      end,
      ["enum"] = function(_ck, a, b)
         if not a.literal then
            return false, { types.error("%s is not a %s", a, b) }
         end

         if b.enumset[a.literal] then
            return true
         end

         return false, { types.error("%s is not a member of %s", a, b) }
      end,
   },
   ["number"] = {
      ["number"] = function(_ck, a, b)
         return compare_number_literals(_ck, a, b)
      end,
   },
   ["integer"] = {
      ["integer"] = function(_ck, a, b)
         return compare_integer_literals(_ck, a, b)
      end,
      ["number"] = compare_true,
   },
   ["boolean"] = {
      ["boolean"] = function(_ck, a, b)
         return compare_boolean_literals(_ck, a, b)
      end,
   },
   ["interface"] = {
      ["interface"] = function(ck, a, b)
         if is_in_interface_list(ck, a, b) then
            return true
         end
         return ck:same_type(a, b)
      end,
      ["array"] = subtype_array,
      ["tupletable"] = function(ck, a, b)
         return relations.subtype_relations["record"]["tupletable"](ck, a, b)
      end,
      ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
   },
   ["emptytable"] = emptytable_relations,
   ["tupletable"] = {
      ["tupletable"] = function(ck, a, b)
         for i = 1, math.min(#a.types, #b.types) do
            if not ck:is_a(a.types[i], b.types[i]) then
               return false, { types.error("in tuple entry " ..
               tostring(i) .. ": got %s, expected %s",
               a.types[i], b.types[i]), }
            end
         end
         if #a.types > #b.types then
            return false, { types.error("tuple %s is too big for tuple %s", a, b) }
         end
         return true
      end,
      ["record"] = function(ck, a, b)
         if b.elements then
            return relations.subtype_relations["tupletable"]["array"](ck, a, b)
         end
      end,
      ["array"] = function(ck, a, b)
         if b.inferred_len and b.inferred_len > #a.types then
            return false, { errors.new("incompatible length, expected maximum length of " .. tostring(#a.types) .. ", got " .. tostring(b.inferred_len)) }
         end
         local aa, err = ck:arraytype_from_tuple(a.inferred_at or a, a)
         if not aa then
            return false, err
         end
         if not ck:is_a(aa, b) then
            return false, { types.error("got %s (from %s), expected %s", aa, a, b) }
         end
         return true
      end,
      ["map"] = function(ck, a, b)
         local aa = ck:arraytype_from_tuple(a.inferred_at or a, a)
         if not aa then
            return false, { types.error("Unable to convert tuple %s to map", a) }
         end

         return compare_map(ck, a_type(a, "integer", {}), b.keys, aa.elements, b.values)
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["record"] = {
      ["record"] = subtype_record,
      ["interface"] = function(ck, a, b)
         if is_in_interface_list(ck, a, b) then
            return true
         end
         if not a.declname then

            return subtype_record(ck, a, b)
         end
      end,
      ["array"] = subtype_array,
      ["map"] = function(ck, a, b)
         if not ck:is_a(b.keys, a_type(b, "string", {})) then
            return false, { errors.new("can't match a record to a map with non-string keys") }
         end

         for _, k in ipairs(a.field_order) do
            local bk = b.keys
            if bk.typename == "enum" and not bk.enumset[k] then
               return false, { errors.new("key is not an enum value: " .. k) }
            end
            if not ck:is_a(a.fields[k], b.values) then
               return false, { errors.new("record is not a valid map; not all fields have the same type") }
            end
         end

         return true
      end,
      ["tupletable"] = function(ck, a, b)
         if a.elements then
            return relations.subtype_relations["array"]["tupletable"](ck, a, b)
         end
      end,
      ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
   },
   ["array"] = {
      ["array"] = subtype_array,
      ["record"] = function(ck, a, b)
         if b.elements then
            return subtype_array(ck, a, b)
         end
      end,
      ["map"] = function(ck, a, b)
         return compare_map(ck, a_type(a, "integer", {}), b.keys, a.elements, b.values)
      end,
      ["tupletable"] = function(ck, a, b)
         local alen = a.inferred_len or 0
         if alen > #b.types then
            return false, { errors.new("incompatible length, expected maximum length of " .. tostring(#b.types) .. ", got " .. tostring(alen)) }
         end



         for i = 1, (alen > 0) and alen or #b.types do
            if not ck:is_a(a.elements, b.types[i]) then
               return false, { types.error("tuple entry " .. i .. " of type %s does not match type of array elements, which is %s", b.types[i], a.elements) }
            end
         end
         return true
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["map"] = {
      ["map"] = function(ck, a, b)
         return compare_map(ck, a.keys, b.keys, a.values, b.values)
      end,
      ["array"] = function(ck, a, b)
         return compare_map(ck, a.keys, a_type(b, "integer", {}), a.values, b.elements)
      end,
      ["emptytable"] = compare_true_inferring_emptytable,
   },
   ["typedecl"] = {
      ["*"] = function(ck, a, b)
         return ck:is_a(a.def, b)
      end,
   },
   ["function"] = {
      ["function"] = function(ck, a, b)
         local errs = {}

         local aa, ba = a.args.tuple, b.args.tuple
         if (not b.args.is_va) and (ck.feat_arity and (#aa > #ba and a.min_arity > b.min_arity)) then
            table.insert(errs, types.error("incompatible number of arguments: got " .. show_arity(a) .. " %s, expected " .. show_arity(b) .. " %s", a.args, b.args))
         else
            for i = ((a.is_method or b.is_method) and 2 or 1), #aa do
               local ai = aa[i]
               local bi = ba[i] or (b.args.is_va and ba[#ba])
               if bi then
                  ck:arg_check(nil, errs, ai, bi, "bivariant", "argument", i)
               end
            end
         end

         local ar, br = a.rets.tuple, b.rets.tuple
         local diff_by_va = #br - #ar == 1 and b.rets.is_va
         if #ar < #br and not diff_by_va then
            table.insert(errs, types.error("incompatible number of returns: got " .. #ar .. " %s, expected " .. #br .. " %s", a.rets, b.rets))
         else
            local nrets = #br
            if diff_by_va then
               nrets = nrets - 1
            end
            for i = 1, nrets do
               ck:arg_check(nil, errs, ar[i], br[i], "bivariant", "return", i)
            end
         end

         return errors.any(errs)
      end,
   },
   ["self"] = {
      ["self"] = function(_ck, _a, _b)
         return true
      end,
      ["*"] = function(ck, a, b)
         return ck:is_a(ck:type_of_self(a), b)
      end,
   },
   ["typearg"] = {
      ["typearg"] = function(_ck, a, b)
         return a.typearg == b.typearg
      end,
      ["*"] = function(ck, a, b)
         if a.constraint then
            return ck:is_a(a.constraint, b)
         end
      end,
   },
   ["boolean_context"] = {
      ["boolean"] = compare_true,
   },
   ["generic"] = {
      ["*"] = function(ck, a, b)


         local aa = ck:apply_generic(a, a)
         local ok, errs = ck:is_a(aa, b)

         return ok, errs
      end,
   },
   ["*"] = {
      ["any"] = compare_true,
      ["boolean_context"] = compare_true,
      ["emptytable"] = function(_ck, a, _b)
         return false, { types.error("assigning %s to a variable declared with {}", a) }
      end,
      ["unresolved_emptytable_value"] = function(ck, a, b)
         ck:infer_emptytable_from_unresolved_value(b, b, a)
         return true
      end,
      ["generic"] = function(ck, a, b)


         local bb = ck:apply_generic(b, b)
         local ok, errs = ck:is_a(a, bb)

         return ok, errs
      end,
      ["self"] = function(ck, a, b)
         return ck:is_a(a, (ck:type_of_self(b)))
      end,
      ["tuple"] = function(ck, a, b)
         local tuple = a_type(a, "tuple", { tuple = { a } })
         return ck:is_a(tuple, b)
      end,
      ["typedecl"] = function(ck, a, b)
         return ck:is_a(a, b.def)
      end,
      ["typevar"] = function(ck, a, b)
         return compare_or_infer_typevar(ck, b.typevar, a, nil, ck.is_a)
      end,
      ["typearg"] = function(ck, a, b)
         if b.constraint then
            return ck:is_a(a, b.constraint)
         end
      end,



      ["union"] = exists_supertype_in,
      ["nominal"] = subtype_nominal,



      ["poly"] = function(ck, a, b)
         for _, t in ipairs(b.types) do
            if not ck:is_a(a, t) then
               return false, { errors.new("cannot match against all alternatives of the polymorphic type") }
            end
         end
         return true
      end,
   },
}


relations.type_priorities = {

   ["generic"] = -1,
   ["nil"] = 0,
   ["unresolved_emptytable_value"] = 1,
   ["emptytable"] = 2,
   ["self"] = 3,
   ["tuple"] = 4,
   ["typevar"] = 5,
   ["typedecl"] = 6,
   ["any"] = 7,
   ["boolean_context"] = 8,
   ["union"] = 9,
   ["poly"] = 10,

   ["typearg"] = 11,

   ["nominal"] = 12,

   ["enum"] = 13,
   ["string"] = 13,
   ["integer"] = 13,
   ["boolean"] = 13,

   ["interface"] = 14,

   ["tupletable"] = 15,
   ["record"] = 15,
   ["array"] = 15,
   ["map"] = 15,
   ["function"] = 15,
}

function relations.compare_types(ck, prios, rels, t1, t2)
   if t1.typeid == t2.typeid then
      return true
   end

   local s1 = rels[t1.typename]
   local fn = s1 and s1[t2.typename]
   if not fn then
      local p1 = prios[t1.typename] or 999
      local p2 = prios[t2.typename] or 999
      fn = (p1 < p2 and (s1 and s1["*"]) or (rels["*"][t2.typename]))
   end

   local ok, err
   if fn then
      if fn == compare_true then
         return true
      end
      ok, err = fn(ck, t1, t2)
   else
      ok = t1.typename == t2.typename
   end

   if (not ok) and not err then
      if t1.typename == "invalid" or t2.typename == "invalid" then
         return false, {}
      end
      local show_t1 = show_type(t1)
      local show_t2 = show_type(t2)
      if show_t1 == show_t2 then
         return false, { errors.at(t1, "types are incompatible") }
      else
         return false, { errors.at(t1, "got " .. show_t1 .. ", expected " .. show_t2) }
      end
   end
   return ok, err
end

function relations.lax_type_priorities()
   local copy = shallow_copy_table(relations.type_priorities)
   copy["unknown"] = -10
   return copy
end

function relations.lax_subtype_relations()
   local copy = shallow_copy_table(relations.subtype_relations)

   copy["unknown"] = {}
   copy["unknown"]["*"] = compare_true

   copy["*"] = shallow_copy_table(copy["*"])
   copy["*"]["unknown"] = compare_true

   copy["*"]["boolean"] = compare_true

   return copy
end

return relations

end

-- module teal.check.require_file from teal/check/require_file.lua
package.preload["teal.check.require_file"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local input = require("teal.input")




local types = require("teal.types")


local a_type = types.a_type





local require_file = {}











require_file.all_extensions = {
   [".d.tl"] = true,
   [".tl"] = true,
   [".lua"] = true,
}

local function search_for(module_name, suffix, path, tried)
   for entry in path:gmatch("[^;]+") do
      local slash_name = module_name:gsub("%.", "/")


      if not entry:match("%?[/\\]init%.lua$") then
         local filename = entry:gsub("?", slash_name)
         local tl_filename = filename:gsub("%.lua$", suffix)
         local fd = io.open(tl_filename, "rb")
         if not fd then
            table.insert(tried, "no file '" .. tl_filename .. "'")


            tl_filename = filename:gsub("%.lua$", "/init" .. suffix)
            fd = io.open(tl_filename, "rb")
            if not fd then
               table.insert(tried, "no file '" .. tl_filename .. "'")
            end
         end

         if fd then
            local code = fd:read("*a")
            if not code then
               return nil, nil, tried
            end
            fd:close()
            return tl_filename, code, tried
         end
      end
   end
   return nil, nil, tried
end

function require_file.search_module(module_name, extension_set)
   local found
   local code
   local tried = {}
   local path = os.getenv("TL_PATH") or package.path

   if extension_set and extension_set[".d.tl"] then
      found, code, tried = search_for(module_name, ".d.tl", path, tried)
      if found then
         return found, code
      end
   end
   if (not extension_set) or extension_set[".tl"] then
      found, code, tried = search_for(module_name, ".tl", path, tried)
      if found then
         return found, code
      end
   end
   if extension_set and extension_set[".lua"] then
      found, code, tried = search_for(module_name, ".lua", path, tried)
      if found then
         return found, code
      end
   end
   return nil, nil, tried
end

local function a_circular_require(w)
   return a_type(w, "typedecl", { def = a_type(w, "circular_require", {}) })
end

function require_file.search_and_load(env, module_name, extension_set)
   local found, code, tried = require_file.search_module(module_name, extension_set)
   if not found then
      return nil, nil, tried
   end

   env.module_filenames[module_name] = found

   local w = { f = found, x = 1, y = 1 }
   env.modules[module_name] = a_circular_require(w)

   local found_result = input.check(env, found, code, true)
   if not found_result then
      return nil, nil, tried
   end

   env.modules[module_name] = found_result.type

   return found_result, found
end

function require_file.require_module(env, module_name)
   local mod = env.modules[module_name]
   if mod then
      return mod, env.module_filenames[module_name]
   end

   local extensions = require_file.all_extensions
   local found_result, found = require_file.search_and_load(env, module_name, extensions)
   if not found_result then
      return nil
   end

   return found_result.type, found
end

return require_file

end

-- module teal.check.special_functions from teal/check/special_functions.lua
package.preload["teal.check.special_functions"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table






local parser = require("teal.parser")

local node_at = parser.node_at

local types = require("teal.types")

















local a_type = types.a_type
local a_function = types.a_function
local a_vararg = types.a_vararg
local ensure_not_method = types.ensure_not_method
local is_unknown = types.is_unknown

























local function special_pcall_xpcall(self, node, a, b, argdelta)
   local isx = a.special_function_handler == "xpcall"
   local base_nargs = isx and 2 or 1
   local bool = a_type(node, "boolean", {})
   if #node.e2 < base_nargs then
      self:add_error(node, "wrong number of arguments (given " .. #node.e2 .. ", expects at least " .. base_nargs .. ")")
      return a_type(node, "tuple", { tuple = { bool } })
   end

   local ftype = table.remove(b.tuple, 1)




   ftype = ensure_not_method(ftype)

   local fe2 = node_at(node.e2, {})
   if isx then
      base_nargs = 2
      local arg2 = node.e2[2]
      local msgh = table.remove(b.tuple, 1)
      local msgh_type = a_function(arg2, {
         min_arity = self.feat_arity and 1 or 0,
         args = a_type(arg2, "tuple", { tuple = { a_type(arg2, "any", {}) } }),
         rets = a_vararg(arg2, { a_type(arg2, "any", {}) }),
      })
      local ok, errs = self:is_a(msgh, msgh_type)
      if not ok then
         self:add_errors_prefixing(arg2, errs, "in message handler: ")
      end
   end
   for i = base_nargs + 1, #node.e2 do
      table.insert(fe2, node.e2[i])
   end
   local fnode = node_at(node, {
      kind = "op",
      op = { op = "@funcall" },
      e1 = node.e2[1],
      e2 = fe2,
   })
   local rets = self:type_check_funcall(fnode, ftype, b, argdelta + base_nargs)
   if rets.typename == "invalid" then
      return rets
   end
   table.insert(rets.tuple, 1, bool)
   return rets
end

local function pattern_findclassend(pat, i, strict)
   local c = pat:sub(i, i)
   if c == "%" then
      local peek = pat:sub(i + 1, i + 1)
      if peek == "f" then

         if pat:sub(i + 2, i + 2) ~= "[" then
            return nil, nil, "malformed pattern: missing '[' after %f"
         end
         local e, _, err = pattern_findclassend(pat, i + 2, strict)
         if not e then
            return nil, nil, err
         else
            return e, false
         end
      elseif peek == "b" then
         if pat:sub(i + 3, i + 3) == "" then
            return nil, nil, "malformed pattern: need balanced characters"
         end
         return i + 3, false
      elseif peek == "" then
         return nil, nil, "malformed pattern: expected class"
      elseif peek:match("[1-9]") then
         return i + 1, false
      elseif strict and not peek:match("[][^$()%%.*+%-?AaCcDdGgLlPpSsUuWwXxZz]") then
         return nil, nil, "malformed pattern: invalid class '" .. peek .. "'"
      else
         return i + 1, true
      end
   elseif c == "[" then
      if pat:sub(i + 1, i + 1) == "^" then
         i = i + 2
      else
         i = i + 1
      end

      local isfirst = true
      repeat
         local c_ = pat:sub(i, i)
         if c_ == "" then
            return nil, nil, "malformed pattern: missing ']'"
         elseif c_ == "%" then
            if strict and not pat:sub(i + 1, i + 1):match("[][^$()%%.*+%-?AaCcDdGgLlPpSsUuWwXxZz]") then
               return nil, nil, "malformed pattern: invalid escape"
            end
            i = i + 2
         elseif c_ == "-" and strict and not isfirst then
            return nil, nil, "malformed pattern: unexpected '-'"
         else
            local c2 = pat:sub(i + 1, i + 1)
            local c3 = pat:sub(i + 2, i + 2)
            if c2 == "-" then
               if strict and c3 == "]" then
                  return nil, nil, "malformed pattern: unexpected ']'"
               elseif strict and c3 == "-" then
                  return nil, nil, "malformed pattern: unexpected '-'"
               elseif strict and c3 == "%" then
                  return nil, nil, "malformed pattern: unexpected '%'"
               end

               i = i + 2
            else
               i = i + 1
            end
         end
         isfirst = false
      until pat:sub(i, i) == "]"

      return i, true
   else
      return i, true
   end
end

local pattern_isop = {
   ["?"] = true,
   ["+"] = true,
   ["-"] = true,
   ["*"] = true,
}

local function parse_pattern_string(node, pat, inclempty)





















   local strict = false

   local results = {}

   local i = pat:sub(1, 1) == "^" and 2 or 1
   local unclosed = 0

   while i <= #pat do
      local c = pat:sub(i, i)

      if i == #pat and c == "$" then
         break
      end

      local classend, canhavemul, err = pattern_findclassend(pat, i, strict)
      if not classend then
         return nil, err
      end

      local peek = pat:sub(classend + 1, classend + 1)

      if c == "(" and peek == ")" then

         table.insert(results, a_type(node, "integer", {}))
         i = i + 2
      elseif c == "(" then
         table.insert(results, a_type(node, "string", {}))
         unclosed = unclosed + 1
         i = i + 1
      elseif c == ")" then
         unclosed = unclosed - 1
         if unclosed < 0 then
            return nil, "malformed pattern: unexpected ')'"
         end
         i = i + 1
      elseif strict and c:match("[]^$()*+%-?]") then
         return nil, "malformed pattern: character was unexpected: '" .. c .. "'"
      elseif pattern_isop[peek] and canhavemul then
         i = classend + 2
      else

         i = classend + 1
      end
   end

   if inclempty and not results[1] then
      results[1] = a_type(node, "string", {})
   end
   if unclosed ~= 0 then
      return nil, "malformed pattern: " .. unclosed .. " capture" .. (unclosed == 1 and "" or "s") .. " not closed"
   end
   return results
end

local function parse_format_string(node, pat)
   local pos = 1
   local results = {}
   while pos <= #pat do

      local endc = pat:match("%%[-+#0-9. ]*()", pos)
      if not endc then return results end
      local c = pat:sub(endc, endc)
      if c == "" then
         return nil, "missing pattern specifier at end"
      end
      if c:match("[AaEefGg]") then
         table.insert(results, a_type(node, "number", {}))
      elseif c:match("[cdiouXx]") then
         table.insert(results, a_type(node, "integer", {}))
      elseif c == "q" then
         table.insert(results,
         a_type(node, "union", { types = {
            a_type(node, "string", {}),
            a_type(node, "number", {}),
            a_type(node, "integer", {}),
            a_type(node, "boolean", {}),
            a_type(node, "nil", {}),
         } }))

      elseif c == "p" or c == "s" then
         table.insert(results, a_type(node, "any", {}))
      elseif c == "%" then

      else
         return nil, "invalid pattern specifier: '" .. c .. "'"
      end
      pos = endc + 1
   end
   return results
end

local function pack_string_skipnum(pos, pat)

   return pat:match("[0-9]*()", pos)
end

local function parse_pack_string(node, pat)
   local pos = 1
   local results = {}
   local skip_next = false
   while pos <= #pat do
      local c = pat:sub(pos, pos)
      local to_add
      local goto_next
      if c:match("[<> =x]") then

         if skip_next then
            return nil, "expected argument for 'X'"
         end
         pos = pos + 1
         goto_next = true
      elseif c == "X" then
         if skip_next then
            return nil, "expected argument for 'X'"
         end
         skip_next = true
         pos = pos + 1
         goto_next = true
      elseif c == "!" then
         if skip_next then
            return nil, "expected argument for 'X'"
         end
         pos = pack_string_skipnum(pos + 1, pat)
         goto_next = true
      elseif c:match("[Ii]") then
         pos = pack_string_skipnum(pos + 1, pat)
         to_add = a_type(node, "integer", {})
      elseif c:match("[bBhHlLjJT]") then
         pos = pos + 1
         to_add = a_type(node, "integer", {})
      elseif c:match("[fdn]") then
         pos = pos + 1
         to_add = a_type(node, "number", {})
      elseif c == "z" or c == "s" or c == "c" then
         if c == "z" then
            pos = pos + 1
         else
            pos = pack_string_skipnum(pos + 1, pat)
         end

         to_add = a_type(node, "string", {})
      else
         return nil, "invalid format option: '" .. c .. "'"
      end
      if not goto_next then
         if skip_next then
            skip_next = false
         else
            table.insert(results, to_add)
         end
      end
   end
   if skip_next then
      return nil, "expected argument for 'X'"
   end
   return results
end

local special_functions = {
   ["pairs"] = function(self, node, a, b, argdelta)
      if not b.tuple[1] then
         return self:invalid_at(node, "pairs requires an argument")
      end
      local t = self:to_structural(b.tuple[1])
      if t.elements then
         self:add_warning("hint", node, "hint: applying pairs on an array: did you intend to apply ipairs?")
      end

      if not (t.typename == "map") then
         if not (self.feat_lax and is_unknown(t)) then
            if t.fields then
               self:match_all_record_field_names(node.e2, t, t.field_order,
               "attempting pairs on a record with attributes of different types")
               local ct = t.typename == "record" and "{string:any}" or "{any:any}"
               self:add_warning("hint", node.e2, "hint: if you want to iterate over fields of a record, cast it to " .. ct)
            else
               self:add_error(node.e2, "cannot apply pairs on values of type: %s", t)
            end
         end
      end

      return (self:type_check_function_call(node, a, b, argdelta))
   end,

   ["ipairs"] = function(self, node, a, b, argdelta)
      if not b.tuple[1] then
         return self:invalid_at(node, "ipairs requires an argument")
      end
      local orig_t = b.tuple[1]
      local t = self:to_structural(orig_t)

      if t.typename == "tupletable" then
         local arr_type = self:arraytype_from_tuple(node.e2, t)
         if not arr_type then
            return self:invalid_at(node.e2, "attempting ipairs on tuple that's not a valid array: %s", orig_t)
         end
      elseif not t.elements then
         if not (self.feat_lax and (is_unknown(t) or t.typename == "emptytable")) then
            return self:invalid_at(node.e2, "attempting ipairs on something that's not an array: %s", orig_t)
         end
      end

      return (self:type_check_function_call(node, a, b, argdelta))
   end,

   ["rawget"] = function(self, node, _a, b, _argdelta)

      if #b.tuple == 2 then
         local result = self:type_check_index(node.e2[1], node.e2[2], b.tuple[1], b.tuple[2])
         if self.feat_strict_nil and not (result.typename == "invalid") then
            result = types.unite(node, { result, a_type(node, "nil", {}) }, true, false)
         end
         return a_type(node, "tuple", { tuple = { result } })
      else
         return self:invalid_at(node, "rawget expects two arguments")
      end
   end,

   ["require"] = function(self, node, _a, b, _argdelta)
      if #b.tuple ~= 1 then
         return self:invalid_at(node, "require expects one literal argument")
      end
      if node.e2[1].kind ~= "string" then
         if self.native_ffi then
            return self:invalid_at(node, "the C target only supports a literal runtime require of 'ffi'")
         end
         return a_type(node, "tuple", { tuple = { a_type(node, "any", {}) } })
      end

      local module_name = assert(node.e2[1].conststr)
      if self.native_ffi and not node.type_require then
         if module_name == "ffi" then
            return a_type(node, "tuple", { tuple = { self.native_ffi.ffi } })
         end
         return self:invalid_at(node, "the C target only supports runtime require('ffi'); use 'local type' for type imports")
      end
      local t, module_filename = self.env:require_module(module_name)
      if not t then
         return self:invalid_at(node, "module not found: '" .. module_name .. "'")
      end

      if self.feat_lax then
         if t.typename == "invalid" then
            return a_type(node, "tuple", { tuple = { a_type(node, "unknown", {}) } })
         end
      elseif module_filename and module_filename:match("%.lua$") then
         return self:invalid_at(node, "no type information for required module: '" .. module_name .. "'")
      end

      self.dependencies[module_name] = module_filename
      return a_type(node, "tuple", { tuple = { t } })
   end,

   ["pcall"] = special_pcall_xpcall,
   ["xpcall"] = special_pcall_xpcall,
   ["assert"] = function(self, node, a, b, argdelta)
      self.fdb:set_truthy(node)
      local r = self:type_check_function_call(node, a, b, argdelta)
      if node.e2[1] then
         self:apply_facts_from(node, node.e2[1])
      end
      return r
   end,
   ["table.unpack"] = function(self, node, a, b, argdelta)

      if #b.tuple == 1 then
         local first = b.tuple[1]
         if first.typename == "nominal" and first.found then
            local table_t = (self.env.modules["table"]).def
            local packtable = (table_t.fields["PackTable"]).def

            if first.found.def.typeid == packtable.typeid then
               self:add_warning("hint", node, "hint: table.unpack should use indices for packed tables: use the form table.unpack(t, 1, t.n) instead")
            end
         end
      end
      return (self:type_check_function_call(node, a, b, argdelta))
   end,
   ["string.pack"] = function(self, node, a, b, argdelta)
      if #b.tuple < 1 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects at least 1)")
      end

      local packstr = b.tuple[1]

      if packstr.typename == "string" and packstr.literal and a.typename == "function" then
         local st = packstr.literal
         local items, e = parse_pack_string(node, st)

         if e then
            if items then

               self:add_warning("hint", packstr, e)
            else
               return self:invalid_at(packstr, e)
            end
         end

         table.insert(items, 1, a_type(node, "string", {}))

         if #items ~= #b.tuple then
            return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects " .. #items .. ")")
         end

         return (self:type_check_function_call(node, a, b, argdelta, a_type(node, "tuple", { tuple = items }), nil))
      else
         return (self:type_check_function_call(node, a, b, argdelta))
      end
   end,

   ["string.unpack"] = function(self, node, a, b, argdelta)
      if #b.tuple < 2 or #b.tuple > 3 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects 2 or 3)")
      end

      local packstr = b.tuple[1]

      local rets

      if packstr.typename == "string" and packstr.literal then
         local st = packstr.literal
         local items, e = parse_pack_string(node, st)

         if e then
            if items then

               self:add_warning("hint", packstr, e)
            else
               return self:invalid_at(packstr, e)
            end
         end

         table.insert(items, a_type(node, "integer", {}))


         rets = a_type(node, "tuple", { tuple = items })
      end

      return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
   end,

   ["string.format"] = function(self, node, a, b, argdelta)
      if #b.tuple < 1 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects at least 1)")
      end

      local fstr = b.tuple[1]

      if fstr.typename == "string" and fstr.literal and a.typename == "function" then
         local st = fstr.literal
         local items, e = parse_format_string(node, st)

         if e then
            if items then

               self:add_warning("hint", fstr, e)
            else
               return self:invalid_at(fstr, e)
            end
         end

         table.insert(items, 1, a_type(node, "string", {}))

         if #items ~= #b.tuple then
            return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects " .. #items .. ")")
         end


         return (self:type_check_function_call(node, a, b, argdelta, a_type(node, "tuple", { tuple = items }), nil))
      else
         return (self:type_check_function_call(node, a, b, argdelta))
      end
   end,

   ["string.match"] = function(self, node, a, b, argdelta)
      if #b.tuple < 2 or #b.tuple > 3 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects 2 or 3)")
      end

      local rets
      local pat = b.tuple[2]

      if pat.typename == "string" and pat.literal then
         local st = pat.literal
         local items, e = parse_pattern_string(node, st, true)

         if e then
            if items then

               self:add_warning("hint", pat, e)
            else
               return self:invalid_at(pat, e)
            end
         end


         if self.feat_strict_nil then
            for i, item in ipairs(items) do
               items[i] = types.unite(node, { item, a_type(node, "nil", {}) }, true, false)
            end
         end
         rets = a_type(node, "tuple", { tuple = items })
      end
      return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
   end,

   ["string.find"] = function(self, node, a, b, argdelta)
      if #b.tuple < 2 or #b.tuple > 4 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects at least 2 and at most 4)")
      end

      local plainarg = node.e2[4 + (argdelta or 0)]
      local pat = b.tuple[2]

      local rets

      if pat.typename == "string" and pat.literal and
         ((not plainarg) or (plainarg.kind == "boolean" and plainarg.tk == "false")) then

         local st = pat.literal

         local items, e = parse_pattern_string(node, st, false)

         if e then
            if items then

               self:add_warning("hint", pat, e)
            else
               return self:invalid_at(pat, e)
            end
         end

         table.insert(items, 1, a_type(pat, "integer", {}))
         table.insert(items, 1, a_type(pat, "integer", {}))


         if self.feat_strict_nil then
            for i, item in ipairs(items) do
               items[i] = types.unite(node, { item, a_type(node, "nil", {}) }, true, false)
            end
         end
         rets = a_type(node, "tuple", { tuple = items })
      end

      return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
   end,

   ["string.gmatch"] = function(self, node, a, b, argdelta)
      if #b.tuple < 2 or #b.tuple > 3 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects 2 or 3)")
      end

      local rets
      local pat = b.tuple[2]

      if pat.typename == "string" and pat.literal then
         local st = pat.literal
         local items, e = parse_pattern_string(node, st, true)

         if e then
            if items then

               self:add_warning("hint", pat, e)
            else
               return self:invalid_at(pat, e)
            end
         end


         rets = a_type(node, "tuple", { tuple = {
            a_function(node, {
               min_arity = 0,
               args = a_type(node, "tuple", { tuple = {} }),
               rets = a_type(node, "tuple", { tuple = items }),
            }),
         } })
      end

      return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
   end,

   ["string.gsub"] = function(self, node, a, b, argdelta)



      if #b.tuple < 3 or #b.tuple > 4 then
         return self:invalid_at(node, "wrong number of arguments (given " .. #b.tuple .. ", expects 3 or 4)")
      end
      local pat = b.tuple[2]
      local orig_t = b.tuple[3]
      local trepl = self:to_structural(orig_t)

      local has_fourth = b.tuple[4]

      local args

      if pat.typename == "string" and pat.literal then
         local st = pat.literal
         local items, e = parse_pattern_string(node, st, true)

         if e then
            if items then

               self:add_warning("hint", pat, e)
            else
               return self:invalid_at(pat, e)
            end
         end

         local i1 = items[1]






         local replarg_type

         local expected_pat_return = a_type(node, "union", { types = {
            a_type(node, "string", {}),
            a_type(node, "integer", {}),
            a_type(node, "number", {}),
         } })
         if self:is_a(trepl, expected_pat_return) then

            replarg_type = expected_pat_return
         elseif trepl.typename == "map" then
            replarg_type = a_type(node, "map", { keys = i1, values = expected_pat_return })
         elseif trepl.fields then
            if not (i1.typename == "string") then
               self:invalid_at(trepl, "expected a table with integers as keys")
            end
            replarg_type = a_type(node, "map", { keys = i1, values = expected_pat_return })
         elseif trepl.elements then
            if not (i1.typename == "integer") then
               self:invalid_at(trepl, "expected a table with strings as keys")
            end
            replarg_type = a_type(node, "array", { elements = expected_pat_return })
         elseif trepl.typename == "function" then
            local validftype = a_function(node, {
               min_arity = self.feat_arity and #items or 0,
               args = a_type(node, "tuple", { tuple = items }),
               rets = a_vararg(node, { expected_pat_return }),
            })
            replarg_type = validftype
         end


         if replarg_type then
            args = a_type(node, "tuple", { tuple = {
               a_type(node, "string", {}),
               a_type(node, "string", {}),
               replarg_type,
               has_fourth and a_type(node, "integer", {}) or nil,
            } })
         end
      end

      return (self:type_check_function_call(node, a, b, argdelta, args, nil))
   end,
}

return special_functions

end

-- module teal.check.visitors from teal/check/visitors.lua
package.preload["teal.check.visitors"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table



local context = require("teal.check.context")
local c_ffi = require("teal.gen.c_ffi")


local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG




local types = require("teal.types")

































local a_type = types.a_type
local a_function = types.a_function
local a_vararg = types.a_vararg
local drop_constant_value = types.drop_constant_value
local drop_constant_values = types.drop_constant_values
local edit_type = types.edit_type
local ensure_not_method = types.ensure_not_method
local is_unknown = types.is_unknown
local is_valid_union = types.is_valid_union
local show_type = types.show_type
local simple_types = types.simple_types
local type_at = types.type_at
local typedecl_to_nominal = types.typedecl_to_nominal
local unite = types.unite
local untuple = types.untuple
local wrap_generic_if_typeargs = types.wrap_generic_if_typeargs

local parser = require("teal.parser")


local node_at = parser.node_at
local node_is_funcall = parser.node_is_funcall

local facts = require("teal.facts")
local IsFact = facts.IsFact
local facts_not = facts.facts_not

local macroexps = require("teal.macroexps")

local metamethods = require("teal.metamethods")
local unop_to_metamethod = metamethods.unop_to_metamethod
local binop_to_metamethod = metamethods.binop_to_metamethod
local flip_binop_to_metamethod = metamethods.flip_binop_to_metamethod

local traversal = require("teal.traversal")

local traverse_nodes = traversal.traverse_nodes
local fields_of = traversal.fields_of

local type_errors = require("teal.type_errors")

local ensure_not_abstract = type_errors.ensure_not_abstract




local util = require("teal.util")
local sorted_keys = util.sorted_keys



local visitors = {}




visitors.visit_node = {}
visitors.visit_type = {}
local visit_node = visitors.visit_node
local visit_type = visitors.visit_type






























local numeric_binop = {
   ["number"] = {
      ["number"] = "number",
      ["integer"] = "number",
   },
   ["integer"] = {
      ["integer"] = "integer",
      ["number"] = "number",
   },
}

local float_binop = {
   ["number"] = {
      ["number"] = "number",
      ["integer"] = "number",
   },
   ["integer"] = {
      ["integer"] = "number",
      ["number"] = "number",
   },
}

local integer_binop = {
   ["number"] = {
      ["number"] = "integer",
      ["integer"] = "integer",
   },
   ["integer"] = {
      ["integer"] = "integer",
      ["number"] = "integer",
   },
}

local relational_binop = {
   ["number"] = {
      ["integer"] = "boolean",
      ["number"] = "boolean",
   },
   ["integer"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
   },
   ["string"] = {
      ["string"] = "boolean",
   },
   ["boolean"] = {
      ["boolean"] = "boolean",
   },
}

local equality_binop = {
   ["number"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["nil"] = "boolean",
   },
   ["integer"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["nil"] = "boolean",
   },
   ["string"] = {
      ["string"] = "boolean",
      ["nil"] = "boolean",
   },
   ["boolean"] = {
      ["boolean"] = "boolean",
      ["nil"] = "boolean",
   },
   ["record"] = {
      ["emptytable"] = "boolean",
      ["record"] = "boolean",
      ["nil"] = "boolean",
   },
   ["array"] = {
      ["emptytable"] = "boolean",
      ["array"] = "boolean",
      ["nil"] = "boolean",
   },
   ["map"] = {
      ["emptytable"] = "boolean",
      ["map"] = "boolean",
      ["nil"] = "boolean",
   },
   ["thread"] = {
      ["thread"] = "boolean",
      ["nil"] = "boolean",
   },
}

local unop_types = {
   ["#"] = {
      ["enum"] = "integer",
      ["string"] = "integer",
      ["array"] = "integer",
      ["tupletable"] = "integer",
      ["map"] = "integer",
      ["emptytable"] = "integer",
   },
   ["-"] = {
      ["number"] = "number",
      ["integer"] = "integer",
   },
   ["~"] = {
      ["number"] = "integer",
      ["integer"] = "integer",
   },
   ["not"] = {
      ["string"] = "boolean",
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["boolean"] = "boolean",
      ["record"] = "boolean",
      ["array"] = "boolean",
      ["tupletable"] = "boolean",
      ["map"] = "boolean",
      ["emptytable"] = "boolean",
      ["thread"] = "boolean",
   },
}

local binop_types = {
   ["+"] = numeric_binop,
   ["-"] = numeric_binop,
   ["*"] = numeric_binop,
   ["%"] = numeric_binop,
   ["/"] = float_binop,
   ["//"] = numeric_binop,
   ["^"] = float_binop,
   ["&"] = integer_binop,
   ["|"] = integer_binop,
   ["<<"] = integer_binop,
   [">>"] = integer_binop,
   ["~>>"] = integer_binop,
   ["~"] = integer_binop,
   ["=="] = equality_binop,
   ["~="] = equality_binop,
   ["<="] = relational_binop,
   [">="] = relational_binop,
   ["<"] = relational_binop,
   [">"] = relational_binop,
   ["or"] = {
      ["boolean"] = {
         ["boolean"] = "boolean",
      },
      ["number"] = {
         ["integer"] = "number",
         ["number"] = "number",
         ["boolean"] = "boolean",
      },
      ["integer"] = {
         ["integer"] = "integer",
         ["number"] = "number",
         ["boolean"] = "boolean",
      },
      ["string"] = {
         ["string"] = "string",
         ["boolean"] = "boolean",
         ["enum"] = "string",
      },
      ["function"] = {
         ["boolean"] = "boolean",
      },
      ["array"] = {
         ["boolean"] = "boolean",
      },
      ["record"] = {
         ["boolean"] = "boolean",
      },
      ["map"] = {
         ["boolean"] = "boolean",
      },
      ["enum"] = {
         ["string"] = "string",
      },
      ["thread"] = {
         ["boolean"] = "boolean",
      },
   },
   [".."] = {
      ["string"] = {
         ["string"] = "string",
         ["enum"] = "string",
         ["number"] = "string",
         ["integer"] = "string",
      },
      ["number"] = {
         ["integer"] = "string",
         ["number"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      },
      ["integer"] = {
         ["integer"] = "string",
         ["number"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      },
      ["enum"] = {
         ["number"] = "string",
         ["integer"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      },
   },
}

local function resolve_typedecl(t)
   if t.typename == "typedecl" then
      return t.def
   else
      return t
   end
end

local function type_has_explicit_nil(self, t, seen)
   seen = seen or {}
   if seen[t] then
      return false
   end
   seen[t] = true

   if t.typename == "nil" then
      return true
   elseif t.typename == "typedecl" then
      return type_has_explicit_nil(self, t.def, seen)
   elseif t.typename == "nominal" then
      local resolved = self:resolve_nominal(t)
      if resolved then
         return type_has_explicit_nil(self, resolved, seen)
      end
      return false
   elseif t.typename == "union" then
      for _, ut in ipairs(t.types) do
         if type_has_explicit_nil(self, ut, seen) then
            return true
         end
      end
      return false
   elseif t.typename == "tuple" then
      for _, ut in ipairs(t.tuple) do
         if type_has_explicit_nil(self, ut, seen) then
            return true
         end
      end
      return false
   elseif t.typename == "typevar" and t.constraint then
      return type_has_explicit_nil(self, t.constraint, seen)
   elseif t.typename == "typearg" and t.constraint then
      return type_has_explicit_nil(self, t.constraint, seen)
   elseif t.typename == "self" and t.display_type then
      return type_has_explicit_nil(self, t.display_type, seen)
   elseif t.typename == "generic" then
      return type_has_explicit_nil(self, t.t, seen)
   elseif t.typename == "poly" then
      for _, pt in ipairs(t.types) do
         if type_has_explicit_nil(self, pt, seen) then
            return true
         end
      end
      return false
   end

   return false
end

local function has_explicit_argtypes(args)
   if not args then
      return false
   end
   for _, arg_node in ipairs(args) do
      if arg_node.argtype then
         return true
      end
   end
   return false
end

local function function_has_explicit_types(args, rets)
   if rets and #rets.tuple > 0 then
      return true
   end
   return has_explicit_argtypes(args)
end

local function truthy_type(self, t, seen)
   seen = seen or {}
   if seen[t] then
      return t, false
   end
   seen[t] = true

   if t.typename == "typedecl" then
      return truthy_type(self, t.def, seen)
   elseif t.typename == "nominal" then
      local resolved = self:resolve_nominal(t)
      if resolved then
         return truthy_type(self, resolved, seen)
      end
      return t, false
   elseif t.typename == "typevar" and t.constraint then
      return truthy_type(self, t.constraint, seen)
   elseif t.typename == "union" then
      local out = {}
      local has_falsy = false
      for _, ut in ipairs(t.types) do
         local tt, hf = truthy_type(self, ut, seen)
         if tt then
            table.insert(out, tt)
         end
         if hf then
            has_falsy = true
         end
      end
      if #out == 0 then
         return nil, true
      end
      return unite(t, out, nil, not self.feat_strict_nil), has_falsy
   elseif t.typename == "nil" then
      return nil, true
   elseif t.typename == "boolean" then
      if t.literal == nil then
         local tt = a_type(t, "boolean", {})
         tt.literal = true
         return tt, true
      elseif t.literal == false then
         return nil, true
      else
         return t, false
      end
   else
      return t, false
   end
end

local function is_literal_value_type(t)
   return (t.typename == "string" and t.literal ~= nil) or
   (t.typename == "number" and t.literal ~= nil) or
   (t.typename == "integer" and t.literal ~= nil) or
   (t.typename == "boolean" and t.literal ~= nil)
end


local NONE = a_type({ f = "@none", x = -1, y = -1 }, "none", {})

local function end_scope_and_none_type(self, node, _children)
   self:end_scope(node)
   return NONE
end

local is_lua_table_type

do
   local known_table_types = {
      array = true,
      map = true,
      record = true,
      tupletable = true,
      interface = true,
   }


   is_lua_table_type = function(t)
      return known_table_types[t.typename] and
      not (t.fields and t.is_userdata)
   end
end

local function type_is_closable(t)
   if t.typename == "invalid" then
      return false
   end
   if t.typename == "nil" then
      return true
   end
   if t.typename == "nominal" then
      t = assert(t.resolved)
   end
   if t.fields then
      return t.meta_fields and t.meta_fields["__close"] ~= nil
   end
end

local definitely_not_closable_exprs = {
   ["string"] = true,
   ["number"] = true,
   ["integer"] = true,
   ["boolean"] = true,
   ["literal_table"] = true,
}
local function expr_is_definitely_not_closable(e)
   return definitely_not_closable_exprs[e.kind]
end

local function make_is_node(self, var, v, t)
   local node = node_at(var, { kind = "op", op = { op = "is", arity = 2, prec = 3 } })
   node.e1 = var
   node.e2 = node_at(var, { kind = "cast", casttype = self:infer_at(var, t) })
   local _, has = self:check_metamethod(node, "__is", self:to_structural(v), self:to_structural(t), v, t)
   if node.expanded then
      macroexps.apply(node)
   end
   self.fdb:set_is(node, var.tk, t)
   return node, has
end

local function convert_is_of_union_to_or_of_is(self, node, v, u)
   local var = node.e1
   node.op.op = "or"
   node.op.arity = 2
   node.op.prec = 1
   local has_any = nil
   node.e1, has_any = make_is_node(self, var, v, u.types[1])
   local at = node
   local n = #u.types
   for i = 2, n - 1 do
      at.e2 = node_at(var, { kind = "op", op = { op = "or", arity = 2, prec = 1 } })
      local has
      at.e2.e1, has = make_is_node(self, var, v, u.types[i])
      has_any = has_any or has
      self.fdb:set_or(node, at.e1, at.e2)
      at = at.e2
   end
   at.e2 = make_is_node(self, var, v, u.types[n])
   self.fdb:set_or(node, at.e1, at.e2)
   return not not has_any
end

local function flat_tuple(w, vt)
   local n_vals = #vt
   local ret = a_type(w, "tuple", { tuple = {} })
   local rt = ret.tuple

   if n_vals == 0 then
      return ret
   end


   for i = 1, n_vals - 1 do
      rt[i] = untuple(vt[i])
   end

   local last = vt[n_vals]
   if last.typename == "tuple" then

      local lt = last.tuple
      for _, v in ipairs(lt) do
         table.insert(rt, v)
      end
      ret.is_va = last.is_va
   else
      rt[n_vals] = vt[n_vals]
   end

   return ret
end

local function get_assignment_values(w, vals, wanted)
   if vals == nil then
      return a_type(w, "tuple", { tuple = {} })
   end


   if vals.is_va then
      local vt = vals.tuple
      local n_vals = #vt
      if n_vals > 0 and n_vals < wanted then
         local last = vt[n_vals]
         local ret = a_type(w, "tuple", { tuple = {} })
         local rt = ret.tuple
         for i = 1, n_vals do
            table.insert(rt, vt[i])
         end
         for _ = n_vals + 1, wanted do
            table.insert(rt, last)
         end
         return ret
      end
   end
   return vals
end


local function is_localizing_a_variable(node, i)
   return node.exps and
   node.exps[i] and
   node.exps[i].kind == "variable" and
   node.exps[i].tk == node.vars[i].tk
end

local function set_expected_types_to_decltuple(self, node, children)
   local decltuple = node.kind == "assignment" and children[1] or node.decltuple
   assert(decltuple.typename == "tuple")
   local decls = decltuple.tuple
   if decls and node.exps then
      local ndecl = #decls
      local nexps = #node.exps
      for i = 1, nexps do
         local typ
         typ = decls[i]
         if typ then
            if i == nexps and ndecl > nexps and node_is_funcall(node.exps[i]) then
               typ = a_type(node, "tuple", { tuple = {} })
               for a = i, ndecl do
                  table.insert(typ.tuple, decls[a])
               end
            end
            node.exps[i].expected = typ
            node.exps[i].expected_context = { kind = node.kind, name = node.vars[i].tk }
         end
      end
   end

   if node.decltuple then
      local ndecltuple = #node.decltuple.tuple
      local nvars = #node.vars
      if ndecltuple > nvars then
         self.errs:add(node.decltuple.tuple[nvars + 1], "number of types exceeds number of variables")
      end
   end
end

local function is_positive_int(n)
   return n and n >= 1 and math.floor(n) == n
end

local function infer_table_literal(self, node, children)
   local is_record = false
   local is_array = false
   local is_map = false

   local is_tuple = false
   local is_not_tuple = false

   local last_array_idx = 1
   local largest_array_idx = -1

   local seen_keys = {}


   local typs

   local fields
   local field_order

   local elements

   local keys, values

   for i, child in ipairs(children) do
      local ck = child.kname
      local cktype = child.ktype
      local key = ck
      local n
      if not key then
         n = node[i].key.constnum
         key = n
         if not key and node[i].key.kind == "boolean" then
            key = (node[i].key.tk == "true")
         end
      end

      self.errs:check_redeclared_key(node[i], nil, seen_keys, key)

      local raw_vtype = untuple(child.vtype)
      local uvtype = raw_vtype
      if ck then
         is_record = true
         if not fields then
            fields = {}
            field_order = {}
         end
         fields[ck] = uvtype
         table.insert(field_order, ck)
      elseif is_numeric_type(cktype) then
         is_array = true
         if not is_not_tuple then
            is_tuple = true
         end
         if not typs then
            typs = {}
         end

         if node[i].key_parsed == "implicit" then
            local cv = child.vtype
            if i == #children and cv.typename == "tuple" then

               for _, c in ipairs(cv.tuple) do
                  local ct = c
                  local elem = drop_constant_values(ct, false)
                  elements = self:expand_type(node, elements, elem)
                  typs[last_array_idx] = untuple(ct)
                  last_array_idx = last_array_idx + 1
               end
            else
               typs[last_array_idx] = uvtype
               last_array_idx = last_array_idx + 1
               local elem = drop_constant_values(uvtype, false)
               elements = self:expand_type(node, elements, elem)
            end
         else
            if not is_positive_int(n) then
               local elem = drop_constant_values(uvtype, false)
               elements = self:expand_type(node, elements, elem)
               is_not_tuple = true
            elseif n then
               typs[n] = uvtype
               if n > largest_array_idx then
                  largest_array_idx = n
               end
               local elem = drop_constant_values(uvtype, false)
               elements = self:expand_type(node, elements, elem)
            end
         end

         if last_array_idx > largest_array_idx then
            largest_array_idx = last_array_idx
         end
         if not elements then
            is_array = false
         end
      else
         is_map = true
         keys = self:expand_type(node, keys, cktype, false)
         values = self:expand_type(node, values, uvtype, false)
      end
   end

   local t

   if is_array and is_map then
      self.errs:add(node, "cannot determine type of table literal")
      t = a_type(node, "map", { keys =
      self:expand_type(node, keys, a_type(node, "integer", {})), values =

      self:expand_type(node, values, elements) })
   elseif is_record and is_array then

      local pure_array = true
      if not is_not_tuple then
         local last_t
         for _, current_t in pairs(typs) do
            if last_t then
               if not self:same_type(last_t, current_t) then
                  pure_array = false
                  break
               end
            end
            last_t = current_t
         end
      end
      if pure_array then
         t = a_type(node, "record", {
            fields = fields,
            field_order = field_order,
            elements = elements,
            interface_list = {
               a_type(node, "array", { elements = elements }),
            },
         })
      else
         local tuple_iface = a_type(node, "tupletable", { inferred_at = node })
         tuple_iface.types = typs
         t = a_type(node, "record", {
            fields = fields,
            field_order = field_order,
            types = typs,
            interface_list = {
               tuple_iface,
            },
         })
      end
   elseif is_record and is_map then
      if keys.typename == "string" then
         for _, fname in ipairs(field_order) do
            values = self:expand_type(node, values, fields[fname])
         end
         t = a_type(node, "map", { keys = keys, values = values })
      else
         self.errs:add(node, "cannot determine type of table literal")
      end
   elseif is_array then
      local pure_array = true
      if not is_not_tuple then
         local last_t
         for _, current_t in pairs(typs) do
            if last_t then
               if not self:same_type(drop_constant_values(last_t, false), drop_constant_values(current_t, false)) then
                  pure_array = false
                  break
               end
            end
            last_t = current_t
         end
      end
      if pure_array then
         t = a_type(node, "array", { elements = elements })
         t.consttypes = typs
         t.inferred_len = largest_array_idx - 1
      else
         t = a_type(node, "tupletable", { inferred_at = node })
         t.types = typs
      end
   elseif is_record then
      t = a_type(node, "record", {
         fields = fields,
         field_order = field_order,
      })
   elseif is_map then
      t = a_type(node, "map", { keys = keys, values = values })
   elseif is_tuple then
      t = a_type(node, "tupletable", { inferred_at = node })
      t.types = typs
      if not typs or #typs == 0 then
         self.errs:add(node, "cannot determine type of tuple elements")
      end
   end

   if not t then
      t = a_type(node, "emptytable", {})
   end

   return type_at(node, t)
end

local function total_check_key(key, seen_keys, is_total, missing)
   if not seen_keys[key] then
      missing = missing or {}
      table.insert(missing, tostring(key))
      return false, missing
   end
   return is_total, missing
end

local function field_requires_literal_entry(ftype)
   return not (ftype.typename == "typedecl" or (ftype.typename == "function" and (ftype.is_record_function or ftype.macroexp)))
end

local function total_record_check(t, seen_keys)
   local is_total = true
   local missing
   for _, key in ipairs(t.field_order) do
      local ftype = t.fields[key]
      if field_requires_literal_entry(ftype) then
         is_total, missing = total_check_key(key, seen_keys, is_total, missing)
      end
   end
   return is_total, missing
end

local function required_record_check(self, t, seen_keys)
   local missing
   local niltype = a_type(t, "nil", {})
   for _, key in ipairs(t.field_order) do
      local ftype = t.fields[key]
      if field_requires_literal_entry(ftype) then
         if not seen_keys[key] and not self:is_a(niltype, ftype) then
            missing = missing or {}
            table.insert(missing, tostring(key))
         end
      end
   end
   return missing
end

local function total_map_check(keys, seen_keys)
   local is_total = true
   local missing
   if keys.typename == "enum" then
      for _, key in ipairs(sorted_keys(keys.enumset)) do
         is_total, missing = total_check_key(key, seen_keys, is_total, missing)
      end
   elseif keys.typename == "boolean" then
      for _, key in ipairs({ true, false }) do
         is_total, missing = total_check_key(key, seen_keys, is_total, missing)
      end
   else
      is_total = false
   end
   return is_total, missing
end

local function discard_tuple(node, t, b)
   if b.typename == "tuple" then
      node.discarded_tuple = true
   end
   return untuple(t)
end

local function assert_is_a(ctx, w, t1, t2, ectx, name)
   t1 = untuple(t1)
   t2 = untuple(t2)

   if t2.typename == "emptytable" then
      t2 = type_at(w, t2)
   end

   local ok, errs = ctx:is_a(t1, t2)
   if not ok then
      ctx.errs:add_prefixing(w, errs, ctx.errs:get_context(ectx, name))
   end
   return ok
end

local function contextual_function(self, expected)
   if not expected then return nil end
   local resolved = self:resolve_typevars(expected)
   if resolved.typename == "nominal" and resolved.typevals then
      local declaration = resolved.found
      if declaration and declaration.typename == "typedecl" then
         local def = declaration.def


         if def.typename == "generic" and #resolved.typevals ~= #def.typeargs then return nil end
      end
   end
   local structural = self:to_structural(resolved or expected)
   if structural.typename == "function" then return structural end
   if structural.typename == "union" then
      local candidate
      for _, member in ipairs(structural.types) do
         local typ = self:to_structural(member)
         if typ.typename == "function" and not candidate then candidate = typ
         elseif not (typ.typename == "nil") then return nil end
      end
      return candidate
   end
end

local function contextualize_function(self, node, signature)
   node.infer_returns = false
   node.inferred_rets = nil
   local expected = contextual_function(self, signature)
   if not node.has_return_annotation and (node.short_function or expected) then
      local unresolved_returns = false
      if expected then
         types.map(self, expected.rets, {
            ["typevar"] = function(ctx, typ)
               if not ctx:find_var_type(typ.typevar) then unresolved_returns = true end
               return typ, false
            end,
         })
      end


      node.infer_returns = not expected or unresolved_returns
      if expected and not node.infer_returns then node.rets = expected.rets
      else node.rets = a_vararg(node, { a_type(node, "any", {}) }) end
   end
   if expected then
      for i, argument in ipairs(node.args) do
         argument.expected = expected.args.tuple[i] or (expected.args.is_va and expected.args.tuple[#expected.args.tuple])
      end
   end
end

local function callback_literal(node)
   if node.kind == "function" then return true end
   if node.kind == "paren" then return callback_literal(node.e1) end
   if node.kind == "conditional" then return callback_literal(node.e2) or callback_literal(node.e3) end
   return false
end

local function non_nil_type(self, node, t)
   t = untuple(t)
   local structural = self:to_structural(t)
   if structural.typename == "union" then
      local kept = {}
      for _, member in ipairs(structural.types) do
         if not (member.typename == "nil") then table.insert(kept, member) end
      end
      if #kept > 0 then return unite(node, kept, true, false) end
   end
   return t
end

local function count_scope_vars(self)
   local n = 0
   for i = 1, #self.st do
      for _, _ in pairs(self.st[i].vars) do
         n = n + 1
      end
   end
   return n
end

visit_node.cbs = {
   ["statements"] = {
      before = function(self, node)
         self:begin_scope(node)





         if not node.is_repeat then
            for i = #node, 1, -1 do
               if node[i].kind ~= "label" then
                  break
               end
               node[i].is_end_of_block = true
            end
         end
      end,
      after = function(self, node, _children)

         if #self.st == 2 then
            self.errs:fail_unresolved_labels(self.st[2])
            self.errs:fail_unresolved_nominals(self.st[2], self.st[1])
         end

         if not node.is_repeat then
            self:end_scope(node)
         end

         return NONE
      end,
   },
   ["local_type"] = {
      before = function(self, node)
         local name = node.var.tk
         local resolved, aliasing = self:get_typedecl(node.value)
         local var = self:add_var(node.var, name, resolved, node.var.attribute, nil, true)
         if aliasing then
            var.aliasing = aliasing
         end
      end,
      after = function(self, node, _children)
         self:dismiss_unresolved(node.var.tk)
         return NONE
      end,
   },
   ["global_type"] = {
      before = function(self, node)
         local global_scope = self.st[1]
         local name = node.var.tk
         if node.value then
            local resolved, aliasing = self:get_typedecl(node.value)
            local added = self:add_global(node.var, name, resolved)
            if resolved.typename == "invalid" then
               return
            end
            if aliasing then
               added.aliasing = aliasing
            end

            if global_scope.pending_global_types[name] then
               global_scope.pending_global_types[name] = nil
            end
         else
            if not self.st[1].vars[name] then
               global_scope.pending_global_types[name] = true
            end
         end
      end,
      after = function(self, node, _children)
         self:dismiss_unresolved(node.var.tk)
         return NONE
      end,
   },
   ["local_declaration"] = {
      before = function(self, node)
         if self.collector then
            for _, var in ipairs(node.vars) do
               self.collector.reserve_symbol_list_slot(var)
            end
         end
      end,
      before_exp = set_expected_types_to_decltuple,
      after = function(self, node, children)
         local valtuple = children[3]

         local encountered_close = false
         local infertypes = get_assignment_values(node, valtuple, #node.vars)
         for i, var in ipairs(node.vars) do
            if var.attribute == "close" then
               if self.env.opts.gen_target ~= "5.4" and self.env.opts.gen_target ~= "5.5" then
                  self.errs:add(var, "<close> attribute is only valid for Lua 5.4+ (current target is " .. tostring(self.env.opts.gen_target) .. ")")
               end
               if encountered_close then
                  self.errs:add(var, "only one <close> per declaration is allowed")
               else
                  encountered_close = true
               end
            end

            local ok, t = self:determine_declaration_type(var, node, infertypes, i)

            if var.attribute == "close" then
               if not type_is_closable(t) then
                  self.errs:add(var, "to-be-closed variable " .. var.tk .. " has a non-closable type %s", t)
               elseif node.exps and node.exps[i] and expr_is_definitely_not_closable(node.exps[i]) then
                  self.errs:add(var, "to-be-closed variable " .. var.tk .. " assigned a non-closable value")
               end
            end

            assert(var)
            if self.strict_pragma and self:contains_dynamic(t) then
               t = self.errs:invalid_at(var, "strict mode: a declaration cannot have type 'any' or 'unknown'")
            end
            if self.native_ffi then var.native_type = t end
            local keep_literal = node.decltuple and node.decltuple.tuple[i] ~= nil
            if not keep_literal and node.exps and node.exps[i] then
               local exp = node.exps[i]
               if not (exp.kind == "string" or
                  exp.kind == "number" or
                  exp.kind == "integer" or
                  exp.kind == "boolean" or
                  exp.kind == "nil" or
                  exp.kind == "literal_table") then

                  keep_literal = true
               end
            end
            self:add_var(var, var.tk, t, var.attribute, is_localizing_a_variable(node, i) and "localizing", keep_literal)
            if var.elide_type then
               self.errs:add_warning("hint", node, "hint: consider using 'local type' instead")
            end

            local infertype = infertypes.tuple[i]
            if ok and infertype then
               local w = node.exps[i] or node.exps

               local rt = self:to_structural(t)

               local native_number = self.native_ffi and rt.typename == "number" and self:to_structural(infertype).typename == "integer"
               if not native_number and (not (rt.typename == "enum")) and
                  ((not (t.typename == "nominal")) or (rt.typename == "union")) and
                  not self:same_type(t, infertype) then

                  t = self:infer_at(w, infertype)
                  self:add_var(w, var.tk, t, "const", "narrowed_declaration")
               end
            end

            if self.collector then
               self.collector.store_type(var.y, var.x, t)
            end

            self:dismiss_unresolved(var.tk)
         end
         return NONE
      end,
   },
   ["global_declaration"] = {
      before_exp = set_expected_types_to_decltuple,
      after = function(self, node, children)
         local valtuple = children[3]

         local infertypes = get_assignment_values(node, valtuple, #node.vars)
         for i, var in ipairs(node.vars) do
            local _, t, is_inferred = self:determine_declaration_type(var, node, infertypes, i)

            if var.attribute == "close" then
               self.errs:add(var, "globals may not be <close>")
            end

            self:add_global(var, var.tk, t, is_inferred)
            if var.elide_type then
               self.errs:add_warning("hint", node, "hint: consider using 'global type' instead")
            end

            self:dismiss_unresolved(var.tk)
         end
         return NONE
      end,
   },
   ["assignment"] = {
      before_exp = set_expected_types_to_decltuple,
      after = function(self, node, children)
         local vartuple = children[1]
         assert(vartuple.typename == "tuple")
         local vartypes = vartuple.tuple
         local valtuple = children[3]
         assert(valtuple.typename == "tuple")
         local valtypes = get_assignment_values(node, valtuple, #vartypes)
         for i, vartype in ipairs(vartypes) do
            local varnode = node.vars[i]
            local varname = varnode.tk
            local valtype = valtypes.tuple[i]
            local rvar, rval, err = self:check_assignment(varnode, vartype, valtype)
            if err == "missing" then
               if #node.exps == 1 and node_is_funcall(node.exps[1]) then
                  local msg = #valtuple.tuple == 1 and
                  "only 1 value is returned by the function" or
                  ("only " .. #valtuple.tuple .. " values are returned by the function")
                  self.errs:add_warning("hint", varnode, msg)
               end
            end

            if rval and rvar then

               if rval.typename == "function" then
                  self:widen_all_unions()
               end

               if varname and (rvar.typename == "union" or rvar.typename == "interface") then

                  self:add_var(varnode, varname, valtype, nil, "narrow")
               end

               if self.collector then
                  self.collector.store_type(varnode.y, varnode.x, valtype)
               end
            end
         end

         return NONE
      end,
   },
   ["if"] = {
      after = function(self, node, _children)
         if node.if_widens then


            self:widen_all(node.if_widens, {})
         end

         local all_return = true
         for _, b in ipairs(node.if_blocks) do
            if not b.block_returns then
               all_return = false
               break
            end
         end
         if all_return then
            node.block_returns = true
            self:infer_negation_of_if_blocks(node, node, #node.if_blocks)
         end

         return NONE
      end,
   },
   ["if_block"] = {
      before = function(self, node)
         self:begin_scope(node)
         if node.if_block_n > 1 then
            self:infer_negation_of_if_blocks(node, node.if_parent, node.if_block_n - 1)
         end
         if node.exp then
            node.exp.expected = a_type(node, "boolean_context", {})
         end
      end,
      before_statements = function(self, node)
         if node.exp then
            self:apply_facts_from(node.exp)
         end
      end,
      after = function(self, node, _children)
         node.if_parent.if_widens = self:collect_if_widens(node.if_parent.if_widens)

         self:end_scope(node)

         if #node.body > 0 and node.body[#node.body].block_returns then
            node.block_returns = true
         end

         return NONE
      end,
   },
   ["while"] = {
      before = function(self, node)

         self:widen_all_unions(node)
         node.exp.expected = a_type(node, "boolean_context", {})
      end,
      before_statements = function(self, node)
         self:begin_scope(node)
         self:apply_facts_from(node.exp)
      end,
      after = end_scope_and_none_type,
   },
   ["label"] = {
      before = function(self, node)

         self:widen_all_unions()
         local label_id = node.label
         do
            local scope = self.st[#self.st]
            scope.labels = scope.labels or {}
            if scope.labels[label_id] then
               self.errs:add(node, "label '" .. node.label .. "' already defined")
            else
               scope.labels[label_id] = node
            end
         end

         local scope = self.st[#self.st]
         if scope.pending_labels and scope.pending_labels[label_id] then
            if not node.is_end_of_block then
               local n_scope_vars = count_scope_vars(self)
               for _, goto_node in ipairs(scope.pending_labels[label_id]) do
                  if n_scope_vars > goto_node.n_scope_vars then
                     self.errs:add(goto_node, "goto jumps into scope of a local variable")
                  end
               end
            end
            node.used_label = true
            scope.pending_labels[label_id] = nil
         end
      end,
      after = function()
         return NONE
      end,
   },
   ["goto"] = {
      after = function(self, node, _children)
         local label_id = node.label
         local found_label
         for i = #self.st, 1, -1 do
            local scope = self.st[i]
            if scope.labels and scope.labels[label_id] then
               found_label = scope.labels[label_id]
               break
            end
         end

         if found_label then
            found_label.used_label = true
         else
            local scope = self.st[#self.st]
            scope.pending_labels = scope.pending_labels or {}
            scope.pending_labels[label_id] = scope.pending_labels[label_id] or {}
            table.insert(scope.pending_labels[label_id], node)
            node.n_scope_vars = count_scope_vars(self)
         end

         return NONE
      end,
   },
   ["repeat"] = {
      before = function(self, node)

         self:widen_all_unions(node)
         node.exp.expected = a_type(node, "boolean_context", {})
      end,

      after = end_scope_and_none_type,
   },
   ["forin"] = {
      before = function(self, node)
         self:begin_scope(node)
      end,
      before_statements = function(self, node, children)
         local exptuple = children[2]
         assert(exptuple.typename == "tuple")
         local exptypes = exptuple.tuple

         local exp1 = node.exps[1]
         if #exptypes < 1 then
            self.errs:invalid_at(exp1, "expression in 'for' statement does not return any values")
            return
         end

         self:widen_all_unions(node)

         local args = a_type(node.exps, "tuple", { tuple = {
            node.exps[2] and exptypes[2],
            node.exps[3] and exptypes[3],
         } })
         local exp1type = self:resolve_for_call(exptypes[1], args, false)

         if exp1type.typename == "poly" then
            local _r, f
            _r, f = self:type_check_function_call(exp1, exp1type, args, 0, nil, nil, exp1, { node.exps[2], node.exps[3] })
            if f then
               exp1type = f
            else
               self.errs:add(exp1, "cannot resolve polymorphic function given arguments")
            end
         end

         if exp1type.typename == "function" then

            local last
            local rets = exp1type.rets
            for i, v in ipairs(node.vars) do
               local r = rets.tuple[i]
               if not r then
                  if rets.is_va then
                     r = last
                  else
                     r = self.feat_lax and a_type(v, "unknown", {}) or a_type(v, "invalid", {})
                  end
               end
               self:add_var(v, v.tk, r)

               if self.collector then
                  self.collector.store_type(v.y, v.x, r)
               end

               last = r
            end
            local nrets = #rets.tuple
            if (not self.feat_lax) and (not rets.is_va and #node.vars > nrets) then
               local at = node.vars[nrets + 1]
               local n_values = nrets == 1 and "1 value" or tostring(nrets) .. " values"
               self.errs:add(at, "too many variables for this iterator; it produces " .. n_values)
            end
         else
            if not (self.feat_lax and is_unknown(exp1type)) then
               self.errs:add(exp1, "expression in for loop does not return an iterator")
            end
         end
      end,
      after = function(self, node, _children)
         local control_var = node.vars[1]
         local var = self:find_var(control_var.tk)
         if var and var.has_been_written_to then
            node.forin_modifies_control_var = true
         end
         self:end_scope(node)
         return NONE
      end,
   },
   ["fornum"] = {
      before_statements = function(self, node, children)
         self:widen_all_unions(node)
         self:begin_scope(node)
         local from_t = self:to_structural(untuple(children[2]))
         local to_t = self:to_structural(untuple(children[3]))
         local step_t = children[4] and self:to_structural(untuple(children[4]))
         if self.feat_strict_nil then
            local numeric = a_type(node, "number", {})
            if not self:is_a(from_t, numeric) then
               self:add_error(node, "numeric for initial value must be a non-nil number")
            end
            if not self:is_a(to_t, numeric) then
               self:add_error(node, "numeric for limit must be a non-nil number")
            end
            if step_t and not self:is_a(step_t, numeric) then
               self:add_error(node, "numeric for step must be a non-nil number")
            end
         else
            from_t = self:to_structural(non_nil_type(self, node, from_t))
            to_t = self:to_structural(non_nil_type(self, node, to_t))
            if step_t then step_t = self:to_structural(non_nil_type(self, node, step_t)) end
         end
         local typename = (from_t.typename == "integer" and
         to_t.typename == "integer" and
         (not step_t or step_t.typename == "integer")) and
         "integer" or
         "number"
         local t = a_type(node.var, typename, {})
         if self.native_ffi then node.var.native_type = t end
         self:add_var(node.var, node.var.tk, t)
      end,
      after = function(self, node, _children)
         local var = self:find_var(node.var.tk)
         if var and var.has_been_written_to then
            node.fornum_modifies_control_var = true
         end
         self:end_scope(node)
         return NONE
      end,
   },
   ["return"] = {
      before = function(self, node)
         local rets = self:find_var_type("@return")
         if rets and rets.typename == "tuple" then
            for i, exp in ipairs(node.exps) do
               exp.expected = rets.tuple[i]
            end
         end
      end,
      after = function(self, node, children)
         local got = children[1]
         assert(got.typename == "tuple")
         local got_t = got.tuple
         local n_got = #got_t

         node.block_returns = true
         local return_var = self:find_var("@return", "check_only")
         local short = return_var and return_var.declared_at
         if short and short.infer_returns then
            local previous = short.inferred_rets
            if not previous then
               short.inferred_rets = drop_constant_values(got, false)
            else
               local merged = a_type(node, "tuple", { tuple = {} })
               local n = math.max(#previous.tuple, #got_t)
               for i = 1, n do
                  local a = previous.tuple[i] or (previous.is_va and previous.tuple[#previous.tuple]) or a_type(node, "nil", {})
                  local b = got_t[i] or (got.is_va and got_t[n_got]) or a_type(node, "nil", {})
                  merged.tuple[i] = unite(node, { a, b }, true, not self.feat_strict_nil)
               end
               merged.is_va = previous.is_va or got.is_va
               short.inferred_rets = merged
            end
            return NONE
         end
         local expected = self:find_var_type("@return")
         if not expected then

            local module_type = untuple(got)
            if module_type.typename == "nominal" then
               self:resolve_nominal(module_type)
               self.module_type = module_type.resolved
            else
               self.module_type = drop_constant_values(module_type, true)
            end

            expected = self:infer_at(node, got)
            local dropped = drop_constant_values(expected, false)
            if dropped.typename == "tuple" then
               expected = dropped
            end
            self.st[2].vars["@return"] = { t = expected }
         end
         local expected_t = expected.tuple

         local what = "in return value"
         if expected.inferred_at then
            what = what .. types.inferred_msg(expected)
         end

         local n_expected = #expected_t
         local vatype
         if n_expected > 0 then
            vatype = expected.is_va and expected.tuple[n_expected]
         end

         if n_got > n_expected and (not self.feat_lax) and not vatype then
            self.errs:add(node, what .. ": excess return values, expected " .. n_expected .. " %s, got " .. n_got .. " %s", expected, got)
         end

         if n_expected > 1 and
            #node.exps == 1 and
            node.exps[1].kind == "op" and
            (node.exps[1].op.op == "and" or node.exps[1].op.op == "or") and
            node.exps[1].discarded_tuple then
            self.errs:add_warning("hint", node.exps[1].e2, "additional return values are being discarded due to '" .. node.exps[1].op.op .. "' expression; suggest parentheses if intentional")
         end

         for i = 1, n_got do
            local e = expected_t[i] or vatype
            if e then
               e = untuple(e)
               local w = (node.exps[i] and node.exps[i].x) and
               node.exps[i] or
               node.exps
               assert(w and w.x)
               assert_is_a(self, w, got_t[i], e, what)
            end
         end

         return NONE
      end,
   },
   ["variable_list"] = {
      after = function(self, node, children)
         local tuple = flat_tuple(node, children)

         for i, t in ipairs(tuple.tuple) do
            local ok, err = ensure_not_abstract(t, node[i])
            if not ok then
               self.errs:add(node[i], err)
            end
         end

         return tuple
      end,
   },
   ["literal_table"] = {
      before = function(self, node)
         if node.expected then
            local decltype = self:to_structural(node.expected)

            if decltype.typename == "typevar" and decltype.constraint then
               decltype = resolve_typedecl(self:to_structural(decltype.constraint))
            end

            if decltype.typename == "generic" then
               decltype = self:apply_generic(node, decltype)
            end

            if decltype.typename == "tupletable" then
               for _, child in ipairs(node) do
                  local n = child.key.constnum
                  if n and is_positive_int(n) then
                     child.value.expected = decltype.types[n]
                  end
               end
            elseif decltype.elements then
               for _, child in ipairs(node) do
                  if child.key.constnum then
                     child.value.expected = decltype.elements
                  end
               end
            elseif decltype.typename == "map" then
               for _, child in ipairs(node) do
                  child.key.expected = decltype.keys
                  child.value.expected = decltype.values
               end
            end

            if decltype.fields then
               for _, child in ipairs(node) do
                  if child.key.conststr then
                     child.value.expected = decltype.fields[child.key.conststr]
                  end
               end
            end
         end
      end,
      after = function(self, node, children)
         self.fdb:set_truthy(node)

         if not node.expected then
            return infer_table_literal(self, node, children)
         end

         local decltype = self:to_structural(node.expected)

         local constraint
         if decltype.typename == "typevar" and decltype.constraint then
            constraint = resolve_typedecl(decltype.constraint)
            decltype = self:to_structural(constraint)
         end

         if decltype.typename == "generic" then
            decltype = self:apply_generic(node, decltype)
         end

         if decltype.typename == "union" then
            local single_table_type
            local single_table_rt

            for _, t in ipairs(decltype.types) do
               local rt = self:to_structural(t)
               if is_lua_table_type(rt) then
                  if single_table_type then

                     single_table_type = nil
                     single_table_rt = nil
                     break
                  end

                  single_table_type = t
                  single_table_rt = rt
               end
            end

            if single_table_type then
               node.expected = single_table_type
               decltype = single_table_rt
            end
         end

         if not is_lua_table_type(decltype) then
            return infer_table_literal(self, node, children)
         end

         if decltype.fields then
            self:begin_implied_scope()
            self:add_self_type(node, decltype)
            decltype = self:resolve_self(decltype, true)
            self:end_implied_scope()
         end

         local force_array = nil

         local seen_keys = {}

         for i, child in ipairs(children) do
            local cvtype = untuple(child.vtype)
            local ck = child.kname
            local cktype = child.ktype
            local n = node[i].key.constnum
            local b = nil
            if cktype.typename == "boolean" then
               b = (node[i].key.tk == "true")
            end
            self.errs:check_redeclared_key(node[i], node, seen_keys, ck or n or b)
            if decltype.fields and ck then
               local df = decltype.fields[ck]
               if not df then
                  self.errs:add_in_context(node[i], node, "unknown field " .. ck)
               else
                  if df.typename == "typedecl" then
                     self.errs:add_in_context(node[i], node, "cannot reassign a type")
                  else
                     assert_is_a(self, node[i], cvtype, df, "in record field", ck)
                  end
               end
            elseif decltype.types and is_numeric_type(cktype) then
               local dt = decltype.types[n]
               if not n then
                  self.errs:add_in_context(node[i], node, "unknown index in tuple %s", decltype)
               elseif not dt then
                  self.errs:add_in_context(node[i], node, "unexpected index " .. n .. " in tuple %s", decltype)
               else
                  assert_is_a(self, node[i], cvtype, dt, node, "in tuple: at index " .. tostring(n))
               end
            elseif decltype.elements and is_numeric_type(cktype) then
               local cv = child.vtype
               if cv.typename == "tuple" and i == #children and node[i].key_parsed == "implicit" then

                  for ti, tt in ipairs(cv.tuple) do
                     assert_is_a(self, node[i], tt, decltype.elements, node, "expected an array: at index " .. tostring(i + ti - 1))
                  end
               else
                  assert_is_a(self, node[i], cvtype, decltype.elements, node, "expected an array: at index " .. tostring(n))
               end
            elseif node[i].key_parsed == "implicit" then
               if decltype.typename == "map" then
                  assert_is_a(self, node[i].key, a_type(node[i].key, "integer", {}), decltype.keys, node, "in map key")
                  assert_is_a(self, node[i].value, cvtype, decltype.values, node, "in map value")
               end
               force_array = self:expand_type(node[i], force_array, child.vtype)
            elseif decltype.typename == "map" then
               force_array = nil
               assert_is_a(self, node[i].key, cktype, decltype.keys, node, "in map key")
               assert_is_a(self, node[i].value, cvtype, decltype.values, node, "in map value")
            else
               self.errs:add_in_context(node[i], node, "unexpected key of type %s in table of type %s", cktype, decltype)
            end
         end

         if self.feat_strict_nil and decltype.typename == "record" then
            local missing = required_record_check(self, decltype, seen_keys)
            if missing then
               self.errs:add(node, "record literal is missing required fields (missing: " .. table.concat(missing, ", ") .. ")")
            end
         end

         local t = force_array and a_type(node, "array", { elements = force_array }) or node.expected
         t = self:infer_at(node, t)

         if decltype.typename == "record" then
            local rt = self:to_structural(t)
            if rt.typename == "record" then
               node.is_total, node.missing = total_record_check(decltype, seen_keys)
            end
         elseif decltype.typename == "map" then
            local rt = self:to_structural(t)
            if rt.typename == "map" then
               local rk = self:to_structural(rt.keys)
               node.is_total, node.missing = total_map_check(rk, seen_keys)
            end
         end

         if constraint then
            return constraint
         end

         return t
      end,
   },
   ["literal_table_item"] = {
      after = function(self, node, children)
         local kname = node.key.conststr
         local ktype = children[1]
         local vtype = children[2]
         if node.itemtype then
            vtype = node.itemtype
            assert_is_a(self, node.value, children[2], node.itemtype, node)
         end



         vtype = ensure_not_method(vtype)
         return a_type(node, "literal_table_item", {
            kname = kname,
            ktype = ktype,
            vtype = vtype,
         })
      end,
   },
   ["local_function"] = {
      before = function(self, node)
         if node.lj_const then
            for _, argument in ipairs(node.args) do
               if argument.tk == node.name.tk then
                  self.errs:add(argument, "cannot re-declare const variable '" .. node.name.tk .. "'")
               end
            end
         end
         self:widen_all_unions()
         if self.collector then
            self.collector.reserve_symbol_list_slot(node)
         end
         self:begin_scope(node)
      end,
      before_statements = function(self, node, children)
         local args = children[2]
         assert(args.typename == "tuple")

         self:add_internal_function_variables(node, args, function_has_explicit_types(node.args, node.rets))
         self:add_function_definition_for_recursion(node, args, self.feat_arity, function_has_explicit_types(node.args, node.rets))
      end,
      after = function(self, node, children)
         local args = children[2]
         assert(args.typename == "tuple")
         local rets = children[3]
         assert(rets.typename == "tuple")

         self:end_function_scope(node)

         local t = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.min_arity or 0,
            args = args,
            rets = self.get_rets(rets),
         }))

         self:add_var(node, node.name.tk, t, node.lj_const and "const" or nil, nil, function_has_explicit_types(node.args, node.rets))
         return t
      end,
   },
   ["local_macroexp"] = {
      before = function(self, node)
         self:widen_all_unions()
         if self.collector then
            self.collector.reserve_symbol_list_slot(node)
         end
         self:begin_scope(node)
      end,
      after = function(self, node, children)
         local args = children[2]
         assert(args.typename == "tuple")
         local rets = children[3]
         assert(rets.typename == "tuple")

         self:end_function_scope(node)

         macroexps.check_arg_use(self, node.macrodef)

         local t = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.macrodef.min_arity or 0,
            args = args,
            rets = self.get_rets(rets),
            macroexp = node.macrodef,
         }))

         self:add_var(node, node.name.tk, t, nil, nil, function_has_explicit_types(node.macrodef.args, node.macrodef.rets))
         return t
      end,
   },
   ["global_function"] = {
      before = function(self, node)
         self:widen_all_unions()
         self:begin_scope(node)
         if node.implicit_global_function then
            local typ, attribute = self:find_var_type(node.name.tk)
            if attribute == "const" then self.errs:add(node, "cannot assign to <const> variable") end
            if typ then
               if typ.typename == "function" then
                  node.is_predeclared_local_function = true
                  contextualize_function(self, node, typ)
               elseif not self.feat_lax then
                  self.errs:add(node, "cannot declare function: type of " .. node.name.tk .. " is %s", typ)
               end
            elseif not self.feat_lax then
               self.errs:add(node, "functions need an explicit 'local' or 'global' annotation")
            end
         end
      end,
      before_statements = function(self, node, children)
         local args = children[2]
         assert(args.typename == "tuple")

         self:add_internal_function_variables(node, args, function_has_explicit_types(node.args, node.rets))
         self:add_function_definition_for_recursion(node, args, self.feat_arity, function_has_explicit_types(node.args, node.rets))
      end,
      after = function(self, node, children)
         local args = children[2]
         assert(args.typename == "tuple")
         local rets = children[3]
         assert(rets.typename == "tuple")

         self:end_function_scope(node)
         if node.is_predeclared_local_function or (node.implicit_global_function and not self.feat_lax) then
            return NONE
         end

         self:add_global(node, node.name.tk, wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.min_arity or 0,
            args = args,
            rets = self.get_rets(rets),
         })))

         return NONE
      end,
   },
   ["record_function"] = {
      before = function(self, node)
         self:widen_all_unions()
         self:begin_scope(node)
      end,
      before_arguments = function(self, node, children)
         local rtype = self:to_structural(resolve_typedecl(children[1]))


         if rtype.typename == "generic" then
            for _, typ in ipairs(rtype.typeargs) do
               self:add_var(nil, typ.typearg, a_type(typ, "typearg", {
                  typearg = typ.typearg,
                  constraint = typ.constraint,
               }))
            end
            rtype = rtype.t
         end
         if rtype.fields then contextualize_function(self, node, rtype.fields[node.name.tk]) end
      end,
      before_statements = function(self, node, children)
         local args = children[3]
         assert(args.typename == "tuple")
         local rets = children[4]
         assert(rets.typename == "tuple")

         local t = children[1]
         local rtype = self:to_structural(resolve_typedecl(t))


         self:add_internal_function_variables(node, args, function_has_explicit_types(node.args, node.rets))

         if rtype.typename == "generic" then
            rtype = rtype.t
         end

         do
            local ok, err = ensure_not_abstract(t)
            if not ok then
               self.errs:add(node, err)
            end
         end

         if self.feat_lax and rtype.typename == "unknown" then
            return
         end

         if rtype.typename == "emptytable" then
            edit_type(rtype, rtype, "record")
            local r = rtype
            r.fields = {}
            r.field_order = {}
         end

         if not rtype.fields then
            local _, _, owner_name = self:find_record_to_extend(node.fn_owner)
            local short_type = show_type(rtype, true)
            local msg = ("record function syntax cannot be used with this type: %s is %s"):format(owner_name, short_type)
            self.errs:add(node, msg, rtype)
            if rtype.typename == "map" then
               self.errs:add_warning("hint", node, "use the assignment syntax to store functions in maps", rtype)
            end
            return
         end

         local selftype = self:get_self_type(node.fn_owner)
         if node.is_method then
            if not selftype then
               self.errs:add(node, "could not resolve type of self")
               return
            end
            args.tuple[1] = a_type(node, "self", { display_type = selftype })
            self:add_var(nil, "self", selftype)
            self:add_self_type(node, selftype)
            if self.collector then
               self.collector.add_to_symbol_list(node.fn_owner, "self", selftype)
            end
         end

         local fn_type = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.min_arity or 0,
            is_method = node.is_method,
            args = args,
            rets = self.get_rets(rets),
            is_record_function = true,
         }))

         local open_t, open_v, owner_name = self:find_record_to_extend(node.fn_owner)
         local open_k = owner_name .. "." .. node.name.tk
         local rfieldtype = rtype.fields[node.name.tk]
         if rfieldtype then
            rfieldtype = self:to_structural(rfieldtype)

            if open_v and open_v.implemented and open_v.implemented[open_k] then
               self.errs:redeclaration_warning(node, node.name.tk, "function")
            end

            if fn_type.typename == "generic" and not (rfieldtype.typename == "generic") then
               self:begin_implied_scope()
               fn_type = self:apply_generic(node, fn_type)
               self:end_implied_scope()
            end

            local ok, err = self:same_type(fn_type, rfieldtype)
            if not ok then
               if rfieldtype.typename == "poly" then
                  self.errs:add_prefixing(node, err, "type signature does not match declaration: field has multiple function definitions (such polymorphic declarations are intended for Lua module interoperability): ")
                  return
               end

               local shortname = selftype and show_type(selftype) or owner_name
               local msg = "type signature of '" .. node.name.tk .. "' does not match its declaration in " .. shortname .. ": "
               self.errs:add_prefixing(node, err, msg)
               return
            end
         else
            if open_t and open_t.typename == "generic" then
               open_t = open_t.t
            end
            if self.feat_lax or rtype == open_t then





               rtype.fields[node.name.tk] = fn_type
               table.insert(rtype.field_order, node.name.tk)

               if self.collector then
                  self.env.reporter:add_field(rtype, node.name.tk, fn_type)
               end
            else
               self.errs:add(node, "cannot add undeclared function '" .. node.name.tk .. "' outside of the scope where '" .. owner_name .. "' was originally declared")
               return
            end

         end

         if open_v then
            if not open_v.implemented then
               open_v.implemented = {}
            end
            open_v.implemented[open_k] = true
         end

      end,
      after = function(self, node, _children)
         self:end_function_scope(node)
         return NONE
      end,
   },
   ["function"] = {
      before = function(self, node)
         self:widen_all_unions(node)
         self:begin_scope(node)

         contextualize_function(self, node, node.expected)
      end,
      before_statements = function(self, node, children)
         local args = children[1]
         assert(args.typename == "tuple")

         self:add_internal_function_variables(node, args, function_has_explicit_types(node.args, node.rets))
      end,
      after = function(self, node, children)
         local args = children[1]
         assert(args.typename == "tuple")
         local rets = children[2]
         assert(rets.typename == "tuple")
         if node.infer_returns then
            rets = node.inferred_rets or a_type(node, "tuple", { tuple = {} })
            if not context.block_returns(node.body) then
               local nullable = a_type(node, "tuple", { tuple = {} })
               for i, member in ipairs(rets.tuple) do
                  nullable.tuple[i] = unite(node, { member, a_type(node, "nil", {}) }, true, not self.feat_strict_nil)
               end
               nullable.is_va = rets.is_va
               rets = nullable
            end
         end

         self:end_function_scope(node)

         return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.min_arity or 0,
            args = args,
            rets = self.get_rets(rets),
         }))
      end,
   },
   ["macroexp"] = {
      before = function(self, node)
         self:widen_all_unions(node)
         self:begin_scope(node)
      end,
      before_exp = function(self, node, children)
         local args = children[1]
         assert(args.typename == "tuple")

         self:add_internal_function_variables(node, args, function_has_explicit_types(node.args, node.rets))
      end,
      after = function(self, node, children)
         local args = children[1]
         assert(args.typename == "tuple")
         local rets = children[2]
         assert(rets.typename == "tuple")

         self:end_function_scope(node)
         return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
            min_arity = self.feat_arity and node.min_arity or 0,
            args = args,
            rets = rets,
         }))
      end,
   },
   ["cast"] = {
      after = function(_self, node, _children)
         return node.casttype
      end,
   },
   ["paren"] = {
      before = function(_self, node)
         node.e1.expected = node.expected
         node.e1.strict_receiver = node.strict_receiver
      end,
      after = function(self, node, children)
         self.fdb:set_from(node, node.e1)
         return untuple(children[1])
      end,
   },
   ["conditional"] = {
      before = function(_self, node)
         node.e1.expected = a_type(node, "boolean_context", {})
         node.e2.expected = node.expected
         node.e3.expected = node.expected
      end,
      before_e2 = function(self, node)
         self:begin_implied_scope()
         self:apply_facts_from(node, node.e1)
      end,
      before_e3 = function(self, node)
         self:end_implied_scope()
         self:begin_implied_scope()
         self:apply_facts(node, facts_not(node, self.fdb:get(node.e1)))
      end,
      after = function(self, node, children)
         self:end_implied_scope()
         return unite(node, { untuple(children[2]), untuple(children[3]) }, true, not self.feat_strict_nil)
      end,
   },
   ["op"] = {
      before = function(self, node)
         self:begin_implied_scope()
         if self.strict_pragma then
            local op = node.op.op
            node.e1.strict_receiver = op == "." or op == ":" or op == "@index" or op == "@funcall"
         end
         if node.expected then
            if node.op.op == "and" then
               node.e2.expected = node.expected
            elseif node.op.op == "or" or node.op.op == "??" then
               node.e1.expected = node.expected
               if not (node.e2.kind == "literal_table" and #node.e2 == 0) then
                  node.e2.expected = node.expected
               end
            end
         end
         if node.op.op == "not" then
            node.e1.expected = a_type(node, "boolean_context", {})
         end
      end,
      before_e2 = function(self, node, children)
         local e1type = children[1]
         if node.optional_chain then
            if node.e1.optional_chain and node.e1.chain_value_type then
               e1type = node.e1.chain_value_type
            end
            if node.safe_navigation then e1type = non_nil_type(self, node, e1type) end
            children[1] = e1type
         end

         if self.collector and (node.op.op == "." or node.op.op == ":") then
            self.collector.store_member_receiver(node.y, node.x, e1type)
         end

         if node.op.op == "and" then
            self:apply_facts_from(node, node.e1)
         elseif node.op.op == "or" then
            self:apply_facts(node, facts_not(node, self.fdb:get(node.e1)))


            if node.e1.kind == "op" and node.e1.op.op == "and" and
               node.e1.e1.kind == "op" and node.e1.e1.op.op == "is" and
               node.e1.e2.kind == "variable" and
               node.e1.e2.tk == node.e1.e1.e1.tk and
               node.e1.e1.e2.casttype.typename ~= "boolean" and
               node.e1.e1.e2.casttype.typename ~= "nil" then

               self:apply_facts(node, facts_not(node, IsFact({ var = node.e1.e1.e1.tk, typ = node.e1.e1.e2.casttype, w = node })))
            end

         elseif node.op.op == "@funcall" then
            if e1type.typename == "generic" then
               e1type = self:apply_generic(node, e1type)
            end
            if e1type.typename == "function" then
               local argdelta = (node.e1.op and node.e1.op.op == ":") and -1 or 0
               if node.expected then

                  self:is_a(e1type.rets, node.expected)
               end
               local e1args = e1type.args.tuple
               local has_callback = false
               for _, argument in ipairs(node.e2) do
                  if callback_literal(argument) then has_callback = true end
               end
               if has_callback then
                  local expected_args = a_type(node.e2, "tuple", { tuple = {} })
                  expected_args.is_va = e1type.args.is_va
                  for i, typ in ipairs(e1args) do
                     if i + argdelta > 0 then expected_args.tuple[i + argdelta] = typ end
                  end
                  node.e2.expected = expected_args
               end
               local at = argdelta
               for _, typ in ipairs(e1args) do
                  at = at + 1
                  if node.e2[at] then
                     node.e2[at].expected = self:infer_at(node.e2[at], typ)
                  end
               end
               if e1type.args.is_va then
                  local typ = e1args[#e1args]
                  for i = at + 1, #node.e2 do
                     node.e2[i].expected = self:infer_at(node.e2[i], typ)
                  end
               end
            end
         elseif node.op.op == "@index" then
            if e1type.typename == "map" then
               node.e2.expected = e1type.keys
            end
         end
      end,
      after = function(self, node, children)
         self:end_implied_scope()


         local ga = children[1]
         local gb = children[3]


         local ua = untuple(ga)
         local ub


         local ra = self:to_structural(ua)
         local rb

         if ra.typename == "circular_require" or (ra.typename == "typedecl" and ra.def and ra.def.typename == "circular_require") then
            return self.errs:invalid_at(node, "cannot dereference a type from a circular require")
         end

         if node.compound_value and node.e1.chain_always_nil then return a_type(node, "any", {}) end
         if node.op.op == "??" then
            if ra.typename == "nil" then return untuple(gb) end
            return unite(node, { non_nil_type(self, node, ua), untuple(gb) }, true, not self.feat_strict_nil)
         end

         if node.optional_chain and (node.e1.chain_always_nil or (node.safe_navigation and ra.typename == "nil")) then
            node.chain_always_nil = true
            return node.is_lvalue and a_type(node, "any", {}) or a_type(node, "nil", {})
         end

         if node.op.op == "@funcall" then
            if self.native_ffi and ra.typeid == self.native_ffi.cdef.typeid then
               if not node.native_top_level then
                  return self.errs:invalid_at(node, "ffi.cdef must be a standalone top-level statement")
               end
               if #node.e2 ~= 1 or node.e2[1].kind ~= "string" then
                  return self.errs:invalid_at(node, "ffi.cdef expects one string literal")
               end
               local current = self:find_var("C", "check_only")
               if current and current.t.typeid ~= self.native_ffi.namespace.typeid then
                  return self.errs:invalid_at(node, "ffi.cdef cannot declare C because that name is already in use")
               end
               local source, literal_error = c_ffi.decode_string(node.e2[1].tk)
               if not source then
                  return self.errs:invalid_at(node.e2[1], literal_error)
               end
               local ok, err = c_ffi.declare(self.native_ffi, node, source)
               if not ok then
                  return self.errs:invalid_at(node, "ffi.cdef: " .. err:gsub("%%", "%%%%"))
               end
               if not current then self:add_var(nil, "C", self.native_ffi.namespace, "const") end
               node.native_cdef = true
               return a_type(node, "tuple", { tuple = {} })
            end
            if not self.feat_strict_nil then ua = non_nil_type(self, node, ua) end
            if self.feat_lax and is_unknown(ua) then
               if node.e1.op and node.e1.op.op == ":" and node.e1.e1.kind == "variable" then
                  self.errs:add_unknown_dot(node, node.e1.e1.tk .. "." .. node.e1.e2.tk)
               end
            end
            assert(gb.typename == "tuple")
            local t = self:type_check_funcall(node, ua, gb)
            return t

         elseif node.op.op == "as" then
            local ok, err = ensure_not_abstract(ra)
            if not ok then
               return self.errs:invalid_at(node.e1, err)
            end
            if self.strict_pragma then
               local source = gb.typename == "tuple" and ga or ua
               if self:contains_dynamic(source) or self:contains_dynamic(gb) or not self:is_a(source, gb) then
                  return self.errs:invalid_at(node, "strict mode: 'as' requires a widening conversion, got %s as %s", source, gb)
               end
            end
            return gb

         elseif node.op.op == "is" and ra.typename == "typedecl" then
            return self.errs:invalid_at(node, "can only use 'is' on variables, not types")
         end

         local ok, err = ensure_not_abstract(ra)
         if not ok then
            return self.errs:invalid_at(node.e1, err)
         end
         if ra.typename == "typedecl" and ra.def.typename == "record" then
            ra = ra.def
         end



         if gb then
            ub = untuple(gb)
            rb = self:to_structural(ub)
            ok, err = ensure_not_abstract(rb)
            if not ok then
               return self.errs:invalid_at(node.e2, err)
            end
            if rb.typename == "typedecl" and rb.def.typename == "record" then
               rb = rb.def
            end
         end

         if node.op.op == "." then
            node.receiver = ua

            assert(node.e2.kind == "identifier")
            local bnode = node_at(node.e2, {
               tk = node.e2.tk,
               kind = "string",
            })
            local btype = a_type(node.e2, "string", { literal = node.e2.tk })
            local t = self:type_check_index(node.e1, bnode, ua, btype)
            if t.needs_compat then
               node.op.needs_compat = true
            end

            return t
         end

         if node.op.op == "@index" then
            return self:type_check_index(node.e1, node.e2, ua, ub)
         end

         if node.op.op == "is" then
            if ra.typename == "typedecl" then
               self.errs:add(node, "can only use 'is' on variables, not types")
            elseif node.e1.kind == "variable" then
               if rb.typename == "union" then
                  convert_is_of_union_to_or_of_is(self, node, ra, rb)
               else
                  self:check_metamethod(node, "__is", ra, resolve_typedecl(rb), ua, ub)
                  self.fdb:set_is(node, node.e1.tk, ub)
               end
            else
               self.errs:add(node, "can only use 'is' on variables")
            end
            return a_type(node, "boolean", {})
         end

         if node.op.op == ":" then
            node.receiver = ua



            if self.feat_lax and (is_unknown(ua) or ua.typename == "typevar") then
               if node.e1.kind == "variable" then
                  self.errs:add_unknown_dot(node.e1, node.e1.tk .. "." .. node.e2.tk)
               end
               return a_type(node, "unknown", {})
            end

            local t, e = self:match_record_key(ra, node.e1, node.e2.conststr or node.e2.tk)
            if not t then
               return self.errs:invalid_at(node.e2, e, ua)
            end

            return t
         end

         if node.op.op == "not" then
            self.fdb:set_not(node, node.e1)
            return a_type(node, "boolean", {})
         end

         if node.op.op == "and" then
            self.fdb:set_and(node, node.e1, node.e2)
            return discard_tuple(node, ub, gb)
         end

         if node.op.op == "or" then
            local t

            local expected = node.expected and self:to_structural(untuple(node.expected))

            if ub.typename == "nil" then
               self.fdb:unset(node)
               t = ua

            elseif is_lua_table_type(ra) and rb.typename == "emptytable" then
               self.fdb:unset(node)
               t = ua

            elseif ((ra.typename == "enum" and rb.typename == "string" and self:is_a(rb, ra)) or
               (ra.typename == "string" and rb.typename == "enum" and self:is_a(ra, rb))) then
               self.fdb:unset(node)
               t = (ra.typename == "enum" and ra or rb)

            elseif expected and expected.typename == "union" then

               self.fdb:set_or(node, node.e1, node.e2)
               local u = unite(node, { ra, rb }, true, not self.feat_strict_nil)
               if u.typename == "union" then
                  ok, err = is_valid_union(u)
                  if not ok then
                     u = err and self.errs:invalid_at(node, err, u) or a_type(node, "invalid", {})
                  end
               end
               t = u


            elseif ra.typename == "union" and not (rb.typename == "union") and self:is_a(rb, ra) then

               if self.feat_strict_nil then
                  local truthy_ra, has_falsy = truthy_type(self, ua)
                  if has_falsy then
                     if not truthy_ra then
                        t = drop_constant_value(ub)
                     elseif self:is_a(rb, truthy_ra) then
                        t = drop_constant_value(truthy_ra)
                     else
                        t = drop_constant_value(ra)
                     end
                  else
                     t = drop_constant_value(ra)
                  end
               else
                  t = drop_constant_value(ra)
               end

            elseif rb.typename == "union" and not (ra.typename == "union") and self:is_a(ra, rb) then

               t = drop_constant_value(rb)

            else


               local ua_cmp = drop_constant_value(ua)
               local ub_cmp = drop_constant_value(ub)
               local a_ge_b = self:is_a(ub_cmp, ua_cmp)
               local b_ge_a = self:is_a(ua_cmp, ub_cmp)
               self.fdb:set_or(node, node.e1, node.e2)


               local ra_cmp = self:to_structural(ua_cmp)
               local rb_cmp = self:to_structural(ub_cmp)
               local is_same = self:same_type(ra_cmp, rb_cmp)


               local ambiguous = a_ge_b and b_ge_a and not is_same



               if is_same then
                  t = ua
               elseif (a_ge_b or b_ge_a) and not ambiguous then
                  local larger_type = b_ge_a and ub or ua
                  t = larger_type
               elseif expected and self:is_a(ua, expected) and self:is_a(ub, expected) then
                  t = self:infer_at(node, expected)
               end

               if ambiguous and not t then
                  if TL_DEBUG then
                     self.errs:add_warning("debug", node, "the resulting type is ambiguous: %s or %s", ua, ub)
                     self.errs:add_warning("debug", node, "currently choosing %s", ub)
                  end

                  t = ub
               end
               if t then
                  t = drop_constant_value(t)
               end

               if expected and expected.typename == "boolean_context" then
                  t = a_type(node, "boolean", {})
               end
            end

            if t then
               return discard_tuple(node, t, gb)
            end

         end

         if node.op.op == "==" or node.op.op == "~=" then
            local ua_cmp = drop_constant_value(ua)
            local ub_cmp = drop_constant_value(ub)
            local ua_literal = is_literal_value_type(ua)
            local ub_literal = is_literal_value_type(ub)
            if is_lua_table_type(ra) and is_lua_table_type(rb) then

               self:check_metamethod(node, "__eq", ra, rb, ua, ub)
            end

            if ra.typename == "enum" and rb.typename == "string" then
               if not (rb.literal and ra.enumset[rb.literal]) then
                  return self.errs:invalid_at(node, "%s is not a member of %s", ub, ua)
               end
            elseif ra.typename == "tupletable" and rb.typename == "tupletable" and #ra.types ~= #rb.types then
               return self.errs:invalid_at(node, "tuples are not the same size")
            else
               local nil_in_a = type_has_explicit_nil(self, ua_cmp)
               local nil_in_b = type_has_explicit_nil(self, ub_cmp)
               if nil_in_a or nil_in_b then

                  local niltype = a_type(node, "nil", {})
                  local variable_against_nil = false

                  if node.e1.kind == "variable" and node.e2.kind == "nil" and nil_in_a then
                     variable_against_nil = true
                     if node.op.op == "==" then
                        self.fdb:set_is(node, node.e1.tk, niltype)
                     else
                        self.fdb:set_is(node, node.e1.tk, niltype)
                        self.fdb:set_not(node, node)
                     end
                  elseif node.e2.kind == "variable" and node.e1.kind == "nil" and nil_in_b then
                     variable_against_nil = true
                     if node.op.op == "==" then
                        self.fdb:set_is(node, node.e2.tk, niltype)
                     else
                        self.fdb:set_is(node, node.e2.tk, niltype)
                        self.fdb:set_not(node, node)
                     end
                  end

                  if not variable_against_nil and node.op.op == "==" then
                     if node.e1.kind == "variable" and ua.typename == "invalid" then
                        self.fdb:set_eq(node, node.e1.tk, ub)
                     elseif node.e2.kind == "variable" and ub.typename == "invalid" then
                        self.fdb:set_eq(node, node.e2.tk, ua)
                     end
                  end
               elseif self:is_a(ub_cmp, ua_cmp) or (ub_literal and self:is_a(ub, ua)) or ua.typename == "typevar" then
                  if node.op.op == "==" and node.e1.kind == "variable" then
                     self.fdb:set_eq(node, node.e1.tk, ub)
                  end
               elseif self:is_a(ua_cmp, ub_cmp) or (ua_literal and self:is_a(ua, ub)) or ub.typename == "typevar" then
                  if node.op.op == "==" and node.e2.kind == "variable" then
                     self.fdb:set_eq(node, node.e2.tk, ua)
                  end
               elseif self.feat_lax and (is_unknown(ua) or is_unknown(ub)) then
                  return a_type(node, "unknown", {})
               else
                  return self.errs:invalid_at(node, "types are not comparable for equality: %s and %s", ua, ub)
               end
            end

            return a_type(node, "boolean", {})
         end

         if node.op.arity == 1 and unop_types[node.op.op] then
            if ra.typename == "union" then
               ra = unite(node, ra.types, true, not self.feat_strict_nil)
            end

            local types_op = unop_types[node.op.op]

            local tn = types_op[ra.typename]
            local t = tn and a_type(node, tn, {})

            if not t then
               local mt_name = unop_to_metamethod[node.op.op]
               if mt_name then
                  t, node.op.meta_on_operand = self:check_metamethod(node, mt_name, ra, nil, ua, nil)
               end
            end

            if not t and ra.fields then
               if ra.interface_list then
                  for _, iface in ipairs(ra.interface_list) do
                     if types_op[iface.typename] then
                        t = a_type(node, types_op[iface.typename], {})
                        break
                     end
                  end
               end
            end

            if ra.typename == "map" then
               if ra.keys.typename == "number" or ra.keys.typename == "integer" then
                  self.errs:add_warning("hint", node, "using the '#' operator on a map with numeric key type may produce unexpected results")
               else
                  self.errs:add(node, "using the '#' operator on this map will always return 0")
               end
            end

            if ua.typename == "nominal" and ua.found then
               local table_t = (self.env.modules["table"]).def
               local packtable = (table_t.fields["PackTable"]).def

               if ua.found.def.typeid == packtable.typeid then
                  self:add_warning("hint", node, "hint: using the '#' operator on a PackTable may produce unexpected results. Use '.n' instead")
               end
            end

            if not t then
               return self.errs:invalid_at(node, "cannot use operator '" .. node.op.op:gsub("%%", "%%%%") .. "' on type %s", ua)
            end

            if not (t.typename == "boolean" or is_unknown(t)) then
               self.fdb:set_truthy(node)
            end

            return t
         end

         if node.op.arity == 2 and binop_types[node.op.op] then
            if node.op.op == "or" then
               self.fdb:set_or(node, node.e1, node.e2)
            end

            if ra.typename == "union" then
               ra = unite(ra, ra.types, true, not self.feat_strict_nil)
            end
            if rb.typename == "union" then
               rb = unite(rb, rb.types, true, not self.feat_strict_nil)
            end

            local types_op = binop_types[node.op.op]
            if self.env.opts.gen_target == "luajit" and types_op == integer_binop and
               (ra.fields or rb.fields) then
               return self.errs:invalid_at(node, "bit operator metamethods are not available in the LuaJIT 2.1 backport")
            end

            local tn = types_op[ra.typename] and types_op[ra.typename][rb.typename]
            local t = tn and a_type(node, tn, {})

            if not t then
               local mt_name = binop_to_metamethod[node.op.op]
               local flipped = false
               if not mt_name then
                  mt_name = flip_binop_to_metamethod[node.op.op]
                  if mt_name then
                     flipped = true
                     ra, rb = rb, ra
                     ua, ub = ub, ua
                  end
               end
               if mt_name then
                  t, node.op.meta_on_operand = self:check_metamethod(node, mt_name, ra, rb, ua, ub, flipped)
                  if flipped and not node.op.meta_on_operand then
                     ra, rb = rb, ra
                     ua, ub = ub, ua
                  end
               end
            end

            if (not t) and ua.typename == "nominal" and ub.typename == "nominal" and not node.op.meta_on_operand then
               if self:is_a(ua, ub) then
                  t = ua
               end
            end

            if types_op == numeric_binop or node.op.op == ".." then
               self.fdb:set_truthy(node)
            end

            if not t then
               if node.op.op == "or" then
                  local u = unite(node, { ua, ub }, nil, not self.feat_strict_nil)
                  if u.typename == "union" and is_valid_union(u) then
                     self.errs:add_warning("hint", node, "if a union type was intended, consider declaring it explicitly")
                  end
               end
               return self.errs:invalid_at(node, "cannot use operator '" .. node.op.op:gsub("%%", "%%%%") .. "' for types %s and %s", ua, ub)
            end

            return t
         end

         error("unknown node op " .. node.op.op)
      end,
   },
   ["variable"] = {
      after = function(self, node, _children)
         if node.tk == "..." then
            local va_sentinel = self:find_var_type("@is_va")
            if not va_sentinel or va_sentinel.typename == "nil" then
               return self.errs:invalid_at(node, "cannot use '...' outside a vararg function")
            end
         end

         local t
         if node.tk == "_G" then
            t, node.attribute = self:simulate_g()
         else
            local use = node.is_lvalue and "lvalue" or "use"
            t, node.attribute = self:find_var_type(node.tk, use)
         end
         if not t then
            if self.feat_lax then
               self.errs:add_unknown(node, node.tk)
               return a_type(node, "unknown", {})
            end

            return self.errs:invalid_at(node, "unknown variable: " .. node.tk)
         end

         if t.typename == "typedecl" then
            t = typedecl_to_nominal(node, node.tk, t, t)
         end

         local truthy, has_falsy = truthy_type(self, t)
         if has_falsy and truthy then
            self.fdb:set_is(node, node.tk, truthy)
         end

         return t
      end,
   },
   ["type_identifier"] = {
      after = function(self, node, _children)
         local typ, attr = self:find_var_type(node.tk)
         node.attribute = attr
         if typ then
            return typ
         end

         if self.feat_lax then
            self.errs:add_unknown(node, node.tk)
            return a_type(node, "unknown", {})
         end

         return self.errs:invalid_at(node, "unknown variable: " .. node.tk)
      end,
   },
   ["argument"] = {
      after = function(self, node, children)
         local t = children[1]
         if not t then
            if node.expected then
               t = self:infer_at(node, node.expected)
            else
               t = self.feat_lax and
               a_type(node, "unknown", {}) or
               a_type(node, "any", {})
            end
         end

         local is_named_vararg = false
         if node.tk == "..." then
            if node.name then
               local table_t = (self.env.modules["table"]).def
               local generic_pack_table = (table_t.fields["PackTable"]).def
               local pack_table = self:apply_generic(node, generic_pack_table, { t })

               self:add_var(node, node.name.tk, pack_table, "const").is_func_arg = true
               is_named_vararg = true
            end
            t = a_vararg(node, { t })
         elseif node.opt and self.feat_strict_nil then
            local niltype = a_type(node, "nil", {})
            if not self:is_a(niltype, t) then
               t = unite(node, { t, niltype }, nil, false)
            end
         end

         local arg_var = self:add_var(node, node.tk, t)
         arg_var.is_func_arg = true
         if is_named_vararg then


            arg_var.has_been_read_from = true
         end

         return t
      end,
   },
   ["identifier"] = {
      after = function(_self, _node, _children)
         return NONE
      end,
   },
   ["newtype"] = {
      after = function(_self, node, _children)
         return node.newtype
      end,
   },
   ["pragma"] = {
      after = function(self, node, _children)
         if node.pkey == "strict" then
            if node.pvalue ~= "on" then
               return self.errs:invalid_at(node, "pragma 'strict' expects 'on'")
            elseif self.strict_pragma ~= node then
               return self.errs:invalid_at(node, "pragma 'strict on' must appear once at the beginning of the file")
            end
         elseif self.strict_pragma and (node.pkey == "arity" or node.pkey == "strict_nil") then
            if node.pvalue ~= "on" then
               return self.errs:invalid_at(node, "strict mode: pragma '" .. node.pkey .. "' must be 'on'")
            end
         elseif node.pkey == "arity" then
            if node.pvalue == "on" then
               self.feat_arity = true
               self.env.opts.feat_arity = "on"
            elseif node.pvalue == "off" then
               self.feat_arity = false
               self.env.opts.feat_arity = "off"
            else
               return self.errs:invalid_at(node, "invalid value for pragma 'arity': " .. node.pvalue)
            end
         elseif node.pkey == "strict_nil" then
            if node.pvalue == "on" then
               self.feat_strict_nil = true
               self.env.opts.feat_strict_nil = "on"
            elseif node.pvalue == "off" then
               self.feat_strict_nil = false
               self.env.opts.feat_strict_nil = "off"
            else
               return self.errs:invalid_at(node, "invalid value for pragma 'strict_nil': " .. node.pvalue)
            end
         else
            return self.errs:invalid_at(node, "invalid pragma: " .. node.pkey)
         end
         return NONE
      end,
   },
   ["error_node"] = {
      after = function(_self, node, _children)
         return a_type(node, "invalid", {})
      end,
   },
}

visit_node.cbs["break"] = {
   after = function(_self, _node, _children)
      return NONE
   end,
}
visit_node.cbs["do"] = visit_node.cbs["break"]
visit_node.cbs["continue"] = visit_node.cbs["break"]

local function after_literal(self, node)
   self.fdb:set_truthy(node)
   local t = a_type(node, node.kind, {})
   if node.kind == "number" then
      (t).literal = node.constnum
   elseif node.kind == "integer" then
      (t).literal = node.constnum
   elseif node.kind == "boolean" then
      (t).literal = node.tk == "true"
   end
   return t
end

visit_node.cbs["string"] = {
   after = function(self, node, _children)
      local t = after_literal(self, node)
      t.literal = node.conststr

      local expected = node.expected and self:to_structural(node.expected)
      if expected and expected.typename == "enum" and self:is_a(t, expected) then
         return node.expected
      end

      return t
   end,
}
visit_node.cbs["number"] = { after = after_literal }
visit_node.cbs["integer"] = { after = after_literal }

visit_node.cbs["boolean"] = {
   after = function(self, node, _children)
      local t = after_literal(self, node)
      if node.tk == "true" then
         self.fdb:set_truthy(node)
      else
         self.fdb:unset(node)
      end
      return t
   end,
}
visit_node.cbs["nil"] = visit_node.cbs["boolean"]

visit_node.cbs["..."] = visit_node.cbs["variable"]
visit_node.cbs["argument_list"] = visit_node.cbs["variable_list"]
visit_node.cbs["expression_list"] = {
   after = visit_node.cbs["variable_list"].after,
   child_order = function(_self, node)
      local expected = node.expected
      if not expected or not (expected.typename == "tuple") then return nil end



      local order = {}
      for i, child in ipairs(node) do if not callback_literal(child) then table.insert(order, i) end end
      for i, child in ipairs(node) do if callback_literal(child) then table.insert(order, i) end end
      return order
   end,
   before_child = function(self, node, children, index)
      local expected = node.expected
      if not expected or not (expected.typename == "tuple") then return end
      local expected_args = expected
      local function formal(i)
         return expected_args.tuple[i] or (expected_args.is_va and expected_args.tuple[#expected_args.tuple])
      end
      for i = 1, #node do
         local actual = children[i]
         if actual then
            if i == #node and actual.typename == "tuple" then
               for j, member in ipairs(actual.tuple) do
                  local typ = formal(i + j - 1)
                  if typ then self:is_a(member, typ) end
               end
            else
               local typ = formal(i)
               if typ then self:is_a(untuple(actual), typ) end
            end
         end
      end
      local typ = formal(index)
      if typ then node[index].expected = self:infer_at(node[index], typ) end
   end,
}

visit_node.after = function(self, node, _children, t)
   if node.expanded then
      macroexps.apply(node)
   end

   if self.native_ffi and t ~= NONE then node.native_type = t end
   if self.strict_pragma and not node.type_require and self:contains_dynamic(t, node.strict_receiver) then
      return self.errs:invalid_at(node, "strict mode: a value cannot have type 'any' or 'unknown'")
   end
   return t
end



local function ensure_is_method_self(typ, selfarg, g)
   if selfarg.typename == "self" then
      return true
   end
   if not (selfarg.typename == "nominal") then
      return false
   end

   if #selfarg.names ~= 1 or selfarg.names[1] ~= typ.declname then
      return false
   end

   if g then
      if not selfarg.typevals then
         return false
      end

      if g.t.typeid ~= typ.typeid then
         return false
      end

      for j = 1, #g.typeargs do
         local tv = selfarg.typevals[j]
         if not (tv and tv.typename == "typevar" and tv.typevar == g.typeargs[j].typearg) then
            return false
         end
      end
   end

   return true
end

local metamethod_is_method = {
   ["__bnot"] = true,
   ["__call"] = true,
   ["__close"] = true,
   ["__gc"] = true,
   ["__index"] = true,
   ["__is"] = true,
   ["__len"] = true,
   ["__newindex"] = true,
   ["__pairs"] = true,
   ["__tostring"] = true,
   ["__unm"] = true,
}

visit_type.cbs = {
   ["generic"] = {
      before = function(self, typ)
         self:begin_implied_scope()
         self:add_var(nil, "@generic", typ)
      end,
      after = function(self, typ, _children)
         self:end_implied_scope()
         return self:fresh_typeargs(typ)
      end,
   },
   ["function"] = {
      after = function(self, typ, _children)
         if self.feat_arity == false then
            typ.min_arity = 0
         end
         return typ
      end,
   },
   ["record"] = {
      before = function(self, typ)
         self:begin_implied_scope()
         self:begin_temporary_record_types(typ)
      end,
      after = function(self, typ, children)
         local i = 1
         if typ.interface_list then
            for j, _ in ipairs(typ.interface_list) do
               local iface = children[i]
               if iface.typename == "array" then
                  typ.interface_list[j] = iface
               elseif iface.typename == "nominal" then
                  local ri = self:resolve_nominal(iface)
                  if ri.typename == "interface" then
                     typ.interface_list[j] = iface
                  else
                     self.errs:add(children[i], "%s is not an interface", children[i])
                  end
               end
               i = i + 1
            end
         end
         if typ.elements then
            typ.elements = children[i]
            i = i + 1
         end
         local fmacros
         local g
         for name, _ in fields_of(typ) do
            local ftype = children[i]
            if ftype.typename == "function" then
               if ftype.macroexp then
                  fmacros = fmacros or {}
                  table.insert(fmacros, ftype)
               end

               if ftype.is_method then
                  local fargs = ftype.args.tuple
                  if fargs[1] then
                     if not g then
                        g = self:find_var("@generic")
                     end
                     ftype.is_method = ensure_is_method_self(typ, fargs[1], g and g.t)
                     if ftype.is_method then
                        fargs[1] = a_type(fargs[1], "self", { display_type = typ })
                     end
                  end
               end
            elseif ftype.typename == "typedecl" and ftype.is_alias then
               self:resolve_typealias(ftype)
            end

            typ.fields[name] = ftype
            i = i + 1
         end
         for name, _ in fields_of(typ, "meta") do
            local ftype = children[i]
            if ftype.typename == "function" then
               if ftype.macroexp then
                  fmacros = fmacros or {}
                  table.insert(fmacros, ftype)
               end
               ftype.is_method = metamethod_is_method[name]
            end
            typ.meta_fields[name] = ftype
            i = i + 1
         end

         if typ.interface_list then
            self:expand_interfaces(typ)

            if self.collector then
               for fname, ftype in fields_of(typ) do
                  self.env.reporter:add_field(typ, fname, ftype)
               end
            end
         end

         if fmacros then
            for _, t in ipairs(fmacros) do
               local macroexp_type = traverse_nodes(self, t.macroexp, visit_node, visit_type)

               macroexps.check_arg_use(self, t.macroexp)

               if not self:is_a(macroexp_type, t) then
                  self.errs:add(macroexp_type, "macroexp type does not match declaration")
               end
            end
         end

         self:end_temporary_record_types(typ)
         self:end_implied_scope()

         return typ
      end,
   },
   ["typearg"] = {
      after = function(self, typ, _children)
         local name = typ.typearg
         local old = self:find_var(name, "check_only")
         if old then
            self.errs:redeclaration_warning(typ, name, "type argument", old)
         end
         if simple_types[name] then
            self.errs:add(typ, "cannot use base type name '" .. name .. "' as a type variable")
         end

         self:add_var(nil, name, a_type(typ, "typearg", {
            typearg = name,
            constraint = typ.constraint,
         }))
         return typ
      end,
   },
   ["typevar"] = {
      after = function(self, typ, _children)
         if not self:find_var_type(typ.typevar) then
            self.errs:add(typ, "undefined type variable " .. typ.typevar)
         end
         return typ
      end,
   },
   ["nominal"] = {
      after = function(self, typ, _children)
         if typ.found then
            return typ
         end

         local t, typearg = self:find_type(typ.names)
         if t then
            local def = t.def
            if t.is_alias then
               if def.typename == "generic" then
                  def = def.t
               end
               if def.typename == "nominal" then
                  typ.found = def.found
               end
            elseif def.typename ~= "circular_require" then
               typ.found = t
            end
         elseif typearg then

            typ.names = nil
            edit_type(typ, typ, "typevar")
            local tv = typ
            tv.typevar = typearg.typearg
            tv.constraint = typearg.constraint
         else
            local name = typ.names[1]
            local scope = self.st[#self.st]
            scope.pending_nominals = scope.pending_nominals or {}
            scope.pending_nominals[name] = scope.pending_nominals[name] or {}
            table.insert(scope.pending_nominals[name], typ)
         end
         return typ
      end,
   },
   ["union"] = {
      after = function(self, typ, _children)
         local _, err = is_valid_union(typ)
         if err then
            return self.errs:invalid_at(typ, err, typ)
         end
         return typ
      end,
   },
}

local default_type_visitor = {
   after = function(_self, typ, _children)
      return typ
   end,
}

visit_type.cbs["interface"] = visit_type.cbs["record"]

visit_type.cbs["typedecl"] = default_type_visitor
visit_type.cbs["self"] = default_type_visitor
visit_type.cbs["string"] = default_type_visitor
visit_type.cbs["tupletable"] = default_type_visitor
visit_type.cbs["array"] = default_type_visitor
visit_type.cbs["map"] = default_type_visitor
visit_type.cbs["enum"] = default_type_visitor
visit_type.cbs["boolean"] = default_type_visitor
visit_type.cbs["nil"] = default_type_visitor
visit_type.cbs["number"] = default_type_visitor
visit_type.cbs["integer"] = default_type_visitor
visit_type.cbs["thread"] = default_type_visitor
visit_type.cbs["emptytable"] = default_type_visitor
visit_type.cbs["literal_table_item"] = default_type_visitor
visit_type.cbs["unresolved_emptytable_value"] = default_type_visitor
visit_type.cbs["tuple"] = default_type_visitor
visit_type.cbs["poly"] = default_type_visitor
visit_type.cbs["any"] = {
   after = function(self, t, _children)
      if self.strict_pragma then
         return self.errs:invalid_at(t, "strict mode: type 'any' is not allowed")
      end
      return t
   end,
}
visit_type.cbs["unknown"] = default_type_visitor
visit_type.cbs["invalid"] = default_type_visitor
visit_type.cbs["none"] = default_type_visitor

return visitors

end

-- module teal.debug from teal/debug.lua
package.preload["teal.debug"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local debug = _tl_compat and _tl_compat.debug or debug; local io = _tl_compat and _tl_compat.io or io; local math = _tl_compat and _tl_compat.math or math; local _tl_math_maxinteger = math.maxinteger or math.pow(2, 53); local os = _tl_compat and _tl_compat.os or os; local string = _tl_compat and _tl_compat.string or string



local tldebug = {}







function tldebug.write(...)
   io.stderr:write(...)
end

function tldebug.flush()
   io.stderr:flush()
end

tldebug.TL_DEBUG = os.getenv("TL_DEBUG")
tldebug.TL_DEBUG_FACTS = os.getenv("TL_DEBUG_FACTS")
tldebug.TL_DEBUG_MAXLINE = _tl_math_maxinteger

if tldebug.TL_DEBUG_FACTS and not tldebug.TL_DEBUG then
   tldebug.TL_DEBUG = "1"
end

if tldebug.TL_DEBUG then
   local max = assert(tonumber(tldebug.TL_DEBUG), "TL_DEBUG was defined, but not a number")
   if max < 0 then
      tldebug.TL_DEBUG_MAXLINE = math.tointeger(-max)
   elseif max > 1 then
      local count = 0
      local skip
      debug.sethook(function(event)
         if event == "call" or event == "tail call" or event == "return" then
            local info = debug.getinfo(2)

            if skip then
               if info.name == skip and event == "return" then
                  skip = nil
               end
               return
            elseif (info.name or "?"):match("^tl_debug_") and event == "call" then
               skip = info.name
               return
            end

            local name = info.name or "<anon>", info.currentline > 0 and "@" .. info.currentline or ""
            tldebug.write(name, " :: ", event, "\n")
            tldebug.flush()
         else
            count = count + 100
            if count > max then
               error("Too many instructions")
            end
         end
      end, "cr", 100)
   end
end

do







   local curr_indent = 0
   local curr_entry = nil
   local curr_y = 1

   local function loc(y, x)
      return (tostring(y) or "?") .. ":" .. (tostring(x) or "?")
   end

   function tldebug.indent_push(mark, y, x, fmt, ...)
      if curr_entry then
         local entry = curr_entry
         if entry.y and (entry.y > curr_y) then
            tldebug.write("\n")
            curr_y = entry.y
         end
         tldebug.write(("   "):rep(curr_indent) .. entry.mark .. " " ..
         loc(entry.y, entry.x) .. " " ..
         entry.msg .. "\n")
         tldebug.flush()
         curr_entry = nil
         curr_indent = curr_indent + 1
      end
      curr_entry = {
         mark = mark,
         y = y,
         x = x,
         msg = fmt:format(...),
      }
   end

   function tldebug.indent_pop(mark, single, y, x, fmt, ...)
      if curr_entry then
         local entry = curr_entry
         local msg = entry.msg
         if fmt then
            msg = fmt:format(...)
         end
         if y and (y > curr_y) then
            tldebug.write("\n")
            curr_y = y
         end
         tldebug.write(("   "):rep(curr_indent) .. single .. " " .. loc(y, x) .. " " .. msg .. "\n")
         tldebug.flush()
         curr_entry = nil
      else
         curr_indent = curr_indent - 1
         if fmt then
            tldebug.write(("   "):rep(curr_indent) .. mark .. " " .. fmt:format(...) .. "\n")
            tldebug.flush()
         end
      end
   end
end

return tldebug

end

-- module teal.environment from teal/environment.lua
package.preload["teal.environment"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table

local VERSION = "0.25.0-alpha+dev"

local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG

local default_env = require("teal.precompiled.default_env")




local targets = require("teal.gen.targets")





local types = require("teal.types")






local a_type = types.a_type







local environment = { EnvOptions = {}, Env = {}, Result = {} }


























































environment.VERSION = VERSION
environment.DEFAULT_GEN_COMPAT = "optional"
environment.DEFAULT_GEN_TARGET = "5.3"





local require_module

function environment.set_require_module_fn(fn)
   require_module = fn
end

local function empty_environment()
   return {
      modules = {},
      module_filenames = {},
      loaded = {},
      loaded_order = {},
      globals = {},
      opts = {},
      require_module = require_module,
   }
end

local function declare_globals(env)
   for name, var in pairs(environment.stdlib_globals) do
      env.globals[name] = var
      local t = var.t
      if t.typename == "typedecl" then

         env.modules[name] = t
      end
   end
end

local function load_precompiled_default_env(env)
   if not environment.stdlib_globals then



      environment.stdlib_globals = default_env.globals
      types.internal_force_state(default_env.typeid_ctr, default_env.typevar_ctr)
   end

   declare_globals(env)
end


function environment.new(opts)
   local env = empty_environment()
   env.opts = opts or env.opts
   if not env.opts.no_stdlib then
      load_precompiled_default_env(env)
   else


      env:require_module("teal.default.prelude")
   end
   return env
end





function environment.for_runtime()
   local gen_target = targets.detect()
   local gen_compat = (gen_target == "5.4" or gen_target == "5.5") and "off" or environment.DEFAULT_GEN_COMPAT
   return environment.new({
      gen_target = gen_target,
      gen_compat = gen_compat,
      run_internal_compiler_checks = false,
   })
end

do
   local stdlib_compat = {
      ["io"] = true,
      ["math"] = true,
      ["string"] = true,
      ["table"] = true,
      ["utf8"] = true,
      ["coroutine"] = true,
      ["os"] = true,
      ["package"] = true,
      ["debug"] = true,
      ["load"] = true,
      ["loadfile"] = true,
      ["assert"] = true,
      ["pairs"] = true,
      ["ipairs"] = true,
      ["pcall"] = true,
      ["xpcall"] = true,
      ["rawlen"] = true,
   }

   local function set_special_function(t, fname)
      t = types.resolve_for_special_function(t)
      t.special_function_handler = fname
   end










   function environment.construct(opts, prelude, stdlib)
      if opts and (opts.gen_target == "5.4" or opts.gen_target == "5.5") and opts.gen_compat ~= "off" then
         return nil, "gen-compat must be explicitly 'off' when gen-target is '5.4' or '5.5'"
      end

      local env = empty_environment()
      env.opts = opts or env.opts

      local stdlib_globals = environment.stdlib_globals
      if not stdlib_globals then
         local tl_debug = TL_DEBUG
         TL_DEBUG = nil

         local typ = env:require_module(prelude or "teal.default.prelude")
         if typ.typename == "invalid" then
            return nil, "prelude contains errors"
         end

         typ = env:require_module(stdlib or "teal.default.stdlib")
         if typ.typename == "invalid" then
            return nil, "standard library contains errors"
         end

         stdlib_globals = env.globals
         environment.stdlib_globals = env.globals

         TL_DEBUG = tl_debug


         local math_t = (stdlib_globals["math"].t).def
         local table_t = (stdlib_globals["table"].t).def
         math_t.fields["maxinteger"].needs_compat = true
         math_t.fields["mininteger"].needs_compat = true
         table_t.fields["pack"].needs_compat = true
         table_t.fields["unpack"].needs_compat = true


         set_special_function(table_t.fields["unpack"], "table.unpack")

         local string_t = (stdlib_globals["string"].t).def
         set_special_function(string_t.fields["find"], "string.find")
         set_special_function(string_t.fields["format"], "string.format")
         set_special_function(string_t.fields["gmatch"], "string.gmatch")
         set_special_function(string_t.fields["gsub"], "string.gsub")
         set_special_function(string_t.fields["match"], "string.match")
         set_special_function(string_t.fields["pack"], "string.pack")
         set_special_function(string_t.fields["unpack"], "string.unpack")

         set_special_function(stdlib_globals["assert"].t, "assert")
         set_special_function(stdlib_globals["ipairs"].t, "ipairs")
         set_special_function(stdlib_globals["pairs"].t, "pairs")
         set_special_function(stdlib_globals["pcall"].t, "pcall")
         set_special_function(stdlib_globals["xpcall"].t, "xpcall")
         set_special_function(stdlib_globals["rawget"].t, "rawget")
         set_special_function(stdlib_globals["require"].t, "require")




         local w = { filename = "@<stdlib>.tl", y = 1, x = 1 }
         stdlib_globals["..."] = { t = a_type(w, "tuple", { tuple = { a_type(w, "string", {}) }, is_va = true }) }
         stdlib_globals["@is_va"] = { t = a_type(w, "any", {}) }

         env.globals = {}
      end

      declare_globals(env)

      for name, _ in pairs(stdlib_compat) do
         env.globals[name].needs_compat = true
      end

      return env
   end
end

function environment.load_module(env, name)
   local module_type = env:require_module(name)

   if not module_type then
      return false, string.format("could not load module '%s'", name)
   end

   return true
end

function environment.register(env, filename, result)
   env.loaded[filename] = result

   table.insert(env.loaded_order, filename)
end

function environment.register_failed(env, filename, syntax_errors)
   local result = {
      filename = filename,
      type = a_type({ f = filename, y = 1, x = 1 }, "boolean", {}),
      type_errors = {},
      syntax_errors = syntax_errors,
      dependencies = {},
      env = env,
   }
   env.loaded[filename] = result
   table.insert(env.loaded_order, filename)
   return result
end

return environment

end

-- module teal.errors from teal/errors.lua
package.preload["teal.errors"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local table = _tl_compat and _tl_compat.table or table
local errors = { Error = {}, ErrorContext = {} }







































function errors.new(msg)
   return { msg = msg }
end

function errors.at(w, msg)
   return {
      msg = msg,
      x = assert(w.x),
      y = assert(w.y),
      filename = assert(w.f),
   }
end

function errors.any(all_errs)
   if #all_errs == 0 then
      return true
   else
      return false, all_errs
   end
end

function errors.clear_redundant_errors(errs)
   local redundant = {}
   local lastx, lasty = 0, 0
   for i, err in ipairs(errs) do
      err.i = i
   end
   table.sort(errs, function(a, b)
      local af = assert(a.filename)
      local bf = assert(b.filename)
      return af < bf or
      (af == bf and (a.y < b.y or
      (a.y == b.y and (a.x < b.x or
      (a.x == b.x and (a.i < b.i))))))
   end)
   for i, err in ipairs(errs) do
      err.i = nil
      if err.x == lastx and err.y == lasty then
         table.insert(redundant, i)
      end
      lastx, lasty = err.x, err.y
   end
   for i = #redundant, 1, -1 do
      table.remove(errs, redundant[i])
   end
end

local wk = {
   ["unknown"] = true,
   ["unused"] = true,
   ["redeclaration"] = true,
   ["branch"] = true,
   ["hint"] = true,
   ["debug"] = true,
   ["unread"] = true,
   ["inheritance"] = true,
}
errors.warning_kinds = wk

return errors

end

-- module teal.facts from teal/facts.lua
package.preload["teal.facts"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local tldebug = require("teal.debug")
local TL_DEBUG_FACTS = tldebug.TL_DEBUG_FACTS




local types = require("teal.types")




local a_type = types.a_type
local show_type = types.show_type
local unite = types.unite




local util = require("teal.util")
local sorted_keys = util.sorted_keys

local facts = { TruthyFact = {}, NotFact = {}, AndFact = {}, OrFact = {}, EqFact = {}, IsFact = {}, FactDatabase = {} }























































































local IsFact = facts.IsFact
local EqFact = facts.EqFact
local AndFact = facts.AndFact
local OrFact = facts.OrFact
local NotFact = facts.NotFact
local TruthyFact = facts.TruthyFact
local FactDatabase = facts.FactDatabase

local IsFact_mt = {
   __tostring = function(f)
      return ("(%s is %s)"):format(f.var, show_type(f.typ))
   end,
}

setmetatable(IsFact, {
   __call = function(_, fact)
      fact.fact = "is"
      assert(fact.w)
      return setmetatable(fact, IsFact_mt)
   end,
})

local EqFact_mt = {
   __tostring = function(f)
      return ("(%s == %s)"):format(f.var, show_type(f.typ))
   end,
}

setmetatable(EqFact, {
   __call = function(_, fact)
      fact.fact = "=="
      assert(fact.w)
      return setmetatable(fact, EqFact_mt)
   end,
})

local TruthyFact_mt = {
   __tostring = function(_f)
      return "*"
   end,
}

setmetatable(TruthyFact, {
   __call = function(_, fact)
      fact.fact = "truthy"
      return setmetatable(fact, TruthyFact_mt)
   end,
})

local NotFact_mt = {
   __tostring = function(f)
      return ("(not %s)"):format(tostring(f.f1))
   end,
}

setmetatable(NotFact, {
   __call = function(_, fact)
      fact.fact = "not"
      return setmetatable(fact, NotFact_mt)
   end,
})

local AndFact_mt = {
   __tostring = function(f)
      return ("(%s and %s)"):format(tostring(f.f1), tostring(f.f2))
   end,
}

setmetatable(AndFact, {
   __call = function(_, fact)
      fact.fact = "and"
      return setmetatable(fact, AndFact_mt)
   end,
})

local OrFact_mt = {
   __tostring = function(f)
      return ("(%s or %s)"):format(tostring(f.f1), tostring(f.f2))
   end,
}

setmetatable(OrFact, {
   __call = function(_, fact)
      fact.fact = "or"
      return setmetatable(fact, OrFact_mt)
   end,
})


local FACT_TRUTHY = TruthyFact({})
facts.FACT_TRUTHY = FACT_TRUTHY

function facts.facts_and(w, f1, f2)
   if not f1 and not f2 then
      return
   end
   return AndFact({ f1 = f1, f2 = f2, w = w })
end

function facts.facts_or(w, f1, f2)
   return OrFact({ f1 = f1 or FACT_TRUTHY, f2 = f2 or FACT_TRUTHY, w = w })
end

function facts.facts_not(w, f1)
   if f1 then
      return NotFact({ f1 = f1, w = w })
   else
      return nil
   end
end


local function unite_types(ck, w, t1, t2)
   return unite(w, { t2, t1 }, nil, not ck.feat_strict_nil)
end


local function intersect_types(ck, w, t1, t2)
   if t2.typename == "union" then
      t1, t2 = t2, t1
   end
   if t1.typename == "union" then
      local out = {}
      for _, t in ipairs(t1.types) do
         if ck:is_a(t, t2) then
            table.insert(out, t)
         end
      end
      if #out > 0 then
         return unite(w, out, nil, not ck.feat_strict_nil)
      end
   end
   if ck:is_a(t1, t2) then
      return t1
   elseif ck:is_a(t2, t1) then
      return t2
   else
      return a_type(w, "nil", {})
   end
end

local function resolve_if_union(ck, t)
   local rt = ck:to_structural(t)
   if rt.typename == "union" then
      return rt
   end
   return t
end


local function subtract_types(ck, w, t1, t2)
   local typs = {}

   t1 = resolve_if_union(ck, t1)


   if not (t1.typename == "union") then
      return t1
   end

   t2 = resolve_if_union(ck, t2)
   local t2types = t2.typename == "union" and t2.types or { t2 }

   for _, at in ipairs(t1.types) do
      local not_present = true
      for _, bt in ipairs(t2types) do
         if ck:same_type(at, bt) then
            not_present = false
            break
         end
      end
      if not_present then
         table.insert(typs, at)
      end
   end

   if #typs == 0 then
      return a_type(w, "nil", {})
   end

   return unite(w, typs, nil, not ck.feat_strict_nil)
end

local eval_not
local not_facts
local or_facts
local and_facts

local function invalid_from(f)
   return IsFact({ fact = "is", var = f.var, typ = a_type(f.w, "invalid", {}), w = f.w })
end





not_facts = function(ck, fs)
   local ret = {}
   for var, f in pairs(fs) do
      local typ = ck:find_var_type(f.var, "check_only")

      if not typ then
         ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
      elseif f.fact == "==" then

         ret[var] = EqFact({ var = var, typ = typ, w = f.w, no_infer = true })
      elseif typ.typename == "typevar" then
         assert(f.fact == "is")

         ret[var] = EqFact({ var = var, typ = typ, w = f.w, no_infer = true })
      elseif not ck:is_a(f.typ, typ) then
         assert(f.fact == "is")
         ck:add_warning("branch", f.w, f.var .. " (of type %s) can never be a %s", show_type(typ), show_type(f.typ))
         ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
      else
         assert(f.fact == "is")
         ret[var] = IsFact({ var = var, typ = subtract_types(ck, f.w, typ, f.typ), w = f.w, no_infer = f.no_infer })
      end
   end
   return ret
end

eval_not = function(ck, f)
   if not f then
      return {}
   elseif f.fact == "is" then
      return not_facts(ck, { [f.var] = f })
   elseif f.fact == "not" then
      return facts.eval_fact(ck, f.f1)
   elseif f.fact == "and" and f.f2 and f.f2.fact == "truthy" then
      return eval_not(ck, f.f1)
   elseif f.fact == "or" and f.f2 and f.f2.fact == "truthy" then
      return eval_not(ck, f.f1)
   elseif f.fact == "and" then
      return or_facts(ck, eval_not(ck, f.f1), eval_not(ck, f.f2))
   elseif f.fact == "or" then
      return and_facts(ck, eval_not(ck, f.f1), eval_not(ck, f.f2))
   else
      return not_facts(ck, facts.eval_fact(ck, f))
   end
end

or_facts = function(ck, fs1, fs2)
   local ret = {}

   for var, f in pairs(fs2) do
      if fs1[var] then
         local united = unite_types(ck, f.w, f.typ, fs1[var].typ)
         if fs1[var].fact == "is" and f.fact == "is" then
            ret[var] = IsFact({ var = var, typ = united, w = f.w })
         else
            ret[var] = EqFact({ var = var, typ = united, w = f.w })
         end
      end
   end

   return ret
end

and_facts = function(ck, fs1, fs2)
   local ret = {}
   local has = {}

   for var, f in pairs(fs1) do
      local rt
      local ctor = EqFact
      if fs2[var] then
         if fs2[var].fact == "is" and f.fact == "is" then
            ctor = IsFact
         end
         rt = intersect_types(ck, f.w, f.typ, fs2[var].typ)
      else
         rt = f.typ
      end
      local ff = ctor({ var = var, typ = rt, w = f.w, no_infer = f.no_infer })
      ret[var] = ff
      has[ff.fact] = true
   end

   for var, f in pairs(fs2) do
      if not fs1[var] then
         ret[var] = EqFact({ var = var, typ = f.typ, w = f.w, no_infer = f.no_infer })
         has["=="] = true
      end
   end

   if has["is"] and has["=="] then
      for _, f in pairs(ret) do
         f.fact = "=="
      end
   end

   return ret
end

function facts.eval_fact(ck, f)
   if not f then
      return {}
   elseif f.fact == "is" then
      local typ = ck:find_var_type(f.var, "check_only")
      if not typ then
         return { [f.var] = invalid_from(f) }
      end
      if not (typ.typename == "typevar") then
         if ck:is_a(typ, f.typ) then


            return { [f.var] = f }
         elseif not ck:is_a(f.typ, typ) then
            ck:add_error(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
            return { [f.var] = invalid_from(f) }
         end
      end
      return { [f.var] = f }
   elseif f.fact == "==" then
      return { [f.var] = f }
   elseif f.fact == "not" then
      return eval_not(ck, f.f1)
   elseif f.fact == "truthy" then
      return {}
   elseif f.fact == "and" and f.f2 and f.f2.fact == "truthy" then
      return facts.eval_fact(ck, f.f1)
   elseif f.fact == "or" and f.f2 and f.f2.fact == "truthy" then
      return eval_not(ck, f.f1)
   elseif f.fact == "and" then
      return and_facts(ck, facts.eval_fact(ck, f.f1), facts.eval_fact(ck, f.f2))
   elseif f.fact == "or" then
      return or_facts(ck, facts.eval_fact(ck, f.f1), facts.eval_fact(ck, f.f2))
   end
end

if TL_DEBUG_FACTS then
   local eval_indent = -1
   local real_eval_fact = facts.eval_fact
   facts.eval_fact = function(self, known)
      eval_indent = eval_indent + 1
      tldebug.write(("   "):rep(eval_indent))
      tldebug.write("eval fact: ", tostring(known), "\n")
      local fcts = real_eval_fact(self, known)
      if fcts then
         for _, k in ipairs(sorted_keys(fcts)) do
            local f = fcts[k]
            tldebug.write(("   "):rep(eval_indent), "=> ", tostring(f), "\n")
         end
      else
         tldebug.write(("   "):rep(eval_indent), "=> .\n")
      end
      tldebug.flush()
      eval_indent = eval_indent - 1
      return fcts
   end
end

function FactDatabase.new()
   local self = {
      db = {},
   }
   setmetatable(self, { __index = FactDatabase })
   return self
end

function FactDatabase:set_truthy(w)
   self.db[w] = FACT_TRUTHY
end

function FactDatabase:set_is(w, var, typ)
   self.db[w] = IsFact({ var = var, typ = typ, w = w })
end

function FactDatabase:set_eq(w, var, typ)
   self.db[w] = EqFact({ var = var, typ = typ, w = w })
end

function FactDatabase:set_or(w, e1, e2)
   self.db[w] = OrFact({ f1 = self.db[e1] or FACT_TRUTHY, f2 = self.db[e2] or FACT_TRUTHY, w = w })
end

function FactDatabase:set_not(w, e1)
   self.db[w] = facts.facts_not(w, self.db[e1])
end

function FactDatabase:set_and(w, e1, e2)
   self.db[w] = facts.facts_and(w, self.db[e1], self.db[e2])
end

function FactDatabase:set_from(w, from)
   if from then
      self.db[w] = self.db[from]
   end
end

function FactDatabase:unset(w)
   self.db[w] = nil
end

function FactDatabase:get(w)
   return self.db[w]
end

return facts

end

-- module teal.gen.c_ffi from teal/gen/c_ffi.lua
package.preload["teal.gen.c_ffi"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local utf8 = _tl_compat and _tl_compat.utf8 or utf8
local types = require("teal.types")






local a_type = types.a_type
local util = require("teal.util")

local c_ffi = { CType = {}, Symbol = {}, State = {} }













































local function record_type(w, name)
   return a_type(w, "record", { declname = name, fields = {}, field_order = {} })
end

local function tuple(w, members, variadic)
   return a_type(w, "tuple", { tuple = members, is_va = variadic })
end

function c_ffi.new(w)
   local ffi = record_type(w, "ffi")
   local namespace = record_type(w, "C")
   local cdef = types.a_function(w, {
      min_arity = 1,
      args = tuple(w, { a_type(w, "string", {}) }),
      rets = tuple(w, {}),
   })
   ffi.fields = { C = namespace, cdef = cdef }
   ffi.field_order = { "C", "cdef" }
   return {
      ffi = ffi, namespace = namespace, cdef = cdef,
      symbols = {}, aliases = {}, pointers = {}, tags = {}, declarations = {},
   }
end

local escapes = {
   a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
   ["\\"] = "\\", ["'"] = "'", ['"'] = '"',
}


function c_ffi.decode_string(token)
   local opening = token:match("^%[=*%[")
   if opening then
      local text = token:sub(#opening + 1, -#opening - 1)
      text = text:gsub("\r\n", "\n"):gsub("\n\r", "\n"):gsub("\r", "\n")
      return (text:gsub("^\n", ""))
   end

   local text = token:sub(2, -2)
   local parts = {}
   local pos = 1
   while pos <= #text do
      local slash = text:find("\\", pos, true)
      if not slash then
         table.insert(parts, text:sub(pos))
         break
      end
      table.insert(parts, text:sub(pos, slash - 1))
      local c = text:sub(slash + 1, slash + 1)
      pos = slash + 2
      if escapes[c] then
         table.insert(parts, escapes[c])
      elseif c == "\n" or c == "\r" then
         local following = text:sub(pos, pos)
         if (following == "\n" or following == "\r") and following ~= c then pos = pos + 1 end
         table.insert(parts, "\n")
      elseif c == "z" then
         pos = text:find("%S", pos) or (#text + 1)
      elseif c == "u" then
         local hex = text:match("^%{(%x+)%}", pos)
         local codepoint = hex and tonumber(hex, 16)
         if not codepoint or codepoint > 0x10ffff then return nil, "invalid Unicode string escape" end
         table.insert(parts, utf8.char(codepoint))
         pos = pos + #hex + 2
      elseif c == "x" then
         local hex = text:match("^%x%x", pos)
         if not hex then return nil, "invalid hexadecimal string escape" end
         table.insert(parts, string.char(tonumber(hex, 16)))
         pos = pos + 2
      else
         local decimal = text:match("^%d%d?%d?", slash + 1)
         local byte = decimal and tonumber(decimal)
         if not byte or byte > 255 then return nil, "unsupported string escape" end
         table.insert(parts, string.char(byte))
         pos = slash + 1 + #decimal
      end
   end
   return table.concat(parts)
end

local failure_tag = {}
local function fail(message)
   error({ failure_tag, message }, 0)
end

local function tokenize(source)
   local tokens = {}
   local pos = 1
   while pos <= #source do
      local space = source:match("^%s+", pos)
      local start = source:sub(pos, pos + 1)
      if space then
         pos = pos + #space
      elseif start == "//" then
         pos = source:find("\n", pos + 2, true) or (#source + 1)
      elseif start == "/*" then
         local close = source:find("*/", pos + 2, true)
         if not close then fail("unterminated C comment") end
         pos = close + 2
      else
         local token = source:match("^[a-zA-Z_][a-zA-Z_0-9]*", pos) or
         source:match("^%.%.%.", pos) or source:match("^[*(),;]", pos)
         if not token then
            fail("unexpected character " .. string.format("%q", source:sub(pos, pos)))
         end
         table.insert(tokens, token)
         pos = pos + #token
      end
   end
   return tokens
end

local integer_spellings = {
   ["char"] = "char",
   ["signed char"] = "signed char",
   ["unsigned char"] = "unsigned char",
   ["short"] = "short",
   ["short int"] = "short",
   ["signed short"] = "short",
   ["signed short int"] = "short",
   ["unsigned short"] = "unsigned short",
   ["unsigned short int"] = "unsigned short",
   ["int"] = "int",
   ["signed"] = "int",
   ["signed int"] = "int",
   ["unsigned"] = "unsigned int",
   ["unsigned int"] = "unsigned int",
   ["long"] = "long",
   ["long int"] = "long",
   ["signed long"] = "long",
   ["signed long int"] = "long",
   ["unsigned long"] = "unsigned long",
   ["unsigned long int"] = "unsigned long",
   ["long long"] = "long long",
   ["long long int"] = "long long",
   ["signed long long"] = "long long",
   ["signed long long int"] = "long long",
   ["unsigned long long"] = "unsigned long long",
   ["unsigned long long int"] = "unsigned long long",
}
for _, name in ipairs({ "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
   "int8_t", "uint8_t", "int16_t", "uint16_t",
   "int32_t", "uint32_t", "int64_t", "uint64_t", }) do
   integer_spellings[name] = name
end

local reserved = {}
for name in ("auto break case char const continue default do double else enum extern float for goto if inline " ..
   "int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile " ..
   "while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local " ..
   "_Nonnull _Nullable alignas alignof bool constexpr false nullptr static_assert thread_local true typeof " ..
   "typeof_unqual NULL main"):gmatch("%S+") do
   reserved[name] = true
end

local function identifier(name)
   return name and name:match("^[a-zA-Z_][a-zA-Z_0-9]*$") ~= nil and
   not reserved[name] and not name:match("^tl_native_")
end

local function parse_type(aliases, words)
   local base = {}
   local is_const = false
   local is_pointer = false
   local nullability
   for _, word in ipairs(words) do
      if word == "*" and not is_pointer then
         is_pointer = true
      elseif (word == "_Nullable" or word == "_Nonnull") and not nullability then
         nullability = word
      elseif word == "const" and not is_pointer and not is_const then
         is_const = true
      elseif is_pointer and (word == "const" or word == "restrict") then

      elseif not is_pointer then
         table.insert(base, word)
      else
         return nil
      end
   end

   local name = table.concat(base, " ")
   local integer = integer_spellings[name]
   local kind
   local spelling, tag
   local aliased = aliases[name]
   if aliased then
      if aliased.pointer then
         if is_pointer or is_const then return nil end
         local copy = util.shallow_copy_table(aliased)
         copy.nullability = nullability or copy.nullability
         copy.spelling = name
         return copy
      end
      kind, spelling, tag = aliased.kind, aliased.spelling, aliased.tag
   elseif integer then
      kind, spelling = "integer", integer
   elseif name == "double" or name == "float" then
      kind, spelling = "number", name
   elseif name == "_Bool" or name == "bool" then
      kind, spelling = "boolean", "_Bool"
   elseif name == "void" then
      kind, spelling = "void", name
   elseif #base == 2 and (base[1] == "struct" or base[1] == "union") and identifier(base[2]) then
      kind, spelling, tag = "tag", name, name
   else
      return nil
   end

   if is_pointer then
      local pointer = (is_const and "const " or "") .. spelling .. " *"
      return {
         kind = is_const and spelling == "char" and "string" or "pointer",
         spelling = pointer,
         pointer = pointer,
         nullability = nullability,
         tag = tag,
         mutable_char = not is_const and spelling == "char",
      }
   elseif not nullability and not (is_const and kind == "void") then
      return { kind = kind, spelling = (is_const and "const " or "") .. spelling, tag = tag }
   end
end

local function declared_type(aliases, words, needs_name)
   local text = table.concat(words, " ")
   if not needs_name then
      local t = parse_type(aliases, words)
      if t then return t, nil end
   end
   local name = table.remove(words)
   local t = identifier(name) and parse_type(aliases, words)
   if not t then fail("unsupported C declarator '" .. text .. "'") end
   return t, name
end

local function parse_declarations(state, source)
   local tokens = tokenize(source)
   local aliases = util.shallow_copy_table(state.aliases)
   local symbols = {}
   local names = {}
   local i = 1

   local function consume(token)
      if tokens[i] ~= token then
         fail("expected '" .. token .. "' before '" .. (tokens[i] or "end of declaration") .. "'")
      end
      i = i + 1
   end

   local function words_until(delimiters)
      local words = {}
      while tokens[i] and not delimiters[tokens[i]] do
         table.insert(words, tokens[i])
         i = i + 1
      end
      return words
   end

   while tokens[i] do
      local is_extern = tokens[i] == "extern"
      local is_typedef = tokens[i] == "typedef"
      if is_extern or is_typedef then i = i + 1 end
      local head = words_until({ ["("] = true, [";"] = true })
      local is_function = tokens[i] == "("
      local tag = not is_function and not is_typedef and not is_extern and parse_type(aliases, head)
      if tag and tag.kind == "tag" then
         table.insert(symbols, { result = tag })
         consume(";")
      else
         local t, name = declared_type(aliases, head, true)
         if names[name] or state.symbols[name] or integer_spellings[name] then
            fail("duplicate or reserved C name '" .. name .. "'")
         end
         names[name] = true
         local symbol = { name = name, result = t, typedef = is_typedef }
         if is_function then
            if is_typedef or t.kind == "tag" then fail("unsupported C function declaration for '" .. name .. "'") end
            consume("(")
            symbol.params = {}
            local spellings = {}
            if tokens[i] == "void" and tokens[i + 1] == ")" then i = i + 1 end
            if tokens[i] ~= ")" then
               while true do
                  if tokens[i] == "..." then
                     if #symbol.params == 0 then fail("a variadic C function needs a fixed parameter") end
                     symbol.variadic = true
                     table.insert(spellings, "...")
                     i = i + 1
                     break
                  end
                  local param = declared_type(aliases, words_until({ [","] = true, [")"] = true }), false)
                  if param.kind == "tag" or param.kind == "void" then
                     fail("unsupported parameter type '" .. param.spelling .. "' for '" .. name .. "'")
                  end
                  table.insert(symbol.params, param)
                  table.insert(spellings, param.spelling)
                  if tokens[i] ~= "," then break end
                  consume(",")
               end
            end
            consume(")")
            local args = #spellings > 0 and table.concat(spellings, ", ") or "void"
            symbol.declaration = t.spelling .. " " .. name .. "(" .. args .. ");"
         elseif is_typedef then
            aliases[name] = t
            symbol.declaration = "typedef " .. t.spelling .. " " .. name .. ";"
         elseif is_extern and t.kind ~= "void" and t.kind ~= "tag" then
            symbol.declaration = "extern " .. t.spelling .. " " .. name .. ";"
         else
            fail("expected a function prototype, typedef, or extern object declaration for '" .. name .. "'")
         end
         consume(";")
         table.insert(symbols, symbol)
      end
   end
   if #symbols == 0 then fail("expected at least one C declaration") end
   return symbols, aliases
end

local function teal_type(state, w, c, output)
   local t
   if c.kind == "pointer" and not (output and c.mutable_char) then
      t = state.pointers[c.pointer]
      if not t then
         local pointer = record_type(w, c.pointer)
         pointer.is_userdata = true
         pointer.native_pointer = c.pointer
         state.pointers[c.pointer] = pointer
         t = pointer
      end
   elseif c.kind == "string" or (output and c.mutable_char) then
      t = a_type(w, "string", {})
   elseif c.kind == "integer" or c.kind == "number" or c.kind == "boolean" then
      t = a_type(w, c.kind, {})
   end
   if t and c.pointer and (c.nullability == "_Nullable" or (output and c.nullability ~= "_Nonnull")) then
      t = types.unite(w, { t, a_type(w, "nil", {}) }, true, false)
   end
   return t
end

local function add_tag(state, c)
   if c.tag and not state.tags[c.tag] then
      state.tags[c.tag] = true
      table.insert(state.declarations, c.tag .. ";")
   end
end

function c_ffi.declare(state, w, source)
   local ok, result, aliases = pcall(parse_declarations, state, source)
   if not ok then
      local failure = result
      if type(failure) == "table" and failure[1] == failure_tag then return false, failure[2] end
      error(result, 0)
   end

   state.aliases = aliases
   for _, symbol in ipairs(result) do
      local c = symbol.result
      add_tag(state, c)
      if symbol.name then
         local t
         if symbol.typedef then
            local def = teal_type(state, w, c)
            if def then t = a_type(w, "typedecl", { def = def, closed = true }) end
         elseif symbol.params then
            local args = {}
            for _, param in ipairs(symbol.params) do
               add_tag(state, param)
               table.insert(args, teal_type(state, w, param))
            end
            if symbol.variadic then
               table.insert(args, types.unite(w, {
                  a_type(w, "number", {}), a_type(w, "boolean", {}),
                  a_type(w, "string", {}), a_type(w, "nil", {}),
               }, true, false))
            end
            local ret = teal_type(state, w, c, true)
            t = types.a_function(w, {
               min_arity = #symbol.params, args = tuple(w, args, symbol.variadic),
               rets = tuple(w, ret and { ret } or {}),
            })
         else
            t = teal_type(state, w, c, true)
         end
         state.symbols[symbol.name] = symbol
         if t then
            state.namespace.fields[symbol.name] = t
            table.insert(state.namespace.field_order, symbol.name)
         end
         table.insert(state.declarations, symbol.declaration)
      end
   end
   return true
end

return c_ffi

end

-- module teal.gen.c_generator from teal/gen/c_generator.lua
package.preload["teal.gen.c_generator"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table

local ffi = require("teal.gen.c_ffi")


local types = require("teal.types")


local generator = {}




































local integer = { kind = "integer", ctype = "int64_t" }
local number = { kind = "number", ctype = "double" }
local boolean = { kind = "boolean", ctype = "_Bool" }
local string_type = { kind = "string", ctype = "const char *" }
local nil_type = { kind = "nil", ctype = "void *", nullable = true }
local void = { kind = "void", ctype = "void" }

local failure_tag = {}
local function fail(node, message)
   local position = ("%s:%d:%d"):format(node.f or "<input>", node.y or 1, node.x or 1)
   error({ failure_tag, position .. ": C target: " .. message }, 0)
end

local function resolve(t)
   if not (t.typename == "nominal" or t.typename == "typedecl") then return t end
   local seen = {}
   while t.typename == "nominal" or t.typename == "typedecl" do
      if seen[t] then return nil end
      seen[t] = true
      if t.typename == "nominal" then
         t = t.resolved or (t.found and t.found.def)
      else
         t = t.def
      end
   end
   return t
end

local function representation(t)
   t = resolve(t)
   if not t then return nil end
   if t.typename == "tuple" then
      if t.is_va or #t.tuple > 1 then return nil end
      if #t.tuple == 0 then return nil_type end
      return representation(t.tuple[1])
   elseif t.typename == "union" then
      local value
      local nullable = false
      for _, member in ipairs(t.types) do
         local r = representation(member)
         if not r then return nil end
         if r.kind == "nil" then
            nullable = true
         elseif not value or value.ctype == r.ctype then
            value = r
            nullable = nullable or r.nullable
         else
            return nil
         end
      end
      if not value then return nil_type end
      if nullable then
         if value.kind ~= "string" and value.kind ~= "pointer" then return nil end
         return { kind = value.kind, ctype = value.ctype, nullable = true }
      end
      return value
   elseif t.typename == "record" and t.native_pointer then
      return { kind = "pointer", ctype = t.native_pointer }
   end
   if t.typename == "integer" then return integer end
   if t.typename == "number" then return number end
   if t.typename == "boolean" then return boolean end
   if t.typename == "string" or t.typename == "enum" then return string_type end
   if t.typename == "nil" then return nil_type end
end

local function repr(node, t)
   t = t or node.native_type
   local r = representation(t)
   if not r then fail(node, "unsupported value type " .. (t and types.show_type(t) or node.kind)) end
   return r
end

local function emit(s, line)
   table.insert(s.out, ("   "):rep(s.indent) .. line)
end

local function fresh(s)
   s.next_id = s.next_id + 1
   return "tl_native_" .. tostring(s.next_id)
end

local function lookup(s, name)
   for i = #s.scopes, 1, -1 do
      local binding = s.scopes[i][name]
      if binding then return binding end
   end
end

local function c_string(node)
   local value, err = ffi.decode_string(node.tk)
   if not value then fail(node, err) end
   if value:find("\0", 1, true) then
      fail(node, "strings containing NUL bytes are unsupported")
   end
   local parts = { '"' }
   for i = 1, #value do
      local byte = value:byte(i)
      if byte >= 32 and byte <= 126 and byte ~= 34 and byte ~= 92 and byte ~= 63 then
         table.insert(parts, string.char(byte))
      else
         table.insert(parts, ("\\%03o"):format(byte))
      end
   end
   table.insert(parts, '"')
   return table.concat(parts)
end

local helpers = {
   int = [[
#define tl_native_int(type, value) __extension__ ({ \
   type tl_native_converted; \
   if (__builtin_add_overflow((value), 0, &tl_native_converted)) __builtin_trap(); \
   tl_native_converted; \
})
]],
   idiv = [[
static int64_t tl_native_idiv(int64_t a, int64_t b) {
   if (b == 0) __builtin_trap();
   if (b == -1) return (int64_t)(0 - (uint64_t)a);
   int64_t quotient = a / b;
   if (a % b != 0 && (a < 0) != (b < 0)) --quotient;
   return quotient;
}
]],
   imod = [[
static int64_t tl_native_imod(int64_t a, int64_t b) {
   if (b == 0) __builtin_trap();
   if (b == -1) return 0;
   int64_t remainder = a % b;
   if (remainder != 0 && (remainder < 0) != (b < 0)) remainder += b;
   return remainder;
}
]],
   fmod = [[
static double tl_native_fmod(double a, double b) {
   double remainder = __builtin_fmod(a, b);
   if ((remainder > 0 && b < 0) || (remainder < 0 && b > 0)) remainder += b;
   return remainder;
}
]],
   shift = [[
static int64_t tl_native_shift(uint64_t value, int64_t amount, _Bool left) {
   uint64_t count = (uint64_t)amount;
   if (amount < 0) {
      count = 0 - count;
      left = !left;
   }
   if (count >= 64) return 0;
   return (int64_t)(left ? value << count : value >> count);
}
]],
   compare = [[
/* 2 denotes an unordered comparison with NaN. */
static int tl_native_compare(int64_t a, double b) {
   if (__builtin_isnan(b)) return 2;
   if (b >= 0x1p63) return -1;
   if (b < -0x1p63) return 1;
   int64_t integral = (int64_t)b;
   if (a != integral) return a < integral ? -1 : 1;
   return ((double)integral > b) - ((double)integral < b);
}
]],
}

local function int_conversion(s, ctype, value)
   s.helpers.int = true
   return "tl_native_int(" .. ctype .. ", " .. value .. ")"
end

local function ffi_result(s, typ, value)
   if typ.kind == "void" then return "((void)(" .. value .. "), (void *)0)" end
   if typ.kind == "integer" then return int_conversion(s, integer.ctype, value) end
   if typ.kind == "number" then return "(double)(" .. value .. ")" end
   if typ.mutable_char then return "(const char *)(" .. value .. ")" end
   return value
end

local function is_ffi_reference(s, node)
   if not node.native_type then return false end
   local t = types.untuple(node.native_type)
   if t.typeid ~= s.ffi.ffi.typeid and t.typeid ~= s.ffi.namespace.typeid then return false end
   if node.kind == "variable" then
      local b = lookup(s, node.tk)
      return (b and b.virtual) or (not b and node.tk == "C" and t.typeid == s.ffi.namespace.typeid)
   elseif node.kind == "paren" then
      return is_ffi_reference(s, node.e1)
   elseif node.kind == "op" then
      if node.op.op == "." then return is_ffi_reference(s, node.e1) end
      return t.typeid == s.ffi.ffi.typeid and node.op.op == "@funcall" and node.e1.kind == "variable" and
      node.e1.tk == "require" and #node.e2 == 1 and node.e2[1].conststr == "ffi"
   end
   return false
end

local function foreign_symbol(s, node)
   if node.kind == "op" and node.op.op == "." and node.e1.native_type and
      types.untuple(node.e1.native_type).typeid == s.ffi.namespace.typeid and is_ffi_reference(s, node.e1) then
      return s.ffi.symbols[node.e2.tk]
   end
end

local expression

local function returns_no_values(node)
   local t = node.native_type
   return t.typename == "tuple" and #t.tuple == 0 and not t.is_va
end

local function vararg(s, node, value)
   local r = repr(node)
   if r.kind == "integer" then return int_conversion(s, "int", value) end
   if r.kind == "boolean" then return "(int)(" .. value .. ")" end
   return value
end

local function call(s, node)
   local callee = node.e1
   while callee.kind == "paren" do callee = callee.e1 end
   local foreign = foreign_symbol(s, callee)
   local binding = callee.kind == "variable" and lookup(s, callee.tk)
   if not (foreign and foreign.params) and not (binding and binding.params) then
      fail(node, "only direct calls to local functions and declared C functions are supported")
   end

   local params = {}
   local temps = {}
   for i, argument in ipairs(node.e2) do
      local value = expression(s, argument)
      if i == #node.e2 and returns_no_values(argument) then
         table.insert(temps, "(void)(" .. value .. ");")
         break
      end
      local fixed = foreign and foreign.params[i]
      local r = repr(argument)
      if fixed and fixed.kind == "integer" then
         value = int_conversion(s, fixed.spelling:gsub("^const ", ""), value)
         r = { kind = "integer", ctype = fixed.spelling }
      elseif foreign and not fixed then
         value = vararg(s, argument, value)
         if r.kind == "integer" or r.kind == "boolean" then r = { kind = "integer", ctype = "int" } end
      end


      if argument.kind ~= "string" and argument.kind ~= "integer" and argument.kind ~= "number" and
         argument.kind ~= "boolean" and argument.kind ~= "nil" then
         local tmp = fresh(s)
         table.insert(temps, r.ctype .. " " .. tmp .. " = " .. value .. ";")
         value = tmp
      end
      table.insert(params, value)
   end

   if binding then
      for i = #params + 1, #binding.params do
         if not binding.params[i].nullable then fail(node, "missing argument " .. tostring(i)) end
         params[i] = "NULL"
      end
   end
   local name = foreign and foreign.name or binding.name
   local value = name .. "(" .. table.concat(params, ", ") .. ")"
   if foreign then
      value = ffi_result(s, foreign.result, value)
   elseif representation(node.native_type) == nil_type then
      value = "((void)(" .. value .. "), (void *)0)"
   end
   if #temps > 0 then
      value = "__extension__ ({ " .. table.concat(temps, " ") .. " " .. value .. "; })"
   end
   return value
end

local function truth(r, value)
   if r.kind == "boolean" then return value end
   if r.kind == "nil" then return "((void)(" .. value .. "), 0)" end
   if r.nullable then return value .. " != NULL" end
   return "((void)(" .. value .. "), 1)"
end

local function condition(s, node)
   return truth(repr(node), expression(s, node))
end

local function numeric(r)
   return r.kind == "integer" or r.kind == "number"
end

local comparison_ops = {
   ["=="] = "==", ["~="] = "!=", ["<"] = "<", [">"] = ">", ["<="] = "<=", [">="] = ">=",
}
local reversed_comparison = { ["<"] = ">", [">"] = "<", ["<="] = ">=", [">="] = "<=" }
local function compare(s, node, op, a, b, left, right)
   local equality = op == "==" or op == "!="
   if a.kind == "string" and b.kind == "string" then
      local compare_strings = "__builtin_strcmp(" .. left .. ", " .. right .. ")"
      if equality then
         local same = "(" .. left .. " == " .. right .. " || (" .. left .. " && " .. right .. " && " .. compare_strings .. " == 0))"
         return op == "!=" and "!" .. same or same
      end
      return compare_strings .. " " .. op .. " 0"
   elseif numeric(a) and numeric(b) and a.kind ~= b.kind then
      s.helpers.compare = true
      if a.kind == "number" then
         left, right = right, left
         op = reversed_comparison[op] or op
      end
      local tmp = fresh(s)
      local test = tmp .. " " .. op .. " 0"
      if not equality then test = tmp .. " != 2 && " .. test end
      return "__extension__ ({ int " .. tmp .. " = tl_native_compare(" .. left .. ", " .. right .. "); " .. test .. "; })"
   elseif numeric(a) and numeric(b) or (a.kind == "boolean" and b.kind == "boolean") then
      return left .. " " .. op .. " " .. right
   elseif equality then
      local ap = a.kind == "pointer" or a.kind == "nil" or a.kind == "string"
      local bp = b.kind == "pointer" or b.kind == "nil" or b.kind == "string"
      if ap and bp then return "(const void *)" .. left .. " " .. op .. " (const void *)" .. right end
      return op == "==" and "0" or "1"
   end
   fail(node, "unsupported comparison '" .. node.op.op .. "'")
end

local arithmetic = { ["+"] = true, ["-"] = true, ["*"] = true }
local bitwise = { ["&"] = true, ["|"] = true, ["~"] = true }
local function binary(s, node, op)
   local a, b = repr(node.e1), repr(node.e2)
   local left, right = fresh(s), fresh(s)
   local operands = a.ctype .. " " .. left .. " __attribute__((unused)) = " .. expression(s, node.e1) .. "; " ..
   b.ctype .. " " .. right .. " __attribute__((unused)) = " .. expression(s, node.e2) .. "; "
   local result
   if comparison_ops[op] then
      result = compare(s, node, comparison_ops[op], a, b, left, right)
   elseif arithmetic[op] and numeric(a) and numeric(b) then
      if a.kind == "integer" and b.kind == "integer" then
         result = "(int64_t)((uint64_t)" .. left .. " " .. op .. " (uint64_t)" .. right .. ")"
      else
         result = left .. " " .. op .. " " .. right
      end
   elseif (op == "/" or op == "//" or op == "%" or op == "^") and numeric(a) and numeric(b) then
      local ints = a.kind == "integer" and b.kind == "integer"
      if (op == "//" and ints) or op == "%" then
         local name = op == "//" and "idiv" or (ints and "imod" or "fmod")
         s.helpers[name] = true
         result = "tl_native_" .. name .. "(" .. left .. ", " .. right .. ")"
      elseif op == "^" then
         result = "__builtin_pow(" .. left .. ", " .. right .. ")"
      else
         result = "(double)" .. left .. " / (double)" .. right
         if op == "//" then result = "__builtin_floor(" .. result .. ")" end
      end
   elseif (bitwise[op] or op == "<<" or op == ">>") and a.kind == "integer" and b.kind == "integer" then
      if bitwise[op] then
         result = "(int64_t)((uint64_t)" .. left .. " " .. (op == "~" and "^" or op) .. " (uint64_t)" .. right .. ")"
      else
         s.helpers.shift = true
         result = "tl_native_shift((uint64_t)" .. left .. ", " .. right .. ", " .. (op == "<<" and "1" or "0") .. ")"
      end
   else
      fail(node, "unsupported binary operator '" .. op .. "'")
   end
   return "__extension__ ({ " .. operands .. result .. "; })"
end

local function operator(s, node)
   local op = node.op.op
   if op == "@funcall" then return call(s, node) end
   if op == "." then
      local foreign = foreign_symbol(s, node)
      if foreign and not foreign.params and not foreign.typedef then
         return ffi_result(s, foreign.result, foreign.name)
      end
      fail(node, "only declared C objects can be read through a field access")
   end
   if op == "as" then
      local r = repr(node)
      return "(" .. r.ctype .. ")(" .. expression(s, node.e1) .. ")"
   end

   local a = repr(node.e1)
   if op == "is" then
      local tested = resolve(node.e2.casttype)
      if not tested or tested.typename == "union" or tested.typename == "enum" then
         fail(node, "union and enum type tests are unsupported")
      end
      local b = repr(node.e2, tested)
      local value = expression(s, node.e1)
      if a.nullable and a.kind ~= "nil" and (b.kind == "nil" or a.ctype == b.ctype) then
         return value .. (b.kind == "nil" and " == " or " != ") .. "NULL"
      end
      local is_type = a.ctype == b.ctype or (a.kind == "integer" and b.kind == "number")
      return "((void)(" .. value .. "), " .. (is_type and "1" or "0") .. ")"
   elseif op == "and" or op == "or" then
      local value = expression(s, node.e1)
      local r = repr(node)
      local first = resolve(types.untuple(node.e1.native_type))
      local known_truth
      if first.typename == "boolean" then
         known_truth = first.literal
      elseif a.kind == "nil" then
         known_truth = false
      elseif not a.nullable then
         known_truth = true
      end
      if known_truth ~= nil then
         if (op == "or") == known_truth then return "(" .. r.ctype .. ")(" .. value .. ")" end
         return "((void)(" .. value .. "), (" .. r.ctype .. ")(" .. expression(s, node.e2) .. "))"
      end
      local tmp = fresh(s)
      local right = "(" .. r.ctype .. ")(" .. expression(s, node.e2) .. ")"
      local left = "(" .. r.ctype .. ")" .. tmp
      return "__extension__ ({ " .. a.ctype .. " " .. tmp .. " = " .. value .. "; " ..
      truth(a, tmp) .. " ? " .. (op == "and" and right or left) .. " : " .. (op == "and" and left or right) .. "; })"
   elseif node.op.arity == 1 then
      local value = expression(s, node.e1)
      if op == "not" then return "!(" .. truth(a, value) .. ")" end
      if op == "#" and a.kind == "string" and not a.nullable then return "(int64_t)__builtin_strlen(" .. value .. ")" end
      if op == "-" and a.kind == "integer" then return "(int64_t)(0 - (uint64_t)(" .. value .. "))" end
      if op == "-" and a.kind == "number" then return "-(" .. value .. ")" end
      if op == "~" and a.kind == "integer" then return "(int64_t)(~(uint64_t)(" .. value .. "))" end
      fail(node, "unsupported unary operator '" .. op .. "'")
   end
   return binary(s, node, op)
end

expression = function(s, node)
   if node.kind == "string" then
      return c_string(node)
   elseif node.kind == "integer" then
      local lexeme = node.tk
      if lexeme:match("^%d+$") then
         lexeme = lexeme:gsub("^0+", "")
         if lexeme == "" then lexeme = "0" end
         if #lexeme > 20 or (#lexeme == 20 and lexeme > "18446744073709551615") then
            fail(node, "integer literal exceeds 64 bits")
         end
      elseif lexeme:match("^0[xX]") then
         local digits = lexeme:sub(3):gsub("^0+", "")
         if #digits > 16 then fail(node, "integer literal exceeds 64 bits") end
         lexeme = "0x" .. (#digits > 0 and digits or "0")
      end
      return "((int64_t)" .. lexeme .. "ULL)"
   elseif node.kind == "number" then
      local lexeme = node.tk
      if lexeme:match("^0[xX]") and not lexeme:match("[pP]") then lexeme = lexeme .. "p0" end
      return "((double)" .. lexeme .. ")"
   elseif node.kind == "boolean" then
      return node.tk == "true" and "((_Bool)1)" or "((_Bool)0)"
   elseif node.kind == "nil" then
      return "NULL"
   elseif node.kind == "variable" then
      local b = lookup(s, node.tk)
      if b and not b.params and not b.virtual then return b.name end
      fail(node, "unsupported value '" .. node.tk .. "'")
   elseif node.kind == "paren" then
      return "(" .. expression(s, node.e1) .. ")"
   elseif node.kind == "op" then
      return operator(s, node)
   end
   fail(node, "unsupported expression '" .. node.kind .. "'")
end

local statement

local function statements(s, body)
   for _, node in ipairs(body) do statement(s, node) end
end

local function block(s, header, body)
   emit(s, header .. "{")
   s.indent = s.indent + 1
   table.insert(s.scopes, {})
   statements(s, body)
   table.remove(s.scopes)
   s.indent = s.indent - 1
   emit(s, "}")
end

local function rhs(s, exps, count)
   local values = {}
   for i, e in ipairs(exps or {}) do
      local value = expression(s, e)
      if i <= count then
         local tmp = fresh(s)
         emit(s, repr(e).ctype .. " " .. tmp .. " = " .. value .. ";")
         values[i] = tmp
      else
         emit(s, "(void)(" .. value .. ");")
      end
   end
   return values
end

local function local_declaration(s, node, top_level)
   if #node.vars == 1 and node.exps and #node.exps == 1 and is_ffi_reference(s, node.exps[1]) then
      s.scopes[#s.scopes][node.vars[1].tk] = { virtual = true }
      return
   end
   local values = rhs(s, node.exps, #node.vars)
   for i, var in ipairs(node.vars) do
      local r = repr(var)
      local name = fresh(s)
      local declaration = r.ctype .. " " .. name .. " __attribute__((unused))"
      local value = values[i] or "NULL"
      if top_level then
         table.insert(s.globals, "static " .. declaration .. ";")
         emit(s, name .. " = " .. value .. ";")
      else
         emit(s, declaration .. " = " .. value .. ";")
      end
      s.scopes[#s.scopes][var.tk] = { name = name }
   end
end

local function local_function(s, node, top_level)
   if not top_level then fail(node, "local functions must be declared at the top level") end
   if (node.typeargs and #node.typeargs > 0) or node.rets.is_va or #node.rets.tuple > 1 then
      fail(node, "generic functions and multiple return values are unsupported")
   end

   local name = fresh(s)
   local binding = { name = name, params = {} }
   s.scopes[#s.scopes][node.name.tk] = binding
   local ret = node.native_return_type and repr(node, node.native_return_type) or void
   local params = {}
   local scope = {}
   for i, argument in ipairs(node.args) do
      if argument.tk == "..." then fail(argument, "variadic Teal functions are unsupported") end
      local r = repr(argument)
      local param = fresh(s)
      binding.params[i] = r
      params[i] = r.ctype .. " " .. param .. " __attribute__((unused))"
      scope[argument.tk] = { name = param }
   end

   local saved = s.out
   s.out, s.indent, s.return_type = s.functions, 0, ret
   emit(s, "static __attribute__((unused)) " .. ret.ctype .. " " .. name ..
   "(" .. (#params > 0 and table.concat(params, ", ") or "void") .. ") {")
   table.insert(s.scopes, scope)
   s.indent = 1
   statements(s, node.body)
   if ret.nullable then emit(s, "return NULL;") end
   table.remove(s.scopes)
   s.indent = 0
   emit(s, "}")
   emit(s, "")
   s.out, s.indent, s.return_type = saved, 1, nil
end

local function numeric_for(s, node)
   local r = repr(node.var)
   local start, limit, step, variable = fresh(s), fresh(s), fresh(s), fresh(s)
   emit(s, "{")
   s.indent = s.indent + 1
   emit(s, r.ctype .. " " .. start .. " = " .. expression(s, node.from) .. ";")
   emit(s, r.ctype .. " " .. limit .. " = " .. expression(s, node.to) .. ";")
   emit(s, r.ctype .. " " .. step .. " = " .. (node.step and expression(s, node.step) or "1") .. ";")
   emit(s, "if (" .. step .. " == 0) __builtin_trap();")
   emit(s, "while (" .. step .. " > 0 ? " .. start .. " <= " .. limit .. " : " .. start .. " >= " .. limit .. ") {")
   s.indent = s.indent + 1
   emit(s, r.ctype .. " " .. variable .. " __attribute__((unused)) = " .. start .. ";")
   table.insert(s.scopes, { [node.var.tk] = { name = variable } })
   statements(s, node.body)
   table.remove(s.scopes)
   if r.kind == "integer" then
      emit(s, "if (__builtin_add_overflow(" .. start .. ", " .. step .. ", &" .. start .. ")) break;")
   else
      emit(s, start .. " += " .. step .. ";")
   end
   s.indent = s.indent - 1
   emit(s, "}")
   s.indent = s.indent - 1
   emit(s, "}")
end

statement = function(s, node, top_level)
   if node.kind == "pragma" or node.kind == "local_type" or node.kind == "global_type" or
      node.kind == "local_macroexp" or node.native_cdef then
      return
   elseif node.kind == "local_declaration" then
      local_declaration(s, node, top_level)
   elseif node.kind == "assignment" then
      local values = rhs(s, node.exps, #node.vars)
      for i, var in ipairs(node.vars) do
         local binding = var.kind == "variable" and lookup(s, var.tk)
         if not binding or binding.virtual or binding.params then
            fail(var, "only local variables can be assigned")
         end
         emit(s, binding.name .. " = " .. (values[i] or "NULL") .. ";")
      end
   elseif node.kind == "local_function" then
      local_function(s, node, top_level)
   elseif node.kind == "if" then
      for i, branch in ipairs(node.if_blocks) do
         local header = i == 1 and "if " or "else "
         if branch.exp then
            if i > 1 then header = header .. "if " end
            header = header .. "(" .. condition(s, branch.exp) .. ") "
         end
         block(s, header, branch.body)
      end
   elseif node.kind == "while" then
      block(s, "while (" .. condition(s, node.exp) .. ") ", node.body)
   elseif node.kind == "repeat" then
      emit(s, "for (;;) {")
      s.indent = s.indent + 1
      table.insert(s.scopes, {})
      statements(s, node.body)
      emit(s, "if (" .. condition(s, node.exp) .. ") break;")
      table.remove(s.scopes)
      s.indent = s.indent - 1
      emit(s, "}")
   elseif node.kind == "fornum" then
      numeric_for(s, node)
   elseif node.kind == "do" then
      block(s, "", node.body)
   elseif node.kind == "break" then
      emit(s, "break;")
   elseif node.kind == "return" then
      local value = node.exps[1]
      if #node.exps > 1 then fail(node, "multiple return values are unsupported") end
      if not s.return_type then
         if value and returns_no_values(value) then
            emit(s, "(void)(" .. expression(s, value) .. ");")
            value = nil
         end
         if value and repr(value).kind ~= "integer" then fail(node, "the program exit status must be an integer") end
         emit(s, "return " .. (value and int_conversion(s, "int", expression(s, value)) or "0") .. ";")
      elseif s.return_type.kind == "void" then
         if value then emit(s, "(void)(" .. expression(s, value) .. ");") end
         emit(s, "return;")
      else
         emit(s, "return " .. (value and expression(s, value) or "NULL") .. ";")
      end
   elseif node.kind == "op" and node.op.op == "@funcall" then
      emit(s, "(void)(" .. expression(s, node) .. ");")
   else
      fail(node, "unsupported statement '" .. node.kind .. "'")
   end
end

local function generate(ast)
   local s = {
      ffi = ast.native_ffi, scopes = { {} }, globals = {}, functions = {},
      out = {}, indent = 1, next_id = 0, helpers = {},
   }
   for _, node in ipairs(ast) do statement(s, node, true) end

   local out = { "/* Generated by Teal's experimental C target. */", "#include <stddef.h>", "#include <stdint.h>", "" }
   for _, decl in ipairs(s.ffi.declarations) do table.insert(out, decl) end
   if #s.ffi.declarations > 0 then table.insert(out, "") end
   for _, name in ipairs({ "int", "idiv", "imod", "fmod", "shift", "compare" }) do
      if s.helpers[name] then table.insert(out, helpers[name]) end
   end
   for _, decl in ipairs(s.globals) do table.insert(out, decl) end
   if #s.globals > 0 then table.insert(out, "") end
   for _, line in ipairs(s.functions) do table.insert(out, line) end
   table.insert(out, "int main(void) {")
   for _, line in ipairs(s.out) do table.insert(out, line) end
   if not ast[#ast] or ast[#ast].kind ~= "return" then table.insert(out, "   return 0;") end
   table.insert(out, "}")
   return table.concat(out, "\n")
end

function generator.generate(ast)
   if not ast.native_checked then
      return nil, "the C target requires a Teal file successfully checked with target 'c' and '--#pragma strict on'"
   end
   local ok, result = pcall(generate, ast)
   if ok then return result, nil end
   local failure = result
   if type(failure) == "table" and failure[1] == failure_tag then return nil, failure[2] end
   error(result, 0)
end

return generator

end

-- module teal.gen.lua_compat from teal/gen/lua_compat.lua
package.preload["teal.gen.lua_compat"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG

local environment = require("teal.environment")



local parser = require("teal.parser")


local node_at = parser.node_at

local metamethods = require("teal.metamethods")
local unop_to_metamethod = metamethods.unop_to_metamethod
local binop_to_metamethod = metamethods.binop_to_metamethod

local traversal = require("teal.traversal")

local traverse_nodes = traversal.traverse_nodes

local util = require("teal.util")
local sorted_keys = util.sorted_keys

local types = require("teal.types")


local lua_compat = {}


local compat_code_cache = {}

local function add_compat_entries(program, used_set, gen_compat)
   if not next(used_set) or gen_compat == "off" then
      return
   end

   local tl_debug = TL_DEBUG
   TL_DEBUG = nil

   local used_list = sorted_keys(used_set)

   local compat_loaded = false

   local n = 1
   local function load_code(name, text)
      local code = compat_code_cache[name]
      if not code then
         code = parser.parse(text, "@<internal>.lua")
         compat_code_cache[name] = code
      end
      for _, c in ipairs(code) do
         table.insert(program, n, c)
         n = n + 1
      end
   end

   local function req(m)
      return (gen_compat == "optional") and
      "pcall(require, '" .. m .. "')" or
      "true, require('" .. m .. "')"
   end

   for _, name in ipairs(used_list) do
      if name == "table.unpack" then
         load_code(name, "local _tl_table_unpack = unpack or table.unpack")
      elseif name == "table.pack" then
         load_code(name, [[local _tl_table_pack = table.pack or function(...) return { n = select("#", ...), ... } end]])
      elseif name == "bit32" then
         load_code(name, "local bit32 = bit32; if not bit32 then local p, m = " .. req("bit32") .. "; if p then bit32 = m end")
      elseif name == "mt" then
         load_code(name, "local _tl_mt = function(m, s, a, b) return (getmetatable(s == 1 and a or b)[m](a, b) end")
      elseif name == "math.maxinteger" then
         load_code(name, "local _tl_math_maxinteger = math.maxinteger or math.pow(2,53)")
      elseif name == "math.mininteger" then
         load_code(name, "local _tl_math_mininteger = math.mininteger or -math.pow(2,53)")
      elseif name == "type" then
         load_code(name, "local type = type")
      else
         if not compat_loaded then
            load_code("compat", "local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = " .. req("compat53.module") .. "; if p then _tl_compat = m end")
            compat_loaded = true
         end
         load_code(name, (("local $NAME = _tl_compat and _tl_compat.$NAME or $NAME"):gsub("$NAME", name)))
      end
   end
   program.y = 1

   TL_DEBUG = tl_debug
end

local function convert_node_to_compat_call(node, mod_name, fn_name, e1, e2)
   node.op.op = "@funcall"
   node.op.arity = 2
   node.op.prec = 100
   node.e1 = node_at(node, { kind = "op", op = parser.operator(node, 2, ".") })
   node.e1.e1 = node_at(node, { kind = "identifier", tk = mod_name })
   node.e1.e2 = node_at(node, { kind = "identifier", tk = fn_name })
   node.e2 = node_at(node, { kind = "expression_list" })
   node.e2[1] = e1
   node.e2[2] = e2
end

local function convert_node_to_compat_mt_call(node, mt_name, which_self, e1, e2)
   node.op.op = "@funcall"
   node.op.arity = 2
   node.op.prec = 100
   node.e1 = node_at(node, { kind = "identifier", tk = "_tl_mt" })
   node.e2 = node_at(node, { kind = "expression_list" })
   node.e2[1] = node_at(node, { kind = "string", tk = "\"" .. mt_name .. "\"" })
   node.e2[2] = node_at(node, { kind = "integer", tk = tostring(which_self) })
   node.e2[3] = e1
   node.e2[4] = e2
end

local bit_operators = {
   ["&"] = "band",
   ["|"] = "bor",
   ["~"] = "bxor",
   [">>"] = "rshift",
   ["<<"] = "lshift",
}


local function shadow_control_var(node, control_var)
   if #node.body == 0 then
      return
   end
   local stmt = node_at(node, {
      kind = "local_declaration",
      vars = node_at(node, {
         kind = "variable_list",
         node_at(node, { kind = "variable", is_lvalue = true, tk = control_var }),
      }),
      exps = node_at(node, {
         kind = "expression_list",
         node_at(node, { kind = "variable", tk = control_var }),
      }),
   })
   table.insert(node.body, 1, stmt)
end

local function adjust_code(ast, needs_compat, gen_compat, gen_target)
   local visit = false

   local visit_node = {
      cbs = {},
   }
















   if gen_target < "5.5" or gen_target == "luajit" then
      visit = true
      local functionvisit = {
         after = function(_self, node, _children)
            local last_arg = node.args[#node.args]
            if last_arg and last_arg.tk == "..." and last_arg.name then



               local use_compat_pack = (gen_target == "5.1" or gen_target == "5.3" or gen_target == "luajit") and gen_compat ~= "off"

               local fnname
               if use_compat_pack then
                  needs_compat["table.pack"] = true
                  fnname = node_at(last_arg, {
                     kind = "variable",
                     tk = "_tl_table_pack",
                  })
               else
                  fnname = node_at(last_arg, {
                     kind = "op",
                     op = parser.operator(last_arg, 2, "."),
                     e1 = node_at(last_arg, { kind = "variable", tk = "table" }),
                     e2 = node_at(last_arg, { kind = "identifier", tk = "pack" }),
                  })
               end

               local stmt = node_at(last_arg, {
                  kind = "local_declaration",
                  vars = node_at(last_arg, {
                     kind = "variable_list",
                     node_at(last_arg, { kind = "variable", is_lvalue = true, tk = last_arg.name.tk }),
                  }),
                  exps = node_at(last_arg, {
                     kind = "expression_list",
                     node_at(last_arg, {
                        kind = "op",
                        op = parser.operator(last_arg, 2, "@funcall"),
                        e1 = fnname,
                        e2 = node_at(last_arg, { kind = "expression_list", node_at(last_arg, { kind = "...", tk = "..." }) }),
                     }),
                  }),
               })
               table.insert(node.body, 1, stmt)
            end
         end,
      }
      visit_node.cbs["function"] = functionvisit
      visit_node.cbs["global_function"] = functionvisit
      visit_node.cbs["record_function"] = functionvisit
      visit_node.cbs["local_function"] = functionvisit
   end

   if (gen_target == "5.1" or gen_target == "5.3" or gen_target == "luajit") and gen_compat ~= "off" then
      visit = true
      visit_node.cbs["op"] = {
         after = function(_, node, _children)
            if node.op.op == "is" then
               local ct = node.e2.casttype
               while ct.typename == "nominal" and ct.resolved do
                  ct = ct.resolved
               end
               if ct.typename == "integer" then
                  needs_compat["math"] = true
               elseif ct.typename ~= "nil" then
                  needs_compat["type"] = true
               end
            elseif node.op.op == "." then
               if node.op.needs_compat then

                  if node.e1.kind == "variable" and node.e2.kind == "identifier" then
                     local key = node.e1.tk .. "." .. node.e2.tk
                     node.kind = "variable"
                     node.tk = "_tl_" .. node.e1.tk .. "_" .. node.e2.tk
                     needs_compat[key] = true
                  end
               end

            elseif node.op.op == "~" and node.op.arity == 1 and gen_target == "5.1" then
               if node.op.meta_on_operand then
                  needs_compat["mt"] = true
                  convert_node_to_compat_mt_call(node, unop_to_metamethod[node.op.op], 1, node.e1)
               else
                  needs_compat["bit32"] = true
                  convert_node_to_compat_call(node, "bit32", "bnot", node.e1)
               end
            elseif node.op.op == "//" and (gen_target == "5.1" or gen_target == "luajit") then
               if node.op.meta_on_operand then
                  needs_compat["mt"] = true
                  convert_node_to_compat_mt_call(node, "__idiv", node.op.meta_on_operand, node.e1, node.e2)
               else
                  local div = node_at(node, { kind = "op", op = parser.operator(node, 2, "/"), e1 = node.e1, e2 = node.e2 })
                  convert_node_to_compat_call(node, "math", "floor", div)
               end
            elseif bit_operators[node.op.op] and gen_target == "5.1" then
               if node.op.meta_on_operand then
                  needs_compat["mt"] = true
                  convert_node_to_compat_mt_call(node, binop_to_metamethod[node.op.op], node.op.meta_on_operand, node.e1, node.e2)
               else
                  needs_compat["bit32"] = true
                  convert_node_to_compat_call(node, "bit32", bit_operators[node.op.op], node.e1, node.e2)
               end
            end
         end,
      }
   end


   if gen_target == "5.4" or gen_target == "5.5" then
      visit = true
      visit_node.cbs["forin"] = {
         after = function(_, node, _children)
            if node.forin_modifies_control_var then
               shadow_control_var(node, node.vars[1].tk)
            end
         end,
      }
      visit_node.cbs["fornum"] = {
         after = function(_, node, _children)
            if node.fornum_modifies_control_var then
               shadow_control_var(node, node.var.tk)
            end
         end,
      }
   end

   if not visit then
      return
   end

   traverse_nodes(nil, ast, visit_node, {})

   add_compat_entries(ast, needs_compat, gen_compat)
end

function lua_compat.apply(result)
   if not (result and result.ast) then
      return
   end

   if result.compat_applied then
      return
   end
   result.compat_applied = true

   local gen_compat = result.env.opts.gen_compat or environment.DEFAULT_GEN_COMPAT
   local gen_target = result.env.opts.gen_target or environment.DEFAULT_GEN_TARGET

   if gen_target ~= "c" then
      adjust_code(result.ast, result.needs_compat, gen_compat, gen_target)
   end
end

return lua_compat

end

-- module teal.gen.lua_generator from teal/gen/lua_generator.lua
package.preload["teal.gen.lua_generator"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _tl_table_unpack = unpack or table.unpack; local type = type; local utf8 = _tl_compat and _tl_compat.utf8 or utf8






local targets = require("teal.gen.targets")


local types = require("teal.types")












local traversal = require("teal.traversal")



local lua_generator = { Options = {} }












local tight_op = {
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

local spaced_op = {
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

function lua_generator.generate(ast, gen_target, opts)
   local indent = 0

   opts = opts or lua_generator.default_opts







   local function increment_indent(_, node)
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

   local function add_string(out, s)
      table.insert(out, s)
      if string.find(s, "\n", 1, true) then
         for _nl in s:gmatch("\n") do
            out.h = out.h + 1
         end
      end
   end

   local function add_child(out, child, space, current_indent)
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
      table.insert(out, child)
      out.h = out.h + child.h
   end

   local function concat_output(out)
      for i, s in ipairs(out) do
         if type(s) == "table" then
            out[i] = concat_output(s)
         end
      end
      return table.concat(out)
   end

   local function first_output_character(out)
      for _, part in ipairs(out) do
         local first
         if type(part) == "table" then
            first = first_output_character(part)
         else
            first = part:match("^%s*(.)")
         end
         if first then
            return first
         end
      end
   end

   local function print_record_def(typ)
      local out = { "{" }
      local i = 0
      for fname, ftype in traversal.fields_of(typ) do
         if ftype.typename == "typedecl" then
            local def = ftype.def
            if def.typename == "generic" then
               def = def.t
            end
            if def.typename == "record" then
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

   local visit_node = {}

   local lua_54_attribute = {
      ["const"] = " <const>",
      ["close"] = " <close>",
      ["total"] = " <const>",
   }

   local function emit_exactly(_, node, _children)
      local out = { y = node.y, h = 0 }
      add_string(out, node.tk)
      return out
   end

   local emit_exactly_visitor_cbs = { after = emit_exactly }

   local emit_nothing_visitor_cbs = {
      after = function(_, node, _children)
         local out = { y = node.y, h = 0 }
         return out
      end,
   }

   local function starts_with_longstring(n)
      while n.e1 do n = n.e1 end
      return n.is_longstring
   end

   local function drop_initial_indentation(out)
      if not out then
         return
      end
      local first = out[1]
      if type(first) == "string" then
         if first:match("^ +$") then
            table.remove(out, 1)
            drop_initial_indentation(out)
         end
      else
         drop_initial_indentation(first)
      end
   end

   local function add_block(out, block_out, top_node)
      if not block_out then
         return
      end
      if block_out.y == top_node.y then
         drop_initial_indentation(block_out)
      end

      add_child(out, block_out, " ")
      decrement_indent()
   end








   local function_indexes = {

      ["anonymous"] = { 1, 3 },
      ["record"] = { 3, 5 },
      ["local"] = { 2, 4 },
      ["global"] = { 2, 4 },
   }

   local function after_function(kind)
      local arguments_index, body_index = _tl_table_unpack(function_indexes[kind])
      return function(_, node, children)
         local out = { y = node.y, h = 0 }

         if kind == "local" then
            table.insert(out, node.lj_const and gen_target == "luajit" and "const " or "local ")
         end

         table.insert(out, "function")

         if kind == "record" then
            add_child(out, children[1], " ")
            table.insert(out, node.is_method and ":" or ".")
            add_child(out, children[2])
         elseif kind ~= "anonymous" then
            add_child(out, children[1], " ")
         end
         table.insert(out, "(")


         local args = children[arguments_index]
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
      ["statements"] = {
         after = function(_, node, children)
            local out
            if opts.preserve_hashbang and node.hashbang then
               out = { y = 1, h = 0 }
               table.insert(out, node.hashbang)
            else
               out = { y = node.y, h = 0 }
            end
            local space
            local previous_statement
            for i, child in ipairs(children) do
               local statement = node[i]


               if statement.kind == "assignment" and previous_statement and not previous_statement.semicolon and
                  opts.preserve_newlines and child.y > out.y + out.h and first_output_character(child) == "(" then
                  table.insert(out, ";")
               end
               add_child(out, child, space, indent)
               if statement.semicolon then
                  table.insert(out, ";")
                  space = " "
               else
                  space = "; "
               end
               if #child > 0 then
                  previous_statement = statement
               end
            end
            return out
         end,
      },
      ["local_declaration"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            if children[2] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[2], " ")
            end
            return out
         end,
      },
      ["global_declaration"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            if children[3] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[3], " ")
            end
            return out
         end,
      },
      ["assignment"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            add_child(out, children[1])
            table.insert(out, " " .. (node.compound or "") .. "=")
            add_child(out, children[3], " ")
            return out
         end,
      },
      ["conditional"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0, "(" }
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
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            for i, child in ipairs(children) do
               add_child(out, child, i > 1 and " ", child.y ~= node.y and indent)
            end
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["if_block"] = {
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "while")
            add_child(out, children[1], " ")
            table.insert(out, " do")
            add_block(out, children[2], node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["repeat"] = {
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "repeat")
            add_block(out, children[1], node)
            add_child(out, { y = node.yend, h = 0, [1] = "until " }, " ", indent)
            add_child(out, children[2])
            return out
         end,
      },
      ["do"] = {
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "do")
            add_block(out, children[1], node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["forin"] = {
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "for")
            add_child(out, children[1], " ")
            table.insert(out, " in")
            add_child(out, children[2], " ")
            table.insert(out, " do")
            add_block(out, children[3], node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["fornum"] = {
         before = increment_indent,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
            add_block(out, children[5], node)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["return"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "return")
            if #children[1] > 0 then
               add_child(out, children[1], " ")
            end
            return out
         end,
      },
      ["break"] = {
         after = function(_, node, _children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "break")
            return out
         end,
      },
      ["variable_list"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            local space
            for i, child in ipairs(children) do
               if i > 1 then
                  table.insert(out, ",")
                  space = " "
               end
               add_child(out, child, space, child.y ~= node.y and indent)
            end
            return out
         end,
      },
      ["literal_table"] = {
         before = increment_indent and function(_, node)
            if node[1] and node[1].y ~= node.y then
               increment_indent(_, node)
            end
         end,
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
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
         after = function(_, node, _children)
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
         after = after_function("record"),
      },
      ["function"] = {
         before = increment_indent,
         after = after_function("anonymous"),
      },
      ["paren"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "(")
            add_child(out, children[1], "", indent)
            table.insert(out, ")")
            return out
         end,
      },
      ["op"] = {
         after = function(_, node, children)
            local out = { y = node.y, h = 0 }
            if node.compound_value then
               return children[3]
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
            elseif node.op.op == "as" then
               add_child(out, children[1], "", indent)
            elseif node.op.op == "is" then
               local ct = node.e2.casttype
               while ct.typename == "nominal" and ct.resolved do
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
               end
            else
               error("unknown node op " .. node.op.op)
            end
            return out
         end,
      },
      ["newtype"] = {
         after = function(_, node, _children)
            local out = { y = node.y, h = 0 }
            local nt = node.newtype
            if nt.typename == "typedecl" then
               local def = nt.def
               if def.fields then
                  table.insert(out, print_record_def(def))
               elseif def.typename == "nominal" then
                  table.insert(out, table.concat(def.names, "."))
               else
                  table.insert(out, "{}")
               end
            end
            return out
         end,
      },
      ["goto"] = {
         after = function(_, node, _children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "goto ")
            table.insert(out, node.label)
            return out
         end,
      },
      ["label"] = {
         after = function(_, node, _children)
            local out = { y = node.y, h = 0 }
            table.insert(out, "::")
            table.insert(out, node.label)
            table.insert(out, "::")
            return out
         end,
      },
      ["string"] = {
         after = function(_, node, children)






            if node.tk:sub(1, 1) == "[" or gen_target ~= "5.1" or not node.tk:find("\\", 1, true) then
               return emit_exactly(nil, node, children)
            end

            local str = node.tk
            local replaced = {}

            local i = 1
            local currstrstart = 1
            while true do
               local slashpos = str:find("\\", i)
               if not slashpos then break end
               local nextc = str:sub(slashpos + 1, slashpos + 1)
               if nextc == "z" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local wsend = str:find("%S", slashpos + 2)
                  currstrstart = wsend
                  i = currstrstart
               elseif nextc == "x" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local digits = str:sub(slashpos + 2, slashpos + 3)
                  local byte = tonumber(digits, 16)
                  table.insert(replaced, string.format("\\%03d", byte))
                  currstrstart = slashpos + 4
                  i = currstrstart
               elseif nextc == "u" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local _, e, hex_digits = str:find("{(.-)}", slashpos + 2)
                  local codepoint = tonumber(hex_digits, 16)
                  local sequence = utf8.char(codepoint)
                  table.insert(replaced, (sequence:gsub(".", function(c)
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

      ["continue"] = emit_exactly_visitor_cbs,
      ["variable"] = emit_exactly_visitor_cbs,
      ["identifier"] = emit_exactly_visitor_cbs,
      ["number"] = {
         after = function(_, node)
            local text = node.tk:gsub("_", "")
            if gen_target ~= "luajit" and text:match("^0[bB][01]+$") then
               text = string.format("%.17g", tonumber(text:sub(3), 2))
            end
            return { y = node.y, h = 0, text }
         end,
      },
      ["integer"] = {
         after = function(_, node)
            local text = node.tk:gsub("_", "")
            if gen_target ~= "luajit" and text:match("^0[bB][01]+$") then
               text = string.format("%.17g", tonumber(text:sub(3), 2))
            end
            return { y = node.y, h = 0, text }
         end,
      },
      ["nil"] = emit_exactly_visitor_cbs,
      ["boolean"] = emit_exactly_visitor_cbs,
      ["..."] = emit_exactly_visitor_cbs,
      ["argument"] = {
         after = function(_, node, _children)
            local out = { y = node.y, h = 0 }
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

   local visit_type = {}
   visit_type.cbs = {}
   local default_type_visitor = {
      after = function(_, typ, _children)
         local out = { y = typ.y or -1, h = 0 }
         local r = typ.typename == "nominal" and typ.resolved or typ
         local lua_type = types.lua_primitives[r.typename] or "table"
         if r.fields and r.is_userdata then
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

   visit_node.after = function(_, node, _children, out)
      if gen_target ~= "luajit" and
         (node.kind == "conditional" or node.kind == "continue" or node.safe_navigation or node.compound or node.luajit_literal or
         (node.op and (node.op.op == "??" or node.op.op == "~>>"))) then
         error("this extension requires the luajit generation target")
      end
      return out
   end
   local out = traversal.traverse_nodes(nil, ast, visit_node, visit_type)

   local code
   if opts.preserve_newlines then
      code = { y = 1, h = 0 }
      add_child(code, out)
   else
      code = out
   end
   return (concat_output(code):gsub(" *\n", "\n"))
end

return lua_generator

end

-- module teal.gen.targets from teal/gen/targets.lua
package.preload["teal.gen.targets"] = function(...)

local targets = {}










function targets.detect(override)
   local version = override or _VERSION
   if version == "Lua 5.1" or
      version == "Lua 5.2" then
      return "5.1"
   elseif version == "Lua 5.3" then
      return "5.3"
   elseif version == "Lua 5.4" then
      return "5.4"
   elseif version == "Lua 5.5" then
      return "5.5"
   end
end

return targets

end

-- module teal.init from teal/init.lua
package.preload["teal.init"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string
local c_generator = require("teal.gen.c_generator")
local check = require("teal.check.check")
local environment = require("teal.environment")

local errors = require("teal.errors")
local lexer = require("teal.lexer")
local loader = require("teal.loader")
local lua_compat = require("teal.gen.lua_compat")
local lua_generator = require("teal.gen.lua_generator")
local package_loader = require("teal.package_loader")
local parser = require("teal.parser")
local require_file = require("teal.check.require_file")
local targets = require("teal.gen.targets")

local util = require("teal.util")

local teal = { CheckError = {}, Compiler = {}, Input = {}, TokenList = {}, ParseTree = {}, Module = {}, CompilerOptions = {} }
























































































































local Compiler = teal.Compiler
local Module = teal.Module



local Input = teal.Input


local ParseTree = teal.ParseTree


local TokenList = teal.TokenList



local Compiler_mt = { __index = Compiler }
local Input_mt = { __index = Input }
local TokenList_mt = { __index = TokenList }
local ParseTree_mt = { __index = ParseTree }
local Module_mt = { __index = Module }

environment.set_require_module_fn(require_file.require_module)





local function module_from_result(result)
   local module = setmetatable({
      filename = result.filename,
      parse_tree = setmetatable({
         filename = result.filename,
         ast = result.ast,
         required_modules = util.sorted_keys(result.dependencies),
         syntax_errors = result.syntax_errors,
      }, ParseTree_mt),
      env = result.env,
   }, Module_mt)

   local check_error = {
      syntax_errors = result.syntax_errors or {},
      type_errors = result.type_errors or {},
      warnings = result.warnings or {},
   }

   return module, check_error
end





function Compiler:input(teal_code, filename)
   if teal_code == nil then
      return nil, "missing Teal code as input"
   end
   return setmetatable({
      filename = filename or "<input>.tl",
      teal_code = teal_code,
      env = self.env,
   }, Input_mt)
end

function Compiler:open(filename)
   local fd, err = io.open(filename, "rb")
   if not fd then
      return nil, "could not open " .. err
   end

   local teal_code, read_err = fd:read("*a")
   if not teal_code then
      return nil, "could not open " .. read_err
   end

   return self:input(teal_code, filename)
end

function Compiler:require(module_name)
   local ok, err = environment.load_module(self.env, module_name)
   if not ok then
      return nil, nil, err
   end

   local filename = self.env.module_filenames[module_name]
   local result = self.env.loaded[filename]
   return module_from_result(result)
end

function Compiler:enable_type_reporting(enable)
   self.env.keep_going = enable
   self.env.report_types = enable
end

function Compiler:get_type_report()
   if not self.env.reporter then
      return nil
   end

   return self.env.reporter:get_report()
end

function Compiler:loaded_files()
   local i = 0
   return function()
      i = i + 1
      return self.env.loaded_order[i]
   end
end

function Compiler:recall(filename)
   local result = self.env.loaded[filename]
   if not result then
      return nil, nil
   end
   lua_compat.apply(result)
   return module_from_result(result)
end





function Input:lex()
   local tokens, errs = lexer.lex(self.teal_code, self.filename)
   return setmetatable({
      filename = self.filename,
      tokens = tokens,
      lexical_errors = errs,
      env = self.env,
   }, TokenList_mt), errs
end

function Input:parse()
   local token_list = self:lex()
   return token_list:parse()
end

function Input:check(module_name)
   local parse_tree, parse_error = self:parse()

   if parse_error and not self.env.keep_going then
      return nil, {
         syntax_errors = parse_error,
         type_errors = {},
         warnings = {},
      }
   end

   return parse_tree:check(module_name)
end

function Input:gen(opts)
   local module, check_error = self:check()
   if #check_error.syntax_errors > 0 then
      return nil, module, check_error
   end
   local output, gen_error = module:gen(opts)
   check_error.gen_error = gen_error
   return output, module, check_error
end





function TokenList:get_token_at(line, column)
   return lexer.get_token_at(self.tokens, line, column)
end

function TokenList:parse()
   local errs = self.lexical_errors or {}
   local ast, required_modules = parser.parse_program(self.tokens, errs, self.filename)

   if #errs > 0 and not self.env.keep_going then
      environment.register_failed(self.env, self.filename, errs)
   end

   return setmetatable({
      filename = self.filename,
      required_modules = required_modules,
      ast = ast,
      env = self.env,
      syntax_errors = errs,
   }, ParseTree_mt), #errs > 0 and errs or nil
end





function ParseTree:check(module_name)
   if #self.syntax_errors > 0 and not self.env.keep_going then
      local result = self.env.loaded[self.filename]
      local _, check_err = module_from_result(result)
      return nil, check_err
   end

   local result = check.check(self.ast, self.env, self.filename)
   if result then
      result.syntax_errors = self.syntax_errors

      lua_compat.apply(result)

      if module_name then
         self.env.modules[module_name] = result.type
         if module_name:match("%.init$") then
            module_name = module_name:sub(1, -6)
            self.env.modules[module_name] = result.type
         end
      end
   end

   return module_from_result(result)
end





function Module:gen(opts)
   local ast = self.parse_tree.ast
   if self.env.opts.gen_target == "c" then
      if self.parse_tree.syntax_errors and #self.parse_tree.syntax_errors > 0 then
         return nil, "cannot generate C with syntax errors"
      end
      return c_generator.generate(ast)
   end
   return lua_generator.generate(ast, self.env.opts.gen_target, opts)
end





function teal.compiler(opts)
   local compiler = setmetatable({}, Compiler_mt)

   local env_opts = {
      feat_arity = opts and opts.feat_arity,
      gen_compat = opts and opts.gen_compat,
      gen_target = opts and opts.gen_target,
      no_stdlib = opts and not not opts.no_stdlib,
   }

   compiler.env = environment.new(env_opts)

   return compiler
end

teal.load = loader.load

function teal.loader()
   package_loader.install_loader()
end

function teal.search_module(module_name, extension_set)
   local found, _, tried = require_file.search_module(module_name, extension_set)
   if not found then
      return nil, tried
   end
   return found
end

teal.runtime_target = targets.detect

function teal.warning_set()
   local warning_set = {}
   for k, v in pairs(errors.warning_kinds) do
      warning_set[k] = v
   end
   return warning_set
end

function teal.version()
   return environment.VERSION
end

return teal

end

-- module teal.input from teal/input.lua
package.preload["teal.input"] = function(...)

local check = require("teal.check.check")

local parser = require("teal.parser")


local environment = require("teal.environment")



local input = {}


function input.check(env, filename, code, dependency)
   if env.loaded and env.loaded[filename] then
      return env.loaded[filename]
   end

   local program, syntax_errors = parser.parse(code, filename)

   if (not env.keep_going) and #syntax_errors > 0 then
      return environment.register_failed(env, filename, syntax_errors)
   end

   local result = check.check(program, env, filename, dependency)

   result.syntax_errors = syntax_errors

   return result
end

return input

end

-- module teal.lexer from teal/lexer.lua
package.preload["teal.lexer"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table



local errors = require("teal.errors")


local util = require("teal.util")
local binary_search = util.binary_search

local lexer = { Comment = {}, Token = {} }







































do










































   local last_token_kind = {
      ["start"] = nil,
      ["any"] = nil,
      ["identifier"] = "identifier",
      ["got -"] = "op",
      ["got --"] = nil,
      ["got ."] = ".",
      ["got .."] = "op",
      ["got ="] = "op",
      ["got ~"] = "op",
      ["got ["] = "[",
      ["got 0"] = "number",
      ["got <"] = "op",
      ["got >"] = "op",
      ["got /"] = "op",
      ["got :"] = "op",
      ["got --["] = nil,
      ["string single"] = "$ERR$",
      ["string single got \\"] = "$ERR$",
      ["string double"] = "$ERR$",
      ["string double got \\"] = "$ERR$",
      ["string backtick"] = "$ERR$",
      ["string backtick got \\"] = "$ERR$",
      ["string backtick triple"] = "$ERR$",
      ["string long"] = "$ERR$",
      ["string long got ]"] = "$ERR$",
      ["comment short"] = nil,
      ["comment long"] = "$ERR$",
      ["comment long got ]"] = "$ERR$",
      ["number dec"] = "integer",
      ["number decfloat"] = "number",
      ["number binary"] = "integer",
      ["number suffix"] = "number",
      ["number hex"] = "integer",
      ["number hexfloat"] = "number",
      ["number power"] = "number",
      ["number powersign"] = "$ERR$",
      ["pragma"] = nil,
      ["pragma any"] = nil,
      ["pragma word"] = "pragma_identifier",
   }

   local keywords = {
      ["and"] = true,
      ["break"] = true,
      ["do"] = true,
      ["else"] = true,
      ["elseif"] = true,
      ["end"] = true,
      ["false"] = true,
      ["for"] = true,
      ["function"] = true,
      ["goto"] = true,
      ["if"] = true,
      ["in"] = true,
      ["local"] = true,
      ["nil"] = true,
      ["not"] = true,
      ["or"] = true,
      ["repeat"] = true,
      ["return"] = true,
      ["then"] = true,
      ["true"] = true,
      ["until"] = true,
      ["while"] = true,
   }

   local lex_any_char_states = {
      ["\""] = "string double",
      ["'"] = "string single",
      ["-"] = "got -",
      ["."] = "got .",
      ["0"] = "got 0",
      ["<"] = "got <",
      [">"] = "got >",
      ["/"] = "got /",
      [":"] = "got :",
      ["="] = "got =",
      ["~"] = "got ~",
      ["["] = "got [",
   }

   for c = string.byte("a"), string.byte("z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   lex_any_char_states["_"] = "identifier"

   for c = string.byte("1"), string.byte("9") do
      lex_any_char_states[string.char(c)] = "number dec"
   end

   local lex_word = {}
   for c = string.byte("a"), string.byte("z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("0"), string.byte("9") do
      lex_word[string.char(c)] = true
   end
   lex_word["_"] = true

   local lex_decimals = {}
   for c = string.byte("0"), string.byte("9") do
      lex_decimals[string.char(c)] = true
   end

   local lex_hexadecimals = {}
   for c = string.byte("0"), string.byte("9") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("a"), string.byte("f") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("F") do
      lex_hexadecimals[string.char(c)] = true
   end

   local lex_any_char_kinds = {}
   local single_char_kinds = { "[", "]", "(", ")", "{", "}", ",", ";", "?", "$" }
   for _, c in ipairs(single_char_kinds) do
      lex_any_char_kinds[c] = c
   end
   for _, c in ipairs({ "#", "+", "*", "|", "&", "%", "^", "!" }) do
      lex_any_char_kinds[c] = "op"
   end

   local lex_space = {}
   for _, c in ipairs({ " ", "\t", "\v", "\n", "\r" }) do
      lex_space[c] = true
   end

   local escapable_characters = {
      a = true,
      b = true,
      f = true,
      n = true,
      r = true,
      t = true,
      v = true,
      z = true,
      ["\\"] = true,
      ["\'"] = true,
      ["\""] = true,
      ["\r"] = true,
      ["\n"] = true,
   }

   local function lex_string_escape(input, i, c)
      if escapable_characters[c] then
         return 0, true
      elseif c == "x" then
         return 2, (
         lex_hexadecimals[input:sub(i + 1, i + 1)] and
         lex_hexadecimals[input:sub(i + 2, i + 2)])

      elseif c == "u" then
         if input:sub(i + 1, i + 1) == "{" then
            local p = i + 2
            if not lex_hexadecimals[input:sub(p, p)] then
               return 2, false
            end
            while true do
               p = p + 1
               c = input:sub(p, p)
               if not lex_hexadecimals[c] then
                  return p - i, c == "}"
               end
            end
         end
      elseif lex_decimals[c] then
         local len = lex_decimals[input:sub(i + 1, i + 1)] and
         (lex_decimals[input:sub(i + 2, i + 2)] and 2 or 1) or
         0
         return len, tonumber(input:sub(i, i + len)) < 256
      else
         return 0, false
      end
   end

   lexer.lex = function(input, filename)
      local tokens = {}

      local state = "any"
      local fwd = true
      local y = 1
      local x = 0
      local i = 0
      local lc_open_lvl = 0
      local lc_close_lvl = 0
      local ls_open_lvl = 0
      local ls_close_lvl = 0
      local errs = {}
      local nt = 0

      local tx
      local ty
      local ti
      local in_token = false

      local comments

      local function begin_token()
         tx = x
         ty = y
         ti = i
         in_token = true
      end

      local function end_token(kind, tk)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_identifier()
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = keywords[tk] and "keyword" or "identifier",
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_prev(kind)
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_here(kind)
         local tk = input:sub(ti, i)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,

         }
         comments = nil
         in_token = false
      end

      local function drop_token()
         in_token = false
      end

      local function add_syntax_error(msg)
         local t = tokens[nt]
         table.insert(errs, {
            filename = filename,
            y = t.y,
            x = t.x,
            msg = msg or "invalid token '" .. t.tk .. "'",
         })
      end

      local function add_comment(text)
         if not comments then
            comments = {}
         end
         comments[#comments + 1] = {
            x = tx,
            y = ty,
            text = text,
         }
      end

      local bom = "\239\187\191"
      local bom_len = bom:len()
      if input:sub(1, bom_len) == bom then
         input = input:sub(bom_len + 1)
      end

      local len = #input
      if input:sub(1, 2) == "#!" then
         begin_token()
         i = input:find("\n")
         if not i then
            i = len + 1
         end
         end_token_prev("hashbang")
         y = 2
         x = 0
      end
      state = "any"

      local extension_operators = {
         ["~"] = { "~>>=", "~>>" }, ["<"] = { "<<=" }, [">"] = { ">>=" },
         ["."] = { "..=" }, ["!"] = { "!=" }, ["&"] = { "&&", "&=" },
         ["|"] = { "||", "|=" }, ["?"] = { "??", "?." },
         ["+"] = { "+=" }, ["-"] = { "-=", "->" }, ["*"] = { "*=" },
         ["/"] = { "/=" }, ["%"] = { "%=" },
      }

      while i <= len do
         if fwd then
            i = i + 1
            if i > len then
               break
            end
         end

         local c = input:sub(i, i)

         if fwd then
            if c == "\n" then
               y = y + 1
               x = 0
            else
               x = x + 1
            end
         else
            fwd = true
         end

         local extension_op
         if state == "any" and extension_operators[c] then
            for _, candidate in ipairs(extension_operators[c]) do
               if input:sub(i, i + #candidate - 1) == candidate then
                  extension_op = candidate
                  break
               end
            end
         end
         if extension_op then
            begin_token()
            end_token("op", extension_op)
            i = i + #extension_op - 1
            x = x + #extension_op - 1
         elseif c == "_" and (state == "got 0" or state:sub(1, 7) == "number ") then

         elseif state ~= "number suffix" and (state == "got 0" or state:sub(1, 7) == "number ") and
            (c == "L" or c == "l" or c == "U" or c == "u" or c == "i" or c == "I") then
            state = "number suffix"
         elseif state == "number suffix" then
            if not lex_word[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number binary" then
            if c ~= "0" and c ~= "1" then
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "any" then
            if c == "`" then
               local c2 = input:sub(i + 1, i + 1)
               local c3 = input:sub(i + 2, i + 2)
               if c2 == "`" and c3 == "`" then
                  state = "string backtick triple"
               else
                  state = "string backtick"
               end
               begin_token()
            else
               local st = lex_any_char_states[c]
               if st then
                  state = st
                  begin_token()
               else
                  local k = lex_any_char_kinds[c]
                  if k then
                     begin_token()
                     end_token(k, c)
                  elseif c:match("%p") or c:byte() >= 128 then
                     begin_token()
                     end_token_here("op")
                  elseif not lex_space[c] then
                     begin_token()
                     end_token_here("$ERR$")
                     add_syntax_error()
                  end
               end
            end
         elseif state == "identifier" then
            if not lex_word[c] then
               end_token_identifier()
               fwd = false
               state = "any"
            end
         elseif state == "string double" then
            if c == "\\" then
               state = "string double got \\"
            elseif c == "\"" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "string backtick" then
            if c == "\\" then
               state = "string backtick got \\"
            elseif c == "`" then
               end_token_here("`")
               state = "any"
            end
         elseif state == "string backtick triple" then
            if input:sub(i, i + 2) == "```" then
               if i == ti then
                  i = i + 2
                  x = x + 2
               else
                  i = i + 2
                  x = x + 2
                  end_token_here("`")
                  state = "any"
               end
            end
         elseif state == "string backtick got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string backtick"
         elseif state == "comment short" then
            if c == "\n" then
               add_comment(input:sub(ti, i - 1))
               state = "any"
            end
         elseif state == "got =" then
            local t
            if c == "=" then
               t = "=="
            else
               t = "="
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got ." then
            if c == "." then
               state = "got .."
            elseif lex_decimals[c] then
               state = "number decfloat"
            else
               end_token(".", ".")
               fwd = false
               state = "any"
            end
         elseif state == "got :" then
            local t
            if c == ":" then
               t = "::"
            else
               t = ":"
               fwd = false
            end
            end_token(t, t)
            state = "any"
         elseif state == "got [" then
            if c == "[" then
               state = "string long"
            elseif c == "=" then
               ls_open_lvl = ls_open_lvl + 1
            else
               end_token("[", "[")
               fwd = false
               state = "any"
               ls_open_lvl = 0
            end
         elseif state == "number dec" then
            if lex_decimals[c] then

            elseif c == "." then
               state = "number decfloat"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got -" then
            if c == "-" then
               state = "got --"
            else
               end_token("op", "-")
               fwd = false
               state = "any"
            end
         elseif state == "got .." then
            if c == "." then
               end_token("...", "...")
            else
               end_token("op", "..")
               fwd = false
            end
            state = "any"
         elseif state == "number hex" then
            if lex_hexadecimals[c] then

            elseif c == "." then
               state = "number hexfloat"
            elseif c == "p" or c == "P" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --" then
            if c == "[" then
               state = "got --["
            elseif c == "#" then
               state = "pragma"
            else
               fwd = false
               state = "comment short"
               drop_token()
            end
         elseif state == "pragma" then
            if not lex_word[c] then
               end_token_prev("pragma")
               if tokens[nt].tk == "--#pragma" then
                  state = "pragma any"
               else
                  state = "comment short"
                  table.remove(tokens)
                  nt = nt - 1
                  drop_token()
               end
               fwd = false
            end
         elseif state == "pragma any" then
            if c == "\n" then
               state = "any"
            elseif lex_word[c] then
               state = "pragma word"
               begin_token()
            elseif not lex_space[c] then
               begin_token()
               end_token_here("$ERR$")
               add_syntax_error()
            end
         elseif state == "pragma word" then
            if not lex_word[c] then
               end_token_prev("pragma_identifier")
               fwd = false
               state = (c == "\n") and "any" or "pragma any"
            end
         elseif state == "got 0" then
            if c == "x" or c == "X" then
               state = "number hex"
            elseif c == "b" or c == "B" then
               state = "number binary"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            elseif lex_decimals[c] then
               state = "number dec"
            elseif c == "." then
               state = "number decfloat"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --[" then
            if c == "[" then
               state = "comment long"
            elseif c == "=" then
               lc_open_lvl = lc_open_lvl + 1
            else
               fwd = false
               state = "comment short"
               drop_token()
               lc_open_lvl = 0
            end
         elseif state == "comment long" then
            if c == "]" then
               state = "comment long got ]"
            end
         elseif state == "comment long got ]" then
            if c == "]" and lc_close_lvl == lc_open_lvl then
               add_comment(input:sub(ti, i))
               drop_token()
               state = "any"
               lc_open_lvl = 0
               lc_close_lvl = 0
            elseif c == "=" then
               lc_close_lvl = lc_close_lvl + 1
            else
               state = "comment long"
               lc_close_lvl = 0
            end
         elseif state == "string double got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string double"
         elseif state == "string single" then
            if c == "\\" then
               state = "string single got \\"
            elseif c == "'" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "string single got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string single"
         elseif state == "got ~" then
            local t
            if c == "=" then
               t = "~="
            else
               t = "~"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got <" then
            local t
            if c == "=" then
               t = "<="
            elseif c == "<" then
               t = "<<"
            else
               t = "<"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got >" then
            local t
            if c == "=" then
               t = ">="
            elseif c == ">" then
               t = ">>"
            else
               t = ">"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got /" then
            local t
            if c == "/" then
               t = "//"
            else
               t = "/"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "string long" then
            if c == "]" then
               state = "string long got ]"
            end
         elseif state == "string long got ]" then
            if c == "]" then
               if ls_close_lvl == ls_open_lvl then
                  end_token_here("string")
                  state = "any"
                  ls_open_lvl = 0
                  ls_close_lvl = 0
               end
            elseif c == "=" then
               ls_close_lvl = ls_close_lvl + 1
            else
               state = "string long"
               ls_close_lvl = 0
            end
         elseif state == "number hexfloat" then
            if c == "p" or c == "P" then
               state = "number powersign"
            elseif not lex_hexadecimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number decfloat" then
            if c == "e" or c == "E" then
               state = "number powersign"
            elseif not lex_decimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number powersign" then
            if c == "-" or c == "+" then
               state = "number power"
            elseif lex_decimals[c] then
               state = "number power"
            elseif lex_space[c] then
               end_token_prev("$ERR$")
               fwd = false
               add_syntax_error("malformed number")
               state = "any"
            else
               end_token_here("$ERR$")
               add_syntax_error("malformed number")
               state = "any"
            end
         elseif state == "number power" then
            if not lex_decimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         end
      end

      if in_token then
         if last_token_kind[state] then
            end_token_prev(last_token_kind[state])
            if last_token_kind[state] == "$ERR$" then
               local state_type = state:sub(1, 6)
               if state_type == "string" then
                  add_syntax_error("malformed string")
               elseif state_type == "number" then
                  add_syntax_error("malformed number")
               elseif state_type == "commen" then
                  add_syntax_error("unfinished long comment")
               else
                  add_syntax_error()
               end
            elseif keywords[tokens[nt].tk] then
               tokens[nt].kind = "keyword"
            end
         else
            drop_token()
         end
      end

      if state == "comment short" or state == "got --" or state == "got --[" then
         add_comment(input:sub(ti, #input))
      end

      for _, token in ipairs(tokens) do
         if token.kind == "number" or token.kind == "integer" then
            local text = token.tk:gsub("_", ""):lower()
            local integer_suffix = text:sub(-2) == "ll"
            if text:sub(-3) == "ull" then text = text:sub(1, -4)
            elseif integer_suffix then text = text:sub(1, -3)
            elseif text:sub(-1) == "i" then text = text:sub(1, -2) end
            local value = text:match("^0b[01]+$") and tonumber(text:sub(3), 2) or tonumber(text)
            if not value then
               token.kind = "$ERR$"
               table.insert(errs, { filename = filename, y = token.y, x = token.x, msg = "malformed number" })
            elseif integer_suffix then
               token.kind = "integer"
            end
         end
      end
      table.insert(tokens, { x = x + 1, y = y, tk = "$EOF$", kind = "$EOF$", comments = comments })

      return tokens, errs
   end
end

lexer.get_token_at = function(tks, y, x)
   local _, found = binary_search(
   tks, nil,
   function(tk)
      return tk.y < y or
      (tk.y == y and tk.x <= x)
   end)


   if found and
      found.y == y and
      found.x <= x and x < found.x + #found.tk then

      return found.tk
   end
end

return lexer

end

-- module teal.loader from teal/loader.lua
package.preload["teal.loader"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local load = _tl_compat and _tl_compat.load or load; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local environment = require("teal.environment")
local lua_compat = require("teal.gen.lua_compat")
local lua_generator = require("teal.gen.lua_generator")
local package_loader = require("teal.package_loader")
local input = require("teal.input")


local loader = {}
















local function env_for(env_tbl)
   if not env_tbl then
      if not package_loader.env then
         package_loader.env = environment.for_runtime()
      end
      return assert(package_loader.env)
   end

   if not loader.load_envs then
      loader.load_envs = setmetatable({}, { __mode = "k" })
   end

   loader.load_envs[env_tbl] = loader.load_envs[env_tbl] or environment.for_runtime()
   return loader.load_envs[env_tbl]
end

function loader.load(teal_code, chunkname, mode, ...)
   local env = env_for(...)
   local filename = chunkname or ("string \"" .. teal_code:sub(45) .. (#teal_code > 45 and "..." or "") .. "\".tl")
   local result = input.check(env, filename, teal_code)

   local errs = result.syntax_errors
   if #errs > 0 then
      return nil, (chunkname or "") .. ":" .. errs[1].y .. ":" .. errs[1].x .. ": " .. errs[1].msg
   end

   if mode and mode:match("c") then
      if #result.type_errors > 0 then
         local errout = {}
         for _, err in ipairs(result.type_errors) do
            table.insert(errout, err.filename .. ":" .. err.y .. ":" .. err.x .. ": " .. (err.msg or ""))
         end
         return nil, table.concat(errout, "\n")
      end

      mode = mode:gsub("c", "")
   end

   lua_compat.apply(result)

   local lua_code = lua_generator.generate(result.ast, package_loader.env.opts.gen_target, lua_generator.fast_opts)

   return load(lua_code, chunkname, mode, ...)
end

return loader

end

-- module teal.macro_eval from teal/macro_eval.lua
package.preload["teal.macro_eval"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local coroutine = _tl_compat and _tl_compat.coroutine or coroutine; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local load = _tl_compat and _tl_compat.load or load; local math = _tl_compat and _tl_compat.math or math; local os = _tl_compat and _tl_compat.os or os; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local rawlen = _tl_compat and _tl_compat.rawlen or rawlen; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _tl_table_unpack = unpack or table.unpack; local type = type; local utf8 = _tl_compat and _tl_compat.utf8 or utf8; local xpcall = _tl_compat and _tl_compat.xpcall or xpcall
local block = require("teal.block")


local BLOCK_INDEXES = block.BLOCK_INDEXES

local errors = require("teal.errors")


local ast = require("teal.ast")




local macro_gen_target = ((_G).jit and load("return true ? 1 : 2", "=(syntax probe)", "t")) and "luajit" or "5.1"

local macro_eval = {}






















local function children_iter(b, at)
   while true do
      at = at + 1
      local val = b[at]
      if val then
         return at, val
      elseif at >= block.child_limit(b) then
         return
      end
   end
end

local function children(b)
   return children_iter, b, 0
end

local function clone_value(v, splice_name)
   if type(v) ~= "table" or not v.kind then
      local subject = splice_name and ("macro splice '$" .. splice_name .. "'") or "macro clone"
      error(subject .. " expected a Block, got " .. type(v), 0)
   end
   local out = {
      kind = v.kind,
      f = v.f,
      y = v.y,
      x = v.x,
      tk = v.tk,
      yend = v.yend,
      xend = v.xend,
   }
   for idx, child in children(v) do
      out[idx] = clone_value(child)
   end
   return out
end

local function reanchor_block_positions(b, where_y, where_x, seen_blocks)
   if seen_blocks[b] then
      return
   end
   seen_blocks[b] = true

   if where_y then
      b.y = where_y
      b.yend = where_y
   end
   if where_x then
      b.x = where_x
      b.xend = where_x
   end

   for idx, child in children(b) do
      reanchor_block_positions(child, where_y, where_x, seen_blocks)
   end
end

local function path_block_to_string(node)
   if not node then
      return nil
   end
   if node.kind == "identifier" then
      return node.tk
   elseif node.kind == "op_dot" then
      local lhs = path_block_to_string(node[BLOCK_INDEXES.OP.E1])
      local rhs = node[BLOCK_INDEXES.OP.E2]
      if lhs and rhs and rhs.kind == "identifier" then
         return lhs .. "." .. rhs.tk
      end
   end
   return nil
end

local function macro_target_key(node)
   if not node then
      return nil, false
   end
   if node.kind == "paren" then
      return macro_target_key(node[BLOCK_INDEXES.PAREN.EXP])
   end
   if node.kind == "identifier" then
      return node.tk, false
   end
   if node.kind == "op_dot" then
      local lhs, has_colon = macro_target_key(node[BLOCK_INDEXES.OP.E1])
      local rhs = node[BLOCK_INDEXES.OP.E2]
      if lhs and rhs and rhs.kind == "identifier" then
         return lhs .. "." .. rhs.tk, has_colon
      end
      return nil, has_colon
   end
   if node.kind == "op_colon" then
      return nil, true
   end
   return nil, false
end

local function require_call_module_name(n)
   if not n then
      return nil
   end
   if n.kind == "op_dot" then
      return require_call_module_name(n[BLOCK_INDEXES.OP.E1])
   elseif n.kind == "op_funcall" and
      n[BLOCK_INDEXES.OP.E1] and n[BLOCK_INDEXES.OP.E1].kind == "identifier" and n[BLOCK_INDEXES.OP.E1].tk == "require" and
      n[BLOCK_INDEXES.OP.E2] and n[BLOCK_INDEXES.OP.E2].kind == "expression_list" and #n[BLOCK_INDEXES.OP.E2] == 1 and
      n[BLOCK_INDEXES.OP.E2][1] and
      n[BLOCK_INDEXES.OP.E2][1].kind == "string" and
      n[BLOCK_INDEXES.OP.E2][1].tk then

      return block.string_value(n[BLOCK_INDEXES.OP.E2][1])
   end
   return nil
end

function macro_eval.new_env(errs, parse_expression)
   local env = {
      macros = {},
      signatures = {},
      imported_aliases = {},
      where = { f = "@macro", y = 1, x = 1 },
      sandbox = {
         block = function(_)
            return { kind = "statements", f = "@macro", y = 1, x = 1, tk = "", yend = 1, xend = 1 }
         end,
         expect = function(_, _)
            error("macro env not initialized")
            return nil
         end,
         clone = clone_value,

         BLOCK_INDEXES = BLOCK_INDEXES,

         math = math,
         string = string,
         table = table,
         pairs = pairs,
         ipairs = ipairs,
         tostring = tostring,
         tonumber = tonumber,
         type = type,
         error = error,
         pcall = pcall,
         unpack = (_G).unpack,
         select = select,
         coroutine = coroutine,
         assert = assert,

         next = next,
         xpcall = xpcall,
         print = print,
         _VERSION = _VERSION,

         getmetatable = getmetatable,
         setmetatable = setmetatable,

         rawget = rawget,
         rawset = rawset,
         rawequal = rawequal,
         rawlen = rawlen,

         utf8 = utf8,
         bit = (_G).bit,

         os = {
            clock = os.clock,
            date = os.date,
            difftime = os.difftime,
            time = os.time,
         },









      },
   }
   env.sandbox.block = function(kind)
      local w = env.where
      if not block.BLOCK_KINDS[kind] then
         table.insert(errs, { filename = w.f, y = w.y, x = w.x, msg = "unknown block kind: " .. tostring(kind) })
      end
      return { kind = kind, f = w.f, y = w.y, x = w.x, tk = "", yend = w.y, xend = w.x }
   end
   env.sandbox.expect = function(b, k)
      if b and b.kind == k then
         return b
      end
      table.insert(errs, { filename = env.where.f, y = env.where.y, x = env.where.x, msg = "expected " .. k .. ", got " .. (b and b.kind or "nil") })
      return nil
   end

   env.sandbox.string_value = block.string_value

   env.sandbox.parse_expression = function(source)
      assert(parse_expression, "expression parsing is unavailable in this macro environment")
      local expression = parse_expression(source)
      reanchor_block_positions(expression, env.where.y, env.where.x, {})
      return expression
   end

   return env
end

local function is_statement_kind(k)
   return k == "assignment" or k == "local_declaration" or k == "global_declaration" or
   k == "return" or k == "if" or k == "while" or k == "fornum" or k == "forin" or
   k == "do" or k == "repeat" or k == "local_function" or k == "global_function" or
   k == "record_function" or k == "newtype" or k == "pragma" or
   k == "local_type" or k == "global_type" or k == "goto" or k == "label" or
   k == "break" or k == "continue" or k == ";" or k == "comment" or k == "hashbang" or
   k == "local_macroexp" or k == "local_macro"
end

local function is_expression_kind(k)
   return k == "nil" or k == "string" or k == "number" or k == "integer" or
   k == "boolean" or k == "literal_table" or k == "function" or
   k == "identifier" or k == "..." or k == "paren" or k == "conditional" or k == "macro_invocation" or
   k:sub(1, 3) == "op_"
end



local function validate_statement_positions(b, statement)
   if statement then

      while b.kind == "paren" and b[BLOCK_INDEXES.PAREN.EXP] do
         b = b[BLOCK_INDEXES.PAREN.EXP]
      end
      if b.kind ~= "statements" and b.kind ~= "op_funcall" and not is_statement_kind(b.kind) then
         return nil
      end
   end
   if b.kind ~= "macro_quote" and b.kind ~= "local_macro" then
      for i, child in children(b) do
         local checked = validate_statement_positions(child, b.kind == "statements")
         if not checked then
            return nil
         end
         b[i] = checked
      end
   end
   return b
end


local function add_for_shadows(b)
   if b.kind == "forin" or b.kind == "fornum" then
      local map = BLOCK_INDEXES[b.kind:upper()]
      local body = b[map.BODY]

      local var = b[1]
      if b.kind == "forin" then
         var = var and var[1]
      end

      if body and var and var.kind == "identifier" then
         local name = var.tk

         local function at(kind)
            return { kind = kind, tk = name, f = b.f, y = b.y, x = b.x, yend = b.y, xend = b.x }
         end

         local LD = BLOCK_INDEXES.LOCAL_DECLARATION
         local stmt = at("local_declaration")
         stmt[LD.VARS] = at("variable_list")
         stmt[LD.VARS][1] = at("identifier")
         stmt[LD.EXPS] = at("expression_list")
         stmt[LD.EXPS][1] = at("identifier")

         table.insert(body, 1, stmt)
      end
   end

   for _, child in children(b) do
      add_for_shadows(child)
   end
end

local function compile_local_macro(mb, filename, read_lang, env, errs)
   local name_block = mb[BLOCK_INDEXES.LOCAL_MACRO.NAME]
   if not name_block or name_block.kind ~= "identifier" then
      return
   end
   local name = name_block.tk
   local owner_key = path_block_to_string(mb[BLOCK_INDEXES.LOCAL_MACRO.OWNER])
   local macro_key = owner_key and (owner_key .. "." .. name) or name
   local import_alias = mb[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS]
   if import_alias and import_alias.kind == "identifier" then
      env.imported_aliases[import_alias.tk] = true
   end

   local sig = { kinds = {}, vararg = "" }
   local args = mb[BLOCK_INDEXES.LOCAL_MACRO.ARGS]
   if args then
      local idx = 1
      for _, ab in ipairs(args) do
         local expected
         local annot = ab[BLOCK_INDEXES.ARGUMENT.TYPE]
         if not annot then
            table.insert(errs, { filename = filename, y = ab.y, x = ab.x, msg = "macro '" .. macro_key .. "' argument missing type; expected 'Statement' or 'Expression'" })
         else
            if annot.kind == "nominal_type" and annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME] and annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME].kind == "identifier" then
               local tname = annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME].tk
               if tname == "Statement" then
                  expected = "stmt"
               elseif tname == "Expression" then
                  expected = "expr"
               else
                  table.insert(errs, { filename = filename, y = annot.y, x = annot.x, msg = "macro '" .. macro_key .. "' argument type must be 'Statement' or 'Expression'" })
               end
            else
               table.insert(errs, { filename = filename, y = annot.y, x = annot.x, msg = "macro '" .. macro_key .. "' argument type must be 'Statement' or 'Expression'" })
            end
         end
         if ab.tk == "..." then
            sig.vararg = expected or "expr"
         else
            sig.kinds[idx] = expected or "expr"
            idx = idx + 1
         end
      end
   end

   local lua_generator = require("teal.gen.lua_generator")
   local single = { kind = "statements", y = mb.y, x = mb.x, tk = mb.tk, yend = mb.yend, xend = mb.xend }
   single[1] = mb

   add_for_shadows(single)

   local mast, perrs = ast.parse_blocks(single, filename, read_lang)
   if #perrs > 0 then
      for _, e in ipairs(perrs) do table.insert(errs, e) end
      return
   end

   local host_name = name
   if name:sub(1, 1) == "(" then
      host_name = "__teal_operator_macro";
      (mast)[1].name.tk = host_name
   end
   local code = lua_generator.generate(mast, macro_gen_target, lua_generator.fast_opts)
   local chunk, load_err = load(code .. "\nreturn " .. host_name, name, "t", env.sandbox)
   if not chunk then
      table.insert(errs, { filename = filename, y = mb.y, x = mb.x, msg = load_err })
      return
   end
   local ok, fn_raw = pcall(chunk)
   if not ok then
      table.insert(errs, { filename = filename, y = mb.y, x = mb.x, msg = tostring(fn_raw) })
      return
   end
   local operator = mb[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR]
   local binding = operator and operator[BLOCK_INDEXES.OPERATOR_SPEC.BINDING].tk
   if type(fn_raw) == "function" then
      env.macros[macro_key] = fn_raw
      if binding then env.macros[binding] = fn_raw end
   else
      table.insert(errs, { filename = filename, y = mb.y, x = mb.x, msg = "macro '" .. macro_key .. "' did not compile to a function" })
      return
   end
   env.signatures[macro_key] = sig
   if binding then env.signatures[binding] = sig end
end

local function compile_macro_alias(mb, env)
   local name_block = mb[BLOCK_INDEXES.LOCAL_MACRO.NAME]
   local target_key = path_block_to_string(mb[BLOCK_INDEXES.LOCAL_MACRO.TARGET])
   if not name_block or name_block.kind ~= "identifier" or not target_key then
      return true
   end

   local target = env.macros[target_key]
   if not target then
      return false
   end

   env.macros[name_block.tk] = target
   env.signatures[name_block.tk] = env.signatures[target_key]
   local operator = mb[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR]
   if operator then
      local binding = operator[BLOCK_INDEXES.OPERATOR_SPEC.BINDING].tk
      env.macros[binding] = target
      env.signatures[binding] = env.signatures[target_key]
   end
   return true
end

local function compile_macro_aliases(aliases, env)
   local pending = aliases

   while #pending > 0 do
      local unresolved = {}
      local resolved_any = false

      for _, alias in ipairs(pending) do
         if compile_macro_alias(alias, env) then
            resolved_any = true
         else
            table.insert(unresolved, alias)
         end
      end

      if #unresolved == 0 or not resolved_any then
         return
      end

      pending = unresolved
   end
end

local seen

local traverse_invoking_macros
local eval_macro_invocation

eval_macro_invocation = function(b, filename, env, errs, context)
   local mexp = b
   local mname_block = mexp[BLOCK_INDEXES.MACRO_INVOCATION.MACRO]
   local mname
   local has_colon
   mname, has_colon = macro_target_key(mname_block)
   if has_colon then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = "method-style macro invocation is not supported; use owner.macro!()" })
      return b
   end
   if not mname then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = "invalid macro invocation target" })
      return b
   end
   local public_name = mname:match("^@operator:.*:([^:]+)$") or mname
   local operator_use = b[BLOCK_INDEXES.MACRO_INVOCATION.OPERATOR]
   local display_name = operator_use and ("operator '" .. b.tk .. "'") or ("macro '" .. public_name .. "'")
   local fn = env.macros[mname]
   if not fn then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = "unknown " .. display_name })
      return b
   end
   local argv = {}
   local sig = env.signatures[mname]
   local args = mexp[BLOCK_INDEXES.MACRO_INVOCATION.ARGS]

   if sig then
      local provided = args and #args or 0
      local required = #sig.kinds
      local has_vararg = sig.vararg ~= ""
      if provided < required or ((not has_vararg) and provided > required) then
         table.insert(errs, {
            filename = filename,
            y = mname_block.y,
            x = mname_block.x,
            msg = display_name .. " expects " .. tostring(required) .. (required == 1 and " argument" or " arguments") .. ", got " .. tostring(provided),
         })
         return b
      end
   end
   local argument_errors = #errs
   if args then
      for i, ab in ipairs(args) do
         if ab.kind == "macro_quote" and ab[BLOCK_INDEXES.MACRO_QUOTE.BLOCK] then
            ab = ab[BLOCK_INDEXES.MACRO_QUOTE.BLOCK]
         end
         local expected
         if sig then
            expected = sig.kinds and sig.kinds[i] or (sig.vararg ~= "" and sig.vararg or nil)
         end
         if expected == "stmt" then
            if not ab or ab.kind ~= "statements" then
               table.insert(errs, { filename = filename, y = ab and ab.y or b.y, x = ab and ab.x or b.x, msg = display_name .. " argument " .. tostring(i) .. " must be a Statement" })
            end
         elseif expected == "expr" then
            if ab and ab.kind == "statements" then
               if #ab == 1 and is_expression_kind(ab[1].kind) then
                  ab = ab[1]
               else
                  table.insert(errs, { filename = filename, y = ab.y, x = ab.x, msg = display_name .. " argument " .. tostring(i) .. " must be an Expression" })
               end
            end
         end
         if ab then
            local argument_context = expected == "stmt" and "stmt" or "expr"
            table.insert(argv, traverse_invoking_macros(ab, filename, env, errs, argument_context))
         end
      end
   end
   if #errs > argument_errors then
      return b
   end
   local prev_where = env.where
   local current_where = { f = filename, y = mname_block.y, x = mname_block.x }
   env.where = current_where
   local function invoke_macro()
      return fn(_tl_table_unpack(argv, 1, #argv))
   end
   local ok, res = pcall(invoke_macro)
   env.where = prev_where
   if not ok then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = tostring(res) })
      return b
   end
   if type(res) ~= "table" or not res.kind then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = display_name .. " did not return a Block" })
      return b
   end
   local wy = current_where.y
   local wx = current_where.x
   reanchor_block_positions(res, wy, wx, setmetatable({}, { __mode = "k" }))
   if context == "expr" and res.kind == "statements" then
      if #res == 1 and is_expression_kind(res[1].kind) then
         res = res[1]
      else
         table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = display_name .. " returned statements in an expression context; invoke it as a standalone statement" })
         return b
      end
   end

   local previous_errors = #errs
   local expanded = traverse_invoking_macros(res, filename, env, errs, context)
   if #errs > previous_errors then
      return b
   end
   if context == "expr" and not is_expression_kind(expanded.kind) then
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = display_name .. " returned statements in an expression context; invoke it as a standalone statement" })
      return b
   end
   local checked = validate_statement_positions(expanded, context == "stmt")
   if not checked then
      local message = operator_use and "operator expression cannot be used as a statement" or
      (display_name .. " returned an expression that cannot be used as a statement; assign or return its value")
      table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = message })
      return b
   end
   if operator_use and context == "expr" then
      return {
         kind = "paren", tk = "(", f = filename, y = b.y, x = b.x,
         [BLOCK_INDEXES.PAREN.EXP] = checked,
         [BLOCK_INDEXES.PAREN.OPERATOR_GROUPING] = { kind = "operator_grouping", tk = "", f = filename, y = b.y, x = b.x },
      }
   end
   return checked
end

local function expand_assignment_target(target, filename, env, errs)
   local previous_errors = #errs
   local expanded = traverse_invoking_macros(target, filename, env, errs, "expr")
   if #errs > previous_errors then
      return expanded
   end


   while expanded.kind == "paren" and expanded[BLOCK_INDEXES.PAREN.OPERATOR_GROUPING] do
      expanded = expanded[BLOCK_INDEXES.PAREN.EXP]
   end
   if expanded.kind ~= "identifier" and expanded.kind ~= "op_index" and expanded.kind ~= "op_dot" then
      table.insert(errs, { filename = filename, y = target.y, x = target.x, msg = "invalid assignment target: expected a variable, field, or index" })
      return target
   end
   return expanded
end

traverse_invoking_macros = function(b, filename, env, errs, context)

   if seen and seen[b] then return b end
   if seen then seen[b] = true end
   if b.kind == "macro_invocation" then
      return eval_macro_invocation(b, filename, env, errs, context)
   end

   local patches
   for i, child in children(b) do
      local ret
      if b.kind == "assignment" and i == BLOCK_INDEXES.ASSIGNMENT.VARS then
         for j, target in ipairs(child) do
            child[j] = expand_assignment_target(target, filename, env, errs)
         end
      elseif child.kind == "macro_invocation" then
         ret = eval_macro_invocation(child, filename, env, errs, b.kind == "statements" and "stmt" or "expr")
         if ret.kind == "statements" then
            patches = patches or {}
            patches[i] = ret
         else
            b[i] = ret
         end
      else
         traverse_invoking_macros(child, filename, env, errs, context)
      end
   end

   if patches then
      for i = #b, 1, -1 do
         local patch = patches[i]
         if patch then
            table.remove(b, i)
            for j = 1, #patch do
               table.insert(b, i + j - 1, patch[j])
            end
         end
      end
   end

   return b
end

local function local_require_alias(stmt)
   if not stmt or stmt.kind ~= "local_declaration" then
      return nil
   end
   local vars = stmt[BLOCK_INDEXES.LOCAL_DECLARATION.VARS]
   local exps = stmt[BLOCK_INDEXES.LOCAL_DECLARATION.EXPS]
   if not vars or not exps or #vars ~= 1 or #exps ~= 1 then
      return nil
   end
   local v = vars[1]
   if not v or v.kind ~= "identifier" then
      return nil
   end
   local module_name = require_call_module_name(exps[1])
   if not module_name then
      return nil
   end
   return v.tk
end

local function block_uses_name(b, name, skip)
   local pending = { b }
   local visited = { [skip] = true }

   while #pending > 0 do
      local current = table.remove(pending)
      if not visited[current] then
         visited[current] = true
         if current.kind == "identifier" and current.tk == name then return true end
         for index, child in children(current) do


            local member_name = (current.kind == "op_dot" or current.kind == "op_colon") and index == BLOCK_INDEXES.OP.E2
            if not member_name and not visited[child] then table.insert(pending, child) end
         end
      end
   end
   return false
end

local function remove_macro_only_requires(node, imported_aliases)
   for i = #node, 1, -1 do
      local stmt = node[i]
      local alias = local_require_alias(stmt)
      if alias and imported_aliases[alias] and not block_uses_name(node, alias, stmt) then
         table.remove(node, i)
      end
   end
end

function macro_eval.compile_all_and_expand(node, filename, read_lang, errs, parse_expression)
   seen = setmetatable({}, { __mode = "k" })
   local env = macro_eval.new_env(errs, parse_expression)
   local aliases = {}

   local collected_operators = {}
   local function collect_operators(b)
      if collected_operators[b] then return end
      collected_operators[b] = true
      if b.kind == "local_macro" or b.kind == "macro_quote" then return end
      local remove = {}
      for index, child in children(b) do
         if child.kind == "local_macro" and child[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR] then
            if child[BLOCK_INDEXES.LOCAL_MACRO.TARGET] then table.insert(aliases, child)
            else compile_local_macro(child, filename, read_lang, env, errs) end
            table.insert(remove, 1, index)
         else
            collect_operators(child)
         end
      end
      for _, index in ipairs(remove) do table.remove(b, index) end
   end
   collect_operators(node)

   local i = 1
   while i <= #node do
      local it = node[i]
      if it and it.kind == "local_macro" then
         table.remove(node, i)
         if it[BLOCK_INDEXES.LOCAL_MACRO.TARGET] then
            table.insert(aliases, it)
         else
            compile_local_macro(it, filename, read_lang, env, errs)
         end
      else
         i = i + 1
      end
   end

   compile_macro_aliases(aliases, env)

   node = traverse_invoking_macros(node, filename, env, errs, "stmt")
   remove_macro_only_requires(node, env.imported_aliases)
   return node
end

return macro_eval

end

-- module teal.macroexps from teal/macroexps.lua
package.preload["teal.macroexps"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs



local parser = require("teal.parser")
local Node = parser.Node

local node_at = parser.node_at

local traversal = require("teal.traversal")


local traverse_nodes = traversal.traverse_nodes



local util = require("teal.util")
local shallow_copy_table = util.shallow_copy_table
local lua_generator = require("teal.gen.lua_generator")

local macroexps = {}







local function traverse_macroexp(macroexp, on_arg_id, on_node)
   local root = macroexp.exp
   local argnames = {}
   for i, a in ipairs(macroexp.args) do
      argnames[a.tk] = i
   end

   local visit_node = {
      cbs = {
         ["variable"] = {
            after = function(_, node, _children)
               local i = argnames[node.tk]
               if not i then
                  return nil
               end

               return on_arg_id(node, i)
            end,
         },
         ["..."] = {
            after = function(_, node, _children)
               local i = argnames[node.tk]
               if not i then
                  return nil
               end

               return on_arg_id(node, i)
            end,
         },
      },
      after = on_node,
   }

   return traverse_nodes(nil, root, visit_node, {})
end

function macroexps.expand(orignode, args, macroexp)
   local on_arg_id = function(node, i)
      if node.kind == '...' then

         local nd = node_at(orignode, {
            kind = "expression_list",
         })
         for n = i, #args do
            nd[n - i + 1] = args[n]
         end
         return { Node, nd }
      else



         local nd = args[i] or node_at(orignode, { kind = "nil", tk = "nil" })
         return { Node, nd }
      end
   end

   local on_node = function(_, node, children, ret)
      local orig = ret and ret[2] or node

      local out = shallow_copy_table(orig)

      local map = {}
      for _, pair in pairs(children) do
         if type(pair) == "table" then
            map[pair[1]] = pair[2]
         end
      end

      for k, v in pairs(orig) do
         if type(v) == "table" and map[v] then
            (out)[k] = map[v]
         end
      end

      out.yend = out.yend and (orignode.y + (out.yend - out.y)) or nil
      out.xend = nil
      out.y = orignode.y
      out.x = orignode.x
      return { node, out }
   end

   local p = traverse_macroexp(macroexp, on_arg_id, on_node)
   orignode.expanded = p[2]
   orignode.macro_expansion = lua_generator.generate(p[2], "5.1", lua_generator.default_opts)
end

function macroexps.check_arg_use(ck, macroexp)
   local used = {}

   local on_arg_id = function(node, _i)
      if used[node.tk] then
         ck:add_error(node, "cannot use argument '" .. node.tk .. "' multiple times in macroexp")
      else
         used[node.tk] = true
      end
   end

   traverse_macroexp(macroexp, on_arg_id, nil)
end

function macroexps.apply(orignode)
   local expanded = orignode.expanded
   local expansion = orignode.macro_expansion
   orignode.expanded = nil

   for k, _ in pairs(orignode) do
      (orignode)[k] = nil
   end
   for k, v in pairs(expanded) do
      (orignode)[k] = v
   end
   orignode.macro_expansion = expansion
end

return macroexps

end

-- module teal.metamethods from teal/metamethods.lua
package.preload["teal.metamethods"] = function(...)

local metamethods = {}





metamethods.unop_to_metamethod = {
   ["#"] = "__len",
   ["-"] = "__unm",
   ["~"] = "__bnot",
}

metamethods.binop_to_metamethod = {
   ["+"] = "__add",
   ["-"] = "__sub",
   ["*"] = "__mul",
   ["/"] = "__div",
   ["%"] = "__mod",
   ["^"] = "__pow",
   ["//"] = "__idiv",
   ["&"] = "__band",
   ["|"] = "__bor",
   ["~"] = "__bxor",
   ["<<"] = "__shl",
   [">>"] = "__shr",
   [".."] = "__concat",
   ["=="] = "__eq",
   ["<"] = "__lt",
   ["<="] = "__le",
   ["@index"] = "__index",
   ["is"] = "__is",
}

metamethods.flip_binop_to_metamethod = {
   [">"] = "__lt",
   [">="] = "__le",
}

return metamethods

end

-- module teal.package_loader from teal/package_loader.lua
package.preload["teal.package_loader"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local load = _tl_compat and _tl_compat.load or load; local package = _tl_compat and _tl_compat.package or package; local table = _tl_compat and _tl_compat.table or table
local environment = require("teal.environment")


local require_file = require("teal.check.require_file")

local lua_compat = require("teal.gen.lua_compat")
local lua_generator = require("teal.gen.lua_generator")

local package_loader = {}



local function tl_package_loader(module_name)
   local env = package_loader.env
   if not env then
      package_loader.env = environment.for_runtime()
      env = package_loader.env
   end

   local result, found_filename, tried = require_file.search_and_load(env, module_name)
   if not found_filename then
      return table.concat(tried, "\n\t")
   end

   local errs = result.syntax_errors
   if #errs > 0 then
      error(found_filename .. ":" .. errs[1].y .. ":" .. errs[1].x .. ": " .. errs[1].msg)
   end

   lua_compat.apply(result)



   local code = assert(lua_generator.generate(result.ast, env.opts.gen_target, lua_generator.fast_opts))
   local chunk, err = load(code, "@" .. found_filename, "t")
   if not chunk then
      error("Internal Compiler Error: Teal generator produced invalid Lua. Please report a bug at https://github.com/teal-language/tl\n\n" .. err)
   end

   return function(modname, loader_data)
      if loader_data == nil then
         loader_data = found_filename
      end
      local ret = chunk(modname, loader_data)
      return ret
   end, found_filename
end

function package_loader.install_loader()
   local searchers = package.searchers or package.loaders
   table.insert(searchers, 2, tl_package_loader)
end

return package_loader

end

-- module teal.parser from teal/parser.lua
package.preload["teal.parser"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local table = _tl_compat and _tl_compat.table or table
local ast = require("teal.ast")
local reader = require("teal.reader")














local parser = {}




















parser.parse_blocks = ast.parse_blocks
parser.parse_program_block = ast.parse_program_block
parser.parse_type = ast.parse_type
parser.parse_type_list = ast.parse_type_list
parser.operator = ast.operator
parser.node_is_funcall = ast.node_is_funcall
parser.node_is_require_call = ast.node_is_require_call
parser.node_at = ast.node_at
parser.lang_heuristic = ast.lang_heuristic

function parser.parse(input, filename, parse_lang)
   local block_ast, read_errs = reader.read(input, filename, parse_lang)
   read_errs = read_errs or {}

   local ast_nodes, parse_errs, required = ast.parse_blocks(block_ast, filename, parse_lang)
   for _, e in ipairs(parse_errs) do
      table.insert(read_errs, e)
   end

   return ast_nodes, read_errs, required
end

function parser.parse_program(tokens, errs, filename, parse_lang)
   errs = errs or {}
   local block_ast = reader.read_program(tokens, errs, filename, parse_lang)
   local ast_nodes, parse_errs, required = ast.parse_program_block(block_ast, filename or "input", parse_lang)
   for _, e in ipairs(parse_errs) do
      table.insert(errs, e)
   end
   return ast_nodes, required
end

return parser

end

-- module teal.precompiled.default_env from teal/precompiled/default_env.lua
package.preload["teal.precompiled.default_env"] = function(...)
local K1,K2,K3,K4,K5,K6,K7,K8,K9,K10="typename","typeid","./teal/default/stdlib.d.tl","tuple","typevar","./teal/default/prelude.d.tl","min_arity","is_method","function","maybe_method"
local K11,K12,K13,K14,K15,K16,K17,K18,K19,K20="typearg","string","types","integer","union","number","is_va","nominal","names","found"
local K21,K22,K23,K24,K25,K26,K27,K28,K29,K30="typeargs","generic","const","attribute","identifier","is_global","declared_at","typedecl","boolean","fresh"
local K31,K32,K33,K34,K35,K36,K37,K38,K39,K40="--- @return The result values; check for nil where indicated in the signature.","declname","needs_compat","values","elements","array","meta_field_comments","fields","field_order","field_comments"
local K41,K42,K43,K44,K45,K46,K47,K48,K49,K50="thread","special_function_handler","closed","value_comments","record","field_locations","enumset","resolved","AnyFunction","close"
local K={"interfaces_expanded","SeekWhence","SetVBufMode","flush","--- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.","lines","--- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.","--- @param self Open file handle.","--- @param formats Optional formats: line, all remaining text, number, or a byte count.","--- @return Values in format order; test each result for nil when reading can fail.","setvbuf","write","FileNumberMode","FileStringMode","FileMode","interface_list","__close","FileType","OpenMode","input","--- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.","--- ```teal","--- ```","output","popen","--- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.","--- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.","--- @return One result per requested format; a failed read produces nil.","stderr","stdin","stdout","tmpfile","used_as_type","interface","assert","coroutine","Function","create","isyieldable","resume","running","status","yield","debug","GetInfoTable","HookEvent","HookFunction","gethook","getinfo","--- Inspect a local variable or parameter by index. Returns its name and, for a stack frame, its value; returns nil when absent.","getlocal","getmetatable","getregistry","getupvalue","getuservalue","sethook","setlocal","setmetatable","setupvalue","setuservalue","--- Build a stack traceback from an optional message, thread and starting level. Non-string messages may pass through unchanged.","traceback","upvalueid","upvaluejoin","activelines","currentline","ftransfer","istailcall","isvararg","lastlinedefined","linedefined","namewhat","nparams","ntransfer","short_src","source","metatable","__add","__band","__bnot","__bor","__bxor","__call","__concat","__div","__idiv","__index","__len","__mod","__mode","__mul","__name","__newindex","__pairs","__pow","__shl","__shr","__sub","__tostring","__unm","typevals","userdata","ipairs","LoadMode","Numeric","atan2","floor","frexp","ldexp","log10","--- Return the greatest argument according to the applicable comparison.","maxinteger","--- Return the least argument according to the applicable comparison.","mininteger","random","randomseed","tointeger","constraint","DateMode","DateTable","clock","difftime","execute","getenv","remove","rename","setlocale","tmpname","isdst","month","package","config","cpath","loaded","loaders","loadlib","preload","searchers","searchpath","pairs","pcall","rawget","require","format","gmatch","--- Replace pattern matches using a string, table, or callback. Return the new string and replacement count.","lower","match","packsize","reverse","unpack","upper","table","PackTable","SortFunction","concat","insert","--- Return elements from an inclusive index range as separate results.","tupletable","charpattern","codepoint","codes","offset","xpcall"}
local T1 = {[K43]=true,f=K3,[K2]=1289,[K1]=K28,x=1,y=246,}
local T2 = {[K32]="FILE",f=K3,[K[1]]=true,["is_userdata"]=true,[K2]=1095,[K1]=K45,x=1,y=246,}
local T3 = {f=K3,[K2]=1099,[K1]=K28,x=4,y=250,}
local T4 = {f=K3,[K2]=1103,[K1]=K28,x=4,y=254,}
local T5 = {f=K3,[K2]=569,[K1]=K28,x=1,y=19,}
local T6 = {f=K3,[K2]=565,[K1]=K28,x=1,y=15,}
local T7 = {f=K3,[K2]=573,[K1]=K28,x=1,y=23,}
local T8 = {[K43]=true,f=K3,[K2]=1092,[K1]=K28,x=1,y=151,}
local T9 = {f=K3,[K2]=894,[K1]=K28,x=4,y=159,}
local T10 = {f=K3,[K2]=890,[K1]=K28,x=4,y=152,}
local T11 = {f=K3,kind="variable",tk="self",x=18,xend=21,y=248,yend=248,}
local T12 = {f=K3,[K2]=584,[K1]=K28,x=20,y=29,}
local T13 = {f=K3,[K2]=680,[K1]=K28,x=23,y=78,}
local T14 = {[K43]=true,f=K3,[K2]=660,[K1]=K28,x=4,y=53,}
local T15 = {f=K3,[K2]=664,[K1]=K28,x=4,y=72,}
local T16 = {f=K3,[K2]=672,[K1]=K28,x=24,y=76,}
local T17 = {f=K6,[K2]=239,[K1]=K28,x=1,y=18,}
local T18 = {f=K6,[K2]=24,[K1]=K28,x=4,y=19,}
local T19 = {[K43]=true,f=K6,[K2]=16,[K1]=K28,x=1,y=14,}
local T20 = {f=K3,[K2]=2154,[K1]=K28,x=24,y=657,}
local T21 = {f=K3,[K2]=2158,[K1]=K28,x=4,y=659,}
local T22 = {f=K3,[K2]=1298,[K1]=K28,x=19,y=324,}
local T23 = {f=K3,[K2]=1300,[K1]=K18,x=23,y=327,}
local T24 = {f=K3,[K2]=1549,[K1]=K28,x=4,y=439,}
local T25 = {[K43]=true,f=K3,[K2]=1545,[K1]=K28,x=4,y=427,}
local T26 = {f=K3,[K2]=1924,[K1]=K28,x=4,y=573,}
local T27 = {f=K3,[K2]=2680,[K1]=K5,[K5]="A",x=11,y=574,}
local T28 = {f=K3,[K2]=1915,[K1]=K28,x=24,y=571,}
local T0 = {["..."]={t={[K17]=true,[K4]={[1]={[K2]=3158,[K1]=K12,x=1,y=1,},},[K2]=3159,[K1]=K4,x=1,y=1,},},["@is_va"]={t={[K2]=3160,[K1]="any",x=1,y=1,},},FILE={[K27]={f=K3,kind=K25,tk="FILE",x=15,xend=18,y=246,yend=246,},[K26]=true,t=T1,[K[33]]=true,},["_VERSION"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="_VERSION",x=8,xend=15,y=825,yend=825,},[K26]=true,t={f=K3,[K2]=2547,[K1]=K12,x=14,y=798,},},any={[K27]={f=K6,kind=K25,tk="any",x=18,xend=20,y=8,yend=8,},[K26]=true,t={[K43]=true,def={[K32]="any",f=K6,[K40]={},[K39]={},[K38]={},[K[16]]={},[K[1]]=true,[K37]={},[K2]=7,[K1]=K[34],x=1,y=8,},f=K6,[K2]=8,[K1]=K28,x=1,y=8,},},arg={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="arg",x=8,xend=10,y=801,yend=801,},[K26]=true,t={[K35]={f=K3,[K2]=2168,[K1]=K12,x=10,y=666,},f=K3,[K2]=2167,[K1]=K36,x=9,xend=16,y=666,yend=666,},},[K[35]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[35],x=8,xend=13,y=802,yend=802,},[K26]=true,[K33]=true,t={f=K3,[K30]=true,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2879,[K1]=K15,[K13]={[1]={f=K3,[K2]=2878,[K1]=K5,[K5]="A@43",x=27,y=669,},[2]={f=K3,[K2]=2175,[K1]="nil",x=31,y=669,},},x=27,y=669,},[2]={f=K3,[K2]=2880,[K1]=K5,[K5]="B@43",x=38,y=669,},[3]={f=K3,[K2]=2177,[K1]="any",x=46,y=669,},},[K2]=2881,[K1]=K4,x=50,y=669,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2882,[K1]=K5,[K5]="A@43",x=52,y=669,},},[K2]=2883,[K1]=K4,x=50,y=669,},[K42]=K[35],[K2]=2884,[K1]=K9,x=12,y=669,},[K21]={[1]={f=K3,[K11]="A@43",[K2]=2876,[K1]=K11,x=21,y=669,},[2]={f=K3,[K11]="B@43",[K2]=2877,[K1]=K11,x=24,y=669,},},[K2]=2885,[K1]=K22,x=4,y=672,},},["collectgarbage"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="collectgarbage",x=8,xend=21,y=803,yend=803,},[K26]=true,t={f=K3,[K2]=2192,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K20]={def={[K32]="CollectGarbageCommand",[K47]={["collect"]=true,["count"]=true,["restart"]=true,stop=true,},f=K3,[K2]=2136,[K1]="enum",[K44]={},x=4,y=640,},f=K3,[K2]=2137,[K1]=K28,x=4,y=640,},[K19]={[1]="CollectGarbageCommand",},[K2]=2183,[K1]=K18,x=31,y=672,},},[K2]=2182,[K1]=K4,x=53,y=672,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2185,[K1]=K16,x=55,y=672,},},[K2]=2184,[K1]=K4,x=53,y=672,},[K2]=2181,[K1]=K9,x=20,y=672,},[2]={args={f=K3,[K4]={[1]={f=K3,[K20]={def={[K32]="CollectGarbageSetValue",[K47]={["setpause"]=true,["setstepmul"]=true,step=true,},f=K3,[K2]=2140,[K1]="enum",[K44]={},x=4,y=647,},f=K3,[K2]=2141,[K1]=K28,x=4,y=647,},[K19]={[1]="CollectGarbageSetValue",},[K2]=2188,[K1]=K18,x=29,y=674,},[2]={f=K3,[K2]=2189,[K1]=K14,x=53,y=674,},},[K2]=2187,[K1]=K4,x=61,y=674,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2191,[K1]=K16,x=63,y=674,},},[K2]=2190,[K1]=K4,x=61,y=674,},[K2]=2186,[K1]=K9,x=20,y=674,},[3]={args={f=K3,[K4]={[1]={f=K3,[K20]={def={[K32]="CollectGarbageIsRunning",[K47]={["isrunning"]=true,},f=K3,[K2]=2144,[K1]="enum",[K44]={},x=4,y=653,},f=K3,[K2]=2145,[K1]=K28,x=4,y=653,},[K19]={[1]="CollectGarbageIsRunning",},[K2]=2195,[K1]=K18,x=29,y=676,},},[K2]=2194,[K1]=K4,x=53,y=676,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2197,[K1]=K29,x=55,y=676,},},[K2]=2196,[K1]=K4,x=53,y=676,},[K2]=2193,[K1]=K9,x=20,y=676,},[4]={args={f=K3,[K4]={[1]={f=K3,[K2]=2200,[K1]=K12,x=29,y=678,},[2]={f=K3,[K2]=2201,[K1]=K16,x=39,y=678,},},[K2]=2199,[K1]=K4,x=46,y=678,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2203,[K1]=K15,[K13]={[1]={f=K3,[K2]=2204,[K1]=K29,x=49,y=678,},[2]={f=K3,[K2]=2205,[K1]=K16,x=59,y=678,},},x=49,y=678,},},[K2]=2202,[K1]=K4,x=46,y=678,},[K2]=2198,[K1]=K9,x=20,y=678,},},x=4,y=674,},},[K[36]]={[K27]={f=K3,kind=K25,tk=K[36],x=15,xend=23,y=28,yend=28,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]=K[36],f=K3,[K40]={[K[37]]={},[K50]={[1]={[1]={text="--- Close a suspended or dead coroutine. Returns success and an error message on failure; availability depends on the runtime.",x=4,y=31,},[2]={text=K31,x=4,y=32,},},},[K[38]]={[1]={[1]={text="--- Create a suspended coroutine for a function. Resume it to start execution.",x=4,y=34,},},},[K[39]]={[1]={[1]={text="--- Report whether the running coroutine can yield at this point.",x=4,y=36,},},},[K[40]]={[1]={[1]={text="--- Resume a coroutine, passing values to its function or yield. Returns a success flag followed by yielded results or an error object.",x=4,y=38,},},},[K[41]]={[1]={[1]={text="--- Return the current coroutine and, where supported, whether it is the main thread. Lua 5.1 may return nil on the main thread.",x=4,y=40,},[2]={text=K31,x=4,y=41,},},},[K[42]]={[1]={[1]={text="--- Return the coroutine state: running, suspended, normal, or dead.",x=4,y=43,},},},wrap={[1]={[1]={text="--- Create a function that resumes a coroutine and returns its results; errors propagate to the caller.",x=4,y=45,},},},[K[43]]={[1]={[1]={text="--- Suspend the running coroutine and pass values to its resumer. Later resume arguments become the yield results.",x=4,y=47,},},},},[K46]={[K[37]]={f=K3,x=9,y=29,},[K50]={f=K3,x=4,y=33,},[K[38]]={f=K3,x=4,y=35,},[K[39]]={f=K3,x=4,y=37,},[K[40]]={f=K3,x=4,y=39,},[K[41]]={f=K3,x=4,y=42,},[K[42]]={f=K3,x=4,y=44,},wrap={f=K3,x=4,y=46,},[K[43]]={f=K3,x=4,y=48,},},[K39]={[1]=K[37],[2]=K50,[3]=K[38],[4]=K[39],[5]=K[40],[6]=K[41],[7]=K[42],[8]="wrap",[9]=K[43],},[K38]={[K[37]]=T12,[K50]={args={f=K3,[K4]={[1]={f=K3,[K2]=587,[K1]=K41,x=20,y=33,},},[K2]=586,[K1]=K4,x=27,y=33,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=589,[K1]=K29,x=29,y=33,},[2]={f=K3,[K2]=590,[K1]=K15,[K13]={[1]={f=K3,[K2]=591,[K1]=K12,x=38,y=33,},[2]={f=K3,[K2]=592,[K1]="nil",x=47,y=33,},},x=38,y=33,},},[K2]=588,[K1]=K4,x=27,y=33,},[K2]=585,[K1]=K9,x=11,y=33,},[K[38]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T12,[K19]={[1]=K[37],},[K2]=595,[K1]=K18,x=21,y=35,},},[K2]=594,[K1]=K4,x=30,y=35,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=597,[K1]=K41,x=32,y=35,},},[K2]=596,[K1]=K4,x=30,y=35,},[K2]=593,[K1]=K9,x=12,y=35,},[K[39]]={args={f=K3,[K4]={},[K2]=599,[K1]=K4,x=27,y=37,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=601,[K1]=K29,x=29,y=37,},},[K2]=600,[K1]=K4,x=27,y=37,},[K2]=598,[K1]=K9,x=17,y=37,},[K[40]]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=604,[K1]=K41,x=21,y=39,},[2]={f=K3,[K2]=605,[K1]="any",x=29,y=39,},},[K2]=603,[K1]=K4,x=36,y=39,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=607,[K1]=K29,x=38,y=39,},[2]={f=K3,[K2]=608,[K1]="any",x=47,y=39,},},[K2]=606,[K1]=K4,x=36,y=39,},[K2]=602,[K1]=K9,x=12,y=39,},[K[41]]={args={f=K3,[K4]={},[K2]=610,[K1]=K4,x=23,y=42,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=612,[K1]=K15,[K13]={[1]={f=K3,[K2]=613,[K1]=K41,x=25,y=42,},[2]={f=K3,[K2]=614,[K1]="nil",x=34,y=42,},},x=25,y=42,},[2]={f=K3,[K2]=615,[K1]=K15,[K13]={[1]={f=K3,[K2]=616,[K1]=K29,x=39,y=42,},[2]={f=K3,[K2]=617,[K1]="nil",x=49,y=42,},},x=39,y=42,},},[K2]=611,[K1]=K4,x=23,y=42,},[K2]=609,[K1]=K9,x=13,y=42,},[K[42]]={args={f=K3,[K4]={[1]={f=K3,[K2]=620,[K1]=K41,x=21,y=44,},},[K2]=619,[K1]=K4,x=28,y=44,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=622,[K1]=K12,x=30,y=44,},},[K2]=621,[K1]=K4,x=28,y=44,},[K2]=618,[K1]=K9,x=12,y=44,},wrap={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2579,[K1]=K5,[K5]="F@23",x=22,y=46,},},[K2]=2580,[K1]=K4,x=24,y=46,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2581,[K1]=K5,[K5]="F@23",x=26,y=46,},},[K2]=2582,[K1]=K4,x=24,y=46,},[K2]=2583,[K1]=K9,x=10,y=46,},[K21]={[1]={f=K3,[K11]="F@23",[K2]=2578,[K1]=K11,x=19,y=46,},},[K2]=2584,[K1]=K22,x=4,y=48,},[K[43]]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=632,[K1]="any",x=20,y=48,},},[K2]=631,[K1]=K4,x=27,y=48,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=634,[K1]="any",x=29,y=48,},},[K2]=633,[K1]=K4,x=27,y=48,},[K2]=630,[K1]=K9,x=11,y=48,},},[K37]={},[K2]=576,[K1]=K45,x=1,y=28,},f=K3,[K2]=635,[K1]=K28,x=1,y=28,},},[K[44]]={[K27]={f=K3,kind=K25,tk=K[44],x=15,xend=19,y=52,yend=52,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]=K[44],f=K3,[K40]={[K49]={},[K[45]]={},[K[46]]={},[K[47]]={},[K[44]]={[1]={[1]={text="--- Enter an interactive debug prompt; availability and interaction depend on the host.",x=4,y=80,},},},[K[48]]={[1]={[1]={text="--- Return the hook function, event mask and instruction count, or nil when no hook is installed.",x=4,y=82,},[2]={text=K31,x=4,y=83,},},},[K[49]]={[1]={[1]={text="--- Inspect a function or stack level. The optional selector chooses which fields are populated; returns nil for an invalid level.",x=4,y=86,},[2]={text=K31,x=4,y=87,},},[2]={[1]={text="--- Inspect a function or stack level. The optional selector chooses which fields are populated; returns nil for an invalid level.",x=4,y=89,},[2]={text=K31,x=4,y=90,},},},[K[51]]={[1]={[1]={text=K[50],x=4,y=93,},[2]={text=K31,x=4,y=94,},},[2]={[1]={text=K[50],x=4,y=96,},[2]={text=K31,x=4,y=97,},},[3]={[1]={text=K[50],x=4,y=99,},[2]={text=K31,x=4,y=100,},},[4]={[1]={text=K[50],x=4,y=102,},[2]={text=K31,x=4,y=103,},},},[K[52]]={[1]={[1]={text="--- Return the actual metatable, bypassing protection, or nil when none is set.",x=4,y=106,},[2]={text=K31,x=4,y=107,},},},[K[53]]={[1]={[1]={text="--- Return the Lua registry, a table used by the C API and runtime.",x=4,y=109,},},},[K[54]]={[1]={[1]={text="--- Return an upvalue name and value, or nil if the index is out of range.",x=4,y=111,},[2]={text=K31,x=4,y=112,},},},[K[55]]={[1]={[1]={text="--- Inspect a userdata user value; the optional index and success result depend on the Lua version.",x=4,y=114,},},},[K[56]]={[1]={[1]={text="--- Install a debug hook for selected events and an optional instruction count.",x=4,y=117,},},[2]={[1]={text="--- Install a debug hook for selected events and an optional instruction count.",x=4,y=119,},},},[K[57]]={[1]={[1]={text="--- Assign a local at a stack level and return its name, or nil if no such local exists.",x=4,y=122,},[2]={text=K31,x=4,y=123,},},[2]={[1]={text="--- Assign a local at a stack level and return its name, or nil if no such local exists.",x=4,y=125,},[2]={text=K31,x=4,y=126,},},},[K[58]]={[1]={[1]={text="--- Set the actual metatable of a value and return that value; bypasses normal metatable protection.",x=4,y=129,},},},[K[59]]={[1]={[1]={text="--- Assign an upvalue and return its name, or nil if the index is invalid.",x=4,y=131,},[2]={text=K31,x=4,y=132,},},},[K[60]]={[1]={[1]={text="--- Set a userdata user value; indexed user values depend on the runtime version.",x=4,y=134,},},},[K[62]]={[1]={[1]={text=K[61],x=4,y=137,},},[2]={[1]={text=K[61],x=4,y=139,},},[3]={[1]={text=K[61],x=4,y=141,},},},[K[63]]={[1]={[1]={text="--- Return an identity token for a closure upvalue, allowing shared upvalues to be compared.",x=4,y=144,},},},[K[64]]={[1]={[1]={text="--- Make one Lua closure upvalue refer to the same storage as another.",x=4,y=146,},},},},[K46]={[K49]={f=K3,x=9,y=78,},[K[45]]={f=K3,x=4,y=53,},[K[46]]={f=K3,x=4,y=72,},[K[47]]={f=K3,x=9,y=76,},[K[44]]={f=K3,x=4,y=81,},[K[48]]={f=K3,x=4,y=84,},[K[49]]={f=K3,x=4,y=88,},[K[51]]={f=K3,x=4,y=95,},[K[52]]={f=K3,x=4,y=108,},[K[53]]={f=K3,x=4,y=110,},[K[54]]={f=K3,x=4,y=113,},[K[55]]={f=K3,x=4,y=115,},[K[56]]={f=K3,x=4,y=118,},[K[57]]={f=K3,x=4,y=124,},[K[58]]={f=K3,x=4,y=130,},[K[59]]={f=K3,x=4,y=133,},[K[60]]={f=K3,x=4,y=135,},[K[62]]={f=K3,x=4,y=138,},[K[63]]={f=K3,x=4,y=145,},[K[64]]={f=K3,x=4,y=147,},},[K39]={[1]=K[45],[2]=K[46],[3]=K[47],[4]=K49,[5]=K[44],[6]=K[48],[7]=K[49],[8]=K[51],[9]=K[52],[10]=K[53],[11]=K[54],[12]=K[55],[13]=K[56],[14]=K[57],[15]=K[58],[16]=K[59],[17]=K[60],[18]=K[62],[19]=K[63],[20]=K[64],},[K38]={[K49]=T13,[K[45]]=T14,[K[46]]=T15,[K[47]]=T16,[K[44]]={args={f=K3,[K4]={},[K2]=682,[K1]=K4,x=4,y=84,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={},[K2]=683,[K1]=K4,x=20,y=81,},[K2]=681,[K1]=K9,x=11,y=81,},[K[48]]={args={f=K3,[K4]={[1]={f=K3,[K2]=686,[K1]=K41,x=24,y=84,},},[K2]=685,[K1]=K4,x=31,y=84,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=688,[K1]=K15,[K13]={[1]={f=K3,[K20]=T16,[K19]={[1]=K[47],},[K2]=689,[K1]=K18,x=33,y=84,},[2]={f=K3,[K2]=690,[K1]="nil",x=48,y=84,},},x=33,y=84,},[2]={f=K3,[K2]=691,[K1]=K15,[K13]={[1]={f=K3,[K2]=692,[K1]=K12,x=53,y=84,},[2]={f=K3,[K2]=693,[K1]="nil",x=62,y=84,},},x=53,y=84,},[3]={f=K3,[K2]=694,[K1]=K15,[K13]={[1]={f=K3,[K2]=695,[K1]=K14,x=67,y=84,},[2]={f=K3,[K2]=696,[K1]="nil",x=77,y=84,},},x=67,y=84,},},[K2]=687,[K1]=K4,x=31,y=84,},[K2]=684,[K1]=K9,x=13,y=84,},[K[49]]={f=K3,[K2]=718,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=699,[K1]=K41,x=22,y=88,},[2]={f=K3,[K2]=700,[K1]=K15,[K13]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=701,[K1]=K18,x=30,y=88,},[2]={f=K3,[K2]=702,[K1]=K14,x=44,y=88,},},x=30,y=88,},[3]={f=K3,[K2]=703,[K1]=K12,x=55,y=88,},},[K2]=698,[K1]=K4,x=62,y=88,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=705,[K1]=K15,[K13]={[1]={f=K3,[K20]=T14,[K19]={[1]=K[45],},[K2]=706,[K1]=K18,x=64,y=88,},[2]={f=K3,[K2]=707,[K1]="nil",x=79,y=88,},},x=64,y=88,},},[K2]=704,[K1]=K4,x=62,y=88,},[K2]=697,[K1]=K9,x=13,y=88,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=710,[K1]=K15,[K13]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=711,[K1]=K18,x=30,y=91,},[2]={f=K3,[K2]=712,[K1]=K14,x=44,y=91,},},x=30,y=91,},[2]={f=K3,[K2]=713,[K1]=K12,x=55,y=91,},},[K2]=709,[K1]=K4,x=62,y=91,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=715,[K1]=K15,[K13]={[1]={f=K3,[K20]=T14,[K19]={[1]=K[45],},[K2]=716,[K1]=K18,x=64,y=91,},[2]={f=K3,[K2]=717,[K1]="nil",x=79,y=91,},},x=64,y=91,},},[K2]=714,[K1]=K4,x=62,y=91,},[K2]=708,[K1]=K9,x=13,y=91,},},x=4,y=91,},[K[51]]={f=K3,[K2]=738,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=721,[K1]=K41,x=23,y=95,},[2]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=722,[K1]=K18,x=31,y=95,},[3]={f=K3,[K2]=723,[K1]=K14,x=44,y=95,},},[K2]=720,[K1]=K4,x=52,y=95,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=725,[K1]=K15,[K13]={[1]={f=K3,[K2]=726,[K1]=K12,x=54,y=95,},[2]={f=K3,[K2]=727,[K1]="nil",x=63,y=95,},},x=54,y=95,},},[K2]=724,[K1]=K4,x=52,y=95,},[K2]=719,[K1]=K9,x=14,y=95,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=730,[K1]=K41,x=23,y=98,},[2]={f=K3,[K2]=731,[K1]=K14,x=31,y=98,},[3]={f=K3,[K2]=732,[K1]=K14,x=40,y=98,},},[K2]=729,[K1]=K4,x=48,y=98,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=734,[K1]=K15,[K13]={[1]={f=K3,[K2]=735,[K1]=K12,x=50,y=98,},[2]={f=K3,[K2]=736,[K1]="nil",x=59,y=98,},},x=50,y=98,},[2]={f=K3,[K2]=737,[K1]="any",x=64,y=98,},},[K2]=733,[K1]=K4,x=48,y=98,},[K2]=728,[K1]=K9,x=14,y=98,},[3]={args={f=K3,[K4]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=741,[K1]=K18,x=23,y=101,},[2]={f=K3,[K2]=742,[K1]=K14,x=36,y=101,},},[K2]=740,[K1]=K4,x=44,y=101,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=744,[K1]=K15,[K13]={[1]={f=K3,[K2]=745,[K1]=K12,x=46,y=101,},[2]={f=K3,[K2]=746,[K1]="nil",x=55,y=101,},},x=46,y=101,},},[K2]=743,[K1]=K4,x=44,y=101,},[K2]=739,[K1]=K9,x=14,y=101,},[4]={args={f=K3,[K4]={[1]={f=K3,[K2]=749,[K1]=K14,x=23,y=104,},[2]={f=K3,[K2]=750,[K1]=K14,x=32,y=104,},},[K2]=748,[K1]=K4,x=40,y=104,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=752,[K1]=K15,[K13]={[1]={f=K3,[K2]=753,[K1]=K12,x=42,y=104,},[2]={f=K3,[K2]=754,[K1]="nil",x=51,y=104,},},x=42,y=104,},[2]={f=K3,[K2]=755,[K1]="any",x=56,y=104,},},[K2]=751,[K1]=K4,x=40,y=104,},[K2]=747,[K1]=K9,x=14,y=104,},},x=4,y=98,},[K[52]]={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2591,[K1]=K5,[K5]="T@24",x=30,y=108,},},[K2]=2592,[K1]=K4,x=32,y=108,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2595,[K1]=K15,[K13]={[1]={f=K3,[K20]=T17,[K19]={[1]=K[77],},[K2]=2594,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=2593,[K1]=K5,[K5]="T@24",x=44,y=108,},},x=34,y=108,},[2]={f=K3,[K2]=764,[K1]="nil",x=49,y=108,},},x=34,y=108,},},[K2]=2596,[K1]=K4,x=32,y=108,},[K2]=2597,[K1]=K9,x=18,y=108,},[K21]={[1]={f=K3,[K11]="T@24",[K2]=2590,[K1]=K11,x=27,y=108,},},[K2]=2598,[K1]=K22,x=4,y=110,},[K[53]]={args={f=K3,[K4]={},[K2]=767,[K1]=K4,x=27,y=110,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=770,[K1]="any",x=30,y=110,},[K2]=769,[K1]="map",[K34]={f=K3,[K2]=771,[K1]="any",x=34,y=110,},x=29,xend=37,y=110,yend=110,},},[K2]=768,[K1]=K4,x=27,y=110,},[K2]=766,[K1]=K9,x=17,y=110,},[K[54]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=774,[K1]=K18,x=25,y=113,},[2]={f=K3,[K2]=775,[K1]=K14,x=38,y=113,},},[K2]=773,[K1]=K4,x=46,y=113,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=777,[K1]=K15,[K13]={[1]={f=K3,[K2]=778,[K1]=K12,x=48,y=113,},[2]={f=K3,[K2]=779,[K1]="nil",x=57,y=113,},},x=48,y=113,},[2]={f=K3,[K2]=780,[K1]="any",x=62,y=113,},},[K2]=776,[K1]=K4,x=46,y=113,},[K2]=772,[K1]=K9,x=16,y=113,},[K[55]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T19,[K19]={[1]=K[102],},[K2]=783,[K1]=K18,x=27,y=115,},[2]={f=K3,[K2]=784,[K1]=K14,x=39,y=115,},},[K2]=782,[K1]=K4,x=47,y=115,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=786,[K1]="any",x=49,y=115,},[2]={f=K3,[K2]=787,[K1]=K29,x=54,y=115,},},[K2]=785,[K1]=K4,x=47,y=115,},[K2]=781,[K1]=K9,x=18,y=115,},[K[56]]={f=K3,[K2]=801,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=790,[K1]=K41,x=22,y=118,},[2]={f=K3,[K20]=T16,[K19]={[1]=K[47],},[K2]=791,[K1]=K18,x=30,y=118,},[3]={f=K3,[K2]=792,[K1]=K12,x=44,y=118,},[4]={f=K3,[K2]=793,[K1]=K14,x=54,y=118,},},[K2]=789,[K1]=K4,x=4,y=120,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={},[K2]=794,[K1]=K4,x=61,y=118,},[K2]=788,[K1]=K9,x=13,y=118,},[2]={args={f=K3,[K4]={[1]={f=K3,[K20]=T16,[K19]={[1]=K[47],},[K2]=797,[K1]=K18,x=22,y=120,},[2]={f=K3,[K2]=798,[K1]=K12,x=36,y=120,},[3]={f=K3,[K2]=799,[K1]=K14,x=46,y=120,},},[K2]=796,[K1]=K4,x=4,y=124,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={},[K2]=800,[K1]=K4,x=53,y=120,},[K2]=795,[K1]=K9,x=13,y=120,},},x=4,y=120,},[K[57]]={f=K3,[K2]=821,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=804,[K1]=K41,x=23,y=124,},[2]={f=K3,[K2]=805,[K1]=K14,x=31,y=124,},[3]={f=K3,[K2]=806,[K1]=K14,x=40,y=124,},[4]={f=K3,[K2]=807,[K1]="any",x=49,y=124,},},[K2]=803,[K1]=K4,x=53,y=124,},f=K3,[K8]=false,[K10]=false,[K7]=4,rets={f=K3,[K4]={[1]={f=K3,[K2]=809,[K1]=K15,[K13]={[1]={f=K3,[K2]=810,[K1]=K12,x=55,y=124,},[2]={f=K3,[K2]=811,[K1]="nil",x=64,y=124,},},x=55,y=124,},},[K2]=808,[K1]=K4,x=53,y=124,},[K2]=802,[K1]=K9,x=14,y=124,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=814,[K1]=K14,x=23,y=127,},[2]={f=K3,[K2]=815,[K1]=K14,x=32,y=127,},[3]={f=K3,[K2]=816,[K1]="any",x=41,y=127,},},[K2]=813,[K1]=K4,x=45,y=127,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=818,[K1]=K15,[K13]={[1]={f=K3,[K2]=819,[K1]=K12,x=47,y=127,},[2]={f=K3,[K2]=820,[K1]="nil",x=56,y=127,},},x=47,y=127,},},[K2]=817,[K1]=K4,x=45,y=127,},[K2]=812,[K1]=K9,x=14,y=127,},},x=4,y=127,},[K[58]]={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2604,[K1]=K5,[K5]="T@25",x=30,y=130,},[2]={f=K3,[K2]=2607,[K1]=K15,[K13]={[1]={f=K3,[K20]=T17,[K19]={[1]=K[77],},[K2]=2606,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=2605,[K1]=K5,[K5]="T@25",x=43,y=130,},},x=33,y=130,},[2]={f=K3,[K2]=829,[K1]="nil",x=48,y=130,},},x=33,y=130,},},[K2]=2608,[K1]=K4,x=52,y=130,},f=K3,[K8]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2609,[K1]=K5,[K5]="T@25",x=54,y=130,},},[K2]=2610,[K1]=K4,x=52,y=130,},[K2]=2611,[K1]=K9,x=18,y=130,},[K21]={[1]={f=K3,[K11]="T@25",[K2]=2603,[K1]=K11,x=27,y=130,},},[K2]=2612,[K1]=K22,x=4,y=133,},[K[59]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=835,[K1]=K18,x=25,y=133,},[2]={f=K3,[K2]=836,[K1]=K14,x=38,y=133,},[3]={f=K3,[K2]=837,[K1]="any",x=47,y=133,},},[K2]=834,[K1]=K4,x=51,y=133,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=839,[K1]=K15,[K13]={[1]={f=K3,[K2]=840,[K1]=K12,x=53,y=133,},[2]={f=K3,[K2]=841,[K1]="nil",x=62,y=133,},},x=53,y=133,},},[K2]=838,[K1]=K4,x=51,y=133,},[K2]=833,[K1]=K9,x=16,y=133,},[K[60]]={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2617,[K1]=K5,[K5]="U@26",x=30,y=135,},[2]={f=K3,[K2]=846,[K1]="any",x=33,y=135,},[3]={f=K3,[K2]=847,[K1]=K14,x=38,y=135,},},[K2]=2618,[K1]=K4,x=46,y=135,},f=K3,[K8]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=2619,[K1]=K5,[K5]="U@26",x=48,y=135,},},[K2]=2620,[K1]=K4,x=46,y=135,},[K2]=2621,[K1]=K9,x=18,y=135,},[K21]={[1]={f=K3,[K11]="U@26",[K2]=2616,[K1]=K11,x=27,y=135,},},[K2]=2622,[K1]=K22,x=4,y=138,},[K[62]]={f=K3,[K2]=864,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=853,[K1]=K41,x=24,y=138,},[2]={f=K3,[K2]=854,[K1]=K12,x=34,y=138,},[3]={f=K3,[K2]=855,[K1]=K14,x=44,y=138,},},[K2]=852,[K1]=K4,x=52,y=138,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=857,[K1]=K12,x=54,y=138,},},[K2]=856,[K1]=K4,x=52,y=138,},[K2]=851,[K1]=K9,x=15,y=138,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=860,[K1]=K12,x=26,y=140,},[2]={f=K3,[K2]=861,[K1]=K14,x=36,y=140,},},[K2]=859,[K1]=K4,x=44,y=140,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=863,[K1]=K12,x=46,y=140,},},[K2]=862,[K1]=K4,x=44,y=140,},[K2]=858,[K1]=K9,x=15,y=140,},[3]={args={f=K3,[K4]={[1]={f=K3,[K2]=867,[K1]="any",x=24,y=142,},},[K2]=866,[K1]=K4,x=28,y=142,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=869,[K1]="any",x=30,y=142,},},[K2]=868,[K1]=K4,x=28,y=142,},[K2]=865,[K1]=K9,x=15,y=142,},},x=4,y=140,},[K[63]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=872,[K1]=K18,x=24,y=145,},[2]={f=K3,[K2]=873,[K1]=K14,x=37,y=145,},},[K2]=871,[K1]=K4,x=45,y=145,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K20]=T19,[K19]={[1]=K[102],},[K2]=875,[K1]=K18,x=47,y=145,},},[K2]=874,[K1]=K4,x=45,y=145,},[K2]=870,[K1]=K9,x=15,y=145,},[K[64]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=878,[K1]=K18,x=26,y=147,},[2]={f=K3,[K2]=879,[K1]=K14,x=39,y=147,},[3]={f=K3,[K20]=T13,[K19]={[1]=K49,},[K2]=880,[K1]=K18,x=48,y=147,},[4]={f=K3,[K2]=881,[K1]=K14,x=61,y=147,},},[K2]=877,[K1]=K4,x=1,y=148,},f=K3,[K8]=false,[K10]=false,[K7]=4,rets={f=K3,[K4]={},[K2]=882,[K1]=K4,x=68,y=147,},[K2]=876,[K1]=K9,x=17,y=147,},},[K37]={},[K2]=638,[K1]=K45,x=1,y=52,},f=K3,[K2]=883,[K1]=K28,x=1,y=52,},},["dofile"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="dofile",x=8,xend=13,y=804,yend=804,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2208,[K1]=K12,x=23,y=681,},},[K2]=2207,[K1]=K4,x=30,y=681,},f=K3,[K8]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2210,[K1]="any",x=32,y=681,},},[K2]=2209,[K1]=K4,x=30,y=681,},[K2]=2206,[K1]=K9,x=12,y=681,},},["error"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="error",x=8,xend=12,y=805,yend=805,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2213,[K1]="any",x=22,y=684,},[2]={f=K3,[K2]=2214,[K1]=K14,x=29,y=684,},},[K2]=2212,[K1]=K4,x=4,y=687,},f=K3,[K8]=false,[K7]=0,rets={f=K3,[K4]={},[K2]=2215,[K1]=K4,x=36,y=684,},[K2]=2211,[K1]=K9,x=11,y=684,},},[K[52]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[52],x=8,xend=19,y=806,yend=806,},[K26]=true,t={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2890,[K1]=K5,[K5]="T@44",x=30,y=687,},},[K2]=2891,[K1]=K4,x=32,y=687,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2894,[K1]=K15,[K13]={[1]={f=K3,[K20]=T17,[K19]={[1]=K[77],},[K2]=2893,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=2892,[K1]=K5,[K5]="T@44",x=44,y=687,},},x=34,y=687,},[2]={f=K3,[K2]=2224,[K1]="nil",x=49,y=687,},},x=34,y=687,},},[K2]=2895,[K1]=K4,x=32,y=687,},[K2]=2896,[K1]=K9,x=18,y=687,},[K21]={[1]={f=K3,[K11]="T@44",[K2]=2889,[K1]=K11,x=27,y=687,},},[K2]=2897,[K1]=K22,x=4,y=689,},},io={[K27]={f=K3,kind=K25,tk="io",x=15,xend=16,y=151,yend=151,},["has_been_read_from"]=true,[K26]=true,[K33]=true,t=T8,},[K[103]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[103],x=8,xend=13,y=822,yend=822,},[K26]=true,[K33]=true,t={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2904,[K1]=K5,[K5]="A@45",x=25,y=689,},f=K3,[K2]=2905,[K1]=K36,x=24,y=689,},},[K2]=2906,[K1]=K4,x=28,y=689,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2907,[K1]=K5,[K5]="A@45",x=41,y=689,},f=K3,[K2]=2908,[K1]=K36,x=40,y=689,},[2]={f=K3,[K2]=2236,[K1]=K14,x=45,y=689,},},[K2]=2909,[K1]=K4,x=53,y=689,},f=K3,[K8]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2238,[K1]=K14,x=56,y=689,},[2]={f=K3,[K2]=2910,[K1]=K5,[K5]="A@45",x=65,y=689,},},[K2]=2911,[K1]=K4,x=53,y=689,},[K2]=2912,[K1]=K9,x=31,y=689,},[2]={[K35]={f=K3,[K2]=2913,[K1]=K5,[K5]="A@45",x=70,y=689,},f=K3,[K2]=2914,[K1]=K36,x=69,y=689,},[3]={f=K3,[K2]=2242,[K1]=K14,x=74,y=689,},},[K2]=2915,[K1]=K4,x=28,y=689,},[K42]=K[103],[K2]=2916,[K1]=K9,x=12,y=689,},[K21]={[1]={f=K3,[K11]="A@45",[K2]=2903,[K1]=K11,x=21,y=689,},},[K2]=2917,[K1]=K22,x=4,y=698,},},load={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="load",x=8,xend=11,y=807,yend=807,},[K26]=true,[K33]=true,t={f=K3,[K2]=2286,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=2246,[K1]=K15,[K13]={[1]={f=K3,[K2]=2247,[K1]=K12,x=20,y=698,},[2]={f=K3,[K20]=T20,[K19]={[1]="LoadFunction",},[K2]=2248,[K1]=K18,x=29,y=698,},},x=20,y=698,},[2]={f=K3,[K2]=2249,[K1]=K12,x=46,y=698,},[3]={f=K3,[K20]=T21,[K19]={[1]=K[104],},[K2]=2250,[K1]=K18,x=56,y=698,},[4]={f=K3,keys={f=K3,[K2]=2252,[K1]="any",x=69,y=698,},[K2]=2251,[K1]="map",[K34]={f=K3,[K2]=2253,[K1]="any",x=73,y=698,},x=68,xend=76,y=698,yend=698,},},[K2]=2245,[K1]=K4,x=78,y=698,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2255,[K1]=K15,[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2258,[K1]="any",x=90,y=698,},},[K2]=2257,[K1]=K4,x=90,y=698,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2260,[K1]="any",x=90,y=698,},},[K2]=2259,[K1]=K4,x=90,y=698,},[K2]=2256,[K1]=K9,x=81,y=698,},[2]={f=K3,[K2]=2261,[K1]="nil",x=92,y=698,},},x=81,y=698,},[2]={f=K3,[K2]=2262,[K1]=K15,[K13]={[1]={f=K3,[K2]=2263,[K1]=K12,x=97,y=698,},[2]={f=K3,[K2]=2264,[K1]="nil",x=106,y=698,},},x=97,y=698,},},[K2]=2254,[K1]=K4,x=78,y=698,},[K2]=2244,[K1]=K9,x=10,y=698,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=2267,[K1]=K15,[K13]={[1]={f=K3,[K2]=2268,[K1]=K12,x=20,y=706,},[2]={f=K3,[K20]=T20,[K19]={[1]="LoadFunction",},[K2]=2269,[K1]=K18,x=29,y=706,},},x=20,y=706,},[2]={f=K3,[K2]=2270,[K1]=K12,x=46,y=706,},[3]={f=K3,[K2]=2271,[K1]=K12,x=56,y=706,},[4]={f=K3,keys={f=K3,[K2]=2273,[K1]="any",x=69,y=706,},[K2]=2272,[K1]="map",[K34]={f=K3,[K2]=2274,[K1]="any",x=73,y=706,},x=68,xend=76,y=706,yend=706,},},[K2]=2266,[K1]=K4,x=78,y=706,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2276,[K1]=K15,[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2279,[K1]="any",x=90,y=706,},},[K2]=2278,[K1]=K4,x=90,y=706,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2281,[K1]="any",x=90,y=706,},},[K2]=2280,[K1]=K4,x=90,y=706,},[K2]=2277,[K1]=K9,x=81,y=706,},[2]={f=K3,[K2]=2282,[K1]="nil",x=92,y=706,},},x=81,y=706,},[2]={f=K3,[K2]=2283,[K1]=K15,[K13]={[1]={f=K3,[K2]=2284,[K1]=K12,x=97,y=706,},[2]={f=K3,[K2]=2285,[K1]="nil",x=106,y=706,},},x=97,y=706,},},[K2]=2275,[K1]=K4,x=78,y=706,},[K2]=2265,[K1]=K9,x=10,y=706,},},x=4,y=706,},},["loadfile"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="loadfile",x=8,xend=15,y=808,yend=808,},[K26]=true,[K33]=true,t={f=K3,[K2]=2323,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=2289,[K1]=K12,x=25,y=710,},[2]={f=K3,[K20]=T21,[K19]={[1]=K[104],},[K2]=2290,[K1]=K18,x=35,y=710,},[3]={f=K3,keys={f=K3,[K2]=2292,[K1]="any",x=48,y=710,},[K2]=2291,[K1]="map",[K34]={f=K3,[K2]=2293,[K1]="any",x=52,y=710,},x=47,xend=55,y=710,yend=710,},},[K2]=2288,[K1]=K4,x=57,y=710,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2295,[K1]=K15,[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2298,[K1]="any",x=69,y=710,},},[K2]=2297,[K1]=K4,x=69,y=710,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2300,[K1]="any",x=69,y=710,},},[K2]=2299,[K1]=K4,x=69,y=710,},[K2]=2296,[K1]=K9,x=60,y=710,},[2]={f=K3,[K2]=2301,[K1]="nil",x=71,y=710,},},x=60,y=710,},[2]={f=K3,[K2]=2302,[K1]=K15,[K13]={[1]={f=K3,[K2]=2303,[K1]=K12,x=76,y=710,},[2]={f=K3,[K2]=2304,[K1]="nil",x=85,y=710,},},x=76,y=710,},},[K2]=2294,[K1]=K4,x=57,y=710,},[K2]=2287,[K1]=K9,x=14,y=710,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=2307,[K1]=K12,x=25,y=713,},[2]={f=K3,[K2]=2308,[K1]=K12,x=35,y=713,},[3]={f=K3,keys={f=K3,[K2]=2310,[K1]="any",x=48,y=713,},[K2]=2309,[K1]="map",[K34]={f=K3,[K2]=2311,[K1]="any",x=52,y=713,},x=47,xend=55,y=713,yend=713,},},[K2]=2306,[K1]=K4,x=57,y=713,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2313,[K1]=K15,[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2316,[K1]="any",x=69,y=713,},},[K2]=2315,[K1]=K4,x=69,y=713,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2318,[K1]="any",x=69,y=713,},},[K2]=2317,[K1]=K4,x=69,y=713,},[K2]=2314,[K1]=K9,x=60,y=713,},[2]={f=K3,[K2]=2319,[K1]="nil",x=71,y=713,},},x=60,y=713,},[2]={f=K3,[K2]=2320,[K1]=K15,[K13]={[1]={f=K3,[K2]=2321,[K1]=K12,x=76,y=713,},[2]={f=K3,[K2]=2322,[K1]="nil",x=85,y=713,},},x=76,y=713,},},[K2]=2312,[K1]=K4,x=57,y=713,},[K2]=2305,[K1]=K9,x=14,y=713,},},x=4,y=713,},},math={[K27]={f=K3,kind=K25,tk="math",x=15,xend=18,y=323,yend=323,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]="math",f=K3,[K40]={[K[105]]={},abs={[1]={[1]={text="--- Return the absolute value, preserving the numeric type where possible.",x=4,y=326,},},},acos={[1]={[1]={text="--- Return the arc cosine in radians.",x=4,y=328,},},},asin={[1]={[1]={text="--- Return the arc sine in radians.",x=4,y=330,},},},atan={[1]={[1]={text="--- Return the arc tangent in radians; an optional second argument selects the quadrant.",x=4,y=332,},},},[K[106]]={[1]={[1]={text="--- Return the two-argument arc tangent in radians; runtime availability varies.",x=4,y=334,},},},ceil={[1]={[1]={text="--- Round toward positive infinity.",x=4,y=336,},},},cos={[1]={[1]={text="--- Return the cosine of an angle in radians.",x=4,y=338,},},},cosh={[1]={[1]={text="--- Return the hyperbolic cosine.",x=4,y=340,},},},deg={[1]={[1]={text="--- Convert radians to degrees.",x=4,y=342,},},},exp={[1]={[1]={text="--- Return e raised to the supplied power.",x=4,y=344,},},},[K[107]]={[1]={[1]={text="--- Round toward negative infinity.",x=4,y=346,},},},fmod={[1]={[1]={text="--- Return the remainder after division with the quotient rounded toward zero.",x=4,y=349,},},[2]={[1]={text="--- Return the remainder after division with the quotient rounded toward zero.",x=4,y=351,},},},[K[108]]={[1]={[1]={text="--- Split a number into a normalized fraction and an exponent in base two.",x=4,y=354,},},},huge={[1]={[1]={text="--- Positive infinity.",x=4,y=356,},},},[K[109]]={[1]={[1]={text="--- Multiply a fraction by two raised to an integer exponent.",x=4,y=358,},},},log={[1]={[1]={text="--- Return a logarithm; the optional base defaults to e.",x=4,y=360,},},},[K[110]]={[1]={[1]={text="--- Return the base-ten logarithm.",x=4,y=362,},},},max={[1]={[1]={text=K[111],x=4,y=365,},},[2]={[1]={text=K[111],x=4,y=367,},},[3]={[1]={text=K[111],x=4,y=369,},},[4]={[1]={text=K[111],x=4,y=371,},},},[K[112]]={[1]={[1]={text="--- Largest representable integer where supported.",x=4,y=374,},},},min={[1]={[1]={text=K[113],x=4,y=377,},},[2]={[1]={text=K[113],x=4,y=379,},},[3]={[1]={text=K[113],x=4,y=381,},},[4]={[1]={text=K[113],x=4,y=383,},},},[K[114]]={[1]={[1]={text="--- Smallest representable integer where supported.",x=4,y=386,},},},modf={[1]={[1]={text="--- Split a number into its integral and fractional parts.",x=4,y=389,},},},pi={[1]={[1]={text="--- The mathematical constant pi.",x=4,y=391,},},},pow={[1]={[1]={text="--- Raise the first argument to the second power.",x=4,y=393,},},},rad={[1]={[1]={text="--- Convert degrees to radians.",x=4,y=395,},},},[K[115]]={[1]={[1]={text="--- Generate a pseudorandom value. Without bounds return a fraction; with one or two integer bounds return an integer in the inclusive range.",x=4,y=398,},},[2]={[1]={text="--- Generate a pseudorandom value. Without bounds return a fraction; with one or two integer bounds return an integer in the inclusive range.",x=4,y=400,},},},[K[116]]={[1]={[1]={text="--- Initialize the pseudorandom generator. Seed handling and returned values vary by Lua version.",x=4,y=403,},},},sin={[1]={[1]={text="--- Return the sine of an angle in radians.",x=4,y=405,},},},sinh={[1]={[1]={text="--- Return the hyperbolic sine.",x=4,y=407,},},},sqrt={[1]={[1]={text="--- Return the square root.",x=4,y=409,},},},tan={[1]={[1]={text="--- Return the tangent of an angle in radians.",x=4,y=411,},},},tanh={[1]={[1]={text="--- Return the hyperbolic tangent.",x=4,y=413,},},},[K[117]]={[1]={[1]={text="--- Convert an exactly representable value to an integer, or return nil if conversion fails.",x=4,y=415,},[2]={text=K31,x=4,y=416,},},},type={[1]={[1]={text="--- Return the numeric representation (`integer` or `float`), or nil for a non-number.",x=4,y=418,},[2]={text=K31,x=4,y=419,},},},ult={[1]={[1]={text="--- Compare two integers as unsigned values.",x=4,y=421,},},},},[K46]={[K[105]]={f=K3,x=9,y=324,},abs={f=K3,x=4,y=327,},acos={f=K3,x=4,y=329,},asin={f=K3,x=4,y=331,},atan={f=K3,x=4,y=333,},[K[106]]={f=K3,x=4,y=335,},ceil={f=K3,x=4,y=337,},cos={f=K3,x=4,y=339,},cosh={f=K3,x=4,y=341,},deg={f=K3,x=4,y=343,},exp={f=K3,x=4,y=345,},[K[107]]={f=K3,x=4,y=347,},fmod={f=K3,x=4,y=350,},[K[108]]={f=K3,x=4,y=355,},huge={f=K3,x=4,y=357,},[K[109]]={f=K3,x=4,y=359,},log={f=K3,x=4,y=361,},[K[110]]={f=K3,x=4,y=363,},max={f=K3,x=4,y=366,},[K[112]]={f=K3,x=4,y=375,},min={f=K3,x=4,y=378,},[K[114]]={f=K3,x=4,y=387,},modf={f=K3,x=4,y=390,},pi={f=K3,x=4,y=392,},pow={f=K3,x=4,y=394,},rad={f=K3,x=4,y=396,},[K[115]]={f=K3,x=4,y=399,},[K[116]]={f=K3,x=4,y=404,},sin={f=K3,x=4,y=406,},sinh={f=K3,x=4,y=408,},sqrt={f=K3,x=4,y=410,},tan={f=K3,x=4,y=412,},tanh={f=K3,x=4,y=414,},[K[117]]={f=K3,x=4,y=417,},type={f=K3,x=4,y=420,},ult={f=K3,x=4,y=422,},},[K39]={[1]=K[105],[2]="abs",[3]="acos",[4]="asin",[5]="atan",[6]=K[106],[7]="ceil",[8]="cos",[9]="cosh",[10]="deg",[11]="exp",[12]=K[107],[13]="fmod",[14]=K[108],[15]="huge",[16]=K[109],[17]="log",[18]=K[110],[19]="max",[20]=K[112],[21]="min",[22]=K[114],[23]="modf",[24]="pi",[25]="pow",[26]="rad",[27]=K[115],[28]=K[116],[29]="sin",[30]="sinh",[31]="sqrt",[32]="tan",[33]="tanh",[34]=K[117],[35]="type",[36]="ult",},[K38]={[K[105]]=T22,abs={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K[118]]=T23,f=K3,[K2]=2638,[K1]=K5,[K5]="N@27",x=32,y=327,},},[K2]=2639,[K1]=K4,x=34,y=327,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={[K[118]]=T23,f=K3,[K2]=2640,[K1]=K5,[K5]="N@27",x=36,y=327,},},[K2]=2641,[K1]=K4,x=34,y=327,},[K2]=2642,[K1]=K9,x=9,y=327,},[K21]={[1]={[K[118]]=T23,f=K3,[K11]="N@27",[K2]=2637,[K1]=K11,x=18,y=327,},},[K2]=2643,[K1]=K22,x=4,y=329,},acos={args={f=K3,[K4]={[1]={f=K3,[K2]=1309,[K1]=K16,x=19,y=329,},},[K2]=1308,[K1]=K4,x=26,y=329,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1311,[K1]=K16,x=28,y=329,},},[K2]=1310,[K1]=K4,x=26,y=329,},[K2]=1307,[K1]=K9,x=10,y=329,},asin={args={f=K3,[K4]={[1]={f=K3,[K2]=1314,[K1]=K16,x=19,y=331,},},[K2]=1313,[K1]=K4,x=26,y=331,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1316,[K1]=K16,x=28,y=331,},},[K2]=1315,[K1]=K4,x=26,y=331,},[K2]=1312,[K1]=K9,x=10,y=331,},atan={args={f=K3,[K4]={[1]={f=K3,[K2]=1319,[K1]=K16,x=19,y=333,},[2]={f=K3,[K2]=1320,[K1]=K16,x=29,y=333,},},[K2]=1318,[K1]=K4,x=36,y=333,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1322,[K1]=K16,x=38,y=333,},},[K2]=1321,[K1]=K4,x=36,y=333,},[K2]=1317,[K1]=K9,x=10,y=333,},[K[106]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1325,[K1]=K16,x=20,y=335,},[2]={f=K3,[K2]=1326,[K1]=K16,x=28,y=335,},},[K2]=1324,[K1]=K4,x=35,y=335,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1328,[K1]=K16,x=37,y=335,},},[K2]=1327,[K1]=K4,x=35,y=335,},[K2]=1323,[K1]=K9,x=11,y=335,},ceil={args={f=K3,[K4]={[1]={f=K3,[K2]=1331,[K1]=K16,x=19,y=337,},},[K2]=1330,[K1]=K4,x=26,y=337,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1333,[K1]=K14,x=28,y=337,},},[K2]=1332,[K1]=K4,x=26,y=337,},[K2]=1329,[K1]=K9,x=10,y=337,},cos={args={f=K3,[K4]={[1]={f=K3,[K2]=1336,[K1]=K16,x=18,y=339,},},[K2]=1335,[K1]=K4,x=25,y=339,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1338,[K1]=K16,x=27,y=339,},},[K2]=1337,[K1]=K4,x=25,y=339,},[K2]=1334,[K1]=K9,x=9,y=339,},cosh={args={f=K3,[K4]={[1]={f=K3,[K2]=1341,[K1]=K16,x=19,y=341,},},[K2]=1340,[K1]=K4,x=26,y=341,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1343,[K1]=K16,x=28,y=341,},},[K2]=1342,[K1]=K4,x=26,y=341,},[K2]=1339,[K1]=K9,x=10,y=341,},deg={args={f=K3,[K4]={[1]={f=K3,[K2]=1346,[K1]=K16,x=18,y=343,},},[K2]=1345,[K1]=K4,x=25,y=343,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1348,[K1]=K16,x=27,y=343,},},[K2]=1347,[K1]=K4,x=25,y=343,},[K2]=1344,[K1]=K9,x=9,y=343,},exp={args={f=K3,[K4]={[1]={f=K3,[K2]=1351,[K1]=K16,x=18,y=345,},},[K2]=1350,[K1]=K4,x=25,y=345,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1353,[K1]=K16,x=27,y=345,},},[K2]=1352,[K1]=K4,x=25,y=345,},[K2]=1349,[K1]=K9,x=9,y=345,},[K[107]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1356,[K1]=K16,x=20,y=347,},},[K2]=1355,[K1]=K4,x=27,y=347,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1358,[K1]=K14,x=29,y=347,},},[K2]=1357,[K1]=K4,x=27,y=347,},[K2]=1354,[K1]=K9,x=11,y=347,},fmod={f=K3,[K2]=1371,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1361,[K1]=K14,x=19,y=350,},[2]={f=K3,[K2]=1362,[K1]=K14,x=28,y=350,},},[K2]=1360,[K1]=K4,x=36,y=350,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1364,[K1]=K14,x=38,y=350,},},[K2]=1363,[K1]=K4,x=36,y=350,},[K2]=1359,[K1]=K9,x=10,y=350,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=1367,[K1]=K16,x=19,y=352,},[2]={f=K3,[K2]=1368,[K1]=K16,x=27,y=352,},},[K2]=1366,[K1]=K4,x=34,y=352,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1370,[K1]=K16,x=36,y=352,},},[K2]=1369,[K1]=K4,x=34,y=352,},[K2]=1365,[K1]=K9,x=10,y=352,},},x=4,y=352,},[K[108]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1374,[K1]=K16,x=20,y=355,},},[K2]=1373,[K1]=K4,x=27,y=355,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1376,[K1]=K16,x=29,y=355,},[2]={f=K3,[K2]=1377,[K1]=K14,x=37,y=355,},},[K2]=1375,[K1]=K4,x=27,y=355,},[K2]=1372,[K1]=K9,x=11,y=355,},huge={f=K3,[K2]=1378,[K1]=K16,x=10,y=357,},[K[109]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1381,[K1]=K16,x=20,y=359,},[2]={f=K3,[K2]=1382,[K1]=K14,x=28,y=359,},},[K2]=1380,[K1]=K4,x=36,y=359,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1384,[K1]=K16,x=38,y=359,},},[K2]=1383,[K1]=K4,x=36,y=359,},[K2]=1379,[K1]=K9,x=11,y=359,},log={args={f=K3,[K4]={[1]={f=K3,[K2]=1387,[K1]=K16,x=18,y=361,},[2]={f=K3,[K2]=1388,[K1]=K16,x=28,y=361,},},[K2]=1386,[K1]=K4,x=35,y=361,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1390,[K1]=K16,x=37,y=361,},},[K2]=1389,[K1]=K4,x=35,y=361,},[K2]=1385,[K1]=K9,x=9,y=361,},[K[110]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1393,[K1]=K16,x=20,y=363,},},[K2]=1392,[K1]=K4,x=27,y=363,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1395,[K1]=K16,x=29,y=363,},},[K2]=1394,[K1]=K4,x=27,y=363,},[K2]=1391,[K1]=K9,x=11,y=363,},max={f=K3,[K2]=1408,[K1]="poly",[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1398,[K1]=K14,x=18,y=366,},},[K2]=1397,[K1]=K4,x=29,y=366,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1400,[K1]=K14,x=31,y=366,},},[K2]=1399,[K1]=K4,x=29,y=366,},[K2]=1396,[K1]=K9,x=9,y=366,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1403,[K1]=K15,[K13]={[1]={f=K3,[K2]=1404,[K1]=K16,x=19,y=368,},[2]={f=K3,[K2]=1405,[K1]=K14,x=28,y=368,},},x=19,y=368,},},[K2]=1402,[K1]=K4,x=40,y=368,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1407,[K1]=K16,x=42,y=368,},},[K2]=1406,[K1]=K4,x=40,y=368,},[K2]=1401,[K1]=K9,x=9,y=368,},[3]={f=K3,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2645,[K1]=K5,[K5]="T",x=21,y=370,},},[K2]=1411,[K1]=K4,x=26,y=370,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2646,[K1]=K5,[K5]="T",x=28,y=370,},},[K2]=1413,[K1]=K4,x=26,y=370,},[K2]=1410,[K1]=K9,x=9,y=370,},[K21]={[1]={f=K3,[K11]="T",[K2]=1409,[K1]=K11,x=18,y=370,},},[K2]=1415,[K1]=K22,x=4,y=372,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1418,[K1]="any",x=18,y=372,},},[K2]=1417,[K1]=K4,x=25,y=372,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1420,[K1]="any",x=27,y=372,},},[K2]=1419,[K1]=K4,x=25,y=372,},[K2]=1416,[K1]=K9,x=9,y=372,},},x=4,y=368,},[K[112]]={f=K3,[K33]=true,[K2]=1421,[K1]=K14,x=16,y=375,},min={f=K3,[K2]=1434,[K1]="poly",[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1424,[K1]=K14,x=18,y=378,},},[K2]=1423,[K1]=K4,x=29,y=378,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1426,[K1]=K14,x=31,y=378,},},[K2]=1425,[K1]=K4,x=29,y=378,},[K2]=1422,[K1]=K9,x=9,y=378,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1429,[K1]=K15,[K13]={[1]={f=K3,[K2]=1430,[K1]=K16,x=19,y=380,},[2]={f=K3,[K2]=1431,[K1]=K14,x=28,y=380,},},x=19,y=380,},},[K2]=1428,[K1]=K4,x=40,y=380,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1433,[K1]=K16,x=42,y=380,},},[K2]=1432,[K1]=K4,x=40,y=380,},[K2]=1427,[K1]=K9,x=9,y=380,},[3]={f=K3,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2655,[K1]=K5,[K5]="T",x=21,y=382,},},[K2]=1437,[K1]=K4,x=26,y=382,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2656,[K1]=K5,[K5]="T",x=28,y=382,},},[K2]=1439,[K1]=K4,x=26,y=382,},[K2]=1436,[K1]=K9,x=9,y=382,},[K21]={[1]={f=K3,[K11]="T",[K2]=1435,[K1]=K11,x=18,y=382,},},[K2]=1441,[K1]=K22,x=4,y=384,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1444,[K1]="any",x=18,y=384,},},[K2]=1443,[K1]=K4,x=25,y=384,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1446,[K1]="any",x=27,y=384,},},[K2]=1445,[K1]=K4,x=25,y=384,},[K2]=1442,[K1]=K9,x=9,y=384,},},x=4,y=380,},[K[114]]={f=K3,[K33]=true,[K2]=1447,[K1]=K14,x=16,y=387,},modf={args={f=K3,[K4]={[1]={f=K3,[K2]=1450,[K1]=K16,x=19,y=390,},},[K2]=1449,[K1]=K4,x=26,y=390,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1452,[K1]=K14,x=28,y=390,},[2]={f=K3,[K2]=1453,[K1]=K16,x=37,y=390,},},[K2]=1451,[K1]=K4,x=26,y=390,},[K2]=1448,[K1]=K9,x=10,y=390,},pi={f=K3,[K2]=1454,[K1]=K16,x=8,y=392,},pow={args={f=K3,[K4]={[1]={f=K3,[K2]=1457,[K1]=K16,x=18,y=394,},[2]={f=K3,[K2]=1458,[K1]=K16,x=26,y=394,},},[K2]=1456,[K1]=K4,x=33,y=394,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1460,[K1]=K16,x=35,y=394,},},[K2]=1459,[K1]=K4,x=33,y=394,},[K2]=1455,[K1]=K9,x=9,y=394,},rad={args={f=K3,[K4]={[1]={f=K3,[K2]=1463,[K1]=K16,x=18,y=396,},},[K2]=1462,[K1]=K4,x=25,y=396,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1465,[K1]=K16,x=27,y=396,},},[K2]=1464,[K1]=K4,x=25,y=396,},[K2]=1461,[K1]=K9,x=9,y=396,},[K[115]]={f=K3,[K2]=1476,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1468,[K1]=K14,x=21,y=399,},[2]={f=K3,[K2]=1469,[K1]=K14,x=32,y=399,},},[K2]=1467,[K1]=K4,x=40,y=399,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1471,[K1]=K14,x=42,y=399,},},[K2]=1470,[K1]=K4,x=40,y=399,},[K2]=1466,[K1]=K9,x=12,y=399,},[2]={args={f=K3,[K4]={},[K2]=1473,[K1]=K4,x=22,y=401,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1475,[K1]=K16,x=24,y=401,},},[K2]=1474,[K1]=K4,x=22,y=401,},[K2]=1472,[K1]=K9,x=12,y=401,},},x=4,y=401,},[K[116]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1479,[K1]=K14,x=27,y=404,},[2]={f=K3,[K2]=1480,[K1]=K14,x=38,y=404,},},[K2]=1478,[K1]=K4,x=46,y=404,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1482,[K1]=K14,x=48,y=404,},[2]={f=K3,[K2]=1483,[K1]=K14,x=57,y=404,},},[K2]=1481,[K1]=K4,x=46,y=404,},[K2]=1477,[K1]=K9,x=16,y=404,},sin={args={f=K3,[K4]={[1]={f=K3,[K2]=1486,[K1]=K16,x=18,y=406,},},[K2]=1485,[K1]=K4,x=25,y=406,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1488,[K1]=K16,x=27,y=406,},},[K2]=1487,[K1]=K4,x=25,y=406,},[K2]=1484,[K1]=K9,x=9,y=406,},sinh={args={f=K3,[K4]={[1]={f=K3,[K2]=1491,[K1]=K16,x=19,y=408,},},[K2]=1490,[K1]=K4,x=26,y=408,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1493,[K1]=K16,x=28,y=408,},},[K2]=1492,[K1]=K4,x=26,y=408,},[K2]=1489,[K1]=K9,x=10,y=408,},sqrt={args={f=K3,[K4]={[1]={f=K3,[K2]=1496,[K1]=K16,x=19,y=410,},},[K2]=1495,[K1]=K4,x=26,y=410,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1498,[K1]=K16,x=28,y=410,},},[K2]=1497,[K1]=K4,x=26,y=410,},[K2]=1494,[K1]=K9,x=10,y=410,},tan={args={f=K3,[K4]={[1]={f=K3,[K2]=1501,[K1]=K16,x=18,y=412,},},[K2]=1500,[K1]=K4,x=25,y=412,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1503,[K1]=K16,x=27,y=412,},},[K2]=1502,[K1]=K4,x=25,y=412,},[K2]=1499,[K1]=K9,x=9,y=412,},tanh={args={f=K3,[K4]={[1]={f=K3,[K2]=1506,[K1]=K16,x=19,y=414,},},[K2]=1505,[K1]=K4,x=26,y=414,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1508,[K1]=K16,x=28,y=414,},},[K2]=1507,[K1]=K4,x=26,y=414,},[K2]=1504,[K1]=K9,x=10,y=414,},[K[117]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1511,[K1]="any",x=24,y=417,},},[K2]=1510,[K1]=K4,x=28,y=417,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1513,[K1]=K15,[K13]={[1]={f=K3,[K2]=1514,[K1]=K14,x=30,y=417,},[2]={f=K3,[K2]=1515,[K1]="nil",x=40,y=417,},},x=30,y=417,},},[K2]=1512,[K1]=K4,x=28,y=417,},[K2]=1509,[K1]=K9,x=15,y=417,},type={args={f=K3,[K4]={[1]={f=K3,[K2]=1518,[K1]="any",x=19,y=420,},},[K2]=1517,[K1]=K4,x=23,y=420,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1520,[K1]=K15,[K13]={[1]={f=K3,[K2]=1521,[K1]=K12,x=25,y=420,},[2]={f=K3,[K2]=1522,[K1]="nil",x=34,y=420,},},x=25,y=420,},},[K2]=1519,[K1]=K4,x=23,y=420,},[K2]=1516,[K1]=K9,x=10,y=420,},ult={args={f=K3,[K4]={[1]={f=K3,[K2]=1525,[K1]=K16,x=18,y=422,},[2]={f=K3,[K2]=1526,[K1]=K16,x=26,y=422,},},[K2]=1524,[K1]=K4,x=33,y=422,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1528,[K1]=K29,x=35,y=422,},},[K2]=1527,[K1]=K4,x=33,y=422,},[K2]=1523,[K1]=K9,x=9,y=422,},},[K37]={},[K2]=1292,[K1]=K45,x=1,y=323,},f=K3,[K2]=1529,[K1]=K28,x=1,y=323,},},[K[77]]={[K27]={f=K6,kind=K25,tk=K[77],x=15,xend=23,y=18,yend=18,},[K26]=true,t=T17,[K[33]]=true,},next={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="next",x=8,xend=11,y=809,yend=809,},[K26]=true,t={f=K3,[K2]=2354,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2920,[K1]=K5,[K5]="K",x=26,y=720,},[K2]=2328,[K1]="map",[K34]={f=K3,[K2]=2921,[K1]=K5,[K5]="V",x=28,y=720,},x=25,xend=29,y=720,yend=720,},[2]={f=K3,[K2]=2922,[K1]=K5,[K5]="K",x=34,y=720,},},[K2]=2327,[K1]=K4,x=36,y=720,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2333,[K1]=K15,[K13]={[1]={f=K3,[K2]=2923,[K1]=K5,[K5]="K",x=39,y=720,},[2]={f=K3,[K2]=2335,[K1]="nil",x=43,y=720,},},x=39,y=720,},[2]={f=K3,[K2]=2336,[K1]=K15,[K13]={[1]={f=K3,[K2]=2924,[K1]=K5,[K5]="V",x=48,y=720,},[2]={f=K3,[K2]=2338,[K1]="nil",x=52,y=720,},},x=48,y=720,},},[K2]=2332,[K1]=K4,x=36,y=720,},[K2]=2326,[K1]=K9,x=10,y=720,},[K21]={[1]={f=K3,[K11]="K",[K2]=2324,[K1]=K11,x=19,y=720,},[2]={f=K3,[K11]="V",[K2]=2325,[K1]=K11,x=22,y=720,},},[K2]=2339,[K1]=K22,x=4,y=726,},[2]={f=K3,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2940,[K1]=K5,[K5]="A",x=23,y=726,},f=K3,[K2]=2343,[K1]=K36,x=22,xend=24,y=726,yend=726,},[2]={f=K3,[K2]=2345,[K1]=K14,x=29,y=726,},},[K2]=2342,[K1]=K4,x=37,y=726,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2347,[K1]=K15,[K13]={[1]={f=K3,[K2]=2348,[K1]=K14,x=40,y=726,},[2]={f=K3,[K2]=2349,[K1]="nil",x=50,y=726,},},x=40,y=726,},[2]={f=K3,[K2]=2350,[K1]=K15,[K13]={[1]={f=K3,[K2]=2941,[K1]=K5,[K5]="A",x=55,y=726,},[2]={f=K3,[K2]=2352,[K1]="nil",x=59,y=726,},},x=55,y=726,},},[K2]=2346,[K1]=K4,x=37,y=726,},[K2]=2341,[K1]=K9,x=10,y=726,},[K21]={[1]={f=K3,[K11]="A",[K2]=2340,[K1]=K11,x=19,y=726,},},[K2]=2353,[K1]=K22,x=4,y=729,},},x=4,y=726,},},os={[K27]={f=K3,kind=K25,tk="os",x=15,xend=16,y=426,yend=426,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]="os",f=K3,[K40]={[K[119]]={},[K[120]]={},[K[121]]={[1]={[1]={text="--- Return approximate CPU time used by the program in seconds.",x=4,y=443,},},},date={[1]={[1]={text="--- Format a time using a date format, or return a date table for `*t` and `!*t`. The `!` prefix selects UTC.",x=4,y=446,},},[2]={[1]={text="--- Format a time using a date format, or return a date table for `*t` and `!*t`. The `!` prefix selects UTC.",x=4,y=448,},},},[K[122]]={[1]={[1]={text="--- Return the difference between two time values in seconds.",x=4,y=451,},},},[K[123]]={[1]={[1]={text="--- Pass a command to the operating system shell. Status results and their availability vary by runtime and platform.",x=4,y=453,},},},exit={[1]={[1]={text="--- Terminate the host process with an optional status and optional close flag.",x=4,y=455,},},},[K[124]]={[1]={[1]={text="--- Read an environment variable, returning nil when it is absent.",x=4,y=457,},[2]={text="---",x=4,y=458,},[3]={text="--- @param name Environment variable name.",x=4,y=459,},[4]={text="--- @return Its string value, or nil if the name is absent.",x=4,y=460,},},},[K[125]]={[1]={[1]={text="--- Remove a file or empty directory. Return success or nil, an error message and a system code.",x=4,y=462,},[2]={text=K31,x=4,y=463,},},},[K[126]]={[1]={[1]={text="--- Rename or move a file. Return success or nil, an error message and a system code.",x=4,y=465,},[2]={text=K31,x=4,y=466,},},},[K[127]]={[1]={[1]={text="--- Set or query the process locale for an optional category; return nil when the locale cannot be selected.",x=4,y=468,},[2]={text=K31,x=4,y=469,},},},time={[1]={[1]={text="--- Return the current time, or convert a date table to a time value in local time.",x=4,y=471,},},},[K[128]]={[1]={[1]={text="--- Return a name suitable for a temporary file; platform-specific creation and cleanup rules apply.",x=4,y=473,},},},},[K46]={[K[119]]={f=K3,x=4,y=439,},[K[120]]={f=K3,x=4,y=427,},[K[121]]={f=K3,x=4,y=444,},date={f=K3,x=4,y=447,},[K[122]]={f=K3,x=4,y=452,},[K[123]]={f=K3,x=4,y=454,},exit={f=K3,x=4,y=456,},[K[124]]={f=K3,x=4,y=461,},[K[125]]={f=K3,x=4,y=464,},[K[126]]={f=K3,x=4,y=467,},[K[127]]={f=K3,x=4,y=470,},time={f=K3,x=4,y=472,},[K[128]]={f=K3,x=4,y=474,},},[K39]={[1]=K[120],[2]=K[119],[3]=K[121],[4]="date",[5]=K[122],[6]=K[123],[7]="exit",[8]=K[124],[9]=K[125],[10]=K[126],[11]=K[127],[12]="time",[13]=K[128],},[K38]={[K[119]]=T24,[K[120]]=T25,[K[121]]={args={f=K3,[K4]={},[K2]=1551,[K1]=K4,x=21,y=444,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1553,[K1]=K16,x=23,y=444,},},[K2]=1552,[K1]=K4,x=21,y=444,},[K2]=1550,[K1]=K9,x=11,y=444,},date={f=K3,[K2]=1566,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K20]=T24,[K19]={[1]=K[119],},[K2]=1556,[K1]=K18,x=19,y=447,},[2]={f=K3,[K2]=1557,[K1]=K16,x=31,y=447,},},[K2]=1555,[K1]=K4,x=38,y=447,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K20]=T25,[K19]={[1]=K[120],},[K2]=1559,[K1]=K18,x=40,y=447,},},[K2]=1558,[K1]=K4,x=38,y=447,},[K2]=1554,[K1]=K9,x=10,y=447,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=1562,[K1]=K12,x=21,y=449,},[2]={f=K3,[K2]=1563,[K1]=K16,x=31,y=449,},},[K2]=1561,[K1]=K4,x=38,y=449,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1565,[K1]=K12,x=40,y=449,},},[K2]=1564,[K1]=K4,x=38,y=449,},[K2]=1560,[K1]=K9,x=10,y=449,},},x=4,y=449,},[K[122]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1569,[K1]=K14,x=23,y=452,},[2]={f=K3,[K2]=1570,[K1]=K14,x=32,y=452,},},[K2]=1568,[K1]=K4,x=40,y=452,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1572,[K1]=K16,x=42,y=452,},},[K2]=1571,[K1]=K4,x=40,y=452,},[K2]=1567,[K1]=K9,x=14,y=452,},[K[123]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1575,[K1]=K12,x=22,y=454,},},[K2]=1574,[K1]=K4,x=29,y=454,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1577,[K1]=K15,[K13]={[1]={f=K3,[K2]=1578,[K1]=K29,x=31,y=454,},[2]={f=K3,[K2]=1579,[K1]="nil",x=41,y=454,},},x=31,y=454,},[2]={f=K3,[K2]=1580,[K1]=K15,[K13]={[1]={f=K3,[K2]=1581,[K1]=K12,x=46,y=454,},[2]={f=K3,[K2]=1582,[K1]="nil",x=55,y=454,},},x=46,y=454,},[3]={f=K3,[K2]=1583,[K1]=K15,[K13]={[1]={f=K3,[K2]=1584,[K1]=K14,x=60,y=454,},[2]={f=K3,[K2]=1585,[K1]="nil",x=70,y=454,},},x=60,y=454,},},[K2]=1576,[K1]=K4,x=29,y=454,},[K2]=1573,[K1]=K9,x=13,y=454,},exit={args={f=K3,[K4]={[1]={f=K3,[K2]=1588,[K1]=K15,[K13]={[1]={f=K3,[K2]=1589,[K1]=K14,x=22,y=456,},[2]={f=K3,[K2]=1590,[K1]=K29,x=32,y=456,},},x=22,y=456,},[2]={f=K3,[K2]=1591,[K1]=K29,x=44,y=456,},},[K2]=1587,[K1]=K4,x=4,y=461,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={},[K2]=1592,[K1]=K4,x=51,y=456,},[K2]=1586,[K1]=K9,x=10,y=456,},[K[124]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1595,[K1]=K12,x=21,y=461,},},[K2]=1594,[K1]=K4,x=28,y=461,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1597,[K1]=K15,[K13]={[1]={f=K3,[K2]=1598,[K1]=K12,x=30,y=461,},[2]={f=K3,[K2]=1599,[K1]="nil",x=39,y=461,},},x=30,y=461,},},[K2]=1596,[K1]=K4,x=28,y=461,},[K2]=1593,[K1]=K9,x=12,y=461,},[K[125]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1602,[K1]=K12,x=21,y=464,},},[K2]=1601,[K1]=K4,x=28,y=464,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1604,[K1]=K15,[K13]={[1]={f=K3,[K2]=1605,[K1]=K29,x=30,y=464,},[2]={f=K3,[K2]=1606,[K1]="nil",x=40,y=464,},},x=30,y=464,},[2]={f=K3,[K2]=1607,[K1]=K15,[K13]={[1]={f=K3,[K2]=1608,[K1]=K12,x=45,y=464,},[2]={f=K3,[K2]=1609,[K1]="nil",x=54,y=464,},},x=45,y=464,},[3]={f=K3,[K2]=1610,[K1]=K15,[K13]={[1]={f=K3,[K2]=1611,[K1]=K14,x=59,y=464,},[2]={f=K3,[K2]=1612,[K1]="nil",x=69,y=464,},},x=59,y=464,},},[K2]=1603,[K1]=K4,x=28,y=464,},[K2]=1600,[K1]=K9,x=12,y=464,},[K[126]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1615,[K1]=K12,x=21,y=467,},[2]={f=K3,[K2]=1616,[K1]=K12,x=29,y=467,},},[K2]=1614,[K1]=K4,x=36,y=467,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1618,[K1]=K15,[K13]={[1]={f=K3,[K2]=1619,[K1]=K29,x=38,y=467,},[2]={f=K3,[K2]=1620,[K1]="nil",x=48,y=467,},},x=38,y=467,},[2]={f=K3,[K2]=1621,[K1]=K15,[K13]={[1]={f=K3,[K2]=1622,[K1]=K12,x=53,y=467,},[2]={f=K3,[K2]=1623,[K1]="nil",x=62,y=467,},},x=53,y=467,},[3]={f=K3,[K2]=1624,[K1]=K15,[K13]={[1]={f=K3,[K2]=1625,[K1]=K14,x=67,y=467,},[2]={f=K3,[K2]=1626,[K1]="nil",x=77,y=467,},},x=67,y=467,},},[K2]=1617,[K1]=K4,x=36,y=467,},[K2]=1613,[K1]=K9,x=12,y=467,},[K[127]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1629,[K1]=K12,x=24,y=470,},[2]={f=K3,[K2]=1630,[K1]=K12,x=34,y=470,},},[K2]=1628,[K1]=K4,x=41,y=470,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1632,[K1]=K15,[K13]={[1]={f=K3,[K2]=1633,[K1]=K12,x=43,y=470,},[2]={f=K3,[K2]=1634,[K1]="nil",x=52,y=470,},},x=43,y=470,},},[K2]=1631,[K1]=K4,x=41,y=470,},[K2]=1627,[K1]=K9,x=15,y=470,},time={args={f=K3,[K4]={[1]={f=K3,[K20]=T25,[K19]={[1]=K[120],},[K2]=1637,[K1]=K18,x=21,y=472,},},[K2]=1636,[K1]=K4,x=31,y=472,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1639,[K1]=K14,x=33,y=472,},},[K2]=1638,[K1]=K4,x=31,y=472,},[K2]=1635,[K1]=K9,x=10,y=472,},[K[128]]={args={f=K3,[K4]={},[K2]=1641,[K1]=K4,x=23,y=474,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1643,[K1]=K12,x=25,y=474,},},[K2]=1642,[K1]=K4,x=23,y=474,},[K2]=1640,[K1]=K9,x=13,y=474,},},[K37]={},[K2]=1532,[K1]=K45,x=1,y=426,},f=K3,[K2]=1644,[K1]=K28,x=1,y=426,},},[K[131]]={[K27]={f=K3,kind=K25,tk=K[131],x=15,xend=21,y=478,yend=478,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]=K[131],f=K3,[K40]={[K[132]]={[1]={[1]={text="--- Runtime-specific directory and module path separator configuration.",x=4,y=479,},},},[K[133]]={[1]={[1]={text="--- Templates used to search for native modules.",x=4,y=481,},},},[K[134]]={[1]={[1]={text="--- Module cache consulted by require.",x=4,y=483,},},},[K[135]]={[1]={[1]={text="--- Lua 5.1 module searchers.",x=4,y=488,},},},[K[136]]={[1]={[1]={text="--- Load a named C symbol from a shared library. Return the function or nil with diagnostic information.",x=4,y=485,},[2]={text=K31,x=4,y=486,},},},path={[1]={[1]={text="--- Templates used to search for Lua modules.",x=4,y=490,},},},[K[137]]={[1]={[1]={text="--- Registered module loader functions.",x=4,y=492,},},},[K[138]]={[1]={[1]={text="--- Module searchers used by later Lua versions.",x=4,y=494,},},},[K[139]]={[1]={[1]={text="--- Search a path template for a module name. Return the filename or nil and a description of attempted paths.",x=4,y=496,},[2]={text=K31,x=4,y=497,},},},},[K46]={[K[132]]={f=K3,x=4,y=480,},[K[133]]={f=K3,x=4,y=482,},[K[134]]={f=K3,x=4,y=484,},[K[135]]={f=K3,x=4,y=489,},[K[136]]={f=K3,x=4,y=487,},path={f=K3,x=4,y=491,},[K[137]]={f=K3,x=4,y=493,},[K[138]]={f=K3,x=4,y=495,},[K[139]]={f=K3,x=4,y=498,},},[K39]={[1]=K[132],[2]=K[133],[3]=K[134],[4]=K[136],[5]=K[135],[6]="path",[7]=K[137],[8]=K[138],[9]=K[139],},[K38]={[K[132]]={f=K3,[K2]=1648,[K1]=K12,x=12,y=480,},[K[133]]={f=K3,[K2]=1649,[K1]=K12,x=11,y=482,},[K[134]]={f=K3,keys={f=K3,[K2]=1651,[K1]=K12,x=13,y=484,},[K2]=1650,[K1]="map",[K34]={f=K3,[K2]=1652,[K1]="any",x=20,y=484,},x=12,xend=23,y=484,yend=484,},[K[135]]={[K35]={args={f=K3,[K4]={[1]={f=K3,[K2]=1674,[K1]=K12,x=25,y=489,},},[K2]=1673,[K1]=K4,x=32,y=489,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1678,[K1]=K12,x=46,y=489,},[2]={f=K3,[K2]=1679,[K1]="any",x=56,y=489,},},[K2]=1677,[K1]=K4,x=60,y=489,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1681,[K1]="any",x=63,y=489,},},[K2]=1680,[K1]=K4,x=60,y=489,},[K2]=1676,[K1]=K9,x=35,y=489,},[2]={f=K3,[K2]=1682,[K1]="any",x=69,y=489,},},[K2]=1675,[K1]=K4,x=32,y=489,},[K2]=1672,[K1]=K9,x=16,y=489,},f=K3,[K2]=1671,[K1]=K36,x=13,xend=75,y=489,yend=489,},[K[136]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1655,[K1]=K12,x=22,y=487,},[2]={f=K3,[K2]=1656,[K1]=K12,x=30,y=487,},},[K2]=1654,[K1]=K4,x=37,y=487,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1658,[K1]=K15,[K13]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1661,[K1]="any",x=48,y=487,},},[K2]=1660,[K1]=K4,x=48,y=487,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1663,[K1]="any",x=48,y=487,},},[K2]=1662,[K1]=K4,x=48,y=487,},[K2]=1659,[K1]=K9,x=39,y=487,},[2]={f=K3,[K2]=1664,[K1]="nil",x=50,y=487,},},x=39,y=487,},[2]={f=K3,[K2]=1665,[K1]=K15,[K13]={[1]={f=K3,[K2]=1666,[K1]=K12,x=55,y=487,},[2]={f=K3,[K2]=1667,[K1]="nil",x=64,y=487,},},x=55,y=487,},[3]={f=K3,[K2]=1668,[K1]=K15,[K13]={[1]={f=K3,[K2]=1669,[K1]=K12,x=69,y=487,},[2]={f=K3,[K2]=1670,[K1]="nil",x=78,y=487,},},x=69,y=487,},},[K2]=1657,[K1]=K4,x=37,y=487,},[K2]=1653,[K1]=K9,x=13,y=487,},path={f=K3,[K2]=1683,[K1]=K12,x=10,y=491,},[K[137]]={f=K3,keys={f=K3,[K2]=1685,[K1]=K12,x=14,y=493,},[K2]=1684,[K1]="map",[K34]={args={f=K3,[K4]={[1]={f=K3,[K2]=1688,[K1]=K12,x=34,y=493,},[2]={f=K3,[K2]=1689,[K1]="any",x=44,y=493,},},[K2]=1687,[K1]=K4,x=48,y=493,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1691,[K1]="any",x=51,y=493,},},[K2]=1690,[K1]=K4,x=48,y=493,},[K2]=1686,[K1]=K9,x=23,y=493,},x=13,xend=56,y=493,yend=493,},[K[138]]={[K35]={args={f=K3,[K4]={[1]={f=K3,[K2]=1695,[K1]=K12,x=27,y=495,},},[K2]=1694,[K1]=K4,x=34,y=495,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1699,[K1]=K12,x=48,y=495,},[2]={f=K3,[K2]=1700,[K1]="any",x=58,y=495,},},[K2]=1698,[K1]=K4,x=62,y=495,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1702,[K1]="any",x=65,y=495,},},[K2]=1701,[K1]=K4,x=62,y=495,},[K2]=1697,[K1]=K9,x=37,y=495,},[2]={f=K3,[K2]=1703,[K1]="any",x=71,y=495,},},[K2]=1696,[K1]=K4,x=34,y=495,},[K2]=1693,[K1]=K9,x=18,y=495,},f=K3,[K2]=1692,[K1]=K36,x=15,xend=77,y=495,yend=495,},[K[139]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1706,[K1]=K12,x=25,y=498,},[2]={f=K3,[K2]=1707,[K1]=K12,x=33,y=498,},[3]={f=K3,[K2]=1708,[K1]=K12,x=43,y=498,},[4]={f=K3,[K2]=1709,[K1]=K12,x=53,y=498,},},[K2]=1705,[K1]=K4,x=60,y=498,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1711,[K1]=K15,[K13]={[1]={f=K3,[K2]=1712,[K1]=K12,x=62,y=498,},[2]={f=K3,[K2]=1713,[K1]="nil",x=71,y=498,},},x=62,y=498,},[2]={f=K3,[K2]=1714,[K1]=K15,[K13]={[1]={f=K3,[K2]=1715,[K1]=K12,x=76,y=498,},[2]={f=K3,[K2]=1716,[K1]="nil",x=85,y=498,},},x=76,y=498,},},[K2]=1710,[K1]=K4,x=60,y=498,},[K2]=1704,[K1]=K9,x=16,y=498,},},[K37]={},[K2]=1647,[K1]=K45,x=1,y=478,},f=K3,[K2]=1717,[K1]=K28,x=1,y=478,},},[K[140]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[140],x=8,xend=12,y=810,yend=810,},[K26]=true,[K33]=true,t={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2965,[K1]=K5,[K5]="K@48",x=27,y=729,},[K2]=2967,[K1]="map",[K34]={f=K3,[K2]=2966,[K1]=K5,[K5]="V@48",x=29,y=729,},x=26,y=729,},},[K2]=2968,[K1]=K4,x=32,y=729,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2969,[K1]=K5,[K5]="K@48",x=45,y=729,},[K2]=2971,[K1]="map",[K34]={f=K3,[K2]=2970,[K1]=K5,[K5]="V@48",x=47,y=729,},x=44,y=729,},[2]={f=K3,[K2]=2972,[K1]=K5,[K5]="K@48",x=53,y=729,},},[K2]=2973,[K1]=K4,x=55,y=729,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2974,[K1]=K5,[K5]="K@48",x=57,y=729,},[2]={f=K3,[K2]=2975,[K1]=K5,[K5]="V@48",x=60,y=729,},},[K2]=2976,[K1]=K4,x=55,y=729,},[K2]=2977,[K1]=K9,x=35,y=729,},[2]={f=K3,keys={f=K3,[K2]=2978,[K1]=K5,[K5]="K@48",x=65,y=729,},[K2]=2980,[K1]="map",[K34]={f=K3,[K2]=2979,[K1]=K5,[K5]="V@48",x=67,y=729,},x=64,y=729,},[3]={f=K3,[K2]=2981,[K1]=K5,[K5]="K@48",x=71,y=729,},},[K2]=2982,[K1]=K4,x=32,y=729,},[K42]=K[140],[K2]=2983,[K1]=K9,x=11,y=729,},[K21]={[1]={f=K3,[K11]="K@48",[K2]=2963,[K1]=K11,x=20,y=729,},[2]={f=K3,[K11]="V@48",[K2]=2964,[K1]=K11,x=23,y=729,},},[K2]=2984,[K1]=K22,x=4,y=731,},},[K[141]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[141],x=8,xend=12,y=811,yend=811,},[K26]=true,[K33]=true,t={args={f=K3,[K17]=true,[K4]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2381,[K1]="any",x=29,y=731,},},[K2]=2380,[K1]=K4,x=36,y=731,},f=K3,[K8]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2383,[K1]="any",x=38,y=731,},},[K2]=2382,[K1]=K4,x=36,y=731,},[K2]=2379,[K1]=K9,x=20,y=731,},[2]={f=K3,[K2]=2384,[K1]="any",x=47,y=731,},},[K2]=2378,[K1]=K4,x=54,y=731,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2386,[K1]=K29,x=56,y=731,},[2]={f=K3,[K2]=2387,[K1]="any",x=65,y=731,},},[K2]=2385,[K1]=K4,x=54,y=731,},[K42]=K[141],[K2]=2377,[K1]=K9,x=11,y=731,},},["print"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="print",x=8,xend=12,y=812,yend=812,},[K26]=true,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2390,[K1]="any",x=20,y=733,},},[K2]=2389,[K1]=K4,x=4,y=735,},f=K3,[K8]=false,[K7]=0,rets={f=K3,[K4]={},[K2]=2391,[K1]=K4,x=26,y=733,},[K2]=2388,[K1]=K9,x=11,y=733,},},["rawequal"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="rawequal",x=8,xend=15,y=813,yend=813,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2394,[K1]="any",x=23,y=735,},[2]={f=K3,[K2]=2395,[K1]="any",x=28,y=735,},},[K2]=2393,[K1]=K4,x=32,y=735,},f=K3,[K8]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2397,[K1]=K29,x=34,y=735,},},[K2]=2396,[K1]=K4,x=32,y=735,},[K2]=2392,[K1]=K9,x=14,y=735,},},[K[142]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[142],x=8,xend=13,y=814,yend=814,},[K26]=true,t={f=K3,[K2]=2419,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2987,[K1]=K5,[K5]="K",x=28,y=739,},[K2]=2402,[K1]="map",[K34]={f=K3,[K2]=2988,[K1]=K5,[K5]="V",x=30,y=739,},x=27,xend=31,y=739,yend=739,},[2]={f=K3,[K2]=2989,[K1]=K5,[K5]="K",x=34,y=739,},},[K2]=2401,[K1]=K4,x=36,y=739,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2407,[K1]=K15,[K13]={[1]={f=K3,[K2]=2990,[K1]=K5,[K5]="V",x=38,y=739,},[2]={f=K3,[K2]=2409,[K1]="nil",x=42,y=739,},},x=38,y=739,},},[K2]=2406,[K1]=K4,x=36,y=739,},[K42]=K[142],[K2]=2400,[K1]=K9,x=12,y=739,},[K21]={[1]={f=K3,[K11]="K",[K2]=2398,[K1]=K11,x=21,y=739,},[2]={f=K3,[K11]="V",[K2]=2399,[K1]=K11,x=24,y=739,},},[K2]=2410,[K1]=K22,x=4,y=741,},[2]={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2414,[K1]="any",x=22,y=741,},[K2]=2413,[K1]="map",[K34]={f=K3,[K2]=2415,[K1]="any",x=26,y=741,},x=21,xend=29,y=741,yend=741,},[2]={f=K3,[K2]=2416,[K1]="any",x=32,y=741,},},[K2]=2412,[K1]=K4,x=36,y=741,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2418,[K1]="any",x=38,y=741,},},[K2]=2417,[K1]=K4,x=36,y=741,},[K2]=2411,[K1]=K9,x=12,y=741,},[3]={args={f=K3,[K4]={[1]={f=K3,[K2]=2422,[K1]="any",x=21,y=743,},[2]={f=K3,[K2]=2423,[K1]="any",x=26,y=743,},},[K2]=2421,[K1]=K4,x=30,y=743,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2425,[K1]="any",x=32,y=743,},},[K2]=2424,[K1]=K4,x=30,y=743,},[K2]=2420,[K1]=K9,x=12,y=743,},},x=4,y=741,},},["rawlen"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="rawlen",x=8,xend=13,y=815,yend=815,},[K26]=true,[K33]=true,t={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=3006,[K1]=K5,[K5]="A@50",x=25,y=746,},f=K3,[K2]=3007,[K1]=K36,x=24,y=746,},},[K2]=3008,[K1]=K4,x=28,y=746,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2432,[K1]=K14,x=30,y=746,},},[K2]=2431,[K1]=K4,x=28,y=746,},[K2]=3009,[K1]=K9,x=12,y=746,},[K21]={[1]={f=K3,[K11]="A@50",[K2]=3005,[K1]=K11,x=21,y=746,},},[K2]=3010,[K1]=K22,x=4,y=749,},},["rawset"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="rawset",x=8,xend=13,y=816,yend=816,},[K26]=true,t={f=K3,[K2]=2459,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=3013,[K1]=K5,[K5]="K",x=28,y=749,},[K2]=2438,[K1]="map",[K34]={f=K3,[K2]=3014,[K1]=K5,[K5]="V",x=30,y=749,},x=27,xend=31,y=749,yend=749,},[2]={f=K3,[K2]=3015,[K1]=K5,[K5]="K",x=34,y=749,},[3]={f=K3,[K2]=3016,[K1]=K5,[K5]="V",x=37,y=749,},},[K2]=2437,[K1]=K4,x=39,y=749,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=3017,[K1]=K5,[K5]="K",x=42,y=749,},[K2]=2444,[K1]="map",[K34]={f=K3,[K2]=3018,[K1]=K5,[K5]="V",x=44,y=749,},x=41,xend=45,y=749,yend=749,},},[K2]=2443,[K1]=K4,x=39,y=749,},[K2]=2436,[K1]=K9,x=12,y=749,},[K21]={[1]={f=K3,[K11]="K",[K2]=2434,[K1]=K11,x=21,y=749,},[2]={f=K3,[K11]="V",[K2]=2435,[K1]=K11,x=24,y=749,},},[K2]=2447,[K1]=K22,x=4,y=751,},[2]={args={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2451,[K1]="any",x=22,y=751,},[K2]=2450,[K1]="map",[K34]={f=K3,[K2]=2452,[K1]="any",x=26,y=751,},x=21,xend=29,y=751,yend=751,},[2]={f=K3,[K2]=2453,[K1]="any",x=32,y=751,},[3]={f=K3,[K2]=2454,[K1]="any",x=37,y=751,},},[K2]=2449,[K1]=K4,x=41,y=751,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,keys={f=K3,[K2]=2457,[K1]="any",x=44,y=751,},[K2]=2456,[K1]="map",[K34]={f=K3,[K2]=2458,[K1]="any",x=48,y=751,},x=43,xend=51,y=751,yend=751,},},[K2]=2455,[K1]=K4,x=41,y=751,},[K2]=2448,[K1]=K9,x=12,y=751,},[3]={args={f=K3,[K4]={[1]={f=K3,[K2]=2462,[K1]="any",x=21,y=753,},[2]={f=K3,[K2]=2463,[K1]="any",x=26,y=753,},[3]={f=K3,[K2]=2464,[K1]="any",x=31,y=753,},},[K2]=2461,[K1]=K4,x=35,y=753,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=2466,[K1]="any",x=37,y=753,},},[K2]=2465,[K1]=K4,x=35,y=753,},[K2]=2460,[K1]=K9,x=12,y=753,},},x=4,y=751,},},[K[143]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[143],x=8,xend=14,y=817,yend=817,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2469,[K1]=K12,x=22,y=756,},},[K2]=2468,[K1]=K4,x=29,y=756,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2471,[K1]="any",x=31,y=756,},},[K2]=2470,[K1]=K4,x=29,y=756,},[K42]=K[143],[K2]=2467,[K1]=K9,x=13,y=756,},},["select"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="select",x=8,xend=13,y=818,yend=818,},[K26]=true,t={f=K3,[K2]=2486,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2475,[K1]=K14,x=24,y=759,},[2]={f=K3,[K2]=3034,[K1]=K5,[K5]="T",x=33,y=759,},},[K2]=2474,[K1]=K4,x=38,y=759,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=3035,[K1]=K5,[K5]="T",x=40,y=759,},},[K2]=2477,[K1]=K4,x=38,y=759,},[K2]=2473,[K1]=K9,x=12,y=759,},[K21]={[1]={f=K3,[K11]="T",[K2]=2472,[K1]=K11,x=21,y=759,},},[K2]=2479,[K1]=K22,x=4,y=761,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2482,[K1]=K14,x=21,y=761,},[2]={f=K3,[K2]=2483,[K1]="any",x=30,y=761,},},[K2]=2481,[K1]=K4,x=37,y=761,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2485,[K1]="any",x=39,y=761,},},[K2]=2484,[K1]=K4,x=37,y=761,},[K2]=2480,[K1]=K9,x=12,y=761,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2489,[K1]=K12,x=21,y=763,},[2]={f=K3,[K2]=2490,[K1]="any",x=29,y=763,},},[K2]=2488,[K1]=K4,x=36,y=763,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2492,[K1]=K14,x=38,y=763,},},[K2]=2491,[K1]=K4,x=36,y=763,},[K2]=2487,[K1]=K9,x=12,y=763,},},x=4,y=761,},},[K[58]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[58],x=8,xend=19,y=819,yend=819,},[K26]=true,t={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=3048,[K1]=K5,[K5]="T@53",x=30,y=766,},[2]={f=K3,[K2]=3051,[K1]=K15,[K13]={[1]={f=K3,[K20]=T17,[K19]={[1]=K[77],},[K2]=3050,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=3049,[K1]=K5,[K5]="T@53",x=43,y=766,},},x=33,y=766,},[2]={f=K3,[K2]=2500,[K1]="nil",x=48,y=766,},},x=33,y=766,},},[K2]=3052,[K1]=K4,x=52,y=766,},f=K3,[K8]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=3053,[K1]=K5,[K5]="T@53",x=54,y=766,},},[K2]=3054,[K1]=K4,x=52,y=766,},[K2]=3055,[K1]=K9,x=18,y=766,},[K21]={[1]={f=K3,[K11]="T@53",[K2]=3047,[K1]=K11,x=27,y=766,},},[K2]=3056,[K1]=K22,x=4,y=777,},},[K12]={[K27]={f=K3,kind=K25,tk=K12,x=15,xend=20,y=502,yend=502,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]=K12,f=K3,[K40]={byte={[1]={[1]={text="--- Return byte values from a string at the requested one-based position or inclusive range.",x=4,y=503,},},[2]={[1]={text="--- Return byte values from a string at the requested one-based position or inclusive range.",x=4,y=505,},},},char={[1]={[1]={text="--- Build a string from byte values.",x=4,y=508,},},},dump={[1]={[1]={text="--- Serialize a Lua function to a binary chunk; the optional strip flag removes debug information where supported.",x=4,y=510,},},},find={[1]={[1]={text="--- Search for a pattern or plain substring. Return one-based start and end positions plus captures, or nil when no match exists.",x=4,y=512,},[2]={text="---",x=4,y=513,},[3]={text="--- @param subject String to search, indexed in bytes.",x=4,y=514,},[4]={text="--- @param pattern Lua pattern, or a literal substring when `plain` is true.",x=4,y=515,},[5]={text="--- @param init Optional starting byte position; negative positions count from the end.",x=4,y=516,},[6]={text="--- @param plain Optional flag disabling pattern interpretation.",x=4,y=517,},[7]={text="--- @return Start and end byte positions followed by captures, or nil when absent.",x=4,y=518,},[8]={text=K[22],x=4,y=519,},[9]={text="--- local first, last = string.find(\"red blue\", \"blue\", 1, true)",x=4,y=520,},[10]={text="--- if first ~= nil and last ~= nil then print(first, last) end",x=4,y=521,},[11]={text=K[23],x=4,y=522,},},},[K[144]]={[1]={[1]={text="--- Format arguments according to a printf-style format string.",x=4,y=524,},},},[K[145]]={[1]={[1]={text="--- Create an iterator over successive pattern matches and their captures.",x=4,y=526,},},},gsub={[1]={[1]={text=K[146],x=4,y=529,},},[2]={[1]={text=K[146],x=4,y=531,},},[3]={[1]={text=K[146],x=4,y=533,},},[4]={[1]={text=K[146],x=4,y=535,},},},len={[1]={[1]={text="--- Return the length in bytes, not Unicode characters.",x=4,y=538,},},},[K[147]]={[1]={[1]={text="--- Return a lowercase copy according to the current locale.",x=4,y=540,},},},[K[148]]={[1]={[1]={text="--- Return pattern captures, or the whole match if there are no captures; return nil if no match exists.",x=4,y=542,},[2]={text="---",x=4,y=543,},[3]={text="--- @param subject String to search.",x=4,y=544,},[4]={text="--- @param pattern Lua pattern; parentheses define captures.",x=4,y=545,},[5]={text="--- @param init Optional starting byte position.",x=4,y=546,},[6]={text="--- @return Captures or the whole match; nil when no match is found.",x=4,y=547,},[7]={text=K[22],x=4,y=548,},[8]={text="--- local word = string.match(\"key=oak\", \"=(%a+)\")",x=4,y=549,},[9]={text="--- if word ~= nil then print(word) end",x=4,y=550,},[10]={text=K[23],x=4,y=551,},},},pack={[1]={[1]={text="--- Pack values into a binary string according to a format.",x=4,y=553,},},},[K[149]]={[1]={[1]={text="--- Return the fixed byte size of a binary packing format.",x=4,y=555,},},},rep={[1]={[1]={text="--- Repeat a string a specified number of times, optionally separating copies.",x=4,y=557,},},},[K[150]]={[1]={[1]={text="--- Return a string with its bytes reversed.",x=4,y=559,},},},sub={[1]={[1]={text="--- Return the inclusive byte range; negative positions count backward from the end.",x=4,y=561,},},},[K[151]]={[1]={[1]={text="--- Unpack binary values according to a format and return them followed by the next byte position.",x=4,y=563,},},},[K[152]]={[1]={[1]={text="--- Return an uppercase copy according to the current locale.",x=4,y=565,},},},},[K46]={byte={f=K3,x=4,y=504,},char={f=K3,x=4,y=509,},dump={f=K3,x=4,y=511,},find={f=K3,x=4,y=523,},[K[144]]={f=K3,x=4,y=525,},[K[145]]={f=K3,x=4,y=527,},gsub={f=K3,x=4,y=530,},len={f=K3,x=4,y=539,},[K[147]]={f=K3,x=4,y=541,},[K[148]]={f=K3,x=4,y=552,},pack={f=K3,x=4,y=554,},[K[149]]={f=K3,x=4,y=556,},rep={f=K3,x=4,y=558,},[K[150]]={f=K3,x=4,y=560,},sub={f=K3,x=4,y=562,},[K[151]]={f=K3,x=4,y=564,},[K[152]]={f=K3,x=4,y=566,},},[K39]={[1]="byte",[2]="char",[3]="dump",[4]="find",[5]=K[144],[6]=K[145],[7]="gsub",[8]="len",[9]=K[147],[10]=K[148],[11]="pack",[12]=K[149],[13]="rep",[14]=K[150],[15]="sub",[16]=K[151],[17]=K[152],},[K38]={byte={f=K3,[K2]=1738,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1723,[K1]=K12,x=19,y=504,},[2]={f=K3,[K2]=1724,[K1]=K14,x=29,y=504,},},[K2]=1722,[K1]=K4,x=37,y=504,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1726,[K1]=K15,[K13]={[1]={f=K3,[K2]=1727,[K1]=K14,x=39,y=504,},[2]={f=K3,[K2]=1728,[K1]="nil",x=49,y=504,},},x=39,y=504,},},[K2]=1725,[K1]=K4,x=37,y=504,},[K2]=1721,[K1]=K9,x=10,y=504,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=1731,[K1]=K12,x=19,y=506,},[2]={f=K3,[K2]=1732,[K1]=K14,x=27,y=506,},[3]={f=K3,[K2]=1733,[K1]=K14,x=38,y=506,},},[K2]=1730,[K1]=K4,x=46,y=506,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1735,[K1]=K15,[K13]={[1]={f=K3,[K2]=1736,[K1]=K14,x=50,y=506,},[2]={f=K3,[K2]=1737,[K1]="nil",x=60,y=506,},},x=50,y=506,},},[K2]=1734,[K1]=K4,x=46,y=506,},[K2]=1729,[K1]=K9,x=10,y=506,},},x=4,y=506,},char={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1741,[K1]=K14,x=19,y=509,},},[K2]=1740,[K1]=K4,x=30,y=509,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1743,[K1]=K12,x=32,y=509,},},[K2]=1742,[K1]=K4,x=30,y=509,},[K2]=1739,[K1]=K9,x=10,y=509,},dump={args={f=K3,[K4]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1748,[K1]="any",x=28,y=511,},},[K2]=1747,[K1]=K4,x=35,y=511,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1750,[K1]="any",x=38,y=511,},},[K2]=1749,[K1]=K4,x=35,y=511,},[K2]=1746,[K1]=K9,x=19,y=511,},[2]={f=K3,[K2]=1751,[K1]=K29,x=46,y=511,},},[K2]=1745,[K1]=K4,x=54,y=511,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1753,[K1]=K12,x=56,y=511,},},[K2]=1752,[K1]=K4,x=54,y=511,},[K2]=1744,[K1]=K9,x=10,y=511,},find={args={f=K3,[K4]={[1]={f=K3,[K2]=1756,[K1]=K12,x=19,y=523,},[2]={f=K3,[K2]=1757,[K1]=K12,x=27,y=523,},[3]={f=K3,[K2]=1758,[K1]=K14,x=37,y=523,},[4]={f=K3,[K2]=1759,[K1]=K29,x=48,y=523,},},[K2]=1755,[K1]=K4,x=56,y=523,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1761,[K1]=K15,[K13]={[1]={f=K3,[K2]=1762,[K1]=K14,x=58,y=523,},[2]={f=K3,[K2]=1763,[K1]="nil",x=68,y=523,},},x=58,y=523,},[2]={f=K3,[K2]=1764,[K1]=K15,[K13]={[1]={f=K3,[K2]=1765,[K1]=K14,x=73,y=523,},[2]={f=K3,[K2]=1766,[K1]="nil",x=83,y=523,},},x=73,y=523,},[3]={f=K3,[K2]=1767,[K1]=K12,x=88,y=523,},},[K2]=1760,[K1]=K4,x=56,y=523,},[K42]="string.find",[K2]=1754,[K1]=K9,x=10,y=523,},[K[144]]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1770,[K1]=K12,x=21,y=525,},[2]={f=K3,[K2]=1771,[K1]="any",x=29,y=525,},},[K2]=1769,[K1]=K4,x=36,y=525,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1773,[K1]=K12,x=38,y=525,},},[K2]=1772,[K1]=K4,x=36,y=525,},[K42]="string.format",[K2]=1768,[K1]=K9,x=12,y=525,},[K[145]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1776,[K1]=K12,x=21,y=527,},[2]={f=K3,[K2]=1777,[K1]=K12,x=29,y=527,},[3]={f=K3,[K2]=1778,[K1]=K14,x=39,y=527,},},[K2]=1775,[K1]=K4,x=47,y=527,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1781,[K1]=K4,x=60,y=527,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1783,[K1]=K12,x=62,y=527,},},[K2]=1782,[K1]=K4,x=60,y=527,},[K2]=1780,[K1]=K9,x=50,y=527,},},[K2]=1779,[K1]=K4,x=47,y=527,},[K42]="string.gmatch",[K2]=1774,[K1]=K9,x=12,y=527,},gsub={f=K3,[K2]=1807,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=1786,[K1]=K12,x=19,y=530,},[2]={f=K3,[K2]=1787,[K1]=K12,x=27,y=530,},[3]={f=K3,[K2]=1788,[K1]=K12,x=35,y=530,},[4]={f=K3,[K2]=1789,[K1]=K14,x=45,y=530,},},[K2]=1785,[K1]=K4,x=53,y=530,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=1791,[K1]=K12,x=55,y=530,},[2]={f=K3,[K2]=1792,[K1]=K14,x=63,y=530,},},[K2]=1790,[K1]=K4,x=53,y=530,},[K42]="string.gsub",[K2]=1784,[K1]=K9,x=10,y=530,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=1795,[K1]=K12,x=19,y=532,},[2]={f=K3,[K2]=1796,[K1]=K12,x=27,y=532,},[3]={f=K3,keys={f=K3,[K2]=1798,[K1]=K12,x=36,y=532,},[K2]=1797,[K1]="map",[K34]={f=K3,[K2]=1799,[K1]=K15,[K13]={[1]={f=K3,[K2]=1800,[K1]=K12,x=43,y=532,},[2]={f=K3,[K2]=1801,[K1]=K14,x=50,y=532,},[3]={f=K3,[K2]=1802,[K1]=K16,x=58,y=532,},},x=43,y=532,},x=35,xend=64,y=532,yend=532,},[4]={f=K3,[K2]=1803,[K1]=K14,x=69,y=532,},},[K2]=1794,[K1]=K4,x=77,y=532,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=1805,[K1]=K12,x=79,y=532,},[2]={f=K3,[K2]=1806,[K1]=K14,x=87,y=532,},},[K2]=1804,[K1]=K4,x=77,y=532,},[K2]=1793,[K1]=K9,x=10,y=532,},[3]={args={f=K3,[K4]={[1]={f=K3,[K2]=1810,[K1]=K12,x=19,y=534,},[2]={f=K3,[K2]=1811,[K1]=K12,x=27,y=534,},[3]={f=K3,keys={f=K3,[K2]=1813,[K1]=K14,x=36,y=534,},[K2]=1812,[K1]="map",[K34]={f=K3,[K2]=1814,[K1]=K15,[K13]={[1]={f=K3,[K2]=1815,[K1]=K12,x=44,y=534,},[2]={f=K3,[K2]=1816,[K1]=K14,x=51,y=534,},[3]={f=K3,[K2]=1817,[K1]=K16,x=59,y=534,},},x=44,y=534,},x=35,xend=65,y=534,yend=534,},[4]={f=K3,[K2]=1818,[K1]=K14,x=70,y=534,},},[K2]=1809,[K1]=K4,x=78,y=534,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=1820,[K1]=K12,x=80,y=534,},[2]={f=K3,[K2]=1821,[K1]=K14,x=88,y=534,},},[K2]=1819,[K1]=K4,x=78,y=534,},[K2]=1808,[K1]=K9,x=10,y=534,},[4]={args={f=K3,[K4]={[1]={f=K3,[K2]=1824,[K1]=K12,x=19,y=536,},[2]={f=K3,[K2]=1825,[K1]=K12,x=27,y=536,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1828,[K1]=K15,[K13]={[1]={f=K3,[K2]=1829,[K1]=K12,x=45,y=536,},[2]={f=K3,[K2]=1830,[K1]=K14,x=52,y=536,},},x=45,y=536,},},[K2]=1827,[K1]=K4,x=64,y=536,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1832,[K1]=K15,[K13]={[1]={f=K3,[K2]=1833,[K1]=K12,x=68,y=536,},[2]={f=K3,[K2]=1834,[K1]=K14,x=75,y=536,},[3]={f=K3,[K2]=1835,[K1]=K16,x=83,y=536,},},x=68,y=536,},},[K2]=1831,[K1]=K4,x=64,y=536,},[K2]=1826,[K1]=K9,x=35,y=536,},[4]={f=K3,[K2]=1836,[K1]=K14,x=98,y=536,},},[K2]=1823,[K1]=K4,x=106,y=536,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={[1]={f=K3,[K2]=1838,[K1]=K12,x=108,y=536,},[2]={f=K3,[K2]=1839,[K1]=K14,x=116,y=536,},},[K2]=1837,[K1]=K4,x=106,y=536,},[K2]=1822,[K1]=K9,x=10,y=536,},},x=4,y=532,},len={args={f=K3,[K4]={[1]={f=K3,[K2]=1842,[K1]=K12,x=18,y=539,},},[K2]=1841,[K1]=K4,x=25,y=539,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1844,[K1]=K14,x=27,y=539,},},[K2]=1843,[K1]=K4,x=25,y=539,},[K2]=1840,[K1]=K9,x=9,y=539,},[K[147]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1847,[K1]=K12,x=20,y=541,},},[K2]=1846,[K1]=K4,x=27,y=541,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1849,[K1]=K12,x=29,y=541,},},[K2]=1848,[K1]=K4,x=27,y=541,},[K2]=1845,[K1]=K9,x=11,y=541,},[K[148]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1852,[K1]=K12,x=20,y=552,},[2]={f=K3,[K2]=1853,[K1]=K12,x=28,y=552,},[3]={f=K3,[K2]=1854,[K1]=K14,x=38,y=552,},},[K2]=1851,[K1]=K4,x=46,y=552,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1856,[K1]=K15,[K13]={[1]={f=K3,[K2]=1857,[K1]=K12,x=50,y=552,},[2]={f=K3,[K2]=1858,[K1]="nil",x=59,y=552,},},x=50,y=552,},},[K2]=1855,[K1]=K4,x=46,y=552,},[K42]="string.match",[K2]=1850,[K1]=K9,x=11,y=552,},pack={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1861,[K1]=K12,x=19,y=554,},[2]={f=K3,[K2]=1862,[K1]="any",x=27,y=554,},},[K2]=1860,[K1]=K4,x=34,y=554,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1864,[K1]=K12,x=36,y=554,},},[K2]=1863,[K1]=K4,x=34,y=554,},[K42]="string.pack",[K2]=1859,[K1]=K9,x=10,y=554,},[K[149]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1867,[K1]=K12,x=23,y=556,},},[K2]=1866,[K1]=K4,x=30,y=556,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1869,[K1]=K14,x=32,y=556,},},[K2]=1868,[K1]=K4,x=30,y=556,},[K2]=1865,[K1]=K9,x=14,y=556,},rep={args={f=K3,[K4]={[1]={f=K3,[K2]=1872,[K1]=K12,x=18,y=558,},[2]={f=K3,[K2]=1873,[K1]=K14,x=26,y=558,},[3]={f=K3,[K2]=1874,[K1]=K12,x=37,y=558,},},[K2]=1871,[K1]=K4,x=44,y=558,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1876,[K1]=K12,x=46,y=558,},},[K2]=1875,[K1]=K4,x=44,y=558,},[K2]=1870,[K1]=K9,x=9,y=558,},[K[150]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1879,[K1]=K12,x=22,y=560,},},[K2]=1878,[K1]=K4,x=29,y=560,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1881,[K1]=K12,x=31,y=560,},},[K2]=1880,[K1]=K4,x=29,y=560,},[K2]=1877,[K1]=K9,x=13,y=560,},sub={args={f=K3,[K4]={[1]={f=K3,[K2]=1884,[K1]=K12,x=18,y=562,},[2]={f=K3,[K2]=1885,[K1]=K14,x=26,y=562,},[3]={f=K3,[K2]=1886,[K1]=K14,x=37,y=562,},},[K2]=1883,[K1]=K4,x=45,y=562,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1888,[K1]=K12,x=47,y=562,},},[K2]=1887,[K1]=K4,x=45,y=562,},[K2]=1882,[K1]=K9,x=9,y=562,},[K[151]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1891,[K1]=K12,x=21,y=564,},[2]={f=K3,[K2]=1892,[K1]=K12,x=29,y=564,},[3]={f=K3,[K2]=1893,[K1]=K14,x=39,y=564,},},[K2]=1890,[K1]=K4,x=47,y=564,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1895,[K1]="any",x=49,y=564,},},[K2]=1894,[K1]=K4,x=47,y=564,},[K42]="string.unpack",[K2]=1889,[K1]=K9,x=12,y=564,},[K[152]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1898,[K1]=K12,x=20,y=566,},},[K2]=1897,[K1]=K4,x=27,y=566,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1900,[K1]=K12,x=29,y=566,},},[K2]=1899,[K1]=K4,x=27,y=566,},[K2]=1896,[K1]=K9,x=11,y=566,},},[K37]={},[K2]=1720,[K1]=K45,x=1,y=502,},f=K3,[K2]=1901,[K1]=K28,x=1,y=502,},},[K[153]]={[K27]={f=K3,kind=K25,tk=K[153],x=15,xend=19,y=570,yend=570,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]=K[153],f=K3,[K40]={[K[154]]={},[K[155]]={},[K[156]]={[1]={[1]={text="--- Join a sequence of strings or numbers, optionally choosing a separator and inclusive index range.",x=4,y=579,},},},[K[157]]={[1]={[1]={text="--- Insert a value at a position or at the end, shifting later elements up.",x=4,y=582,},},[2]={[1]={text="--- Insert a value at a position or at the end, shifting later elements up.",x=4,y=584,},},},move={[1]={[1]={text="--- Copy an inclusive index range into a destination table, handling overlapping ranges, and return the destination.",x=4,y=587,},},},pack={[1]={[1]={text="--- Pack arguments into a table with an `n` field recording their count, including nil arguments.",x=4,y=590,},},[2]={[1]={text="--- Pack arguments into a table with an `n` field recording their count, including nil arguments.",x=4,y=592,},},},[K[125]]={[1]={[1]={text="--- Remove and return an element, shifting following elements down; return nil when no element is removed.",x=4,y=595,},[2]={text="---",x=4,y=596,},[3]={text="--- @param list Sequence to modify in place.",x=4,y=597,},[4]={text="--- @param position Optional one-based index; defaults to the last element.",x=4,y=598,},[5]={text="--- @return The removed value, or nil when there is no element to remove.",x=4,y=599,},},},sort={[1]={[1]={text="--- Sort a sequence in place using an optional strict ordering callback. The sort is not stable.",x=4,y=601,},},},[K[151]]={[1]={[1]={text=K[158],x=4,y=604,},},[2]={[1]={text=K[158],x=4,y=606,},},[3]={[1]={text=K[158],x=4,y=608,},},[4]={[1]={text=K[158],x=4,y=610,},},[5]={[1]={text=K[158],x=4,y=612,},},},},[K46]={[K[154]]={f=K3,x=4,y=573,},[K[155]]={f=K3,x=9,y=571,},[K[156]]={f=K3,x=4,y=580,},[K[157]]={f=K3,x=4,y=583,},move={f=K3,x=4,y=588,},pack={f=K3,x=4,y=591,},[K[125]]={f=K3,x=4,y=600,},sort={f=K3,x=4,y=602,},[K[151]]={f=K3,x=4,y=605,},},[K39]={[1]=K[155],[2]=K[154],[3]=K[156],[4]=K[157],[5]="move",[6]="pack",[7]=K[125],[8]="sort",[9]=K[151],},[K38]={[K[154]]=T26,[K[155]]=T28,[K[156]]={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=1928,[K1]=K15,[K13]={[1]={f=K3,[K2]=1929,[K1]=K12,x=23,y=580,},[2]={f=K3,[K2]=1930,[K1]=K16,x=32,y=580,},},x=23,y=580,},f=K3,[K2]=1927,[K1]=K36,x=21,xend=39,y=580,yend=580,},[2]={f=K3,[K2]=1931,[K1]=K12,x=44,y=580,},[3]={f=K3,[K2]=1932,[K1]=K14,x=54,y=580,},[4]={f=K3,[K2]=1933,[K1]=K14,x=65,y=580,},},[K2]=1926,[K1]=K4,x=73,y=580,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1935,[K1]=K12,x=75,y=580,},},[K2]=1934,[K1]=K4,x=73,y=580,},[K2]=1925,[K1]=K9,x=12,y=580,},[K[157]]={f=K3,[K2]=1953,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2686,[K1]=K5,[K5]="A",x=25,y=583,},f=K3,[K2]=1939,[K1]=K36,x=24,xend=26,y=583,yend=583,},[2]={f=K3,[K2]=1941,[K1]=K14,x=29,y=583,},[3]={f=K3,[K2]=2687,[K1]=K5,[K5]="A",x=38,y=583,},},[K2]=1938,[K1]=K4,x=4,y=585,},f=K3,[K8]=false,[K10]=false,[K7]=3,rets={f=K3,[K4]={},[K2]=1943,[K1]=K4,x=39,y=583,},[K2]=1937,[K1]=K9,x=12,y=583,},[K21]={[1]={f=K3,[K11]="A",[K2]=1936,[K1]=K11,x=21,y=583,},},[K2]=1944,[K1]=K22,x=4,y=585,},[2]={f=K3,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2696,[K1]=K5,[K5]="A",x=25,y=585,},f=K3,[K2]=1948,[K1]=K36,x=24,xend=26,y=585,yend=585,},[2]={f=K3,[K2]=2697,[K1]=K5,[K5]="A",x=29,y=585,},},[K2]=1947,[K1]=K4,x=4,y=588,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={},[K2]=1951,[K1]=K4,x=30,y=585,},[K2]=1946,[K1]=K9,x=12,y=585,},[K21]={[1]={f=K3,[K11]="A",[K2]=1945,[K1]=K11,x=21,y=585,},},[K2]=1952,[K1]=K22,x=4,y=588,},},x=4,y=585,},move={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2710,[K1]=K5,[K5]="A@34",x=23,y=588,},f=K3,[K2]=2711,[K1]=K36,x=22,y=588,},[2]={f=K3,[K2]=1959,[K1]=K14,x=27,y=588,},[3]={f=K3,[K2]=1960,[K1]=K14,x=36,y=588,},[4]={f=K3,[K2]=1961,[K1]=K14,x=45,y=588,},[5]={[K35]={f=K3,[K2]=2712,[K1]=K5,[K5]="A@34",x=57,y=588,},f=K3,[K2]=2713,[K1]=K36,x=56,y=588,},},[K2]=2714,[K1]=K4,x=60,y=588,},f=K3,[K8]=false,[K7]=4,rets={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2715,[K1]=K5,[K5]="A@34",x=63,y=588,},f=K3,[K2]=2716,[K1]=K36,x=62,y=588,},},[K2]=2717,[K1]=K4,x=60,y=588,},[K2]=2718,[K1]=K9,x=10,y=588,},[K21]={[1]={f=K3,[K11]="A@34",[K2]=2709,[K1]=K11,x=19,y=588,},},[K2]=2719,[K1]=K22,x=4,y=591,},pack={f=K3,[K33]=true,[K2]=1982,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2721,[K1]=K5,[K5]="T",x=22,y=591,},},[K2]=1970,[K1]=K4,x=27,y=591,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K20]=T26,[K19]={[1]=K[154],},[K2]=1973,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=2722,[K1]=K5,[K5]="T",x=39,y=591,},},x=29,y=591,},},[K2]=1972,[K1]=K4,x=27,y=591,},[K2]=1969,[K1]=K9,x=10,y=591,},[K21]={[1]={f=K3,[K11]="T",[K2]=1968,[K1]=K11,x=19,y=591,},},[K2]=1975,[K1]=K22,x=4,y=593,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1978,[K1]="any",x=19,y=593,},},[K2]=1977,[K1]=K4,x=26,y=593,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K20]=T26,[K19]={[1]=K[154],},[K2]=1980,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=1981,[K1]="any",x=38,y=593,},},x=28,y=593,},},[K2]=1979,[K1]=K4,x=26,y=593,},[K2]=1976,[K1]=K9,x=10,y=593,},},x=4,y=593,},[K[125]]={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2735,[K1]=K5,[K5]="A@36",x=25,y=600,},f=K3,[K2]=2736,[K1]=K36,x=24,y=600,},[2]={f=K3,[K2]=1988,[K1]=K14,x=31,y=600,},},[K2]=2737,[K1]=K4,x=39,y=600,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2739,[K1]=K15,[K13]={[1]={f=K3,[K2]=2738,[K1]=K5,[K5]="A@36",x=41,y=600,},[2]={f=K3,[K2]=1992,[K1]="nil",x=45,y=600,},},x=41,y=600,},},[K2]=2740,[K1]=K4,x=39,y=600,},[K2]=2741,[K1]=K9,x=12,y=600,},[K21]={[1]={f=K3,[K11]="A@36",[K2]=2734,[K1]=K11,x=21,y=600,},},[K2]=2742,[K1]=K22,x=4,y=602,},sort={f=K3,[K30]=true,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2747,[K1]=K5,[K5]="A@37",x=23,y=602,},f=K3,[K2]=2748,[K1]=K36,x=22,y=602,},[2]={f=K3,[K20]=T28,[K19]={[1]=K[155],},[K2]=2750,[K1]=K18,[K[101]]={[1]={f=K3,[K2]=2749,[K1]=K5,[K5]="A@37",x=42,y=602,},},x=29,y=602,},},[K2]=2751,[K1]=K4,x=4,y=605,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={},[K2]=2001,[K1]=K4,x=44,y=602,},[K2]=2752,[K1]=K9,x=10,y=602,},[K21]={[1]={f=K3,[K11]="A@37",[K2]=2746,[K1]=K11,x=19,y=602,},},[K2]=2753,[K1]=K22,x=4,y=605,},[K[151]]={f=K3,[K33]=true,[K2]=2024,[K1]="poly",[K13]={[1]={f=K3,t={args={f=K3,[K4]={[1]={[K35]={f=K3,[K2]=2755,[K1]=K5,[K5]="A",x=25,y=605,},f=K3,[K2]=2006,[K1]=K36,x=24,xend=26,y=605,yend=605,},[2]={f=K3,[K2]=2008,[K1]=K16,x=31,y=605,},[3]={f=K3,[K2]=2009,[K1]=K16,x=41,y=605,},},[K2]=2005,[K1]=K4,x=48,y=605,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2756,[K1]=K5,[K5]="A",x=50,y=605,},},[K2]=2010,[K1]=K4,x=48,y=605,},[K42]="table.unpack",[K2]=2004,[K1]=K9,x=12,y=605,},[K21]={[1]={f=K3,[K11]="A",[K2]=2003,[K1]=K11,x=21,y=605,},},[K2]=2012,[K1]=K22,x=4,y=607,},[2]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2017,[K1]=K[159],[K13]={[1]={f=K3,[K2]=2767,[K1]=K5,[K5]="A1",x=30,y=607,},[2]={f=K3,[K2]=2768,[K1]=K5,[K5]="A2",x=34,y=607,},},x=29,xend=36,y=607,yend=607,},},[K2]=2016,[K1]=K4,x=38,y=607,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2769,[K1]=K5,[K5]="A1",x=40,y=607,},[2]={f=K3,[K2]=2770,[K1]=K5,[K5]="A2",x=44,y=607,},},[K2]=2020,[K1]=K4,x=38,y=607,},[K2]=2015,[K1]=K9,x=12,y=607,},[K21]={[1]={f=K3,[K11]="A1",[K2]=2013,[K1]=K11,x=21,y=607,},[2]={f=K3,[K11]="A2",[K2]=2014,[K1]=K11,x=25,y=607,},},[K2]=2023,[K1]=K22,x=4,y=609,},[3]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2030,[K1]=K[159],[K13]={[1]={f=K3,[K2]=2785,[K1]=K5,[K5]="A1",x=34,y=609,},[2]={f=K3,[K2]=2786,[K1]=K5,[K5]="A2",x=38,y=609,},[3]={f=K3,[K2]=2787,[K1]=K5,[K5]="A3",x=42,y=609,},},x=33,xend=44,y=609,yend=609,},},[K2]=2029,[K1]=K4,x=46,y=609,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2788,[K1]=K5,[K5]="A1",x=48,y=609,},[2]={f=K3,[K2]=2789,[K1]=K5,[K5]="A2",x=52,y=609,},[3]={f=K3,[K2]=2790,[K1]=K5,[K5]="A3",x=56,y=609,},},[K2]=2034,[K1]=K4,x=46,y=609,},[K2]=2028,[K1]=K9,x=12,y=609,},[K21]={[1]={f=K3,[K11]="A1",[K2]=2025,[K1]=K11,x=21,y=609,},[2]={f=K3,[K11]="A2",[K2]=2026,[K1]=K11,x=25,y=609,},[3]={f=K3,[K11]="A3",[K2]=2027,[K1]=K11,x=29,y=609,},},[K2]=2038,[K1]=K22,x=4,y=611,},[4]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2045,[K1]=K[159],[K13]={[1]={f=K3,[K2]=2809,[K1]=K5,[K5]="A1",x=38,y=611,},[2]={f=K3,[K2]=2810,[K1]=K5,[K5]="A2",x=42,y=611,},[3]={f=K3,[K2]=2811,[K1]=K5,[K5]="A3",x=46,y=611,},[4]={f=K3,[K2]=2812,[K1]=K5,[K5]="A4",x=50,y=611,},},x=37,xend=52,y=611,yend=611,},},[K2]=2044,[K1]=K4,x=54,y=611,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2813,[K1]=K5,[K5]="A1",x=56,y=611,},[2]={f=K3,[K2]=2814,[K1]=K5,[K5]="A2",x=60,y=611,},[3]={f=K3,[K2]=2815,[K1]=K5,[K5]="A3",x=64,y=611,},[4]={f=K3,[K2]=2816,[K1]=K5,[K5]="A4",x=68,y=611,},},[K2]=2050,[K1]=K4,x=54,y=611,},[K2]=2043,[K1]=K9,x=12,y=611,},[K21]={[1]={f=K3,[K11]="A1",[K2]=2039,[K1]=K11,x=21,y=611,},[2]={f=K3,[K11]="A2",[K2]=2040,[K1]=K11,x=25,y=611,},[3]={f=K3,[K11]="A3",[K2]=2041,[K1]=K11,x=29,y=611,},[4]={f=K3,[K11]="A4",[K2]=2042,[K1]=K11,x=33,y=611,},},[K2]=2055,[K1]=K22,x=4,y=613,},[5]={f=K3,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2063,[K1]=K[159],[K13]={[1]={f=K3,[K2]=2839,[K1]=K5,[K5]="A1",x=42,y=613,},[2]={f=K3,[K2]=2840,[K1]=K5,[K5]="A2",x=46,y=613,},[3]={f=K3,[K2]=2841,[K1]=K5,[K5]="A3",x=50,y=613,},[4]={f=K3,[K2]=2842,[K1]=K5,[K5]="A4",x=54,y=613,},[5]={f=K3,[K2]=2843,[K1]=K5,[K5]="A5",x=58,y=613,},},x=41,xend=60,y=613,yend=613,},},[K2]=2062,[K1]=K4,x=62,y=613,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2844,[K1]=K5,[K5]="A1",x=64,y=613,},[2]={f=K3,[K2]=2845,[K1]=K5,[K5]="A2",x=68,y=613,},[3]={f=K3,[K2]=2846,[K1]=K5,[K5]="A3",x=72,y=613,},[4]={f=K3,[K2]=2847,[K1]=K5,[K5]="A4",x=76,y=613,},[5]={f=K3,[K2]=2848,[K1]=K5,[K5]="A5",x=80,y=613,},},[K2]=2069,[K1]=K4,x=62,y=613,},[K2]=2061,[K1]=K9,x=12,y=613,},[K21]={[1]={f=K3,[K11]="A1",[K2]=2056,[K1]=K11,x=21,y=613,},[2]={f=K3,[K11]="A2",[K2]=2057,[K1]=K11,x=25,y=613,},[3]={f=K3,[K11]="A3",[K2]=2058,[K1]=K11,x=29,y=613,},[4]={f=K3,[K11]="A4",[K2]=2059,[K1]=K11,x=33,y=613,},[5]={f=K3,[K11]="A5",[K2]=2060,[K1]=K11,x=37,y=613,},},[K2]=2075,[K1]=K22,x=1,y=614,},},x=4,y=607,},},[K37]={},[K2]=1904,[K1]=K45,x=1,y=570,},f=K3,[K2]=2076,[K1]=K28,x=1,y=570,},},[K41]={[K27]={f=K6,kind=K25,tk=K41,x=18,xend=23,y=11,yend=11,},[K26]=true,t={[K43]=true,def={[K32]=K41,f=K6,[K40]={},[K39]={},[K38]={},[K[16]]={},[K[1]]=true,[K37]={},[K2]=11,[K1]=K[34],x=1,y=11,},f=K6,[K2]=12,[K1]=K28,x=1,y=11,},},["tonumber"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="tonumber",x=8,xend=15,y=821,yend=821,},[K26]=true,t={f=K3,[K2]=2519,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=2506,[K1]="any",x=23,y=777,},},[K2]=2505,[K1]=K4,x=27,y=777,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2508,[K1]=K15,[K13]={[1]={f=K3,[K2]=2509,[K1]=K16,x=29,y=777,},[2]={f=K3,[K2]=2510,[K1]="nil",x=38,y=777,},},x=29,y=777,},},[K2]=2507,[K1]=K4,x=27,y=777,},[K2]=2504,[K1]=K9,x=14,y=777,},[2]={args={f=K3,[K4]={[1]={f=K3,[K2]=2513,[K1]="any",x=23,y=787,},[2]={f=K3,[K2]=2514,[K1]=K14,x=28,y=787,},},[K2]=2512,[K1]=K4,x=36,y=787,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2516,[K1]=K15,[K13]={[1]={f=K3,[K2]=2517,[K1]=K14,x=38,y=787,},[2]={f=K3,[K2]=2518,[K1]="nil",x=48,y=787,},},x=38,y=787,},},[K2]=2515,[K1]=K4,x=36,y=787,},[K2]=2511,[K1]=K9,x=14,y=787,},},x=4,y=787,},},["tostring"]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="tostring",x=8,xend=15,y=820,yend=820,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2522,[K1]="any",x=23,y=790,},},[K2]=2521,[K1]=K4,x=27,y=790,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2524,[K1]=K12,x=29,y=790,},},[K2]=2523,[K1]=K4,x=27,y=790,},[K2]=2520,[K1]=K9,x=14,y=790,},},type={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk="type",x=8,xend=11,y=823,yend=823,},[K26]=true,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2527,[K1]="any",x=19,y=792,},},[K2]=2526,[K1]=K4,x=23,y=792,},f=K3,[K8]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2529,[K1]=K12,x=25,y=792,},},[K2]=2528,[K1]=K4,x=23,y=792,},[K2]=2525,[K1]=K9,x=10,y=792,},},[K[102]]={[K27]={f=K6,kind=K25,tk=K[102],x=18,xend=25,y=14,yend=14,},[K26]=true,t=T19,[K[33]]=true,},utf8={[K27]={f=K3,kind=K25,tk="utf8",x=15,xend=18,y=617,yend=617,},[K26]=true,[K33]=true,t={[K43]=true,def={[K32]="utf8",f=K3,[K40]={char={[1]={[1]={text="--- Encode Unicode code points as a UTF-8 string.",x=4,y=618,},},},[K[160]]={[1]={[1]={text="--- Pattern matching one UTF-8 byte sequence; it does not validate a string.",x=4,y=620,},},},[K[161]]={[1]={[1]={text="--- Decode code points in an inclusive byte range; invalid input raises an error unless supported lax mode is selected.",x=4,y=622,},},},[K[162]]={[1]={[1]={text="--- Iterate over byte positions and code points in a UTF-8 string.",x=4,y=624,},},},len={[1]={[1]={text="--- Count UTF-8 code points in a byte range; return nil and the first invalid byte position on invalid input.",x=4,y=626,},[2]={text="---",x=4,y=627,},[3]={text="--- @param text UTF-8 byte string to inspect.",x=4,y=628,},[4]={text="--- @param first Optional first byte position.",x=4,y=629,},[5]={text="--- @param last Optional last byte position.",x=4,y=630,},[6]={text="--- @return Code-point count, or nil and the invalid byte position.",x=4,y=631,},},},[K[163]]={[1]={[1]={text="--- Find the byte position of a code point relative to a starting byte; return nil when it is outside the string.",x=4,y=633,},[2]={text=K31,x=4,y=634,},},},},[K46]={char={f=K3,x=4,y=619,},[K[160]]={f=K3,x=4,y=621,},[K[161]]={f=K3,x=4,y=623,},[K[162]]={f=K3,x=4,y=625,},len={f=K3,x=4,y=632,},[K[163]]={f=K3,x=4,y=635,},},[K39]={[1]="char",[2]=K[160],[3]=K[161],[4]=K[162],[5]="len",[6]=K[163],},[K38]={char={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2082,[K1]=K16,x=19,y=619,},},[K2]=2081,[K1]=K4,x=29,y=619,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2084,[K1]=K12,x=31,y=619,},},[K2]=2083,[K1]=K4,x=29,y=619,},[K2]=2080,[K1]=K9,x=10,y=619,},[K[160]]={f=K3,[K2]=2085,[K1]=K12,x=17,y=621,},[K[161]]={args={f=K3,[K4]={[1]={f=K3,[K2]=2088,[K1]=K12,x=24,y=623,},[2]={f=K3,[K2]=2089,[K1]=K16,x=34,y=623,},[3]={f=K3,[K2]=2090,[K1]=K16,x=44,y=623,},[4]={f=K3,[K2]=2091,[K1]=K29,x=54,y=623,},},[K2]=2087,[K1]=K4,x=62,y=623,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2093,[K1]=K14,x=64,y=623,},},[K2]=2092,[K1]=K4,x=62,y=623,},[K2]=2086,[K1]=K9,x=15,y=623,},[K[162]]={args={f=K3,[K4]={[1]={f=K3,[K2]=2096,[K1]=K12,x=20,y=625,},[2]={f=K3,[K2]=2097,[K1]=K29,x=30,y=625,},},[K2]=2095,[K1]=K4,x=38,y=625,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=2101,[K1]=K12,x=50,y=625,},[2]={f=K3,[K2]=2102,[K1]=K14,x=60,y=625,},},[K2]=2100,[K1]=K4,x=68,y=625,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2104,[K1]=K14,x=71,y=625,},[2]={f=K3,[K2]=2105,[K1]=K14,x=80,y=625,},},[K2]=2103,[K1]=K4,x=68,y=625,},[K2]=2099,[K1]=K9,x=41,y=625,},[2]={f=K3,[K2]=2106,[K1]=K12,x=90,y=625,},[3]={f=K3,[K2]=2107,[K1]=K14,x=98,y=625,},},[K2]=2098,[K1]=K4,x=38,y=625,},[K2]=2094,[K1]=K9,x=11,y=625,},len={args={f=K3,[K4]={[1]={f=K3,[K2]=2110,[K1]=K12,x=18,y=632,},[2]={f=K3,[K2]=2111,[K1]=K16,x=28,y=632,},[3]={f=K3,[K2]=2112,[K1]=K16,x=38,y=632,},[4]={f=K3,[K2]=2113,[K1]=K29,x=48,y=632,},},[K2]=2109,[K1]=K4,x=56,y=632,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=2115,[K1]=K15,[K13]={[1]={f=K3,[K2]=2116,[K1]=K14,x=58,y=632,},[2]={f=K3,[K2]=2117,[K1]="nil",x=68,y=632,},},x=58,y=632,},[2]={f=K3,[K2]=2118,[K1]=K15,[K13]={[1]={f=K3,[K2]=2119,[K1]=K14,x=73,y=632,},[2]={f=K3,[K2]=2120,[K1]="nil",x=83,y=632,},},x=73,y=632,},},[K2]=2114,[K1]=K4,x=56,y=632,},[K2]=2108,[K1]=K9,x=9,y=632,},[K[163]]={args={f=K3,[K4]={[1]={f=K3,[K2]=2123,[K1]=K12,x=21,y=635,},[2]={f=K3,[K2]=2124,[K1]=K16,x=29,y=635,},[3]={f=K3,[K2]=2125,[K1]=K16,x=39,y=635,},},[K2]=2122,[K1]=K4,x=46,y=635,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=2127,[K1]=K15,[K13]={[1]={f=K3,[K2]=2128,[K1]=K14,x=48,y=635,},[2]={f=K3,[K2]=2129,[K1]="nil",x=58,y=635,},},x=48,y=635,},},[K2]=2126,[K1]=K4,x=46,y=635,},[K2]=2121,[K1]=K9,x=12,y=635,},},[K37]={},[K2]=2079,[K1]=K45,x=1,y=617,},f=K3,[K2]=2130,[K1]=K28,x=1,y=617,},},[K[164]]={[K24]=K23,[K27]={[K24]=K23,f=K3,kind=K25,tk=K[164],x=8,xend=13,y=824,yend=824,},[K26]=true,[K33]=true,t={args={f=K3,[K17]=true,[K4]={[1]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2539,[K1]="any",x=30,y=796,},},[K2]=2538,[K1]=K4,x=37,y=796,},f=K3,[K8]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2541,[K1]="any",x=39,y=796,},},[K2]=2540,[K1]=K4,x=37,y=796,},[K2]=2537,[K1]=K9,x=21,y=796,},[2]={f=K3,[K20]={def={args={f=K3,[K4]={[1]={f=K3,[K2]=2163,[K1]="any",x=39,y=663,},},[K2]=2162,[K1]=K4,x=43,y=663,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2165,[K1]="any",x=45,y=663,},},[K2]=2164,[K1]=K4,x=43,y=663,},[K2]=2161,[K1]=K9,x=30,y=663,},f=K3,[K2]=2166,[K1]=K28,x=30,y=663,},[K19]={[1]="XpcallMsghFunction",},[K2]=2542,[K1]=K18,x=48,y=796,},[3]={f=K3,[K2]=2543,[K1]="any",x=68,y=796,},},[K2]=2536,[K1]=K4,x=75,y=796,},f=K3,[K8]=false,[K7]=2,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=2545,[K1]=K29,x=77,y=796,},[2]={f=K3,[K2]=2546,[K1]="any",x=86,y=796,},},[K2]=2544,[K1]=K4,x=75,y=796,},[K42]=K[164],[K2]=2535,[K1]=K9,x=12,y=796,},},}
T1.def=T2
T2[K40]={[K[2]]={},[K[3]]={},[K50]={[1]={[1]={text="--- Close this handle. Returns success, or nil with an error message and system code.",x=4,y=258,},[2]={text=K31,x=4,y=259,},},},[K[4]]={[1]={[1]={text="--- Flush buffered output. Returns success, or nil with error details.",x=4,y=261,},[2]={text=K31,x=4,y=262,},},},[K[6]]={[1]={[1]={text=K[5],x=4,y=265,},},[2]={[1]={text=K[5],x=4,y=267,},},[3]={[1]={text=K[5],x=4,y=269,},},[4]={[1]={text=K[5],x=4,y=271,},[2]={text=K31,x=4,y=272,},},[5]={[1]={text=K[5],x=4,y=274,},},},read={[1]={[1]={text=K[7],x=4,y=277,},[2]={text="---",x=4,y=278,},[3]={text=K[8],x=4,y=279,},[4]={text=K[9],x=4,y=280,},[5]={text=K[10],x=4,y=281,},},[2]={[1]={text=K[7],x=4,y=283,},[2]={text="---",x=4,y=284,},[3]={text=K[8],x=4,y=285,},[4]={text=K[9],x=4,y=286,},[5]={text=K[10],x=4,y=287,},},[3]={[1]={text=K[7],x=4,y=289,},[2]={text="---",x=4,y=290,},[3]={text=K[8],x=4,y=291,},[4]={text=K[9],x=4,y=292,},[5]={text=K[10],x=4,y=293,},},[4]={[1]={text=K[7],x=4,y=295,},[2]={text="---",x=4,y=296,},[3]={text=K[8],x=4,y=297,},[4]={text=K[9],x=4,y=298,},[5]={text=K[10],x=4,y=299,},},[5]={[1]={text=K[7],x=4,y=301,},[2]={text="---",x=4,y=302,},[3]={text=K[8],x=4,y=303,},[4]={text=K[9],x=4,y=304,},[5]={text=K[10],x=4,y=305,},},},seek={[1]={[1]={text="--- Move or query the file position using `set`, `cur`, or `end`; return the resulting byte offset or nil and error details.",x=4,y=308,},[2]={text=K31,x=4,y=309,},},},[K[11]]={[1]={[1]={text="--- Choose no, full, or line buffering and optionally a buffer size. Returns success or nil and error details.",x=4,y=311,},[2]={text=K31,x=4,y=312,},},},[K[12]]={[1]={[1]={text="--- Write strings or numbers to this handle. Returns the handle on success or nil and error details on failure.",x=4,y=315,},[2]={text=K31,x=4,y=316,},},},}
T2[K46]={[K[2]]={f=K3,x=4,y=250,},[K[3]]={f=K3,x=4,y=254,},[K50]={f=K3,x=4,y=260,},[K[4]]={f=K3,x=4,y=263,},[K[6]]={f=K3,x=4,y=266,},read={f=K3,x=4,y=282,},seek={f=K3,x=4,y=310,},[K[11]]={f=K3,x=4,y=313,},[K[12]]={f=K3,x=4,y=317,},}
T2[K39]={[1]=K[2],[2]=K[3],[3]=K50,[4]=K[4],[5]=K[6],[6]="read",[7]="seek",[8]=K[11],[9]=K[12],}
T2[K38]={[K[2]]=T3,[K[3]]=T4,[K50]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1106,[K1]=K18,x=20,y=260,},},[K2]=1105,[K1]=K4,x=25,y=260,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1108,[K1]=K15,[K13]={[1]={f=K3,[K2]=1109,[K1]=K29,x=27,y=260,},[2]={f=K3,[K2]=1110,[K1]="nil",x=37,y=260,},},x=27,y=260,},[2]={f=K3,[K2]=1111,[K1]=K15,[K13]={[1]={f=K3,[K2]=1112,[K1]=K12,x=42,y=260,},[2]={f=K3,[K2]=1113,[K1]="nil",x=51,y=260,},},x=42,y=260,},[3]={f=K3,[K2]=1114,[K1]=K15,[K13]={[1]={f=K3,[K2]=1115,[K1]=K14,x=56,y=260,},[2]={f=K3,[K2]=1116,[K1]="nil",x=66,y=260,},},x=56,y=260,},},[K2]=1107,[K1]=K4,x=25,y=260,},[K2]=1104,[K1]=K9,x=11,y=260,},[K[4]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1119,[K1]=K18,x=20,y=263,},},[K2]=1118,[K1]=K4,x=25,y=263,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1121,[K1]=K15,[K13]={[1]={f=K3,[K2]=1122,[K1]=K29,x=27,y=263,},[2]={f=K3,[K2]=1123,[K1]="nil",x=37,y=263,},},x=27,y=263,},[2]={f=K3,[K2]=1124,[K1]=K15,[K13]={[1]={f=K3,[K2]=1125,[K1]=K12,x=42,y=263,},[2]={f=K3,[K2]=1126,[K1]="nil",x=51,y=263,},},x=42,y=263,},[3]={f=K3,[K2]=1127,[K1]=K15,[K13]={[1]={f=K3,[K2]=1128,[K1]=K14,x=56,y=263,},[2]={f=K3,[K2]=1129,[K1]="nil",x=66,y=263,},},x=56,y=263,},},[K2]=1120,[K1]=K4,x=25,y=263,},[K2]=1117,[K1]=K9,x=11,y=263,},[K[6]]={f=K3,[K2]=1147,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1132,[K1]=K18,x=20,y=266,},},[K2]=1131,[K1]=K4,x=25,y=266,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1135,[K1]=K4,x=38,y=266,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1137,[K1]=K12,x=41,y=266,},},[K2]=1136,[K1]=K4,x=38,y=266,},[K2]=1134,[K1]=K9,x=28,y=266,},},[K2]=1133,[K1]=K4,x=25,y=266,},[K2]=1130,[K1]=K9,x=11,y=266,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1140,[K1]=K18,x=20,y=268,},[2]={f=K3,[K20]=T5,[K19]={[1]=K[13],},[K2]=1141,[K1]=K18,x=26,y=268,},},[K2]=1139,[K1]=K4,x=44,y=268,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1144,[K1]=K4,x=57,y=268,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1146,[K1]=K16,x=60,y=268,},},[K2]=1145,[K1]=K4,x=57,y=268,},[K2]=1143,[K1]=K9,x=47,y=268,},},[K2]=1142,[K1]=K4,x=44,y=268,},[K2]=1138,[K1]=K9,x=11,y=268,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1150,[K1]=K18,x=20,y=270,},[2]={f=K3,[K2]=1151,[K1]=K15,[K13]={[1]={f=K3,[K2]=1152,[K1]=K16,x=27,y=270,},[2]={f=K3,[K20]=T6,[K19]={[1]=K[14],},[K2]=1153,[K1]=K18,x=36,y=270,},},x=27,y=270,},},[K2]=1149,[K1]=K4,x=55,y=270,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1156,[K1]=K4,x=68,y=270,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1158,[K1]=K12,x=71,y=270,},},[K2]=1157,[K1]=K4,x=68,y=270,},[K2]=1155,[K1]=K9,x=58,y=270,},},[K2]=1154,[K1]=K4,x=55,y=270,},[K2]=1148,[K1]=K9,x=11,y=270,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1161,[K1]=K18,x=20,y=273,},[2]={f=K3,[K2]=1162,[K1]=K15,[K13]={[1]={f=K3,[K2]=1163,[K1]=K16,x=27,y=273,},[2]={f=K3,[K20]=T7,[K19]={[1]=K[15],},[K2]=1164,[K1]=K18,x=36,y=273,},},x=27,y=273,},},[K2]=1160,[K1]=K4,x=49,y=273,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1167,[K1]=K4,x=62,y=273,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1169,[K1]=K15,[K13]={[1]={f=K3,[K2]=1170,[K1]=K12,x=66,y=273,},[2]={f=K3,[K2]=1171,[K1]=K16,x=75,y=273,},[3]={f=K3,[K2]=1172,[K1]="nil",x=84,y=273,},},x=66,y=273,},},[K2]=1168,[K1]=K4,x=62,y=273,},[K2]=1166,[K1]=K9,x=52,y=273,},},[K2]=1165,[K1]=K4,x=49,y=273,},[K2]=1159,[K1]=K9,x=11,y=273,},[5]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1175,[K1]=K18,x=20,y=275,},[2]={f=K3,[K2]=1176,[K1]=K15,[K13]={[1]={f=K3,[K2]=1177,[K1]=K16,x=27,y=275,},[2]={f=K3,[K2]=1178,[K1]=K12,x=36,y=275,},},x=27,y=275,},},[K2]=1174,[K1]=K4,x=47,y=275,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=1181,[K1]=K4,x=60,y=275,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1183,[K1]=K12,x=63,y=275,},},[K2]=1182,[K1]=K4,x=60,y=275,},[K2]=1180,[K1]=K9,x=50,y=275,},},[K2]=1179,[K1]=K4,x=47,y=275,},[K2]=1173,[K1]=K9,x=11,y=275,},},x=4,y=268,},read={f=K3,[K2]=1199,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1186,[K1]=K18,x=19,y=282,},},[K2]=1185,[K1]=K4,x=24,y=282,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1188,[K1]=K15,[K13]={[1]={f=K3,[K2]=1189,[K1]=K12,x=26,y=282,},[2]={f=K3,[K2]=1190,[K1]="nil",x=35,y=282,},},x=26,y=282,},},[K2]=1187,[K1]=K4,x=24,y=282,},[K2]=1184,[K1]=K9,x=10,y=282,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1193,[K1]=K18,x=19,y=288,},[2]={f=K3,[K20]=T5,[K19]={[1]=K[13],},[K2]=1194,[K1]=K18,x=25,y=288,},},[K2]=1192,[K1]=K4,x=43,y=288,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1196,[K1]=K15,[K13]={[1]={f=K3,[K2]=1197,[K1]=K16,x=47,y=288,},[2]={f=K3,[K2]=1198,[K1]="nil",x=56,y=288,},},x=47,y=288,},},[K2]=1195,[K1]=K4,x=43,y=288,},[K2]=1191,[K1]=K9,x=10,y=288,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1202,[K1]=K18,x=19,y=294,},[2]={f=K3,[K2]=1203,[K1]=K15,[K13]={[1]={f=K3,[K2]=1204,[K1]=K16,x=26,y=294,},[2]={f=K3,[K20]=T6,[K19]={[1]=K[14],},[K2]=1205,[K1]=K18,x=35,y=294,},},x=26,y=294,},},[K2]=1201,[K1]=K4,x=54,y=294,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1207,[K1]=K15,[K13]={[1]={f=K3,[K2]=1208,[K1]=K12,x=58,y=294,},[2]={f=K3,[K2]=1209,[K1]="nil",x=67,y=294,},},x=58,y=294,},},[K2]=1206,[K1]=K4,x=54,y=294,},[K2]=1200,[K1]=K9,x=10,y=294,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1212,[K1]=K18,x=19,y=300,},[2]={f=K3,[K2]=1213,[K1]=K15,[K13]={[1]={f=K3,[K2]=1214,[K1]=K16,x=26,y=300,},[2]={f=K3,[K20]=T7,[K19]={[1]=K[15],},[K2]=1215,[K1]=K18,x=35,y=300,},},x=26,y=300,},},[K2]=1211,[K1]=K4,x=48,y=300,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1217,[K1]=K15,[K13]={[1]={f=K3,[K2]=1218,[K1]=K12,x=52,y=300,},[2]={f=K3,[K2]=1219,[K1]=K16,x=61,y=300,},[3]={f=K3,[K2]=1220,[K1]="nil",x=70,y=300,},},x=52,y=300,},},[K2]=1216,[K1]=K4,x=48,y=300,},[K2]=1210,[K1]=K9,x=10,y=300,},[5]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1223,[K1]=K18,x=19,y=306,},[2]={f=K3,[K2]=1224,[K1]=K15,[K13]={[1]={f=K3,[K2]=1225,[K1]=K16,x=26,y=306,},[2]={f=K3,[K2]=1226,[K1]=K12,x=35,y=306,},},x=26,y=306,},},[K2]=1222,[K1]=K4,x=46,y=306,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1228,[K1]=K15,[K13]={[1]={f=K3,[K2]=1229,[K1]=K12,x=50,y=306,},[2]={f=K3,[K2]=1230,[K1]="nil",x=59,y=306,},},x=50,y=306,},},[K2]=1227,[K1]=K4,x=46,y=306,},[K2]=1221,[K1]=K9,x=10,y=306,},},x=4,y=288,},seek={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1233,[K1]=K18,x=19,y=310,},[2]={f=K3,[K20]=T3,[K19]={[1]=K[2],},[K2]=1234,[K1]=K18,x=27,y=310,},[3]={f=K3,[K2]=1235,[K1]=K14,x=41,y=310,},},[K2]=1232,[K1]=K4,x=49,y=310,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1237,[K1]=K15,[K13]={[1]={f=K3,[K2]=1238,[K1]=K14,x=51,y=310,},[2]={f=K3,[K2]=1239,[K1]="nil",x=61,y=310,},},x=51,y=310,},[2]={f=K3,[K2]=1240,[K1]=K15,[K13]={[1]={f=K3,[K2]=1241,[K1]=K12,x=66,y=310,},[2]={f=K3,[K2]=1242,[K1]="nil",x=75,y=310,},},x=66,y=310,},[3]={f=K3,[K2]=1243,[K1]=K15,[K13]={[1]={f=K3,[K2]=1244,[K1]=K14,x=80,y=310,},[2]={f=K3,[K2]=1245,[K1]="nil",x=90,y=310,},},x=80,y=310,},},[K2]=1236,[K1]=K4,x=49,y=310,},[K2]=1231,[K1]=K9,x=10,y=310,},[K[11]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1248,[K1]=K18,x=22,y=313,},[2]={f=K3,[K20]=T4,[K19]={[1]=K[3],},[K2]=1249,[K1]=K18,x=28,y=313,},[3]={f=K3,[K2]=1250,[K1]=K14,x=43,y=313,},},[K2]=1247,[K1]=K4,x=51,y=313,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1252,[K1]=K15,[K13]={[1]={f=K3,[K2]=1253,[K1]=K29,x=53,y=313,},[2]={f=K3,[K2]=1254,[K1]="nil",x=63,y=313,},},x=53,y=313,},[2]={f=K3,[K2]=1255,[K1]=K15,[K13]={[1]={f=K3,[K2]=1256,[K1]=K12,x=68,y=313,},[2]={f=K3,[K2]=1257,[K1]="nil",x=77,y=313,},},x=68,y=313,},[3]={f=K3,[K2]=1258,[K1]=K15,[K13]={[1]={f=K3,[K2]=1259,[K1]=K14,x=82,y=313,},[2]={f=K3,[K2]=1260,[K1]="nil",x=92,y=313,},},x=82,y=313,},},[K2]=1251,[K1]=K4,x=51,y=313,},[K2]=1246,[K1]=K9,x=13,y=313,},[K[12]]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1263,[K1]=K18,x=20,y=317,},[2]={f=K3,[K2]=1264,[K1]=K15,[K13]={[1]={f=K3,[K2]=1265,[K1]=K12,x=27,y=317,},[2]={f=K3,[K2]=1266,[K1]=K16,x=36,y=317,},},x=27,y=317,},},[K2]=1262,[K1]=K4,x=47,y=317,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1268,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1269,[K1]=K18,x=49,y=317,},[2]={f=K3,[K2]=1270,[K1]="nil",x=56,y=317,},},x=49,y=317,},[2]={f=K3,[K2]=1271,[K1]=K15,[K13]={[1]={f=K3,[K2]=1272,[K1]=K12,x=61,y=317,},[2]={f=K3,[K2]=1273,[K1]="nil",x=70,y=317,},},x=61,y=317,},[3]={f=K3,[K2]=1274,[K1]=K15,[K13]={[1]={f=K3,[K2]=1275,[K1]=K14,x=75,y=317,},[2]={f=K3,[K2]=1276,[K1]="nil",x=85,y=317,},},x=75,y=317,},},[K2]=1267,[K1]=K4,x=47,y=317,},[K2]=1261,[K1]=K9,x=11,y=317,},}
T2[K[16]]={}
T2[K37]={[K[17]]={},["__is"]={},}
T2["meta_field_locations"]={[K[17]]={f=K3,x=15,y=319,},["__is"]={f=K3,x=10,y=248,},}
T2["meta_field_order"]={[1]=K[17],[2]="__is",}
T2["meta_fields"]={[K[17]]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K2]=1279,[K1]=K18,x=33,y=319,},},[K2]=1278,[K1]=K4,x=1,y=320,},f=K3,[K8]=true,[K10]=false,[K7]=1,rets={f=K3,[K4]={},[K2]=1280,[K1]=K4,x=37,y=319,},[K2]=1277,[K1]=K9,x=24,y=319,},["__is"]={args={f=K3,[K4]={[1]={["display_type"]=T2,f=K3,[K2]=1285,[K1]="self",x=10,y=248,},},[K2]=1286,[K1]=K4,x=10,y=248,},f=K3,[K8]=true,["macroexp"]={args={[1]={["argtype"]={["display_type"]=T2,f=K3,[K2]=1281,[K1]="self",x=10,y=248,},f=K3,kind="argument",tk="self",x=10,xend=11,y=248,yend=248,},f=K3,kind="argument_list",tk="io",x=10,xend=11,y=248,yend=248,},exp={e1={e1={f=K3,kind="variable",tk="io",x=10,xend=11,y=248,yend=248,},e2={f=K3,kind=K25,tk="type",x=13,xend=16,y=248,yend=248,},f=K3,kind="op",op={["arity"]=2,op=".",prec=100,x=12,y=248,},["receiver"]={f=K3,[K20]=T8,[K19]={[1]="io",},[K48]=T8,[K2]=2627,[K1]=K18,x=10,y=248,},x=12,y=248,},e2={[1]=T11,f=K3,kind="expression_list",tk="(",x=17,xend=22,y=248,yend=248,},f=K3,kind="op",op={["arity"]=2,op="@funcall",prec=100,x=17,y=248,},x=17,y=248,},f=K3,[K8]=true,kind="macroexp",[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1282,[K1]=K29,x=10,y=248,},},[K2]=1283,[K1]=K4,x=10,y=248,},tk="io",x=10,xend=22,y=248,yend=248,},[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1287,[K1]=K29,x=10,y=248,},},[K2]=1288,[K1]=K4,x=10,y=248,},[K2]=1284,[K1]=K9,x=10,y=248,},}
T3.def={[K32]=K[2],[K47]={cur=true,["end"]=true,set=true,},f=K3,[K2]=1098,[K1]="enum",[K44]={},x=4,y=250,}
T4.def={[K32]=K[3],[K47]={full=true,line=true,no=true,},f=K3,[K2]=1102,[K1]="enum",[K44]={},x=4,y=254,}
T5.def={[K32]=K[13],[K47]={["*n"]=true,n=true,},f=K3,[K2]=568,[K1]="enum",[K44]={},x=1,y=19,}
T6.def={[K32]=K[14],[K47]={["*L"]=true,["*a"]=true,["*l"]=true,L=true,a=true,l=true,},f=K3,[K2]=564,[K1]="enum",[K44]={},x=1,y=15,}
T7.def={[K32]=K[15],[K47]={["*L"]=true,["*a"]=true,["*l"]=true,["*n"]=true,L=true,a=true,l=true,n=true,},f=K3,[K2]=572,[K1]="enum",[K44]={},x=1,y=23,}
T8.def={[K32]="io",f=K3,[K40]={[K[18]]={},[K[19]]={},[K50]={[1]={[1]={text="--- Close a file, or the default output when omitted. Closing a standard stream may be restricted by the host.",x=4,y=164,},},},[K[4]]={[1]={[1]={text="--- Flush buffered data for the default output stream.",x=4,y=168,},},},[K[20]]={[1]={[1]={text="--- Get or set the default input stream; a filename opens the file for reading.",x=4,y=166,},},},[K[6]]={[1]={[1]={text=K[21],x=4,y=171,},},[2]={[1]={text=K[21],x=4,y=173,},},[3]={[1]={text=K[21],x=4,y=175,},},[4]={[1]={text=K[21],x=4,y=177,},[2]={text=K31,x=4,y=178,},},[5]={[1]={text=K[21],x=4,y=180,},},},open={[1]={[1]={text="--- Open a file with the selected mode (default `r`). On failure the handle is nil and an error message and system code may follow.",x=4,y=183,},[2]={text="---",x=4,y=184,},[3]={text="--- @param filename Path to open; interpretation is host-specific.",x=4,y=185,},[4]={text="--- @param mode Optional mode: read (`r`), write/truncate (`w`), append (`a`), or an update/binary variant.",x=4,y=186,},[5]={text="--- @return A file handle on success; otherwise nil, an error message, and a system error code.",x=4,y=187,},[6]={text=K[22],x=4,y=188,},[7]={text="--- local file, err = io.open(\"notes.txt\", \"r\")",x=4,y=189,},[8]={text="--- if file ~= nil then",x=4,y=190,},[9]={text="---    local line = file:read()",x=4,y=191,},[10]={text="---    file:close()",x=4,y=192,},[11]={text="--- end",x=4,y=193,},[12]={text=K[23],x=4,y=194,},},},[K[24]]={[1]={[1]={text="--- Get or set the default output stream; a filename opens the file for writing.",x=4,y=196,},},},[K[25]]={[1]={[1]={text="--- Start a process and return a stream connected to it, or nil and an error message on failure. Host support varies.",x=4,y=198,},[2]={text=K31,x=4,y=199,},},},read={[1]={[1]={text=K[26],x=4,y=202,},[2]={text="---",x=4,y=203,},[3]={text=K[27],x=4,y=204,},[4]={text=K[28],x=4,y=205,},},[2]={[1]={text=K[26],x=4,y=207,},[2]={text="---",x=4,y=208,},[3]={text=K[27],x=4,y=209,},[4]={text=K[28],x=4,y=210,},},[3]={[1]={text=K[26],x=4,y=212,},[2]={text="---",x=4,y=213,},[3]={text=K[27],x=4,y=214,},[4]={text=K[28],x=4,y=215,},},[4]={[1]={text=K[26],x=4,y=217,},[2]={text="---",x=4,y=218,},[3]={text=K[27],x=4,y=219,},[4]={text=K[28],x=4,y=220,},},[5]={[1]={text=K[26],x=4,y=222,},[2]={text="---",x=4,y=223,},[3]={text=K[27],x=4,y=224,},[4]={text=K[28],x=4,y=225,},},},[K[29]]={[1]={[1]={text="--- Standard error stream.",x=4,y=228,},},},[K[30]]={[1]={[1]={text="--- Standard input stream.",x=4,y=230,},},},[K[31]]={[1]={[1]={text="--- Standard output stream.",x=4,y=232,},},},[K[32]]={[1]={[1]={text="--- Create an anonymous temporary file. Returns nil and error details on failure; the file is removed when closed.",x=4,y=234,},[2]={text=K31,x=4,y=235,},},},type={[1]={[1]={text="--- Return `file` or `closed file` for a file handle, otherwise nil.",x=4,y=237,},[2]={text=K31,x=4,y=238,},},},[K[12]]={[1]={[1]={text="--- Write strings or numbers to the default output. Returns the stream on success or nil and error details on failure.",x=4,y=240,},[2]={text=K31,x=4,y=241,},},},},[K46]={[K[18]]={f=K3,x=4,y=159,},[K[19]]={f=K3,x=4,y=152,},[K50]={f=K3,x=4,y=165,},[K[4]]={f=K3,x=4,y=169,},[K[20]]={f=K3,x=4,y=167,},[K[6]]={f=K3,x=4,y=172,},open={f=K3,x=4,y=195,},[K[24]]={f=K3,x=4,y=197,},[K[25]]={f=K3,x=4,y=200,},read={f=K3,x=4,y=206,},[K[29]]={f=K3,x=4,y=229,},[K[30]]={f=K3,x=4,y=231,},[K[31]]={f=K3,x=4,y=233,},[K[32]]={f=K3,x=4,y=236,},type={f=K3,x=4,y=239,},[K[12]]={f=K3,x=4,y=242,},},[K39]={[1]=K[19],[2]=K[18],[3]=K50,[4]=K[20],[5]=K[4],[6]=K[6],[7]="open",[8]=K[24],[9]=K[25],[10]="read",[11]=K[29],[12]=K[30],[13]=K[31],[14]=K[32],[15]="type",[16]=K[12],},[K38]={[K[18]]=T9,[K[19]]=T10,[K50]={args={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=897,[K1]=K18,x=22,y=165,},},[K2]=896,[K1]=K4,x=27,y=165,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=899,[K1]=K15,[K13]={[1]={f=K3,[K2]=900,[K1]=K29,x=29,y=165,},[2]={f=K3,[K2]=901,[K1]="nil",x=39,y=165,},},x=29,y=165,},[2]={f=K3,[K2]=902,[K1]=K15,[K13]={[1]={f=K3,[K2]=903,[K1]=K12,x=44,y=165,},[2]={f=K3,[K2]=904,[K1]="nil",x=53,y=165,},},x=44,y=165,},[3]={f=K3,[K2]=905,[K1]=K15,[K13]={[1]={f=K3,[K2]=906,[K1]=K14,x=58,y=165,},[2]={f=K3,[K2]=907,[K1]="nil",x=68,y=165,},},x=58,y=165,},},[K2]=898,[K1]=K4,x=27,y=165,},[K2]=895,[K1]=K9,x=11,y=165,},[K[4]]={args={f=K3,[K4]={},[K2]=916,[K1]=K4,x=21,y=169,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=918,[K1]=K15,[K13]={[1]={f=K3,[K2]=919,[K1]=K29,x=23,y=169,},[2]={f=K3,[K2]=920,[K1]="nil",x=33,y=169,},},x=23,y=169,},[2]={f=K3,[K2]=921,[K1]=K15,[K13]={[1]={f=K3,[K2]=922,[K1]=K12,x=38,y=169,},[2]={f=K3,[K2]=923,[K1]="nil",x=47,y=169,},},x=38,y=169,},[3]={f=K3,[K2]=924,[K1]=K15,[K13]={[1]={f=K3,[K2]=925,[K1]=K14,x=52,y=169,},[2]={f=K3,[K2]=926,[K1]="nil",x=62,y=169,},},x=52,y=169,},},[K2]=917,[K1]=K4,x=21,y=169,},[K2]=915,[K1]=K9,x=11,y=169,},[K[20]]={args={f=K3,[K4]={[1]={f=K3,[K2]=910,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=911,[K1]=K18,x=22,y=167,},[2]={f=K3,[K2]=912,[K1]=K12,x=29,y=167,},},x=22,y=167,},},[K2]=909,[K1]=K4,x=36,y=167,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=914,[K1]=K18,x=38,y=167,},},[K2]=913,[K1]=K4,x=36,y=167,},[K2]=908,[K1]=K9,x=11,y=167,},[K[6]]={f=K3,[K2]=944,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={[1]={f=K3,[K2]=929,[K1]=K12,x=22,y=172,},},[K2]=928,[K1]=K4,x=29,y=172,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=932,[K1]=K4,x=42,y=172,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=934,[K1]=K12,x=45,y=172,},},[K2]=933,[K1]=K4,x=42,y=172,},[K2]=931,[K1]=K9,x=32,y=172,},},[K2]=930,[K1]=K4,x=29,y=172,},[K2]=927,[K1]=K9,x=11,y=172,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=937,[K1]=K12,x=22,y=174,},[2]={f=K3,[K20]=T5,[K19]={[1]=K[13],},[K2]=938,[K1]=K18,x=30,y=174,},},[K2]=936,[K1]=K4,x=48,y=174,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=941,[K1]=K4,x=61,y=174,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=943,[K1]=K16,x=64,y=174,},},[K2]=942,[K1]=K4,x=61,y=174,},[K2]=940,[K1]=K9,x=51,y=174,},},[K2]=939,[K1]=K4,x=48,y=174,},[K2]=935,[K1]=K9,x=11,y=174,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=947,[K1]=K12,x=22,y=176,},[2]={f=K3,[K2]=948,[K1]=K15,[K13]={[1]={f=K3,[K2]=949,[K1]=K16,x=31,y=176,},[2]={f=K3,[K20]=T6,[K19]={[1]=K[14],},[K2]=950,[K1]=K18,x=40,y=176,},},x=31,y=176,},},[K2]=946,[K1]=K4,x=59,y=176,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=953,[K1]=K4,x=72,y=176,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=955,[K1]=K12,x=75,y=176,},},[K2]=954,[K1]=K4,x=72,y=176,},[K2]=952,[K1]=K9,x=62,y=176,},},[K2]=951,[K1]=K4,x=59,y=176,},[K2]=945,[K1]=K9,x=11,y=176,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=958,[K1]=K12,x=22,y=179,},[2]={f=K3,[K2]=959,[K1]=K15,[K13]={[1]={f=K3,[K2]=960,[K1]=K16,x=31,y=179,},[2]={f=K3,[K20]=T7,[K19]={[1]=K[15],},[K2]=961,[K1]=K18,x=40,y=179,},},x=31,y=179,},},[K2]=957,[K1]=K4,x=53,y=179,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=964,[K1]=K4,x=66,y=179,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=966,[K1]=K15,[K13]={[1]={f=K3,[K2]=967,[K1]=K12,x=70,y=179,},[2]={f=K3,[K2]=968,[K1]=K16,x=79,y=179,},[3]={f=K3,[K2]=969,[K1]="nil",x=88,y=179,},},x=70,y=179,},},[K2]=965,[K1]=K4,x=66,y=179,},[K2]=963,[K1]=K9,x=56,y=179,},},[K2]=962,[K1]=K4,x=53,y=179,},[K2]=956,[K1]=K9,x=11,y=179,},[5]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=972,[K1]=K12,x=22,y=181,},[2]={f=K3,[K2]=973,[K1]=K15,[K13]={[1]={f=K3,[K2]=974,[K1]=K16,x=31,y=181,},[2]={f=K3,[K2]=975,[K1]=K12,x=40,y=181,},},x=31,y=181,},},[K2]=971,[K1]=K4,x=51,y=181,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={args={f=K3,[K4]={},[K2]=978,[K1]=K4,x=64,y=181,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=980,[K1]=K12,x=67,y=181,},},[K2]=979,[K1]=K4,x=64,y=181,},[K2]=977,[K1]=K9,x=54,y=181,},},[K2]=976,[K1]=K4,x=51,y=181,},[K2]=970,[K1]=K9,x=11,y=181,},},x=4,y=174,},open={args={f=K3,[K4]={[1]={f=K3,[K2]=983,[K1]=K12,x=19,y=195,},[2]={f=K3,[K20]=T10,[K19]={[1]=K[19],},[K2]=984,[K1]=K18,x=29,y=195,},},[K2]=982,[K1]=K4,x=38,y=195,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=986,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=987,[K1]=K18,x=40,y=195,},[2]={f=K3,[K2]=988,[K1]="nil",x=47,y=195,},},x=40,y=195,},[2]={f=K3,[K2]=989,[K1]=K15,[K13]={[1]={f=K3,[K2]=990,[K1]=K12,x=52,y=195,},[2]={f=K3,[K2]=991,[K1]="nil",x=61,y=195,},},x=52,y=195,},[3]={f=K3,[K2]=992,[K1]=K15,[K13]={[1]={f=K3,[K2]=993,[K1]=K14,x=66,y=195,},[2]={f=K3,[K2]=994,[K1]="nil",x=76,y=195,},},x=66,y=195,},},[K2]=985,[K1]=K4,x=38,y=195,},[K2]=981,[K1]=K9,x=10,y=195,},[K[24]]={args={f=K3,[K4]={[1]={f=K3,[K2]=997,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=998,[K1]=K18,x=23,y=197,},[2]={f=K3,[K2]=999,[K1]=K12,x=30,y=197,},},x=23,y=197,},},[K2]=996,[K1]=K4,x=37,y=197,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1001,[K1]=K18,x=39,y=197,},},[K2]=1000,[K1]=K4,x=37,y=197,},[K2]=995,[K1]=K9,x=12,y=197,},[K[25]]={args={f=K3,[K4]={[1]={f=K3,[K2]=1004,[K1]=K12,x=20,y=200,},[2]={f=K3,[K20]=T10,[K19]={[1]=K[19],},[K2]=1005,[K1]=K18,x=30,y=200,},},[K2]=1003,[K1]=K4,x=39,y=200,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1007,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1008,[K1]=K18,x=41,y=200,},[2]={f=K3,[K2]=1009,[K1]="nil",x=48,y=200,},},x=41,y=200,},[2]={f=K3,[K2]=1010,[K1]=K15,[K13]={[1]={f=K3,[K2]=1011,[K1]=K12,x=53,y=200,},[2]={f=K3,[K2]=1012,[K1]="nil",x=62,y=200,},},x=53,y=200,},},[K2]=1006,[K1]=K4,x=39,y=200,},[K2]=1002,[K1]=K9,x=11,y=200,},read={f=K3,[K2]=1026,[K1]="poly",[K13]={[1]={args={f=K3,[K4]={},[K2]=1014,[K1]=K4,x=20,y=206,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1016,[K1]=K15,[K13]={[1]={f=K3,[K2]=1017,[K1]=K12,x=22,y=206,},[2]={f=K3,[K2]=1018,[K1]="nil",x=31,y=206,},},x=22,y=206,},},[K2]=1015,[K1]=K4,x=20,y=206,},[K2]=1013,[K1]=K9,x=10,y=206,},[2]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K20]=T5,[K19]={[1]=K[13],},[K2]=1021,[K1]=K18,x=19,y=211,},},[K2]=1020,[K1]=K4,x=37,y=211,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1023,[K1]=K15,[K13]={[1]={f=K3,[K2]=1024,[K1]=K16,x=41,y=211,},[2]={f=K3,[K2]=1025,[K1]="nil",x=50,y=211,},},x=41,y=211,},},[K2]=1022,[K1]=K4,x=37,y=211,},[K2]=1019,[K1]=K9,x=10,y=211,},[3]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1029,[K1]=K15,[K13]={[1]={f=K3,[K2]=1030,[K1]=K16,x=20,y=216,},[2]={f=K3,[K20]=T6,[K19]={[1]=K[14],},[K2]=1031,[K1]=K18,x=29,y=216,},},x=20,y=216,},},[K2]=1028,[K1]=K4,x=48,y=216,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1033,[K1]=K15,[K13]={[1]={f=K3,[K2]=1034,[K1]=K12,x=52,y=216,},[2]={f=K3,[K2]=1035,[K1]="nil",x=61,y=216,},},x=52,y=216,},},[K2]=1032,[K1]=K4,x=48,y=216,},[K2]=1027,[K1]=K9,x=10,y=216,},[4]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1038,[K1]=K15,[K13]={[1]={f=K3,[K2]=1039,[K1]=K16,x=20,y=221,},[2]={f=K3,[K20]=T7,[K19]={[1]=K[15],},[K2]=1040,[K1]=K18,x=29,y=221,},},x=20,y=221,},},[K2]=1037,[K1]=K4,x=42,y=221,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1042,[K1]=K15,[K13]={[1]={f=K3,[K2]=1043,[K1]=K12,x=46,y=221,},[2]={f=K3,[K2]=1044,[K1]=K16,x=55,y=221,},[3]={f=K3,[K2]=1045,[K1]="nil",x=64,y=221,},},x=46,y=221,},},[K2]=1041,[K1]=K4,x=42,y=221,},[K2]=1036,[K1]=K9,x=10,y=221,},[5]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1048,[K1]=K15,[K13]={[1]={f=K3,[K2]=1049,[K1]=K16,x=20,y=226,},[2]={f=K3,[K2]=1050,[K1]=K12,x=29,y=226,},},x=20,y=226,},},[K2]=1047,[K1]=K4,x=40,y=226,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1052,[K1]=K15,[K13]={[1]={f=K3,[K2]=1053,[K1]=K12,x=44,y=226,},[2]={f=K3,[K2]=1054,[K1]="nil",x=53,y=226,},},x=44,y=226,},},[K2]=1051,[K1]=K4,x=40,y=226,},[K2]=1046,[K1]=K9,x=10,y=226,},},x=4,y=211,},[K[29]]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1055,[K1]=K18,x=12,y=229,},[K[30]]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1056,[K1]=K18,x=11,y=231,},[K[31]]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1057,[K1]=K18,x=12,y=233,},[K[32]]={args={f=K3,[K4]={},[K2]=1059,[K1]=K4,x=23,y=236,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1061,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1062,[K1]=K18,x=25,y=236,},[2]={f=K3,[K2]=1063,[K1]="nil",x=32,y=236,},},x=25,y=236,},[2]={f=K3,[K2]=1064,[K1]=K15,[K13]={[1]={f=K3,[K2]=1065,[K1]=K12,x=37,y=236,},[2]={f=K3,[K2]=1066,[K1]="nil",x=46,y=236,},},x=37,y=236,},[3]={f=K3,[K2]=1067,[K1]=K15,[K13]={[1]={f=K3,[K2]=1068,[K1]=K14,x=51,y=236,},[2]={f=K3,[K2]=1069,[K1]="nil",x=61,y=236,},},x=51,y=236,},},[K2]=1060,[K1]=K4,x=23,y=236,},[K2]=1058,[K1]=K9,x=13,y=236,},type={args={f=K3,[K4]={[1]={f=K3,[K2]=1072,[K1]="any",x=19,y=239,},},[K2]=1071,[K1]=K4,x=23,y=239,},f=K3,[K8]=false,[K10]=false,[K7]=1,rets={f=K3,[K4]={[1]={f=K3,[K2]=1074,[K1]=K15,[K13]={[1]={f=K3,[K20]=T9,[K19]={[1]=K[18],},[K2]=1075,[K1]=K18,x=25,y=239,},[2]={f=K3,[K2]=1076,[K1]="nil",x=36,y=239,},},x=25,y=239,},},[K2]=1073,[K1]=K4,x=23,y=239,},[K2]=1070,[K1]=K9,x=10,y=239,},[K[12]]={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=1079,[K1]=K15,[K13]={[1]={f=K3,[K2]=1080,[K1]=K12,x=21,y=242,},[2]={f=K3,[K2]=1081,[K1]=K16,x=30,y=242,},},x=21,y=242,},},[K2]=1078,[K1]=K4,x=41,y=242,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=1083,[K1]=K15,[K13]={[1]={f=K3,[K20]=T1,[K19]={[1]="FILE",},[K48]=T2,[K2]=1084,[K1]=K18,x=43,y=242,},[2]={f=K3,[K2]=1085,[K1]="nil",x=50,y=242,},},x=43,y=242,},[2]={f=K3,[K2]=1086,[K1]=K15,[K13]={[1]={f=K3,[K2]=1087,[K1]=K12,x=55,y=242,},[2]={f=K3,[K2]=1088,[K1]="nil",x=64,y=242,},},x=55,y=242,},[3]={f=K3,[K2]=1089,[K1]=K15,[K13]={[1]={f=K3,[K2]=1090,[K1]=K14,x=69,y=242,},[2]={f=K3,[K2]=1091,[K1]="nil",x=79,y=242,},},x=69,y=242,},},[K2]=1082,[K1]=K4,x=41,y=242,},[K2]=1077,[K1]=K9,x=11,y=242,},},[K37]={},[K2]=886,[K1]=K45,x=1,y=151,}
T9.def={[K32]=K[18],[K47]={["closed file"]=true,file=true,},f=K3,[K2]=893,[K1]="enum",[K44]={},x=4,y=159,}
T10.def={[K32]=K[19],[K47]={["*a"]=true,["*a+"]=true,["*a+b"]=true,["*ab"]=true,["*r"]=true,["*r+"]=true,["*r+b"]=true,["*rb"]=true,["*w"]=true,["*w+"]=true,["*w+b"]=true,["*wb"]=true,a=true,["a+"]=true,["a+b"]=true,ab=true,r=true,["r+"]=true,["r+b"]=true,rb=true,w=true,["w+"]=true,["w+b"]=true,wb=true,},f=K3,[K2]=889,[K1]="enum",[K44]={},x=4,y=152,}
T11["expected"]={f=K3,["inferred_at"]=T11,[K2]=2629,[K1]="any",x=18,y=248,}
T12.def={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=581,[K1]="any",x=29,y=29,},},[K2]=580,[K1]=K4,x=36,y=29,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=583,[K1]="any",x=38,y=29,},},[K2]=582,[K1]=K4,x=36,y=29,},[K2]=579,[K1]=K9,x=20,y=29,}
T13.def={args={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=677,[K1]="any",x=32,y=78,},},[K2]=676,[K1]=K4,x=39,y=78,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K17]=true,[K4]={[1]={f=K3,[K2]=679,[K1]="any",x=40,y=78,},},[K2]=678,[K1]=K4,x=39,y=78,},[K2]=675,[K1]=K9,x=23,y=78,}
T14.def={[K32]=K[45],f=K3,[K40]={[K[65]]={},[K[66]]={},[K[67]]={},func={},[K[68]]={},[K[69]]={},[K[70]]={},[K[71]]={},name={},[K[72]]={},[K[73]]={},[K[74]]={[1]={[1]={text="-- TODO: what should compat be for these? (5.4+)",x=26,y=68,},},},nups={},[K[75]]={},[K[76]]={},what={},},[K46]={[K[65]]={f=K3,x=7,y=67,},[K[66]]={f=K3,x=7,y=61,},[K[67]]={f=K3,x=7,y=68,},func={f=K3,x=7,y=66,},[K[68]]={f=K3,x=7,y=62,},[K[69]]={f=K3,x=7,y=65,},[K[70]]={f=K3,x=7,y=59,},[K[71]]={f=K3,x=7,y=58,},name={f=K3,x=7,y=54,},[K[72]]={f=K3,x=7,y=55,},[K[73]]={f=K3,x=7,y=64,},[K[74]]={f=K3,x=7,y=69,},nups={f=K3,x=7,y=63,},[K[75]]={f=K3,x=7,y=57,},[K[76]]={f=K3,x=7,y=56,},what={f=K3,x=7,y=60,},},[K39]={[1]="name",[2]=K[72],[3]=K[76],[4]=K[75],[5]=K[71],[6]=K[70],[7]="what",[8]=K[66],[9]=K[68],[10]="nups",[11]=K[73],[12]=K[69],[13]="func",[14]=K[65],[15]=K[67],[16]=K[74],},[K38]={[K[65]]={f=K3,keys={f=K3,[K2]=656,[K1]=K14,x=21,y=67,},[K2]=655,[K1]="map",[K34]={f=K3,[K2]=657,[K1]=K29,x=29,y=67,},x=20,xend=36,y=67,yend=67,},[K[66]]={f=K3,[K2]=649,[K1]=K14,x=20,y=61,},[K[67]]={f=K3,[K2]=658,[K1]=K14,x=18,y=68,},func={f=K3,[K2]=654,[K1]="any",x=13,y=66,},[K[68]]={f=K3,[K2]=650,[K1]=K29,x=19,y=62,},[K[69]]={f=K3,[K2]=653,[K1]=K29,x=17,y=65,},[K[70]]={f=K3,[K2]=647,[K1]=K14,x=24,y=59,},[K[71]]={f=K3,[K2]=646,[K1]=K14,x=20,y=58,},name={f=K3,[K2]=642,[K1]=K12,x=13,y=54,},[K[72]]={f=K3,[K2]=643,[K1]=K12,x=17,y=55,},[K[73]]={f=K3,[K2]=652,[K1]=K14,x=16,y=64,},[K[74]]={f=K3,[K2]=659,[K1]=K14,x=18,y=69,},nups={f=K3,[K2]=651,[K1]=K14,x=13,y=63,},[K[75]]={f=K3,[K2]=645,[K1]=K12,x=18,y=57,},[K[76]]={f=K3,[K2]=644,[K1]=K12,x=15,y=56,},what={f=K3,[K2]=648,[K1]=K12,x=13,y=60,},},[K37]={},[K2]=641,[K1]=K45,x=4,y=53,}
T15.def={[K32]=K[46],[K47]={call=true,["count"]=true,line=true,["return"]=true,["tail call"]=true,},f=K3,[K2]=663,[K1]="enum",[K44]={},x=4,y=72,}
T16.def={args={f=K3,[K4]={[1]={f=K3,[K20]=T15,[K19]={[1]=K[46],},[K2]=669,[K1]=K18,x=33,y=76,},[2]={f=K3,[K2]=670,[K1]=K14,x=44,y=76,},},[K2]=668,[K1]=K4,x=4,y=78,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={},[K2]=671,[K1]=K4,x=51,y=76,},[K2]=667,[K1]=K9,x=24,y=76,}
T17.def={f=K6,t={[K32]=K[77],f=K6,[K40]={Mode={},[K[78]]={},[K[79]]={},[K[80]]={},[K[81]]={},[K[82]]={},[K[83]]={},[K[17]]={},[K[84]]={},[K[85]]={},["__eq"]={},["__gc"]={},[K[86]]={},[K[87]]={},["__le"]={},[K[88]]={},["__lt"]={},[K[89]]={},[K[90]]={},[K[91]]={},[K[92]]={},[K[93]]={[1]={[1]={text="--[[FIXME: function | table | anything with an __index metamethod]]",x=17,y=29,},},},[K[94]]={},[K[95]]={},[K[96]]={},[K[97]]={},[K[98]]={},[K[99]]={},[K[100]]={},},[K46]={Mode={f=K6,x=4,y=19,},[K[78]]={f=K6,x=4,y=35,},[K[79]]={f=K6,x=4,y=42,},[K[80]]={f=K6,x=4,y=51,},[K[81]]={f=K6,x=4,y=43,},[K[82]]={f=K6,x=4,y=44,},[K[83]]={f=K6,x=4,y=23,},[K[17]]={f=K6,x=4,y=33,},[K[84]]={f=K6,x=4,y=47,},[K[85]]={f=K6,x=4,y=38,},["__eq"]={f=K6,x=4,y=53,},["__gc"]={f=K6,x=4,y=32,},[K[86]]={f=K6,x=4,y=39,},[K[87]]={f=K6,x=4,y=29,},["__le"]={f=K6,x=4,y=55,},[K[88]]={f=K6,x=4,y=49,},["__lt"]={f=K6,x=4,y=54,},[K[89]]={f=K6,x=4,y=40,},[K[90]]={f=K6,x=4,y=24,},[K[91]]={f=K6,x=4,y=37,},[K[92]]={f=K6,x=4,y=25,},[K[93]]={f=K6,x=4,y=30,},[K[94]]={f=K6,x=4,y=27,},[K[95]]={f=K6,x=4,y=41,},[K[96]]={f=K6,x=4,y=45,},[K[97]]={f=K6,x=4,y=46,},[K[98]]={f=K6,x=4,y=36,},[K[99]]={f=K6,x=4,y=26,},[K[100]]={f=K6,x=4,y=50,},},[K39]={[1]="Mode",[2]=K[83],[3]=K[90],[4]=K[92],[5]=K[99],[6]=K[94],[7]=K[87],[8]=K[93],[9]="__gc",[10]=K[17],[11]=K[78],[12]=K[98],[13]=K[91],[14]=K[85],[15]=K[86],[16]=K[89],[17]=K[95],[18]=K[79],[19]=K[81],[20]=K[82],[21]=K[96],[22]=K[97],[23]=K[84],[24]=K[88],[25]=K[100],[26]=K[80],[27]="__eq",[28]="__lt",[29]="__le",},[K38]={Mode=T18,[K[78]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=272,[K1]=K5,[K5]="A@3",x=29,y=35,},[2]={f=K6,[K2]=273,[K1]=K5,[K5]="B@3",x=32,y=35,},},[K2]=274,[K1]=K4,x=34,y=35,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=275,[K1]=K5,[K5]="C@3",x=36,y=35,},},[K2]=276,[K1]=K4,x=34,y=35,},[K2]=277,[K1]=K9,x=11,y=35,},[K21]={[1]={f=K6,[K11]="A@3",[K2]=269,[K1]=K11,x=20,y=35,},[2]={f=K6,[K11]="B@3",[K2]=270,[K1]=K11,x=23,y=35,},[3]={f=K6,[K11]="C@3",[K2]=271,[K1]=K11,x=26,y=35,},},[K2]=278,[K1]=K22,x=4,y=36,},[K[79]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=384,[K1]=K5,[K5]="A@10",x=30,y=42,},[2]={f=K6,[K2]=385,[K1]=K5,[K5]="B@10",x=33,y=42,},},[K2]=386,[K1]=K4,x=35,y=42,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=387,[K1]=K5,[K5]="C@10",x=37,y=42,},},[K2]=388,[K1]=K4,x=35,y=42,},[K2]=389,[K1]=K9,x=12,y=42,},[K21]={[1]={f=K6,[K11]="A@10",[K2]=381,[K1]=K11,x=21,y=42,},[2]={f=K6,[K11]="B@10",[K2]=382,[K1]=K11,x=24,y=42,},[3]={f=K6,[K11]="C@10",[K2]=383,[K1]=K11,x=27,y=42,},},[K2]=390,[K1]=K22,x=4,y=43,},[K[80]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=488,[K1]=K5,[K5]="T",x=24,y=51,},},[K2]=206,[K1]=K4,x=26,y=51,},f=K6,[K8]=false,[K7]=1,rets={f=K6,[K4]={[1]={f=K6,[K2]=491,[K1]=K5,[K5]="A@18",x=28,y=51,},},[K2]=492,[K1]=K4,x=26,y=51,},[K2]=493,[K1]=K9,x=12,y=51,},[K21]={[1]={f=K6,[K11]="A@18",[K2]=490,[K1]=K11,x=21,y=51,},},[K2]=494,[K1]=K22,x=4,y=53,},[K[81]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=400,[K1]=K5,[K5]="A@11",x=29,y=43,},[2]={f=K6,[K2]=401,[K1]=K5,[K5]="B@11",x=32,y=43,},},[K2]=402,[K1]=K4,x=34,y=43,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=403,[K1]=K5,[K5]="C@11",x=36,y=43,},},[K2]=404,[K1]=K4,x=34,y=43,},[K2]=405,[K1]=K9,x=11,y=43,},[K21]={[1]={f=K6,[K11]="A@11",[K2]=397,[K1]=K11,x=20,y=43,},[2]={f=K6,[K11]="B@11",[K2]=398,[K1]=K11,x=23,y=43,},[3]={f=K6,[K11]="C@11",[K2]=399,[K1]=K11,x=26,y=43,},},[K2]=406,[K1]=K22,x=4,y=44,},[K[82]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=416,[K1]=K5,[K5]="A@12",x=30,y=44,},[2]={f=K6,[K2]=417,[K1]=K5,[K5]="B@12",x=33,y=44,},},[K2]=418,[K1]=K4,x=35,y=44,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=419,[K1]=K5,[K5]="C@12",x=37,y=44,},},[K2]=420,[K1]=K4,x=35,y=44,},[K2]=421,[K1]=K9,x=12,y=44,},[K21]={[1]={f=K6,[K11]="A@12",[K2]=413,[K1]=K11,x=21,y=44,},[2]={f=K6,[K11]="B@12",[K2]=414,[K1]=K11,x=24,y=44,},[3]={f=K6,[K11]="C@12",[K2]=415,[K1]=K11,x=27,y=44,},},[K2]=422,[K1]=K22,x=4,y=45,},[K[83]]={args={f=K6,[K17]=true,[K4]={[1]={f=K6,[K2]=245,[K1]=K5,[K5]="T",x=21,y=23,},[2]={f=K6,[K2]=28,[K1]="any",x=24,y=23,},},[K2]=26,[K1]=K4,x=31,y=23,},f=K6,[K8]=false,[K10]=false,[K7]=1,rets={f=K6,[K17]=true,[K4]={[1]={f=K6,[K2]=30,[K1]="any",x=33,y=23,},},[K2]=29,[K1]=K4,x=31,y=23,},[K2]=25,[K1]=K9,x=12,y=23,},[K[17]]={args={f=K6,[K4]={[1]={f=K6,[K2]=262,[K1]=K5,[K5]="T",x=22,y=33,},},[K2]=57,[K1]=K4,x=4,y=35,},f=K6,[K8]=false,[K10]=false,[K7]=1,rets={f=K6,[K4]={},[K2]=59,[K1]=K4,x=23,y=33,},[K2]=56,[K1]=K9,x=13,y=33,},[K[84]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=464,[K1]=K5,[K5]="A@15",x=32,y=47,},[2]={f=K6,[K2]=465,[K1]=K5,[K5]="B@15",x=35,y=47,},},[K2]=466,[K1]=K4,x=37,y=47,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=467,[K1]=K5,[K5]="C@15",x=39,y=47,},},[K2]=468,[K1]=K4,x=37,y=47,},[K2]=469,[K1]=K9,x=14,y=47,},[K21]={[1]={f=K6,[K11]="A@15",[K2]=461,[K1]=K11,x=23,y=47,},[2]={f=K6,[K11]="B@15",[K2]=462,[K1]=K11,x=26,y=47,},[3]={f=K6,[K11]="C@15",[K2]=463,[K1]=K11,x=29,y=47,},},[K2]=470,[K1]=K22,x=4,y=49,},[K[85]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=320,[K1]=K5,[K5]="A@6",x=29,y=38,},[2]={f=K6,[K2]=321,[K1]=K5,[K5]="B@6",x=32,y=38,},},[K2]=322,[K1]=K4,x=34,y=38,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=323,[K1]=K5,[K5]="C@6",x=36,y=38,},},[K2]=324,[K1]=K4,x=34,y=38,},[K2]=325,[K1]=K9,x=11,y=38,},[K21]={[1]={f=K6,[K11]="A@6",[K2]=317,[K1]=K11,x=20,y=38,},[2]={f=K6,[K11]="B@6",[K2]=318,[K1]=K11,x=23,y=38,},[3]={f=K6,[K11]="C@6",[K2]=319,[K1]=K11,x=26,y=38,},},[K2]=326,[K1]=K22,x=4,y=39,},["__eq"]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=501,[K1]=K5,[K5]="A@19",x=25,y=53,},[2]={f=K6,[K2]=502,[K1]=K5,[K5]="B@19",x=28,y=53,},},[K2]=503,[K1]=K4,x=30,y=53,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=218,[K1]=K29,x=32,y=53,},},[K2]=217,[K1]=K4,x=30,y=53,},[K2]=504,[K1]=K9,x=10,y=53,},[K21]={[1]={f=K6,[K11]="A@19",[K2]=499,[K1]=K11,x=19,y=53,},[2]={f=K6,[K11]="B@19",[K2]=500,[K1]=K11,x=22,y=53,},},[K2]=505,[K1]=K22,x=4,y=54,},["__gc"]={args={f=K6,[K4]={[1]={f=K6,[K2]=261,[K1]=K5,[K5]="T",x=19,y=32,},},[K2]=53,[K1]=K4,x=4,y=33,},f=K6,[K8]=false,[K10]=false,[K7]=1,rets={f=K6,[K4]={},[K2]=55,[K1]=K4,x=20,y=32,},[K2]=52,[K1]=K9,x=10,y=32,},[K[86]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=336,[K1]=K5,[K5]="A@7",x=30,y=39,},[2]={f=K6,[K2]=337,[K1]=K5,[K5]="B@7",x=33,y=39,},},[K2]=338,[K1]=K4,x=35,y=39,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=339,[K1]=K5,[K5]="C@7",x=37,y=39,},},[K2]=340,[K1]=K4,x=35,y=39,},[K2]=341,[K1]=K9,x=12,y=39,},[K21]={[1]={f=K6,[K11]="A@7",[K2]=333,[K1]=K11,x=21,y=39,},[2]={f=K6,[K11]="B@7",[K2]=334,[K1]=K11,x=24,y=39,},[3]={f=K6,[K11]="C@7",[K2]=335,[K1]=K11,x=27,y=39,},},[K2]=342,[K1]=K22,x=4,y=40,},[K[87]]={f=K6,[K2]=50,[K1]="any",x=13,y=29,},["__le"]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=523,[K1]=K5,[K5]="A@21",x=25,y=55,},[2]={f=K6,[K2]=524,[K1]=K5,[K5]="B@21",x=28,y=55,},},[K2]=525,[K1]=K4,x=30,y=55,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=236,[K1]=K29,x=32,y=55,},},[K2]=235,[K1]=K4,x=30,y=55,},[K2]=526,[K1]=K9,x=10,y=55,},[K21]={[1]={f=K6,[K11]="A@21",[K2]=521,[K1]=K11,x=19,y=55,},[2]={f=K6,[K11]="B@21",[K2]=522,[K1]=K11,x=22,y=55,},},[K2]=527,[K1]=K22,x=1,y=56,},[K[88]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=472,[K1]=K5,[K5]="T",x=23,y=49,},},[K2]=192,[K1]=K4,x=25,y=49,},f=K6,[K8]=false,[K7]=1,rets={f=K6,[K4]={[1]={f=K6,[K2]=475,[K1]=K5,[K5]="A@16",x=27,y=49,},},[K2]=476,[K1]=K4,x=25,y=49,},[K2]=477,[K1]=K9,x=11,y=49,},[K21]={[1]={f=K6,[K11]="A@16",[K2]=474,[K1]=K11,x=20,y=49,},},[K2]=478,[K1]=K22,x=4,y=50,},["__lt"]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=512,[K1]=K5,[K5]="A@20",x=25,y=54,},[2]={f=K6,[K2]=513,[K1]=K5,[K5]="B@20",x=28,y=54,},},[K2]=514,[K1]=K4,x=30,y=54,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=227,[K1]=K29,x=32,y=54,},},[K2]=226,[K1]=K4,x=30,y=54,},[K2]=515,[K1]=K9,x=10,y=54,},[K21]={[1]={f=K6,[K11]="A@20",[K2]=510,[K1]=K11,x=19,y=54,},[2]={f=K6,[K11]="B@20",[K2]=511,[K1]=K11,x=22,y=54,},},[K2]=516,[K1]=K22,x=4,y=55,},[K[89]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=352,[K1]=K5,[K5]="A@8",x=29,y=40,},[2]={f=K6,[K2]=353,[K1]=K5,[K5]="B@8",x=32,y=40,},},[K2]=354,[K1]=K4,x=34,y=40,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=355,[K1]=K5,[K5]="C@8",x=36,y=40,},},[K2]=356,[K1]=K4,x=34,y=40,},[K2]=357,[K1]=K9,x=11,y=40,},[K21]={[1]={f=K6,[K11]="A@8",[K2]=349,[K1]=K11,x=20,y=40,},[2]={f=K6,[K11]="B@8",[K2]=350,[K1]=K11,x=23,y=40,},[3]={f=K6,[K11]="C@8",[K2]=351,[K1]=K11,x=26,y=40,},},[K2]=358,[K1]=K22,x=4,y=41,},[K[90]]={f=K6,[K20]=T18,[K19]={[1]="Mode",},[K2]=31,[K1]=K18,x=12,y=24,},[K[91]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=304,[K1]=K5,[K5]="A@5",x=29,y=37,},[2]={f=K6,[K2]=305,[K1]=K5,[K5]="B@5",x=32,y=37,},},[K2]=306,[K1]=K4,x=34,y=37,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=307,[K1]=K5,[K5]="C@5",x=36,y=37,},},[K2]=308,[K1]=K4,x=34,y=37,},[K2]=309,[K1]=K9,x=11,y=37,},[K21]={[1]={f=K6,[K11]="A@5",[K2]=301,[K1]=K11,x=20,y=37,},[2]={f=K6,[K11]="B@5",[K2]=302,[K1]=K11,x=23,y=37,},[3]={f=K6,[K11]="C@5",[K2]=303,[K1]=K11,x=26,y=37,},},[K2]=310,[K1]=K22,x=4,y=38,},[K[92]]={f=K6,[K2]=32,[K1]=K12,x=12,y=25,},[K[93]]={f=K6,[K2]=51,[K1]="any",x=16,y=30,},[K[94]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=249,[K1]=K5,[K5]="T",x=28,y=27,},},[K2]=41,[K1]=K4,x=30,y=27,},f=K6,[K8]=false,[K7]=1,rets={f=K6,[K4]={[1]={args={f=K6,[K4]={},[K2]=45,[K1]=K4,x=42,y=27,},f=K6,[K8]=false,[K7]=0,rets={f=K6,[K4]={[1]={f=K6,[K2]=254,[K1]=K5,[K5]="K@2",x=45,y=27,},[2]={f=K6,[K2]=255,[K1]=K5,[K5]="V@2",x=48,y=27,},},[K2]=256,[K1]=K4,x=42,y=27,},[K2]=257,[K1]=K9,x=32,y=27,},},[K2]=258,[K1]=K4,x=30,y=27,},[K2]=259,[K1]=K9,x=13,y=27,},[K21]={[1]={f=K6,[K11]="K@2",[K2]=252,[K1]=K11,x=22,y=27,},[2]={f=K6,[K11]="V@2",[K2]=253,[K1]=K11,x=25,y=27,},},[K2]=260,[K1]=K22,x=4,y=29,},[K[95]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=368,[K1]=K5,[K5]="A@9",x=29,y=41,},[2]={f=K6,[K2]=369,[K1]=K5,[K5]="B@9",x=32,y=41,},},[K2]=370,[K1]=K4,x=34,y=41,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=371,[K1]=K5,[K5]="C@9",x=36,y=41,},},[K2]=372,[K1]=K4,x=34,y=41,},[K2]=373,[K1]=K9,x=11,y=41,},[K21]={[1]={f=K6,[K11]="A@9",[K2]=365,[K1]=K11,x=20,y=41,},[2]={f=K6,[K11]="B@9",[K2]=366,[K1]=K11,x=23,y=41,},[3]={f=K6,[K11]="C@9",[K2]=367,[K1]=K11,x=26,y=41,},},[K2]=374,[K1]=K22,x=4,y=42,},[K[96]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=432,[K1]=K5,[K5]="A@13",x=29,y=45,},[2]={f=K6,[K2]=433,[K1]=K5,[K5]="B@13",x=32,y=45,},},[K2]=434,[K1]=K4,x=34,y=45,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=435,[K1]=K5,[K5]="C@13",x=36,y=45,},},[K2]=436,[K1]=K4,x=34,y=45,},[K2]=437,[K1]=K9,x=11,y=45,},[K21]={[1]={f=K6,[K11]="A@13",[K2]=429,[K1]=K11,x=20,y=45,},[2]={f=K6,[K11]="B@13",[K2]=430,[K1]=K11,x=23,y=45,},[3]={f=K6,[K11]="C@13",[K2]=431,[K1]=K11,x=26,y=45,},},[K2]=438,[K1]=K22,x=4,y=46,},[K[97]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=448,[K1]=K5,[K5]="A@14",x=29,y=46,},[2]={f=K6,[K2]=449,[K1]=K5,[K5]="B@14",x=32,y=46,},},[K2]=450,[K1]=K4,x=34,y=46,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=451,[K1]=K5,[K5]="C@14",x=36,y=46,},},[K2]=452,[K1]=K4,x=34,y=46,},[K2]=453,[K1]=K9,x=11,y=46,},[K21]={[1]={f=K6,[K11]="A@14",[K2]=445,[K1]=K11,x=20,y=46,},[2]={f=K6,[K11]="B@14",[K2]=446,[K1]=K11,x=23,y=46,},[3]={f=K6,[K11]="C@14",[K2]=447,[K1]=K11,x=26,y=46,},},[K2]=454,[K1]=K22,x=4,y=47,},[K[98]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=288,[K1]=K5,[K5]="A@4",x=29,y=36,},[2]={f=K6,[K2]=289,[K1]=K5,[K5]="B@4",x=32,y=36,},},[K2]=290,[K1]=K4,x=34,y=36,},f=K6,[K8]=false,[K7]=2,rets={f=K6,[K4]={[1]={f=K6,[K2]=291,[K1]=K5,[K5]="C@4",x=36,y=36,},},[K2]=292,[K1]=K4,x=34,y=36,},[K2]=293,[K1]=K9,x=11,y=36,},[K21]={[1]={f=K6,[K11]="A@4",[K2]=285,[K1]=K11,x=20,y=36,},[2]={f=K6,[K11]="B@4",[K2]=286,[K1]=K11,x=23,y=36,},[3]={f=K6,[K11]="C@4",[K2]=287,[K1]=K11,x=26,y=36,},},[K2]=294,[K1]=K22,x=4,y=37,},[K[99]]={args={f=K6,[K4]={[1]={f=K6,[K2]=246,[K1]=K5,[K5]="T",x=25,y=26,},},[K2]=34,[K1]=K4,x=27,y=26,},f=K6,[K8]=false,[K10]=false,[K7]=1,rets={f=K6,[K4]={[1]={f=K6,[K2]=37,[K1]=K12,x=29,y=26,},},[K2]=36,[K1]=K4,x=27,y=26,},[K2]=33,[K1]=K9,x=16,y=26,},[K[100]]={f=K6,[K30]=true,t={args={f=K6,[K4]={[1]={f=K6,[K2]=480,[K1]=K5,[K5]="T",x=23,y=50,},},[K2]=199,[K1]=K4,x=25,y=50,},f=K6,[K8]=false,[K7]=1,rets={f=K6,[K4]={[1]={f=K6,[K2]=483,[K1]=K5,[K5]="A@17",x=27,y=50,},},[K2]=484,[K1]=K4,x=25,y=50,},[K2]=485,[K1]=K9,x=11,y=50,},[K21]={[1]={f=K6,[K11]="A@17",[K2]=482,[K1]=K11,x=20,y=50,},},[K2]=486,[K1]=K22,x=4,y=51,},},[K37]={},[K2]=20,[K1]=K45,x=1,y=18,},[K21]={[1]={f=K6,[K11]="T",[K2]=19,[K1]=K11,x=25,y=18,},},[K2]=238,[K1]=K22,x=1,y=18,}
T18.def={[K32]="Mode",[K47]={k=true,kv=true,v=true,},f=K6,[K2]=23,[K1]="enum",[K44]={},x=4,y=19,}
T19.def={[K32]=K[102],f=K6,[K40]={},[K39]={},[K38]={},[K[16]]={},[K[1]]=true,["is_userdata"]=true,[K37]={},[K2]=15,[K1]=K[34],x=1,y=14,}
T20.def={args={f=K3,[K4]={},[K2]=2149,[K1]=K4,x=34,y=657,},f=K3,[K8]=false,[K10]=false,[K7]=0,rets={f=K3,[K4]={[1]={f=K3,[K2]=2151,[K1]=K15,[K13]={[1]={f=K3,[K2]=2152,[K1]=K12,x=36,y=657,},[2]={f=K3,[K2]=2153,[K1]="nil",x=45,y=657,},},x=36,y=657,},},[K2]=2150,[K1]=K4,x=34,y=657,},[K2]=2148,[K1]=K9,x=24,y=657,}
T21.def={[K32]=K[104],[K47]={b=true,bt=true,t=true,},f=K3,[K2]=2157,[K1]="enum",[K44]={},x=4,y=659,}
T22.def={f=K3,[K2]=1295,[K1]=K15,[K13]={[1]={f=K3,[K2]=1296,[K1]=K16,x=19,y=324,},[2]={f=K3,[K2]=1297,[K1]=K14,x=28,y=324,},},x=19,y=324,}
T23[K20]=T22
T23[K19]={[1]=K[105],}
T24.def={[K32]=K[119],[K47]={["!*t"]=true,["*t"]=true,},f=K3,[K2]=1548,[K1]="enum",[K44]={},x=4,y=439,}
T25.def={[K32]=K[120],f=K3,[K40]={day={},hour={},[K[129]]={},min={},[K[130]]={},sec={},wday={},yday={},year={},},[K46]={day={f=K3,x=7,y=430,},hour={f=K3,x=7,y=431,},[K[129]]={f=K3,x=7,y=436,},min={f=K3,x=7,y=432,},[K[130]]={f=K3,x=7,y=429,},sec={f=K3,x=7,y=433,},wday={f=K3,x=7,y=434,},yday={f=K3,x=7,y=435,},year={f=K3,x=7,y=428,},},[K39]={[1]="year",[2]=K[130],[3]="day",[4]="hour",[5]="min",[6]="sec",[7]="wday",[8]="yday",[9]=K[129],},[K38]={day={f=K3,[K2]=1538,[K1]=K14,x=12,y=430,},hour={f=K3,[K2]=1539,[K1]=K14,x=13,y=431,},[K[129]]={f=K3,[K2]=1544,[K1]=K29,x=14,y=436,},min={f=K3,[K2]=1540,[K1]=K14,x=12,y=432,},[K[130]]={f=K3,[K2]=1537,[K1]=K14,x=14,y=429,},sec={f=K3,[K2]=1541,[K1]=K14,x=12,y=433,},wday={f=K3,[K2]=1542,[K1]=K14,x=13,y=434,},yday={f=K3,[K2]=1543,[K1]=K14,x=13,y=435,},year={f=K3,[K2]=1536,[K1]=K14,x=13,y=428,},},[K37]={},[K2]=1535,[K1]=K45,x=4,y=427,}
T26.def={f=K3,t={[K32]=K[154],[K35]=T27,f=K3,[K40]={n={},},[K46]={n={f=K3,x=7,y=576,},},[K39]={[1]="n",},[K38]={n={f=K3,[K2]=1922,[K1]=K14,x=10,y=576,},},[K[16]]={[1]={[K35]=T27,f=K3,[K2]=1920,[K1]=K36,x=10,xend=12,y=574,yend=574,},},[K[1]]=true,[K37]={},[K2]=1919,[K1]=K45,x=4,y=573,},[K21]={[1]={f=K3,[K11]="A",[K2]=1918,[K1]=K11,x=21,y=573,},},[K2]=1923,[K1]=K22,x=4,y=573,}
T28.def={f=K3,t={args={f=K3,[K4]={[1]={f=K3,[K2]=2670,[K1]=K5,[K5]="A",x=36,y=571,},[2]={f=K3,[K2]=2671,[K1]=K5,[K5]="A",x=39,y=571,},},[K2]=1909,[K1]=K4,x=41,y=571,},f=K3,[K8]=false,[K10]=false,[K7]=2,rets={f=K3,[K4]={[1]={f=K3,[K2]=1913,[K1]=K29,x=43,y=571,},},[K2]=1912,[K1]=K4,x=41,y=571,},[K2]=1908,[K1]=K9,x=24,y=571,},[K21]={[1]={f=K3,[K11]="A",[K2]=1907,[K1]=K11,x=33,y=571,},},[K2]=1914,[K1]=K22,x=4,y=573,}

return { globals = T0, typeid_ctr = 3160, typevar_ctr = 53}


end

-- module teal.reader from teal/reader.lua
package.preload["teal.reader"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local type = type
local errors = require("teal.errors")


local lexer = require("teal.lexer")




local block = require("teal.block")



local macro_eval = require("teal.macro_eval")





















local reader = {}










local BLOCK_INDEXES = block.BLOCK_INDEXES

reader.BLOCK_INDEXES = BLOCK_INDEXES











local module_macro_cache = {}
local module_macro_missing = {}
local module_macro_loading = {}
local read_program_depth = 0

local function lang_heuristic(filename, input)
   if filename then
      local pattern = "(.*)%.([a-z]+)$"
      local _, extension = filename:match(pattern)
      extension = extension and extension:lower()

      if extension == "tl" then
         return "tl"
      elseif extension == "lua" then
         return "lua"
      end
   end
   if input then
      return (input:match("^#![^\n]*lua[^\n]*\n")) and "lua" or "tl"
   end
   return "tl"
end

local function is_macro_quote_token(t)
   return t.kind == "`" or t.tk:sub(1, 1) == "`"
end

local attributes = {
   ["const"] = true,
   ["close"] = true,
   ["total"] = true,
}
local is_attribute = attributes

function reader.node_is_require_call(n)
   if not (n[BLOCK_INDEXES.OP.E1] and n[BLOCK_INDEXES.OP.E2]) then
      return nil
   end
   if n.kind == "op_dot" then

      return reader.node_is_require_call(n[BLOCK_INDEXES.OP.E1])
   elseif n[BLOCK_INDEXES.OP.E1].kind == "identifier" and n[BLOCK_INDEXES.OP.E1].tk == "require" and
      n[BLOCK_INDEXES.OP.E2].kind == "expression_list" and #n[BLOCK_INDEXES.OP.E2] == 1 and
      n[BLOCK_INDEXES.OP.E2][1].kind == "string" then


      return block.string_value(n[BLOCK_INDEXES.OP.E2][1])
   end
   return nil
end

function reader.node_is_funcall(node)
   if node.kind == "paren" and node[BLOCK_INDEXES.PAREN.EXP] then
      return reader.node_is_funcall(node[BLOCK_INDEXES.PAREN.EXP])
   end
   return node.kind == "op_funcall" or node.kind == "macro_invocation"
end

local function starts_with(str, prefix)
   return str:sub(1, #prefix) == prefix
end

local function macro_target_key(node)
   if not node then
      return nil, false
   end
   if node.kind == "paren" then
      return macro_target_key(node[BLOCK_INDEXES.PAREN.EXP])
   end
   if node.kind == "identifier" then
      return node.tk, false
   end
   if node.kind == "op_dot" then
      local lhs, has_colon = macro_target_key(node[BLOCK_INDEXES.OP.E1])
      local rhs = node[BLOCK_INDEXES.OP.E2]
      if lhs and rhs and rhs.kind == "identifier" then
         return lhs .. "." .. rhs.tk, has_colon
      end
      return nil, has_colon
   end
   if node.kind == "op_colon" then
      return nil, true
   end
   return nil, false
end

local function path_block_to_string(node)
   if not node then
      return nil
   end
   if node.kind == "identifier" then
      return node.tk
   elseif node.kind == "op_dot" then
      local lhs = path_block_to_string(node[BLOCK_INDEXES.OP.E1])
      local rhs = node[BLOCK_INDEXES.OP.E2]
      if lhs and rhs and rhs.kind == "identifier" then
         return lhs .. "." .. rhs.tk
      end
   end
   return nil
end


























local read_type_list
local read_typeargs_if_any
local read_expression
local read_prefix_expression
local read_short_function
local read_argument
local read_expression_and_tk
local read_statements
local read_argument_list
local read_argument_type_list
local read_macro_quote
local read_type
local read_type_declaration
local read_interface_name
local read_statement_fns
local needs_local_or_global
local read_nested_type
local read_call_or_assignment
local read_record_function

local function read_nested_expression(ps, i)
   local middle = ps.ternary_middle
   ps.ternary_middle = false
   local next_i, expression, n = read_expression(ps, i)
   ps.ternary_middle = middle
   return next_i, expression, n
end


local read_enum_body
local read_record_body
local read_type_body_fns
local type_body_kinds = {
   ["interface"] = "interface",
   ["record"] = "record",
   ["enum"] = "enum",
}

local function fail(ps, i, msg)
   if not ps.tokens[i] then
      local eof = ps.tokens[#ps.tokens]
      table.insert(ps.errs, { filename = ps.filename, y = eof.y, x = eof.x, msg = msg or "unexpected end of file" })
      return #ps.tokens
   end
   table.insert(ps.errs, { filename = ps.filename, y = ps.tokens[i].y, x = ps.tokens[i].x, msg = assert(msg, "syntax error, but no error message provided") })
   return math.min(#ps.tokens, i + 1)
end

local function end_at(node, tk)
   node.yend = tk.y
   node.xend = tk.x + #tk.tk - 1
end

local function verify_tk(ps, i, tk)
   if ps.tokens[i].tk == tk then
      return i + 1
   end
   return fail(ps, i, "syntax error, expected '" .. tk .. "'")
end

local function verify_end(ps, i, istart, node)
   if ps.tokens[i].tk == "end" then
      local endy, endx = ps.tokens[i].y, ps.tokens[i].x
      node.yend = endy
      node.xend = endx + 2
      if node.kind ~= "function" and endy ~= node.y and endx ~= node.x then
         if not ps.end_alignment_hint then
            ps.end_alignment_hint = { filename = ps.filename, y = node.y, x = node.x, msg = "syntax error hint: construct starting here is not aligned with its 'end' at " .. ps.filename .. ":" .. endy .. ":" .. endx .. ":" }
         end
      end
      return i + 1
   end
   end_at(node, ps.tokens[i])
   if ps.end_alignment_hint then
      table.insert(ps.errs, ps.end_alignment_hint)
      ps.end_alignment_hint = nil
   end
   return fail(ps, i, "syntax error, expected 'end' to close construct started at " .. ps.filename .. ":" .. ps.tokens[istart].y .. ":" .. ps.tokens[istart].x .. ":")
end

local node_mt = {
   __tostring = function(n)
      return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
   end,
}

local function new_block(ps, i, kind)
   local token = ps.tokens[i]
   return setmetatable({
      f = ps.filename,
      y = token.y,
      x = token.x,
      tk = token.tk,
      kind = kind or (token.kind),
      yend = token.y,
      xend = token.x + #token.tk - 1,
   }, node_mt)
end

local function new_type(ps, i, typename)
   return new_block(ps, i, typename)
end

local function split_dotted_path(path)
   local out = {}
   local start = 1
   local operator_name = false
   for i = 1, #path do
      local ch = path:sub(i, i)
      if ch == "(" then operator_name = true
      elseif ch == ")" then operator_name = false
      elseif ch == "." and not operator_name then
         table.insert(out, path:sub(start, i - 1))
         start = i + 1
      end
   end
   table.insert(out, path:sub(start))
   return out
end

local function build_path_block_from_parts(f, y, x, parts)
   local function mk_ident(name)
      return setmetatable({
         f = f,
         y = y,
         x = x,
         tk = name,
         kind = "identifier",
      }, node_mt)
   end

   local owner = mk_ident(parts[1])
   for j = 2, #parts do
      local dot = setmetatable({
         f = f,
         y = y,
         x = x,
         tk = ".",
         kind = "op_dot",
      }, node_mt)
      dot[BLOCK_INDEXES.OP.E1] = owner
      dot[BLOCK_INDEXES.OP.E2] = mk_ident(parts[j])
      owner = dot
   end
   return owner
end

local function clone_block_deep(b)
   if not b then
      return nil
   end
   local copy = {
      kind = b.kind,
      f = b.f,
      y = b.y,
      x = b.x,
      tk = b.tk,
      yend = b.yend,
      xend = b.xend,
   }
   local child_indexes = {}
   for k, child in pairs(b) do
      if math.type(k) == "integer" and child then
         table.insert(child_indexes, k)
      end
   end
   table.sort(child_indexes)
   for _, idx in ipairs(child_indexes) do
      copy[idx] = clone_block_deep(b[idx])
   end
   return setmetatable(copy, node_mt)
end

local function make_comment_block(ps, c)
   local text = c.text
   local _, newlines = string.gsub(text, "\n", "")
   local last_line = text:match("([^\n]*)$") or ""
   local cb = {
      f = ps.filename,
      y = c.y,
      x = c.x,
      tk = text,
      kind = "comment",
      yend = c.y + newlines,
      xend = newlines > 0 and #last_line or (c.x + #text - 1),
   }
   return setmetatable(cb, node_mt)
end

local function collect_comment_blocks(ps, i)
   local t = ps.tokens[i]
   if not (t and t.comments) then
      return {}
   end
   local out = {}
   for _, c in ipairs(t.comments) do
      table.insert(out, make_comment_block(ps, c))
   end
   return out
end

local function new_generic(ps, i, typeargs, typ)
   local gt = new_type(ps, i, "generic_type")
   gt[BLOCK_INDEXES.GENERIC_TYPE.TYPEARGS] = typeargs
   gt[BLOCK_INDEXES.GENERIC_TYPE.BASE] = typ
   return gt
end

local function new_typedecl(ps, i, def)
   local t = new_type(ps, i, "typedecl")
   t[BLOCK_INDEXES.TYPEDECL.TYPE] = def
   return t
end

local function new_tuple(ps, i, typelist)
   local t = new_type(ps, i, "tuple_type")
   t[1] = typelist or new_block(ps, i, "type_list")
   return t, t[1]
end

local function new_nominal(ps, i, name)
   local t = new_type(ps, i, "nominal_type")
   if name then
      t[BLOCK_INDEXES.NOMINAL_TYPE.NAME] = new_block(ps, i, "identifier")
      t[BLOCK_INDEXES.NOMINAL_TYPE.NAME].tk = name
   end
   return t
end

local function verify_kind(ps, i, kind, node_kind)
   if ps.tokens[i].kind == kind then
      return i + 1, new_block(ps, i, node_kind)
   end
   return fail(ps, i, "syntax error, expected " .. kind)
end

local function build_macro_sig(args, errs, filename, macro_name)
   local sig = { kinds = {}, vararg = "" }
   if not args then
      return sig
   end

   local idx = 1
   for _, ab in ipairs(args) do
      local annot = ab and ab[BLOCK_INDEXES.ARGUMENT.TYPE]
      local ok = false
      local mode
      if annot and annot.kind == "nominal_type" and
         annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME] and
         annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME].kind == "identifier" then

         local tname = annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME].tk
         if tname == "Statement" then
            ok = true
            mode = "stmt"
         elseif tname == "Expression" then
            ok = true
            mode = "expr"
         end
      end
      if not ok then
         table.insert(errs, {
            filename = filename,
            y = (annot and annot.y) or ab.y,
            x = (annot and annot.x) or ab.x,
            msg = "macro '" .. macro_name .. "' argument type must be 'Statement' or 'Expression'",
         })
      else
         if ab.tk == "..." then
            sig.vararg = mode or "expr"
         else
            sig.kinds[idx] = mode or "expr"
            idx = idx + 1
         end
      end
   end

   return sig
end

local operator_precedences = {
   conditional = 0, logical_or = 1, disjunction = 1, logical_and = 2, conjunction = 2,
   comparison = 3, relational = 3, bitwise_or = 4, bitwise_xor = 5, bitwise_and = 6,
   shift = 7, concatenation = 8, concatenative = 8, additive = 9,
   multiplicative = 10, unary = 11, exponentiation = 12, power = 12,
   postfix = 100, primary = 100,
}

local reserved_operator_tokens = {
   ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
   ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true,
   ["goto"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true,
   ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true,
   ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true,
   ["as"] = true, ["is"] = true,
   ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true,
   ["%"] = true, ["^"] = true, ["#"] = true, ["&"] = true, ["|"] = true,
   ["~"] = true, ["<<"] = true, [">>"] = true, ["~>>"] = true,
   ["=="] = true, ["~="] = true, ["!="] = true, ["<"] = true, [">"] = true,
   ["<="] = true, [">="] = true, ["!"] = true, ["&&"] = true, ["||"] = true,
   ["?"] = true, ["??"] = true, ["?."] = true, ["="] = true, ["->"] = true,
   ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true,
   ["&="] = true, ["|="] = true, ["<<="] = true, [">>="] = true, ["~>>="] = true,
   ["..="] = true, ["."] = true, [".."] = true, ["..."] = true, [":"] = true, ["::"] = true,
}

local function operator_error(ps, where, message)
   table.insert(ps.errs, { filename = ps.filename, y = where.y, x = where.x, msg = message })
end

local function macro_operator_symbol(name)
   if name and name.kind == "identifier" and name.tk:sub(1, 1) == "(" and name.tk:sub(-1) == ")" then
      return name.tk:sub(2, -2)
   end
end

local function valid_operator_symbol(symbol)
   local identifier = symbol:match("^[%a_][%w_]*$")
   return symbol ~= "" and not reserved_operator_tokens[symbol] and not symbol:find("--", 1, true) and
   (identifier ~= nil or symbol:find("[%w_%s%(%){%}%[%],;'\"`$]") == nil)
end

local function read_macro_name(ps, i)
   if ps.tokens[i].kind == "identifier" then return i + 1, new_block(ps, i, "identifier") end
   local name = new_block(ps, i, "error_block")
   if ps.tokens[i].tk ~= "(" then return fail(ps, i, "expected a macro name or parenthesized operator"), name end
   local opening = i
   i = i + 1
   local parts = {}
   local previous
   while ps.tokens[i].tk ~= ")" and ps.tokens[i].kind ~= "$EOF$" do
      local token = ps.tokens[i]
      if token.tk == "(" then
         return fail(ps, i, "operator macro names cannot contain '(' or ')'"), name
      end
      if previous and (token.y ~= previous.y or token.x ~= previous.x + #previous.tk) then
         return fail(ps, i, "operator name must be a non-reserved identifier or unused symbols without whitespace"), name
      end
      table.insert(parts, token.tk)
      previous = token
      i = i + 1
   end
   if ps.tokens[i].tk ~= ")" then return fail(ps, i, "expected ')' after operator macro name"), name end
   local symbol = table.concat(parts)
   if not valid_operator_symbol(symbol) then
      return fail(ps, opening, "operator name must be a non-reserved identifier or unused symbols"), name
   end
   name.kind = "identifier"
   name.tk = "(" .. symbol .. ")"
   end_at(name, ps.tokens[i])
   return i + 1, name
end

local function operator_macro_call_at(ps, i)
   if ps.tokens[i].tk ~= "(" then return false end
   local j = i + 1
   local parts = {}
   local previous
   while ps.tokens[j].tk ~= ")" and ps.tokens[j].kind ~= "$EOF$" do
      local token = ps.tokens[j]
      if token.tk == "(" or (previous and (token.y ~= previous.y or token.x ~= previous.x + #previous.tk)) then return false end
      table.insert(parts, token.tk)
      previous = token
      j = j + 1
   end
   local symbol = table.concat(parts)
   if ps.tokens[j].tk ~= ")" or not ps.tokens[j + 1] or ps.tokens[j + 1].tk ~= "!" or not valid_operator_symbol(symbol) then return false end

   return ps.macro_sigs["(" .. symbol .. ")"] ~= nil or not symbol:match("^[%a_][%w_]*$")
end

local function register_operator(ps, spec, where)
   local registry = ps.custom_operators[spec.fixity]
   local previous = registry[spec.symbol]
   if previous and previous.binding == spec.binding then return end
   local key = spec.fixity .. ":" .. spec.symbol
   if ps.local_operators[key] then
      operator_error(ps, where, "duplicate " .. spec.fixity .. " operator '" .. spec.symbol .. "' in this scope")
      return
   end
   local ambiguous = spec.fixity == "infix" and ps.custom_operators.postfix[spec.symbol] or
   (spec.fixity == "postfix" and ps.custom_operators.infix[spec.symbol])
   if ambiguous then
      operator_error(ps, where, "infix and postfix operators cannot share the symbol '" .. spec.symbol .. "'")
      return
   end
   ps.local_operators[key] = true
   registry[spec.symbol] = spec
end

local function operator_word(b)
   if b and b.kind == "nominal_type" and b[1] and not b[2] then return b[1].tk end
   return nil
end

local function read_operator_annotation(ps, node, key)
   local rets = node[BLOCK_INDEXES.LOCAL_MACRO.RETS]
   local list = rets and rets[1]
   local annotation = list and list[1]
   local symbol = macro_operator_symbol(node[BLOCK_INDEXES.LOCAL_MACRO.NAME])
   if not annotation or annotation.kind ~= "nominal_type" or not annotation[1] or annotation[1].tk ~= "Operator" then
      if symbol then operator_error(ps, node, "operator macro requires Operator<prefix|infix|postfix, precedence[, left|right]>") end
      return nil
   end
   if not symbol then
      operator_error(ps, annotation, "declare the operator in the macro name: local macro (symbol)!(...): Operator<fixity, precedence>")
      return nil
   end
   local args = annotation[2]
   if #list ~= 1 or not args or (#args ~= 2 and #args ~= 3) then
      operator_error(ps, annotation, "expected Operator<prefix|infix|postfix, precedence[, left|right]>")
      return nil
   end
   local fixity = operator_word(args[1])
   if fixity ~= "prefix" and fixity ~= "infix" and fixity ~= "postfix" then
      operator_error(ps, args[1], "operator fixity must be prefix, infix, or postfix")
      return nil
   end
   local group = operator_word(args[2])
   local precedence = group and operator_precedences[group]
   if not precedence then
      operator_error(ps, args[2], "unknown operator precedence group '" .. (group or args[2].tk) .. "'")
      return nil
   end
   local associativity = args[3] and operator_word(args[3]) or "left"
   if associativity ~= "left" and associativity ~= "right" then
      operator_error(ps, args[3], "operator associativity must be left or right")
      return nil
   end
   if args[3] and fixity ~= "infix" then
      operator_error(ps, args[3], "only infix operators accept associativity")
      return nil
   end
   local params = node[BLOCK_INDEXES.LOCAL_MACRO.ARGS]
   local wanted = fixity == "infix" and 2 or 1
   local valid = params and #params == wanted
   if params then
      for _, argument in ipairs(params) do
         local typ = argument[BLOCK_INDEXES.ARGUMENT.TYPE]
         if argument.tk == "..." or operator_word(typ) ~= "Expression" then valid = false end
         for _, child in ipairs(argument) do
            if child.kind == "question" then valid = false end
         end
      end
   end
   if not valid then
      operator_error(ps, annotation, "a " .. fixity .. " operator requires exactly " .. tostring(wanted) .. " Expression parameter(s)")
      return nil
   end
   return {
      symbol = symbol, fixity = fixity, precedence = precedence,
      right_associative = associativity == "right",
      binding = "@operator:" .. ps.filename .. ":" .. tostring(node.y) .. ":" .. tostring(node.x) .. ":" .. key,
   }
end

local function operator_spec_block(owner, spec)
   local function leaf(kind, text)
      return { kind = kind, tk = text, f = owner.f, y = owner.y, x = owner.x }
   end
   local node = leaf("operator_spec", spec.symbol)
   local slots = BLOCK_INDEXES.OPERATOR_SPEC
   node[slots.BINDING] = leaf("identifier", spec.binding)
   node[slots.FIXITY] = leaf("identifier", spec.fixity)
   node[slots.PRECEDENCE] = leaf("integer", tostring(spec.precedence))
   node[slots.ASSOCIATIVITY] = leaf("identifier", spec.right_associative and "right" or "left")
   return node
end

local function operator_spec_from_block(node)
   if not node then return nil end
   local slots = BLOCK_INDEXES.OPERATOR_SPEC
   return {
      symbol = node.tk,
      binding = node[slots.BINDING].tk,
      fixity = node[slots.FIXITY].tk,
      precedence = tonumber(node[slots.PRECEDENCE].tk),
      right_associative = node[slots.ASSOCIATIVITY].tk == "right",
   }
end

local function find_operator(ps, at, fixity)
   local best
   local width = 0
   for symbol, spec in pairs(ps.custom_operators[fixity]) do
      local text = ""
      local previous
      for j = at, #ps.tokens do
         local token = ps.tokens[j]
         if previous and (token.y ~= previous.y or token.x ~= previous.x + #previous.tk) then break end
         text = text .. token.tk
         if text == symbol then
            if not best or #symbol > #best.symbol then best = spec; width = j - at + 1 end
            break
         end
         if #text >= #symbol or symbol:sub(1, #text) ~= text then break end
         previous = token
      end
   end
   return best, width
end

local function forbidden_macro_invocation(ps, y, x)
   if ps.in_local_macro or ps.in_macro_quote then
      table.insert(ps.errs, {
         filename = ps.filename, y = y, x = x,
         msg = "macro invocations cannot appear inside " .. (ps.in_macro_quote and "macro quotes" or "macro bodies"),
      })
      return true
   end
   return false
end

local function operator_invocation(ps, token, spec, lhs, rhs)
   if forbidden_macro_invocation(ps, token.y, token.x) then
      return { kind = "error_block", f = ps.filename, y = token.y, x = token.x, tk = token.tk }
   end
   local target = { kind = "identifier", tk = spec.binding, f = ps.filename, y = token.y, x = token.x }
   local args = { kind = "expression_list", tk = spec.symbol, f = ps.filename, y = token.y, x = token.x, lhs, rhs }
   return { kind = "macro_invocation", tk = spec.symbol, f = ps.filename, y = token.y, x = token.x,
   [BLOCK_INDEXES.MACRO_INVOCATION.MACRO] = target,
   [BLOCK_INDEXES.MACRO_INVOCATION.ARGS] = args,
   [BLOCK_INDEXES.MACRO_INVOCATION.OPERATOR] = { kind = "operator_use", tk = spec.symbol, f = ps.filename, y = token.y, x = token.x },
   }
end

local function extract_macro_owner_from_newtype(nt)
   if not nt or nt.kind ~= "newtype" then
      return nil
   end
   local typedecl = nt[BLOCK_INDEXES.NEWTYPE.TYPEDECL]
   if not typedecl or typedecl.kind ~= "typedecl" then
      return nil
   end
   local typ = typedecl[BLOCK_INDEXES.TYPEDECL.TYPE]
   if typ and typ.kind == "generic_type" then
      typ = typ[BLOCK_INDEXES.GENERIC_TYPE.BASE]
   end
   if typ and ((typ.kind) == "record" or (typ.kind) == "interface") then
      return typ
   end
   return nil
end

local function collect_macro_owner_paths_in_scope(container, prefix, out)
   if not container then
      return
   end
   for _, child in ipairs(container) do
      if child and (child.kind == "local_type" or child.kind == "global_type") then
         local var
         local val
         if child.kind == "local_type" then
            var = child[BLOCK_INDEXES.LOCAL_TYPE.VAR]
            val = child[BLOCK_INDEXES.LOCAL_TYPE.VALUE]
         else
            var = child[BLOCK_INDEXES.GLOBAL_TYPE.VAR]
            val = child[BLOCK_INDEXES.GLOBAL_TYPE.VALUE]
         end
         if var and (var.kind == "identifier" or var.kind == "type_identifier") and val then
            local owner = extract_macro_owner_from_newtype(val)
            if owner then
               local path = prefix == "" and var.tk or (prefix .. "." .. var.tk)
               out[path] = true
               collect_macro_owner_paths_in_scope(owner[BLOCK_INDEXES.RECORD.FIELDS], path, out)
            end
         end
      end
   end
end

local function collect_macro_owner_paths(node)
   local out = {}
   collect_macro_owner_paths_in_scope(node, "", out)
   return out
end

local function validate_attached_macro_owners(node, errs, filename)
   local owners = collect_macro_owner_paths(node)
   for _, child in ipairs(node) do
      if child and
         child.kind == "local_macro" and
         child[BLOCK_INDEXES.LOCAL_MACRO.OWNER] and
         not child[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS] then

         local owner_key = path_block_to_string(child[BLOCK_INDEXES.LOCAL_MACRO.OWNER])
         if owner_key and not owners[owner_key] then
            local owner = child[BLOCK_INDEXES.LOCAL_MACRO.OWNER]
            table.insert(errs, {
               filename = filename,
               y = owner.y,
               x = owner.x,
               msg = "macro owner '" .. owner_key .. "' must be a record or interface",
            })
         end
      end
   end
end



local function skip(ps, i, skip_fn)
   local err_ps = {
      filename = ps.filename,
      tokens = ps.tokens,
      errs = {},
      read_lang = ps.read_lang,
      allow_macro_vars = ps.allow_macro_vars,
      in_local_macro = ps.in_local_macro,
      in_macro_quote = ps.in_macro_quote,
      custom_operators = ps.custom_operators,
      local_operators = ps.local_operators,
      macro_sigs = ps.macro_sigs,
      require_aliases = ps.require_aliases,
      imported_macro_decls = ps.imported_macro_decls,
      imported_macro_keys = ps.imported_macro_keys,
      macro_aliases = ps.macro_aliases,
   }
   return skip_fn(err_ps, i)
end

local function failskip(ps, i, msg, skip_fn, starti)
   local skip_i = skip(ps, starti or i, skip_fn)
   fail(ps, i, msg)
   return skip_i
end

local function search_tl_module(module_name)
   local path = os.getenv("TL_PATH") or package.path
   local slash_name = module_name:gsub("%.", "/")
   for _, suffix in ipairs({ ".tl", ".d.tl" }) do
      for entry in path:gmatch("[^;]+") do
         if not entry:match("%?[/\\]init%.lua$") then
            local filename = entry:gsub("?", slash_name)
            local tl_filename = filename:gsub("%.lua$", suffix)
            local fd = io.open(tl_filename, "rb")
            if not fd then
               tl_filename = filename:gsub("%.lua$", "/init" .. suffix)
               fd = io.open(tl_filename, "rb")
            end
            if fd then
               local code = fd:read("*a")
               fd:close()
               if code then
                  return tl_filename, code
               end
            end
         end
      end
   end
   return nil
end

local function top_level_return_path(node)
   local out
   for _, stmt in ipairs(node) do
      if stmt and stmt.kind == "return" then
         local exps = stmt[BLOCK_INDEXES.RETURN.EXPS]
         if exps and exps[1] then
            local path = path_block_to_string(exps[1])
            if path then
               out = path
            end
         end
      end
   end
   return out
end

local function collect_module_macro_exports(node, errs, filename)
   local exports = {}
   local owners = collect_macro_owner_paths(node)
   local return_path = top_level_return_path(node)

   for _, stmt in ipairs(node) do
      if stmt and
         stmt.kind == "local_macro" and
         stmt[BLOCK_INDEXES.LOCAL_MACRO.OWNER] and
         not stmt[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS] then

         local owner = stmt[BLOCK_INDEXES.LOCAL_MACRO.OWNER]
         local owner_key = path_block_to_string(owner)
         local name = stmt[BLOCK_INDEXES.LOCAL_MACRO.NAME]
         if owner_key and name and name.kind == "identifier" then
            if not owners[owner_key] then
               table.insert(errs, {
                  filename = filename,
                  y = owner.y,
                  x = owner.x,
                  msg = "macro owner '" .. owner_key .. "' must be a record or interface",
               })
            elseif return_path and (owner_key == return_path or starts_with(owner_key, return_path .. ".")) then
               local suffix_owner = owner_key == return_path and "" or owner_key:sub(#return_path + 2)
               local exported_key = suffix_owner == "" and name.tk or (suffix_owner .. "." .. name.tk)
               local sig = build_macro_sig(stmt[BLOCK_INDEXES.LOCAL_MACRO.ARGS], errs, filename, exported_key)
               sig.operator = operator_spec_from_block(stmt[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR])
               table.insert(exports, {
                  key = exported_key,
                  sig = sig,
                  decl = stmt,
               })
            end
         end
      end
   end

   return exports
end

local function load_module_macro_info(ps, module_name)
   if module_macro_missing[module_name] then
      return nil
   end
   local cached = module_macro_cache[module_name]
   if cached ~= nil then
      return cached
   end

   if module_macro_loading[module_name] then
      return nil
   end
   module_macro_loading[module_name] = true

   local found, code = search_tl_module(module_name)
   if not found or not code then
      module_macro_missing[module_name] = true
      module_macro_loading[module_name] = nil
      return nil
   end

   local lang = lang_heuristic(found, code)
   local mod_node, mod_errs = reader.read(code, found, lang, true, true)
   for _, e in ipairs(mod_errs) do
      table.insert(ps.errs, e)
   end

   local info = {
      exports = collect_module_macro_exports(mod_node, ps.errs, found),
   }

   module_macro_cache[module_name] = info
   module_macro_loading[module_name] = nil
   return info
end

local function local_require_alias(stmt)
   if not stmt then
      return nil
   end

   local var
   local exp

   if stmt.kind == "local_declaration" then
      local vars = stmt[BLOCK_INDEXES.LOCAL_DECLARATION.VARS]
      local exps = stmt[BLOCK_INDEXES.LOCAL_DECLARATION.EXPS]
      if not vars or not exps or #vars ~= 1 or #exps ~= 1 then
         return nil
      end
      var = vars[1]
      exp = exps[1]
   elseif stmt.kind == "local_type" then
      var = stmt[BLOCK_INDEXES.LOCAL_TYPE.VAR]
      exp = stmt[BLOCK_INDEXES.LOCAL_TYPE.VALUE]
   else
      return nil
   end

   if not var or var.kind ~= "identifier" then
      return nil
   end

   local module_name = reader.node_is_require_call(exp)
   if not module_name then
      return nil
   end
   return var.tk, module_name
end

local function ensure_required_alias_macros(ps, alias)
   local module_name = ps.require_aliases[alias]
   if not module_name then
      return
   end
   local loaded_key = "@loaded:" .. alias
   if ps.imported_macro_keys[loaded_key] then
      return
   end
   ps.imported_macro_keys[loaded_key] = true

   local info = load_module_macro_info(ps, module_name)
   if not info then
      return
   end

   for _, exp in ipairs(info.exports) do
      local imported_key = alias .. "." .. exp.key
      if not ps.imported_macro_keys[imported_key] then
         ps.imported_macro_keys[imported_key] = true
         ps.macro_sigs[imported_key] = exp.sig
         if exp.sig.operator then ps.macro_sigs[exp.sig.operator.binding] = exp.sig end

         local imported_decl = clone_block_deep(exp.decl)
         local parts = split_dotted_path(imported_key)
         local macro_name = parts[#parts]
         parts[#parts] = nil

         imported_decl[BLOCK_INDEXES.LOCAL_MACRO.NAME] = setmetatable({
            f = imported_decl.f or ps.filename,
            y = imported_decl.y or 1,
            x = imported_decl.x or 1,
            tk = macro_name,
            kind = "identifier",
         }, node_mt)

         if #parts > 0 then
            imported_decl[BLOCK_INDEXES.LOCAL_MACRO.OWNER] = build_path_block_from_parts(imported_decl.f, imported_decl.y, imported_decl.x, parts)
         else
            imported_decl[BLOCK_INDEXES.LOCAL_MACRO.OWNER] = nil
         end

         imported_decl[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS] = setmetatable({
            f = imported_decl.f,
            y = imported_decl.y,
            x = imported_decl.x,
            tk = alias,
            kind = "identifier",
         }, node_mt)

         table.insert(ps.imported_macro_decls, imported_decl)
      end
   end
end

local function read_type_body(ps, i, istart, node, tn)
   local typeargs
   local def
   i, typeargs = read_typeargs_if_any(ps, i)

   def = new_type(ps, istart, tn)

   local ok
   i, ok = read_type_body_fns[tn](ps, i, def)
   if not ok then
      return fail(ps, i, "expected a type")
   end

   i = verify_end(ps, i, istart, node)

   if typeargs then
      return i, new_generic(ps, istart, typeargs, def)
   end

   return i, def
end

local function skip_type_body(ps, i)
   local tn = assert(type_body_kinds[ps.tokens[i].tk], ps.tokens[i].tk .. " has no parse body function")
   i = i + 1
   local ii, tt = read_type_body(ps, i, i - 1, {}, tn)
   return ii, not not tt
end

local function read_table_value(ps, i)
   local next_word = ps.tokens[i].tk
   if next_word == "record" or next_word == "interface" then
      local skip_i, e = skip(ps, i, skip_type_body)
      if e then
         fail(ps, i, next_word == "record" and
         "syntax error: this syntax is no longer valid; declare nested record inside a record" or
         "syntax error: cannot declare interface inside a table; use a statement")
         return skip_i, new_block(ps, i, "error_block")
      end
   elseif next_word == "enum" and ps.tokens[i + 1].kind == "string" then
      i = failskip(ps, i, "syntax error: this syntax is no longer valid; declare nested enum inside a record", skip_type_body)
      return i, new_block(ps, i - 1, "error_block")
   end

   local e
   i, e = read_nested_expression(ps, i)
   if not e then
      e = new_block(ps, i - 1, "error_block")
   end
   return i, e
end

local function read_table_item(ps, i, n)
   local node = new_block(ps, i, "literal_table_item")
   if ps.tokens[i].kind == "$EOF$" then
      return fail(ps, i, "unexpected eof")
   end

   if ps.tokens[i].tk == "[" then
      i = i + 1
      i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = read_expression_and_tk(ps, i, "]")
      i = verify_tk(ps, i, "=")
      i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_table_value(ps, i)
      return i, node, n
   elseif ps.tokens[i].kind == "identifier" then
      if ps.tokens[i + 1].tk == "=" then
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = verify_kind(ps, i, "identifier", "string")
         node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk = '"' .. node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk .. '"'
         i = verify_tk(ps, i, "=")
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_table_value(ps, i)
         return i, node, n
      elseif ps.tokens[i + 1].tk == ":" then
         local orig_i = i
         local try_ps = {
            filename = ps.filename,
            tokens = ps.tokens,
            errs = {},
            read_lang = ps.read_lang,
            allow_macro_vars = ps.allow_macro_vars,
            in_local_macro = ps.in_local_macro,
            in_macro_quote = ps.in_macro_quote,
            custom_operators = ps.custom_operators,
            local_operators = ps.local_operators,
            macro_sigs = ps.macro_sigs,
            require_aliases = ps.require_aliases,
            imported_macro_decls = ps.imported_macro_decls,
            imported_macro_keys = ps.imported_macro_keys,
            macro_aliases = ps.macro_aliases,
         }
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = verify_kind(try_ps, i, "identifier", "string")
         node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk = '"' .. node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk .. '"'
         i = verify_tk(try_ps, i, ":")
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_type(try_ps, i)
         if node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] and ps.tokens[i].tk == "=" then
            i = verify_tk(try_ps, i, "=")
            i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.TYPED_VALUE] = read_table_value(try_ps, i)
            if node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.TYPED_VALUE] then
               for _, e in ipairs(try_ps.errs) do
                  table.insert(ps.errs, e)
               end
               return i, node, n
            end
         end

         table.remove(node, BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE)
         i = orig_i
      end
   end

   node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = new_block(ps, i, "integer")
   node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk = tostring(n)
   node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.IMPLICIT_KEY] = new_block(ps, i, "implicit_table_key")
   i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_expression(ps, i)
   if not node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] then
      return fail(ps, i, "expected an expression")
   end
   return i, node, n + 1
end








local function read_list(ps, i, list, close, sep, read_item)
   local n = 1
   while ps.tokens[i].kind ~= "$EOF$" do
      if close[ps.tokens[i].tk] then
         end_at(list, ps.tokens[i])
         break
      end
      local item
      local oldn = n
      i, item, n = read_item(ps, i, n)
      n = n or oldn
      table.insert(list, item)
      if ps.tokens[i].tk == "," then
         i = i + 1
         if sep == "sep" and close[ps.tokens[i].tk] then
            fail(ps, i, "unexpected '" .. ps.tokens[i].tk .. "'")
            return i, list
         end
      elseif sep == "term" and ps.tokens[i].tk == ";" then
         i = i + 1
      elseif not close[ps.tokens[i].tk] then
         local options = {}
         for k, _ in pairs(close) do
            table.insert(options, "'" .. k .. "'")
         end
         table.sort(options)
         local first = options[1]:sub(2, -2)
         local msg

         if first == ")" and ps.tokens[i].tk == "=" then
            msg = "syntax error, cannot perform an assignment here (did you mean '=='?)"
            i = failskip(ps, i, msg, read_expression, i + 1)
         else
            table.insert(options, "','")
            msg = "syntax error, expected one of: " .. table.concat(options, ", ")
            fail(ps, i, msg)
         end



         if first ~= "}" and ps.tokens[i].y ~= ps.tokens[i - 1].y then

            table.insert(ps.tokens, i, { tk = first, y = ps.tokens[i - 1].y, x = ps.tokens[i - 1].x + 1, kind = "keyword" })
            return i, list
         end
      end
   end
   return i, list
end

local function read_bracket_list(ps, i, list, open, close, sep, read_item)
   i = verify_tk(ps, i, open)
   i = read_list(ps, i, list, { [close] = true }, sep, read_item)
   i = verify_tk(ps, i, close)
   return i, list
end

local function read_table_literal(ps, i)
   local node = new_block(ps, i, "literal_table")
   local middle = ps.ternary_middle
   ps.ternary_middle = false
   i, node = read_bracket_list(ps, i, node, "{", "}", "term", read_table_item)
   ps.ternary_middle = middle
   return i, node
end

local function read_macro_args_with_sig(ps, i, sig)
   local node = new_block(ps, i, "expression_list")
   local function read_item(ps2, ii, n)
      local expected
      if sig then
         expected = sig.kinds[n] or (sig.vararg ~= "" and sig.vararg or nil)
      end
      if expected == "stmt" then
         if is_macro_quote_token(ps2.tokens[ii]) then
            local ni, q = read_macro_quote(ps2, ii)
            return ni, q, n + 1
         else
            local tk0 = ps2.tokens[ii].tk
            local curr_i = ii
            local sblk
            while read_type_body_fns[tk0] and ps2.tokens[curr_i + 1] and ps2.tokens[curr_i + 1].kind == "identifier" do
               local ni
               local lt
               local tn = assert(type_body_kinds[tk0])
               ni, lt = read_nested_type(ps2, curr_i, tn)
               if not sblk then sblk = new_block(ps2, curr_i, "statements") end
               table.insert(sblk, lt)
               curr_i = ni
               tk0 = ps2.tokens[curr_i].tk
            end

            local j = sblk and curr_i or ii
            local paren_depth = 0
            local best_j
            local best_block
            local need_do_end_error = false
            local can_split_on_comma = false
            if sig then
               local fixed = #sig.kinds
               local has_vararg_stmt = sig.vararg == "stmt"
               if (n <= fixed - 1) or has_vararg_stmt then
                  can_split_on_comma = true
               end
            end

            local function try_parse_until(jend)
               local slice = {}
               local nt = 0
               for k = ii, jend - 1 do
                  nt = nt + 1
                  slice[nt] = ps2.tokens[k]
               end
               nt = nt + 1
               local eof_prev = ps2.tokens[math.max(ii, jend - 1)]
               slice[nt] = { x = eof_prev.x, y = eof_prev.y, tk = "$EOF$", kind = "$EOF$" }
               local errs2 = {}
               local block_ast = reader.read_program(slice, errs2, ps2.filename, ps2.read_lang, true, true)
               if #errs2 == 0 and block_ast then
                  if can_split_on_comma and
                     block_ast.kind == "statements" and
                     #block_ast == 1 then

                     local st = block_ast[1]
                     if st and st.kind == "local_declaration" then
                        local vlist = st[BLOCK_INDEXES.LOCAL_DECLARATION.VARS]
                        local decl = st[BLOCK_INDEXES.LOCAL_DECLARATION.DECL]
                        if vlist and decl then
                           local typelist = decl[1] or decl[2]
                           local ntypes = typelist and #typelist or 0
                           if ntypes > #vlist then
                              return false
                           end
                        end
                     end
                  end
                  best_j = jend
                  best_block = block_ast
                  return true
               end
               return false
            end

            while ps2.tokens[j].kind ~= "$EOF$" do
               local t = ps2.tokens[j].tk
               if t == "(" then
                  paren_depth = paren_depth + 1
               elseif t == ")" then
                  if paren_depth == 0 then
                     if try_parse_until(j) then
                        break
                     end
                     break
                  end
                  paren_depth = paren_depth - 1
               elseif t == "," and paren_depth == 0 then
                  if can_split_on_comma then
                     if try_parse_until(j) then
                        best_j = j
                     end
                  end
               end
               j = j + 1
            end

            if not best_block then

               local slice = {}
               local nt = 0
               for k = (sblk and curr_i or ii), j - 1 do
                  nt = nt + 1
                  slice[nt] = ps2.tokens[k]
               end
               nt = nt + 1
               local eof_prev = ps2.tokens[math.max(ii, j - 1)]
               slice[nt] = { x = eof_prev.x, y = eof_prev.y, tk = "$EOF$", kind = "$EOF$" }
               local errs2 = {}
               local block_fallback = reader.read_program(slice, errs2, ps2.filename, ps2.read_lang, true, true)
               for _, e in ipairs(errs2) do table.insert(ps2.errs, e) end
               best_block = block_fallback
               best_j = j
            end


            if best_block and best_block.kind == "statements" and #best_block == 1 then
               local st = best_block[1]
               if st and st.kind == "local_declaration" then
                  local BIDX = BLOCK_INDEXES
                  local vlist = st[BIDX.LOCAL_DECLARATION.VARS]
                  local exps = st[BIDX.LOCAL_DECLARATION.EXPS]
                  local has_top_level_comma = false
                  if vlist and #vlist > 1 then has_top_level_comma = true end
                  if exps and #exps > 1 then has_top_level_comma = true end
                  if has_top_level_comma then
                     need_do_end_error = true
                  end
               end
            end

            if need_do_end_error then
               local st = best_block and best_block[1]
               local basey = ps2.tokens[ii].y
               local ey = basey - 1
               if ey < 1 then ey = (st and st.y) or basey end
               table.insert(ps2.errs, { filename = ps2.filename, y = ey, x = 0, msg = "wrap the statement in 'do ... end'" })
            end

            if sblk and best_block and best_block.kind == "statements" then
               for idx = 1, #best_block do
                  table.insert(sblk, best_block[idx])
               end
               end_at(sblk, ps2.tokens[best_j])
               return best_j, sblk, n + 1
            else
               return best_j, best_block, n + 1
            end
         end
      else
         local ni, e = read_expression(ps2, ii)
         return ni, e, n + 1
      end
   end
   i, node = read_bracket_list(ps, i, node, "(", ")", "sep", read_item)
   return i, node
end

local function read_trying_list(ps, i, list, read_item, ret_lookahead)
   local try_ps = {
      filename = ps.filename,
      tokens = ps.tokens,
      errs = {},
      read_lang = ps.read_lang,
      allow_macro_vars = ps.allow_macro_vars,
      in_local_macro = ps.in_local_macro,
      in_macro_quote = ps.in_macro_quote,
      custom_operators = ps.custom_operators,
      local_operators = ps.local_operators,
      macro_sigs = ps.macro_sigs,
      require_aliases = ps.require_aliases,
      imported_macro_decls = ps.imported_macro_decls,
      imported_macro_keys = ps.imported_macro_keys,
      macro_aliases = ps.macro_aliases,
   }
   local tryi, item = read_item(try_ps, i)
   if not item then
      return i, list
   end
   for _, e in ipairs(try_ps.errs) do
      table.insert(ps.errs, e)
   end
   i = tryi
   table.insert(list, item)
   while ps.tokens[i].tk == "," and
      (not ret_lookahead or
      (not (ps.tokens[i + 1].kind == "identifier" and
      ps.tokens[i + 2] and ps.tokens[i + 2].tk == ":"))) do

      i = i + 1
      i, item = read_item(ps, i)
      table.insert(list, item)
   end
   return i, list
end

local function read_anglebracket_list(ps, i, read_item)
   local second = ps.tokens[i + 1]
   if second.tk == ">" then
      return fail(ps, i + 1, "type argument list cannot be empty")
   elseif second.tk == ">>" then

      second.tk = ">"
      fail(ps, i + 1, "type argument list cannot be empty")
      return i + 1
   end

   local typelist = new_type(ps, i, "type_list")
   i = verify_tk(ps, i, "<")
   i = read_list(ps, i, typelist, { [">"] = true, [">>"] = true }, "sep", read_item)
   if ps.tokens[i].tk == ">" then
      i = i + 1
   elseif ps.tokens[i].tk == ">>" then

      ps.tokens[i].tk = ">"
   else
      return fail(ps, i, "syntax error, expected '>'")
   end
   return i, typelist
end

local function read_typearg(ps, i)
   local name = ps.tokens[i].tk
   local constraint
   local t = new_type(ps, i, "typeargs")
   i = verify_kind(ps, i, "identifier")
   if ps.tokens[i].tk == "is" then
      i = i + 1
      i, constraint = read_interface_name(ps, i)
   end
   t[BLOCK_INDEXES.TYPEARG.NAME] = new_block(ps, i, "identifier")
   t[BLOCK_INDEXES.TYPEARG.NAME].tk = name
   t[BLOCK_INDEXES.TYPEARG.CONSTRAINT] = constraint
   return i, t
end

local function read_return_types(ps, i)
   local iprev = i - 1
   local t

   i, t = read_type_list(ps, i, "rets")
   local list = t[1]
   if list and #list == 0 then
      t.x = ps.tokens[iprev].x
      t.y = ps.tokens[iprev].y
   end
   return i, t
end

read_typeargs_if_any = function(ps, i)
   if ps.tokens[i].tk == "<" then
      return read_anglebracket_list(ps, i, read_typearg)
   end
   return i
end

local function read_function_type(ps, i)
   local typeargs
   local typ = new_type(ps, i, "function")
   i = i + 1

   i, typeargs = read_typeargs_if_any(ps, i)
   if ps.tokens[i].tk == "(" then
      i, typ[BLOCK_INDEXES.FUNCTION_TYPE.ARGS] = read_argument_type_list(ps, i)
      i, typ[BLOCK_INDEXES.FUNCTION_TYPE.RETS] = read_return_types(ps, i)
   else
      local any = new_type(ps, i, "nominal_type")
      any.tk = "any"
      local args_typelist = new_block(ps, i, "type_list")
      args_typelist[1] = any
      args_typelist[2] = new_block(ps, i, "...")
      typ[BLOCK_INDEXES.FUNCTION_TYPE.ARGS] = new_tuple(ps, i, args_typelist)

      local rets_typelist = new_block(ps, i, "type_list")
      rets_typelist[1] = any
      rets_typelist[2] = new_block(ps, i, "...")
      typ[BLOCK_INDEXES.FUNCTION_TYPE.RETS] = new_tuple(ps, i, rets_typelist)
   end

   if typeargs then
      return i, new_generic(ps, i, typeargs, typ)
   end

   return i, typ
end

local function read_simple_type_or_nominal(ps, i)
   local tk = ps.tokens[i].tk
   if tk == "table" and ps.tokens[i + 1].tk ~= "." then
      local typ = new_type(ps, i, "map_type")
      local any = new_type(ps, i, "nominal_type")
      any.tk = "any"
      typ[BLOCK_INDEXES.MAP_TYPE.KEYS] = any
      typ[BLOCK_INDEXES.MAP_TYPE.VALUES] = any
      return i + 1, typ
   end

   local typ
   if ps.allow_macro_vars and tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "syntax error, expected identifier")
      end
      typ = new_nominal(ps, i - 1, nil)
      local mv = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident, tk = "$" }
      typ[BLOCK_INDEXES.NOMINAL_TYPE.NAME] = mv
   else
      if ps.tokens[i].kind ~= "identifier" then
         return fail(ps, i, "syntax error, expected identifier")
      end
      typ = new_nominal(ps, i, tk)
      i = i + 1
   end

   while ps.tokens[i].tk == "." do
      i = i + 1
      if ps.tokens[i].kind == "identifier" then
         local nom = new_block(ps, i, "identifier")
         nom.tk = ps.tokens[i].tk
         table.insert(typ, nom)
         i = i + 1
      elseif ps.allow_macro_vars and ps.tokens[i].tk == "$" then
         local dtk = ps.tokens[i]
         i = i + 1
         local ident
         i, ident = verify_kind(ps, i, "identifier")
         if not ident then
            return fail(ps, i, "syntax error, expected identifier")
         end
         local nom = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident, tk = "$" }
         table.insert(typ, nom)
         i = i + 0
      else
         return fail(ps, i, "syntax error, expected identifier")
      end
   end

   if ps.tokens[i].tk == "<" then
      local t
      i, t = read_anglebracket_list(ps, i, read_type)
      table.insert(typ, t)
   end
   return i, typ
end

local function read_base_type(ps, i)
   local tk = ps.tokens[i].tk
   if ps.tokens[i].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i].tk == "$") then
      return read_simple_type_or_nominal(ps, i)
   elseif ps.tokens[i].kind == "string" then
      local node = new_block(ps, i, "string")
      return i + 1, node
   elseif ps.tokens[i].kind == "number" or ps.tokens[i].kind == "integer" then
      local node
      i, node = verify_kind(ps, i, ps.tokens[i].kind)
      return i, node
   elseif tk == "true" or tk == "false" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "{" then
      local istart = i
      i = i + 1
      local t
      i, t = read_type(ps, i)
      if not t then
         return i
      end
      if ps.tokens[i].tk == "}" then
         local decl = new_type(ps, istart, "array_type")
         decl[BLOCK_INDEXES.ARRAY_TYPE.ELEMENT] = t
         end_at(decl, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      elseif ps.tokens[i].tk == "," then
         local decl = new_type(ps, istart, "type_list")
         decl[1] = t
         local n = 2
         repeat
            i = i + 1
            i, decl[n] = read_type(ps, i)
            if not decl[n] then
               break
            end
            n = n + 1
         until ps.tokens[i].tk ~= ","
         end_at(decl, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      elseif ps.tokens[i].tk == ":" then
         local decl = new_type(ps, istart, "map_type")
         i = i + 1
         decl[BLOCK_INDEXES.MAP_TYPE.KEYS] = t
         i, decl[BLOCK_INDEXES.MAP_TYPE.VALUES] = read_type(ps, i)
         if not decl[BLOCK_INDEXES.MAP_TYPE.VALUES] then
            return i
         end
         end_at(decl, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      end
      return fail(ps, i, "syntax error; did you forget a '}'?")
   elseif tk == "function" then
      return read_function_type(ps, i)
   elseif tk == "nil" then
      return i + 1, new_type(ps, i, "nil")
   end
   return fail(ps, i, "expected a type")
end

read_type = function(ps, i)
   local bt
   local istart = i
   if ps.tokens[i].tk == "(" then
      i, bt = read_type(ps, i + 1)
      i = verify_tk(ps, i, ")")
   else
      i, bt = read_base_type(ps, i)
   end
   if not bt then
      return i
   end

   if ps.tokens[i].tk == "|" and ps.tokens[i + 1].tk ~= "->" and ps.tokens[i + 1].tk ~= ":" then
      local u = new_type(ps, istart, "union_type")
      u[1] = bt
      while ps.tokens[i].tk == "|" and ps.tokens[i + 1].tk ~= "->" and ps.tokens[i + 1].tk ~= ":" do
         i = i + 1
         i, bt = read_base_type(ps, i)
         if not bt then
            return i
         end
         table.insert(u, bt)
      end
      bt = u
   end
   return i, bt
end

read_type_list = function(ps, i, mode)
   local t, list = new_tuple(ps, i)

   local first_token = ps.tokens[i].tk
   if mode == "rets" or mode == "decltuple" then
      if first_token == ":" then
         i = i + 1
      else
         return i, t
      end
   end

   local optional_paren = false
   if ps.tokens[i].tk == "(" then

      local depth = 0
      local grouped_union = false
      for j = i, #ps.tokens do
         local tk = ps.tokens[j].tk
         if tk == "(" then depth = depth + 1 end
         if tk == ")" then
            depth = depth - 1
            if depth == 0 then
               grouped_union = mode ~= "rets" and ps.tokens[j + 1] and ps.tokens[j + 1].tk == "|"
               break
            end
         end
      end
      if not grouped_union then
         optional_paren = true
         i = i + 1
      end
   end

   local prev_i = i
   i = read_trying_list(ps, i, list, read_type, mode == "rets")
   if i == prev_i and ps.tokens[i].tk ~= ")" then
      fail(ps, i - 1, "expected a type list")
   end

   if mode == "rets" and ps.tokens[i].tk == "..." then
      i = i + 1
      local nrets = #list
      if nrets > 0 then
         table.insert(list, new_block(ps, i - 1, "..."))
      else
         fail(ps, i, "unexpected '...'")
      end
   end

   if optional_paren then
      i = verify_tk(ps, i, ")")
   end

   return i, t
end

local function read_function_args_rets_body(ps, i, node)
   local istart = i - 1
   i, node[BLOCK_INDEXES.FUNCTION.TYPEARGS] = read_typeargs_if_any(ps, i)

   i, node[BLOCK_INDEXES.FUNCTION.ARGS] = read_argument_list(ps, i)
   i, node[BLOCK_INDEXES.FUNCTION.RETS] = read_return_types(ps, i)

   local middle = ps.ternary_middle
   ps.ternary_middle = false
   i, node[BLOCK_INDEXES.FUNCTION.BODY] = read_statements(ps, i)
   ps.ternary_middle = middle
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_function_value(ps, i)
   local node = new_block(ps, i, "function")
   i = verify_tk(ps, i, "function")
   return read_function_args_rets_body(ps, i, node)
end

local function skip_any_function(ps, i)
   i = verify_tk(ps, i, "function")

   while ps.tokens[i] and (ps.tokens[i].kind == "identifier" or ps.tokens[i].tk == "." or ps.tokens[i].tk == ":") do
      i = i + 1
   end
   local dummy = new_block(ps, i, "function")
   return read_function_args_rets_body(ps, i, dummy)
end

read_macro_quote = function(ps, i)
   if not ps.in_local_macro then
      return fail(ps, i, "macro quotes can only be used inside macro statements")
   end
   local token = ps.tokens[i]
   local node = new_block(ps, i, "macro_quote")
   local tk = token.tk

   local triple = tk:sub(1, 3) == "```"
   local delim = triple and 3 or 1
   local code = tk:sub(delim + 1, -(delim + 1))
   if code:match("^%s*$") then
      return fail(ps, i, "macro quotes cannot be empty")
   end

   local quoted_block
   local errs

   if triple then









      local splices = {}
      local kept_lines = {}
      local line_index = 1
      for line in (code .. "\n"):gmatch("([^\n]*)\n") do
         local ident = line:match("^%s*%$([%a_][%w_]*)%s*;?%s*$")
         if ident then
            local y = token.y + (line_index - 1)
            local x = token.x + delim
            local ident_block = { f = ps.filename, y = y, x = x + 1, kind = "identifier", tk = ident }
            local mv = { f = ps.filename, y = y, x = x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident_block, tk = "$" }
            table.insert(splices, { idx = line_index, blk = mv })

         else
            table.insert(kept_lines, line)
         end
         line_index = line_index + 1
      end

      local kept_code = table.concat(kept_lines, "\n")
      local parsed_block
      parsed_block, errs = reader.read(kept_code, ps.filename, ps.read_lang, true, true, ps.custom_operators, true)


      if #splices > 0 and parsed_block and parsed_block.kind == "statements" then
         local combined = { f = ps.filename, y = token.y, x = token.x + delim, kind = "statements" }
         for _, s in ipairs(splices) do
            table.insert(combined, s.blk)
         end
         for _, stmt in ipairs(parsed_block) do
            table.insert(combined, stmt)
         end
         quoted_block = combined
      else
         quoted_block = parsed_block
      end
   else

      local wrapped, werrs = reader.read("return " .. code, ps.filename, ps.read_lang, true, true, ps.custom_operators, true)
      if #werrs == 0 then
         local ret = wrapped[1]
         if ret and ret.kind == "return" and ret[BLOCK_INDEXES.RETURN.EXPS] then
            local exp = ret[BLOCK_INDEXES.RETURN.EXPS][1]
            quoted_block = exp
         end
      end
      errs = werrs
   end


   if errs and #errs > 0 then
      local x0 = token.x + delim
      local y0 = token.y
      local ret_prefix = not triple and #("return ") or 0
      for _, e in ipairs(errs) do
         local ey = e.y or 1
         local ex = e.x or 1
         local ny = y0 + (ey - 1)
         local nx
         if ey == 1 then
            local ex_unwrapped = ex - ret_prefix
            if ex_unwrapped < 1 then ex_unwrapped = 1 end
            nx = x0 + (ex_unwrapped - 1)
         else
            nx = ex
         end
         local msg = (e.msg and ("macro quote error: " .. e.msg)) or "macro quote error"
         table.insert(ps.errs, { filename = ps.filename, y = ny, x = nx, msg = msg .. " (quote starts at " .. ps.filename .. ":" .. token.y .. ":" .. token.x .. ")" })
      end
   end

   node[BLOCK_INDEXES.MACRO_QUOTE.BLOCK] = quoted_block
   end_at(node, token)
   return i + 1, node
end

local function read_literal(ps, i)
   local tk = ps.tokens[i].tk
   local kind = ps.tokens[i].kind
   if (kind == "identifier" and ps.tokens[i + 1].tk == "->") or tk == "|" or tk == "||" then
      return read_short_function(ps, i)
   elseif kind == "identifier" then
      return verify_kind(ps, i, "identifier")
   elseif kind == "string" then
      local node = new_block(ps, i, "string")
      return i + 1, node
   elseif kind == "number" or kind == "integer" then
      local node
      i, node = verify_kind(ps, i, kind)
      return i, node
   elseif tk == "true" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "false" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "nil" then
      return verify_kind(ps, i, "keyword", "nil")
   elseif tk == "function" then
      return read_function_value(ps, i)
   elseif is_macro_quote_token(ps.tokens[i]) then
      if not ps.in_local_macro then
         return fail(ps, i, "macro quotes can only be used inside macro statements")
      end
      return read_macro_quote(ps, i)
   elseif tk == "{" then
      return read_table_literal(ps, i)
   elseif kind == "..." then
      return verify_kind(ps, i, "...")
   elseif kind == "$ERR$" then
      return fail(ps, i, "invalid token")
   end
   return fail(ps, i, "syntax error")
end

do
   local precedences = {
      [1] = {
         ["!"] = 11,
         ["not"] = 11,
         ["#"] = 11,
         ["-"] = 11,
         ["~"] = 11,
      },
      [2] = {
         ["||"] = 1,
         ["&&"] = 2,
         ["!="] = 3,
         ["??"] = 1,
         ["or"] = 1,
         ["and"] = 2,
         ["is"] = 3,
         ["<"] = 3,
         [">"] = 3,
         ["<="] = 3,
         [">="] = 3,
         ["~="] = 3,
         ["=="] = 3,
         ["|"] = 4,
         ["~"] = 5,
         ["&"] = 6,
         ["<<"] = 7,
         [">>"] = 7,
         ["~>>"] = 7,
         [".."] = 8,
         ["+"] = 9,
         ["-"] = 9,
         ["*"] = 10,
         ["/"] = 10,
         ["//"] = 10,
         ["%"] = 10,
         ["^"] = 12,
         ["as"] = 50,
         ["@funcall"] = 100,
         ["@index"] = 100,
         ["."] = 100,
         [":"] = 100,
      },
   }

   local is_right_assoc = {
      ["^"] = true,
      [".."] = true,
   }

   local op_map = {
      [1] = {
         ["!"] = "op_not",
         ["not"] = "op_not",
         ["#"] = "op_len",
         ["-"] = "op_unm",
         ["~"] = "op_bnot",
      },
      [2] = {
         ["??"] = "op_coalesce",
         ["||"] = "op_or",
         ["&&"] = "op_and",
         ["!="] = "op_ne",
         ["or"] = "op_or",
         ["and"] = "op_and",
         ["is"] = "op_is",
         ["<"] = "op_lt",
         [">"] = "op_gt",
         ["<="] = "op_le",
         [">="] = "op_ge",
         ["~="] = "op_ne",
         ["=="] = "op_eq",
         ["|"] = "op_bor",
         ["~"] = "op_bxor",
         ["&"] = "op_band",
         ["<<"] = "op_shl",
         [">>"] = "op_shr",
         ["~>>"] = "op_sar",
         [".."] = "op_concat",
         ["+"] = "op_add",
         ["-"] = "op_sub",
         ["*"] = "op_mul",
         ["/"] = "op_div",
         ["//"] = "op_idiv",
         ["%"] = "op_mod",
         ["^"] = "op_pow",
         ["as"] = "op_as",
         ["@funcall"] = "op_funcall",
         ["@index"] = "op_index",
         ["."] = "op_dot",
         [":"] = "op_colon",
      },
   }

   local args_starters = {
      ["("] = true,
      ["{"] = true,
      ["string"] = true,
   }

   local E

   local function after_valid_prefixexp(ps, prevnode, i)
      return prevnode.kind == "paren" or ps.tokens[i - 1].kind == ")" or
      prevnode.kind == "op_funcall" or
      prevnode.kind == "op_index" or
      prevnode.kind == "op_dot" or
      prevnode.kind == "op_colon" or
      prevnode.kind == "identifier" or
      prevnode.kind == "macro_invocation"
   end



   local function failstore(ps, tkop, e1)
      local paren = { f = ps.filename, y = tkop.y, x = tkop.x, kind = "paren", [BLOCK_INDEXES.PAREN.EXP] = e1 }
      return paren
   end

   local function P(ps, i)
      if ps.tokens[i].kind == "$EOF$" then
         return i
      end
      local e1
      local t1 = ps.tokens[i]
      local prefix, prefix_width = find_operator(ps, i, "prefix")
      if prefix then
         i = i + prefix_width
         local previous_errors = #ps.errs
         i, e1 = P(ps, i)
         if not e1 then
            if #ps.errs == previous_errors then
               return fail(ps, i, "expected an operand for operator '" .. prefix.symbol .. "'")
            end
            return i
         end
         i, e1 = E(ps, i, e1, prefix.precedence)
         e1 = operator_invocation(ps, t1, prefix, e1)
      elseif precedences[1][t1.tk] ~= nil then
         local op_kind = op_map[1][t1.tk]
         i = i + 1
         local prev_i = i
         i, e1 = P(ps, i)
         if not e1 then
            fail(ps, prev_i, "expected an expression")
            return i
         end
         i, e1 = E(ps, i, e1, precedences[1][t1.tk])
         e1 = { f = ps.filename, y = t1.y, x = t1.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, tk = t1.tk }
      elseif ps.allow_macro_vars and ps.tokens[i].tk == "$" then
         local dtk = ps.tokens[i]
         i = i + 1
         local ident
         i, ident = verify_kind(ps, i, "identifier")
         if not ident then
            return i
         end
         local macro_var = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
         e1 = macro_var
      elseif operator_macro_call_at(ps, i) then
         i, e1 = read_macro_name(ps, i)
      elseif ps.tokens[i].tk == "(" then
         i = i + 1
         local prev_i = i
         local middle = ps.ternary_middle
         ps.ternary_middle = false
         i, e1 = read_expression_and_tk(ps, i, ")")
         ps.ternary_middle = middle
         if not e1 then
            fail(ps, prev_i, "expected an expression")
            return i
         end
         local paren = { f = ps.filename, y = t1.y, x = t1.x, kind = "paren", [BLOCK_INDEXES.PAREN.EXP] = e1 }
         e1 = paren
      else
         i, e1 = read_literal(ps, i)
      end

      if not e1 then
         return i
      end

      while true do
         local infix = find_operator(ps, i, "infix")
         local postfix, postfix_width = find_operator(ps, i, "postfix")
         if postfix and postfix.precedence >= 100 and not infix then
            e1 = operator_invocation(ps, ps.tokens[i], postfix, e1)
            i = i + postfix_width
         else
            if infix or postfix then break end
         end
         local navigation
         local tkop = ps.tokens[i]
         if tkop.tk == "?." then
            navigation = new_block(ps, i, "safe_navigation")
            i = i + 1
            tkop = ps.tokens[i]
            if tkop.kind == "identifier" then
               tkop = { tk = ".", kind = ".", y = tkop.y, x = tkop.x }
               i = i - 1
            elseif tkop.tk ~= "[" and tkop.tk ~= ":" and not args_starters[tkop.kind] then
               return fail(ps, i, "expected an index or call after '?.'")
            end
         end
         if tkop.tk == ":" and ps.ternary_middle then
            break
         end
         if tkop.kind == "," or tkop.kind == ")" then
            break
         end
         if tkop.tk == "." or tkop.tk == ":" then
            local op_kind = op_map[2][tkop.tk]

            local prev_i = i

            local key
            i = i + 1
            if ps.tokens[i].tk == "(" and tkop.tk == "." then
               i, key = read_macro_name(ps, i)
            elseif ps.allow_macro_vars and ps.tokens[i].tk == "$" then
               local dtk = ps.tokens[i]
               i = i + 1
               local ident
               i, ident = verify_kind(ps, i, "identifier")
               if not ident then
                  return i, failstore(ps, tkop, e1)
               end
               local macro_key = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
               key = macro_key
            else
               if ps.tokens[i].kind ~= "identifier" then
                  local skipped = skip(ps, i, read_type)
                  if skipped > i + 1 then
                     fail(ps, i, "syntax error, cannot declare a type here (missing 'local' or 'global'?)")
                     return skipped, failstore(ps, tkop, e1)
                  end
               end
               i, key = verify_kind(ps, i, "identifier")
               if not key then
                  return i, failstore(ps, tkop, e1)
               end
            end

            if op_kind == "op_colon" then
               if ps.tokens[i].tk ~= "?." and ps.tokens[i].tk ~= "!" and not args_starters[ps.tokens[i].kind] then
                  if ps.tokens[i].tk == "=" then
                     fail(ps, i, "syntax error, cannot perform an assignment here (missing 'local' or 'global'?)")
                  else
                     fail(ps, i, "expected a function call for a method")
                  end
                  return i, failstore(ps, tkop, e1)
               end

               if not after_valid_prefixexp(ps, e1, prev_i) then
                  fail(ps, prev_i, "cannot call a method on this expression")
                  return i, failstore(ps, tkop, e1)
               end
            end

            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, [BLOCK_INDEXES.OP.E2] = key, tk = tkop.tk }
         elseif tkop.tk == "!" then
            local prev_i = i
            i = i + 1
            local next_tk = ps.tokens[i]
            local args = new_block(ps, i, "expression_list")
            local argument
            local mname
            local has_colon
            mname, has_colon = macro_target_key(e1)
            if has_colon then
               fail(ps, prev_i, "method-style macro invocation is not supported; use owner.macro!()")
               return i, failstore(ps, tkop, e1)
            end
            if next_tk.tk == "(" then
               local sig = mname and ps.macro_sigs[mname]
               if (not sig) and mname then
                  local alias = mname:match("^([^.]+)%.")
                  if alias then
                     ensure_required_alias_macros(ps, alias)
                     sig = ps.macro_sigs[mname]
                  end
               end
               if sig then
                  i, args = read_macro_args_with_sig(ps, i, sig)
               else
                  i, args = read_bracket_list(ps, i, args, "(", ")", "sep", read_nested_expression)
               end
            elseif next_tk.kind == "string" or next_tk.kind == "{" then
               if mname then
                  local alias = mname:match("^([^.]+)%.")
                  if alias then
                     ensure_required_alias_macros(ps, alias)
                  end
               end
               if next_tk.kind == "string" then
                  argument = new_block(ps, i, "string")
                  i = i + 1
               else
                  i, argument = read_table_literal(ps, i)
               end
               table.insert(args, argument)
            elseif is_macro_quote_token(next_tk) then
               local qi, q = read_macro_quote(ps, i)
               i = qi
               table.insert(args, q)
            else
               if next_tk.tk == "=" then
                  fail(ps, i, "syntax error, cannot perform an assignment here (missing 'local' or 'global'?)")
               else
                  fail(ps, i, "expected macro arguments")
               end
               return i, failstore(ps, tkop, e1)
            end

            if not after_valid_prefixexp(ps, e1, prev_i) then
               fail(ps, prev_i, "cannot call this expression")
               return i, failstore(ps, tkop, e1)
            end

            if forbidden_macro_invocation(ps, e1.y, e1.x) then
               return i, { kind = "error_block", f = ps.filename, y = e1.y, x = e1.x, tk = tkop.tk }
            end
            local inv = { f = ps.filename, y = args.y, x = args.x, kind = "macro_invocation", [BLOCK_INDEXES.MACRO_INVOCATION.MACRO] = e1, [BLOCK_INDEXES.MACRO_INVOCATION.ARGS] = args, tk = tkop.tk }
            local signature = mname and ps.macro_sigs[mname]
            if signature and signature.operator then
               inv[BLOCK_INDEXES.MACRO_INVOCATION.MACRO] = {
                  kind = "identifier", tk = signature.operator.binding, f = ps.filename, y = e1.y, x = e1.x,
               }
            end
            e1 = inv
         elseif tkop.tk == "(" then
            local prev_tk = ps.tokens[i - 1]
            if tkop.y > prev_tk.y and (ps.read_lang ~= "lua" or not after_valid_prefixexp(ps, e1, i)) then
               table.insert(ps.tokens, i, { y = prev_tk.y, x = prev_tk.x + #prev_tk.tk, tk = ";", kind = ";" })
               break
            end

            local op_kind = op_map[2]["@funcall"]

            local prev_i = i

            local args = new_block(ps, i, "expression_list")
            i, args = read_bracket_list(ps, i, args, "(", ")", "sep", read_nested_expression)

            if not after_valid_prefixexp(ps, e1, prev_i) then
               fail(ps, prev_i, "cannot call this expression")
               return i, failstore(ps, tkop, e1)
            end

            e1 = { f = ps.filename, y = args.y, x = args.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, [BLOCK_INDEXES.OP.E2] = args, tk = tkop.tk }
         elseif tkop.tk == "[" then
            local op_kind = op_map[2]["@index"]

            local prev_i = i

            local idx
            i = i + 1
            i, idx = read_expression_and_tk(ps, i, "]")

            if not after_valid_prefixexp(ps, e1, prev_i) then
               fail(ps, prev_i, "cannot index this expression")
               return i, failstore(ps, tkop, e1)
            end

            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, [BLOCK_INDEXES.OP.E2] = idx, tk = tkop.tk }
         elseif tkop.kind == "string" or tkop.kind == "{" then
            local op_kind = op_map[2]["@funcall"]

            local prev_i = i

            local args = new_block(ps, i, "expression_list")
            local argument
            if tkop.kind == "string" then
               argument = new_block(ps, i, "string")
               i = i + 1
            else
               i, argument = read_table_literal(ps, i)
            end

            if not after_valid_prefixexp(ps, e1, prev_i) then
               if tkop.kind == "string" then
                  fail(ps, prev_i, "cannot use a string here; if you're trying to call the previous expression, wrap it in parentheses")
               else
                  fail(ps, prev_i, "cannot use a table here; if you're trying to call the previous expression, wrap it in parentheses")
               end
               return i, failstore(ps, tkop, e1)
            end

            table.insert(args, argument)
            e1 = { f = ps.filename, y = args.y, x = args.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, [BLOCK_INDEXES.OP.E2] = args, tk = tkop.tk }
         elseif tkop.tk == "as" or tkop.tk == "is" then
            local op_kind = op_map[2][tkop.tk]

            i = i + 1
            local cast
            if ps.tokens[i].tk == "(" then
               i, cast = read_type_list(ps, i, "casttype")
            else
               i, cast = read_type(ps, i)
            end
            if not cast then
               return i, failstore(ps, tkop, e1)
            end
            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = op_kind, [BLOCK_INDEXES.OP.E1] = e1, [BLOCK_INDEXES.OP.E2] = cast, tk = tkop.tk }
         else
            break
         end
         if navigation then
            e1[BLOCK_INDEXES.OP.SAFE] = navigation
         end
      end

      local reference = e1.kind == "op_dot" and e1[BLOCK_INDEXES.OP.E2] or e1
      if macro_operator_symbol(reference) then
         fail(ps, i, "operator macro references require '!()' or a local macro import")
      end
      return i, e1
   end

   read_prefix_expression = function(ps, i)
      local lhs
      i, lhs = P(ps, i)
      local tk = ps.tokens[i].tk
      if lhs and tk ~= "~=" then
         i, lhs = E(ps, i, lhs, 0)
      end
      return i, lhs
   end

   local function next_operator(ps, i)
      local postfix, postfix_width = find_operator(ps, i, "postfix")
      local infix, infix_width = find_operator(ps, i, "infix")
      local spec = postfix or infix
      if infix and postfix and #infix.symbol > #postfix.symbol then spec = infix end
      if spec then return spec.precedence, spec.right_associative, spec, spec == postfix and postfix_width or infix_width, spec.fixity end
      local tk = ps.tokens[i].tk
      if ps.ternary_middle and tk == ":" then return nil end
      return precedences[2][tk], is_right_assoc[tk], nil, 1, "infix"
   end

   E = function(ps, i, lhs, min_precedence)
      while true do
         local precedence, right, custom, width, fixity = next_operator(ps, i)
         if not precedence or precedence < min_precedence then break end
         local token = ps.tokens[i]
         i = i + width
         if fixity == "postfix" then
            lhs = operator_invocation(ps, token, custom, lhs)
         else
            local rhs
            i, rhs = P(ps, i)
            if not rhs then return fail(ps, i, "expected an expression") end
            while true do
               local next_prec = next_operator(ps, i)
               if not next_prec or next_prec < precedence or (next_prec == precedence and not right) then break end
               i, rhs = E(ps, i, rhs, next_prec)
               if not rhs then return fail(ps, i, "expected an expression") end
            end
            if custom then
               lhs = operator_invocation(ps, token, custom, lhs, rhs)
            else
               lhs = { f = ps.filename, y = token.y, x = token.x, kind = op_map[2][token.tk],
               [BLOCK_INDEXES.OP.E1] = lhs, [BLOCK_INDEXES.OP.E2] = rhs, tk = token.tk, }
            end
         end
      end
      return i, lhs
   end

   read_expression = function(ps, i)
      local lhs
      local istart = i
      i, lhs = P(ps, i)
      if lhs then
         i, lhs = E(ps, i, lhs, 0)
      end
      if lhs and ps.tokens[i].tk == "?" then
         local conditional = new_block(ps, i, "conditional")
         conditional[1] = lhs
         local middle = ps.ternary_middle
         ps.ternary_middle = true
         i, conditional[2] = read_expression(ps, i + 1)
         ps.ternary_middle = middle
         i = verify_tk(ps, i, ":")
         i, conditional[3] = read_expression(ps, i)
         lhs = conditional
      end
      if lhs then
         return i, lhs, 0
      end

      if i == istart then
         i = fail(ps, i, "expected an expression")
      end
      return i
   end
end

read_short_function = function(ps, i)
   local node = new_block(ps, i, "function")
   node[BLOCK_INDEXES.FUNCTION.SHORT] = new_block(ps, i, "short_function")
   local args = new_block(ps, i, "argument_list")
   if ps.tokens[i].tk == "||" then
      i = i + 1
   elseif ps.tokens[i].tk == "|" then
      i = i + 1
      while ps.tokens[i].tk ~= "|" and ps.tokens[i].kind ~= "$EOF$" do
         local argument
         i, argument = read_argument(ps, i)
         if argument then table.insert(args, argument) end
         if ps.tokens[i].tk ~= "," then break end
         i = i + 1
      end
      i = verify_tk(ps, i, "|")
      end_at(args, ps.tokens[i - 1])
   else
      table.insert(args, new_block(ps, i, "argument"))
      i = i + 1
   end
   node[BLOCK_INDEXES.FUNCTION.ARGS] = args
   if ps.tokens[i].tk == ":" then
      i, node[BLOCK_INDEXES.FUNCTION.RETS] = read_return_types(ps, i)
   end
   i = verify_tk(ps, i, "->")
   if ps.tokens[i].tk == "do" then
      local middle = ps.ternary_middle
      ps.ternary_middle = false
      i, node[BLOCK_INDEXES.FUNCTION.BODY] = read_statements(ps, i + 1)
      ps.ternary_middle = middle
      end_at(node, ps.tokens[i])
      i = verify_tk(ps, i, "end")
   else
      local exp
      i, exp = read_expression(ps, i)
      local ret = new_block(ps, i - 1, "return")
      ret[BLOCK_INDEXES.RETURN.EXPS] = new_block(ps, i - 1, "expression_list")
      ret[BLOCK_INDEXES.RETURN.EXPS][1] = exp
      local body = new_block(ps, i - 1, "statements")
      body[1] = ret
      node[BLOCK_INDEXES.FUNCTION.BODY] = body
      end_at(node, ps.tokens[i - 1])
   end
   return i, node
end

read_expression_and_tk = function(ps, i, tk)
   local e
   i, e = read_expression(ps, i)
   if not e then
      e = new_block(ps, i - 1, "error_block")
   end
   if ps.tokens[i].tk == tk then
      i = i + 1
   else
      local msg = "syntax error, expected '" .. tk .. "'"
      if ps.tokens[i].tk == "=" then
         msg = "syntax error, cannot perform an assignment here (did you mean '=='?)"
      end


      for n = 0, 19 do
         local t = ps.tokens[i + n]
         if t.kind == "$EOF$" then
            break
         end
         if t.tk == tk then
            fail(ps, i, msg)
            return i + n + 1, e
         end
      end
      i = fail(ps, i, msg)
   end
   return i, e
end

local function read_variable_name(ps, i)
   local node
   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      i = i + 1
      local ident
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return i
      end
      node = new_block(ps, i - 1, "macro_var")
      node[BLOCK_INDEXES.MACRO_VAR.NAME] = ident
      end_at(node, ps.tokens[i - 1])
   else
      i, node = verify_kind(ps, i, "identifier")
      if not node then
         return i
      end
      if ps.tokens[i].tk == "<" then
         i = i + 1
         local annotation
         i, annotation = verify_kind(ps, i, "identifier")
         if annotation then
            if not is_attribute[annotation.tk] then
               fail(ps, i, "unknown variable annotation: " .. annotation.tk)
            end
            table.insert(node, annotation)
         else
            fail(ps, i, "expected a variable annotation")
         end
         i = verify_tk(ps, i, ">")
      end
   end
   return i, node
end

read_argument = function(ps, i)
   local node
   local vararg_name
   if ps.tokens[i].tk == "..." then
      i, node = verify_kind(ps, i, "...", "argument")
      if ps.tokens[i].kind == "identifier" then
         vararg_name = new_block(ps, i, "identifier")
         i = i + 1
      end
   else
      i, node = verify_kind(ps, i, "identifier", "argument")
   end
   if ps.tokens[i].tk == "..." then
      fail(ps, i, "'...' needs to be declared as a typed argument")
   end
   local has_question = false
   local q_i = i
   if ps.tokens[i].tk == "?" then
      has_question = true
      q_i = i
      i = i + 1
   end
   if ps.tokens[i].tk == ":" then
      i = i + 1
      local argtype

      i, argtype = read_type(ps, i)

      if node then
         table.insert(node, argtype)
      end
   end
   if node and has_question then
      table.insert(node, new_block(ps, q_i, "question"))
   end
   if vararg_name then
      table.insert(node, vararg_name)
   end
   return i, node, 0
end

read_argument_list = function(ps, i)
   local node = new_block(ps, i, "argument_list")
   i, node = read_bracket_list(ps, i, node, "(", ")", "sep", read_argument)
   local opts = false
   local min_arity = 0
   for a, fnarg in ipairs(node) do
      if fnarg.tk == "..." then
         if a ~= #node then
            fail(ps, i, "'...' can only be last argument")
            break
         end
      elseif opts then
         return fail(ps, i, "non-optional arguments cannot follow optional arguments")
      else
         min_arity = min_arity + 1
      end
   end
   return i, node, min_arity
end

local function read_argument_type(ps, i)
   local opt = 0
   local is_va = false
   local argument_name = nil

   if ps.tokens[i].kind == "identifier" then
      argument_name = ps.tokens[i].tk
      if ps.tokens[i + 1].tk == "?" then
         opt = i + 1
         if ps.tokens[i + 2].tk == ":" then
            i = i + 3
         end
      elseif ps.tokens[i + 1].tk == ":" then
         i = i + 2
      end
   elseif ps.tokens[i].kind == "?" then
      opt = i
      i = i + 1
   elseif ps.tokens[i].tk == "..." then
      if ps.tokens[i + 1].tk == "?" then
         fail(ps, i + 1, "cannot mix '?' and '...' in a declaration; '...' already implies optional")
         i = i + 1
      end
      if ps.tokens[i + 1].kind == "identifier" then
         i = i + 1
      end
      if ps.tokens[i + 1].tk == ":" then
         i = i + 2
         is_va = true
      else
         return fail(ps, i, "cannot have untyped '...' when declaring the type of an argument")
      end
   end

   local typ; i, typ = read_type(ps, i)
   if typ then
      if not is_va and ps.tokens[i].tk == "..." then
         i = i + 1
         is_va = true
         if opt > 0 then
            fail(ps, opt, "cannot mix '?' and '...' in a declaration; '...' already implies optional")
         end
      end
   end

   local t = new_type(ps, i, "argument_type")
   if argument_name then
      local name_block = new_block(ps, i, "identifier")
      name_block.tk = argument_name
      t[BLOCK_INDEXES.ARGUMENT_TYPE.NAME] = name_block
   end
   t[BLOCK_INDEXES.ARGUMENT_TYPE.TYPE] = typ
   if is_va then t[BLOCK_INDEXES.ARGUMENT_TYPE.VARARG] = new_block(ps, i, "...") end
   if opt > 0 then t[BLOCK_INDEXES.ARGUMENT_TYPE.OPTIONAL] = new_block(ps, opt, "question") end

   return i, t, 0
end

read_argument_type_list = function(ps, i)
   local ars = {}
   i = read_bracket_list(ps, i, ars, "(", ")", "sep", read_argument_type)
   local t, list = new_tuple(ps, i)

   local min_arity = 0
   for l, ar in ipairs(ars) do
      list[l] = ar
   end
   return i, t, min_arity
end

local function read_identifier(ps, i)
   if ps.tokens[i].kind == "identifier" then
      return i + 1, new_block(ps, i, "identifier")
   end
   i = fail(ps, i, "syntax error, expected identifier")
   return i, new_block(ps, i, "error_block")
end

local function read_local_function(ps, i)
   i = verify_tk(ps, i, ps.tokens[i].tk == "const" and "const" or "local")
   i = verify_tk(ps, i, "function")
   local node = new_block(ps, i - 2, "local_function")
   i, node[BLOCK_INDEXES.LOCAL_FUNCTION.NAME] = read_identifier(ps, i)
   return read_function_args_rets_body(ps, i, node)
end

local function read_if_block(ps, i, node, is_else)
   local if_block = new_block(ps, i, "if_block")
   i = i + 1
   if not is_else then
      i, if_block[BLOCK_INDEXES.IF_BLOCK.COND] = read_expression_and_tk(ps, i, "then")
      if not if_block[BLOCK_INDEXES.IF_BLOCK.COND] then
         return i
      end
      i, if_block[BLOCK_INDEXES.IF_BLOCK.BODY] = read_statements(ps, i)
      if not if_block[BLOCK_INDEXES.IF_BLOCK.BODY] then
         return i
      end
   else
      i, if_block[BLOCK_INDEXES.IF_BLOCK.BODY] = read_statements(ps, i)
      if not if_block[BLOCK_INDEXES.IF_BLOCK.BODY] then
         return i
      end
   end
   if_block.yend, if_block.xend = (if_block[BLOCK_INDEXES.IF_BLOCK.BODY] or if_block[BLOCK_INDEXES.IF_BLOCK.COND]).yend, (if_block[BLOCK_INDEXES.IF_BLOCK.BODY] or if_block[BLOCK_INDEXES.IF_BLOCK.COND]).xend
   table.insert(node, if_block)
   return i, node
end

local function read_if(ps, i)
   local istart = i
   local node = new_block(ps, i, "if")
   i, node = read_if_block(ps, i, node)
   if not node then
      return i
   end
   while ps.tokens[i].tk == "elseif" do
      i, node = read_if_block(ps, i, node)
      if not node then
         return i
      end
   end
   if ps.tokens[i].tk == "else" then
      i, node = read_if_block(ps, i, node, true)
      if not node then
         return i
      end
   end
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_while(ps, i)
   local istart = i
   local node = new_block(ps, i, "while")
   i = verify_tk(ps, i, "while")
   i, node[BLOCK_INDEXES.WHILE.COND] = read_expression_and_tk(ps, i, "do")
   i, node[BLOCK_INDEXES.WHILE.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_fornum(ps, i)
   local istart = i
   local node = new_block(ps, i, "fornum")
   i = i + 1
   i, node[BLOCK_INDEXES.FORNUM.VAR] = read_identifier(ps, i)
   i = verify_tk(ps, i, "=")
   i, node[BLOCK_INDEXES.FORNUM.FROM] = read_expression_and_tk(ps, i, ",")
   i, node[BLOCK_INDEXES.FORNUM.TO] = read_expression(ps, i)
   if ps.tokens[i].tk == "," then
      i = i + 1
      i, node[BLOCK_INDEXES.FORNUM.STEP] = read_expression_and_tk(ps, i, "do")
   else
      i = verify_tk(ps, i, "do")
   end
   i, node[BLOCK_INDEXES.FORNUM.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_forin(ps, i)
   local istart = i
   local node = new_block(ps, i, "forin")
   i = i + 1
   node[BLOCK_INDEXES.FORIN.VARS] = new_block(ps, i, "variable_list")
   i, node[BLOCK_INDEXES.FORIN.VARS] = read_list(ps, i, node[BLOCK_INDEXES.FORIN.VARS], { ["in"] = true }, "sep", read_identifier)
   i = verify_tk(ps, i, "in")
   node[BLOCK_INDEXES.FORIN.EXPS] = new_block(ps, i, "expression_list")
   i = read_list(ps, i, node[BLOCK_INDEXES.FORIN.EXPS], { ["do"] = true }, "sep", read_expression)
   if #node[BLOCK_INDEXES.FORIN.EXPS] < 1 then
      return fail(ps, i, "missing iterator expression in generic for")
   elseif #node[BLOCK_INDEXES.FORIN.EXPS] > 3 then
      return fail(ps, i, "too many expressions in generic for")
   end
   i = verify_tk(ps, i, "do")
   i, node[BLOCK_INDEXES.FORIN.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_for(ps, i)
   if ps.tokens[i + 1].kind == "identifier" and ps.tokens[i + 2].tk == "=" then
      return read_fornum(ps, i)
   else
      return read_forin(ps, i)
   end
end

local function read_repeat(ps, i)
   local node = new_block(ps, i, "repeat")
   i = verify_tk(ps, i, "repeat")
   i, node[BLOCK_INDEXES.REPEAT.BODY] = read_statements(ps, i)
   i = verify_tk(ps, i, "until")
   i, node[BLOCK_INDEXES.REPEAT.COND] = read_expression(ps, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function read_do(ps, i)
   local istart = i
   local node = new_block(ps, i, "do")
   i = verify_tk(ps, i, "do")
   i, node[BLOCK_INDEXES.DO.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_break(ps, i)
   local node = new_block(ps, i, "break")
   i = verify_tk(ps, i, "break")
   return i, node
end

local function read_goto(ps, i)
   local node = new_block(ps, i, "goto")
   i = verify_tk(ps, i, "goto")
   node[BLOCK_INDEXES.GOTO.LABEL] = new_block(ps, i, "identifier")
   node[BLOCK_INDEXES.GOTO.LABEL].tk = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   return i, node
end

local function read_label(ps, i)
   local node = new_block(ps, i, "label")
   i = verify_tk(ps, i, "::")
   node[BLOCK_INDEXES.LABEL.NAME] = new_block(ps, i, "identifier")
   node[BLOCK_INDEXES.LABEL.NAME].tk = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   i = verify_tk(ps, i, "::")
   return i, node
end

local stop_statement_list = {
   ["end"] = true,
   ["else"] = true,
   ["elseif"] = true,
   ["until"] = true,
}

local stop_return_list = {
   [";"] = true,
   ["$EOF$"] = true,
}

for k, v in pairs(stop_statement_list) do
   stop_return_list[k] = v
end

local function read_return(ps, i)
   local node = new_block(ps, i, "return")
   i = verify_tk(ps, i, "return")
   node[BLOCK_INDEXES.RETURN.EXPS] = new_block(ps, i, "expression_list")
   i = read_list(ps, i, node[BLOCK_INDEXES.RETURN.EXPS], stop_return_list, "sep", read_expression)
   if ps.tokens[i].kind == ";" then
      i = i + 1
      if ps.tokens[i].kind ~= "$EOF$" and not stop_statement_list[ps.tokens[i].kind] then
         return fail(ps, i, "return must be the last statement of its block")
      end
   end
   return i, node
end

read_nested_type = function(ps, i, tn)
   local istart = i
   i = i + 1

   local v
   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a variable name")
      end
      local macro_var = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
      v = macro_var
   else
      i, v = verify_kind(ps, i, "identifier", "type_identifier")
      if not v then
         return fail(ps, i, "expected a variable name")
      end
   end

   local nt = new_block(ps, istart, "newtype")

   local ndef
   i, ndef = read_type_body(ps, i, istart, nt, tn)
   if not ndef then
      return i
   end

   table.insert(nt, new_typedecl(ps, istart, ndef))
   local asgn = new_block(ps, istart, "local_type")
   asgn[BLOCK_INDEXES.LOCAL_TYPE.VAR] = v
   asgn[BLOCK_INDEXES.LOCAL_TYPE.VALUE] = nt
   return i, asgn
end

read_enum_body = function(ps, i, def)
   while ps.tokens[i].tk ~= "$EOF$" and ps.tokens[i].tk ~= "end" do
      local comment_blocks = collect_comment_blocks(ps, i)
      local item
      i, item = verify_kind(ps, i, "string", "string")
      if item then
         for _, cb in ipairs(comment_blocks) do
            table.insert(def, cb)
         end
         table.insert(def, item)
      end
   end
   return i, true
end

local metamethod_names = {
   ["__add"] = true,
   ["__sub"] = true,
   ["__mul"] = true,
   ["__div"] = true,
   ["__mod"] = true,
   ["__pow"] = true,
   ["__unm"] = true,
   ["__idiv"] = true,
   ["__band"] = true,
   ["__bor"] = true,
   ["__bxor"] = true,
   ["__bnot"] = true,
   ["__shl"] = true,
   ["__shr"] = true,
   ["__concat"] = true,
   ["__len"] = true,
   ["__eq"] = true,
   ["__lt"] = true,
   ["__le"] = true,
   ["__index"] = true,
   ["__newindex"] = true,
   ["__call"] = true,
   ["__tostring"] = true,
   ["__pairs"] = true,
   ["__gc"] = true,
   ["__close"] = true,
   ["__is"] = true,
}

local function read_macroexp(ps, istart, iargs)
   local node = new_block(ps, istart, "macroexp")

   local i
   local idx = 1
   if ps.tokens[istart + 1].tk == "<" then
      i, node[idx] = read_anglebracket_list(ps, istart + 1, read_typearg)
      idx = idx + 1
   else
      i = iargs
   end

   i, node[idx] = read_argument_list(ps, i)
   idx = idx + 1
   i, node[idx] = read_return_types(ps, i)
   idx = idx + 1
   i = verify_tk(ps, i, "return")
   i, node[idx] = read_expression(ps, i)
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_where_clause(ps, i, def)
   local node = new_block(ps, i, "macroexp")

   node[BLOCK_INDEXES.MACROEXP.ARGS] = new_block(ps, i, "argument_list")
   node[BLOCK_INDEXES.MACROEXP.ARGS][1] = new_block(ps, i, "argument")
   node[BLOCK_INDEXES.MACROEXP.ARGS][1].tk = "self"
   node[BLOCK_INDEXES.MACROEXP.ARGS][1][BLOCK_INDEXES.ARGUMENT.TYPE] = new_type(ps, i, "nominal_type")
   node[BLOCK_INDEXES.MACROEXP.ARGS][1][BLOCK_INDEXES.ARGUMENT.TYPE].tk = "self"
   node[BLOCK_INDEXES.MACROEXP.ARGS][1][BLOCK_INDEXES.ARGUMENT.TYPE][BLOCK_INDEXES.NOMINAL_TYPE.NAME] = def
   node[BLOCK_INDEXES.MACROEXP.RETS] = new_tuple(ps, i)
   node[BLOCK_INDEXES.MACROEXP.RETS][1] = new_type(ps, i, "boolean")
   i, node[BLOCK_INDEXES.MACROEXP.EXP] = read_expression(ps, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

read_interface_name = function(ps, i)
   local istart = i
   local typ


   i, typ = read_simple_type_or_nominal(ps, i)
   if (not typ) or typ.kind ~= "nominal_type" then
      return fail(ps, istart, "expected an interface")
   end

   return i, typ

end

local function read_array_interface_type(ps, i)
   local t
   i, t = read_base_type(ps, i)
   if not t then
      return i
   end
   if t.kind ~= "array_type" and t.kind ~= "type_list" then
      fail(ps, i, "expected an array or type list declaration")
      return i
   end
   return i, t
end

local function extract_userdata_from_interface_list(ps, i, interface_list)
   if not interface_list then
      return false
   end
   local is_userdata = false
   for j = #interface_list, 1, -1 do
      local iface = interface_list[j]
      if iface.kind == "nominal_type" and #iface == 1 and iface[BLOCK_INDEXES.NOMINAL_TYPE.NAME].tk == "userdata" then
         table.remove(interface_list, j)
         if is_userdata then
            fail(ps, i, "duplicated 'userdata' declaration")
         end
         is_userdata = true
      end
   end
   return is_userdata
end

read_record_body = function(ps, i, def)
   if ps.tokens[i].tk == "{" then
      local atype
      i, atype = read_array_interface_type(ps, i)
      if atype then
         def[BLOCK_INDEXES.RECORD.ARRAY_TYPE] = atype
      end
   end

   if ps.tokens[i].tk == "is" then
      i = i + 1

      if ps.tokens[i].tk == "{" then
         if def[BLOCK_INDEXES.RECORD.ARRAY_TYPE] then
            return failskip(ps, i, "duplicated declaration of array element type", read_type)
         end
         local atype
         i, atype = read_array_interface_type(ps, i)
         if atype then
            def[BLOCK_INDEXES.RECORD.ARRAY_TYPE] = atype
         end
         if ps.tokens[i].tk == "," then
            i = i + 1
            def[BLOCK_INDEXES.RECORD.INTERFACES] = new_block(ps, i, "interface_list")
            i, def[BLOCK_INDEXES.RECORD.INTERFACES] = read_trying_list(ps, i, def[BLOCK_INDEXES.RECORD.INTERFACES], read_interface_name)
         else
            def[BLOCK_INDEXES.RECORD.INTERFACES] = new_block(ps, i, "interface_list")
         end
      else
         def[BLOCK_INDEXES.RECORD.INTERFACES] = new_block(ps, i, "interface_list")
         i, def[BLOCK_INDEXES.RECORD.INTERFACES] = read_trying_list(ps, i, def[BLOCK_INDEXES.RECORD.INTERFACES], read_interface_name)
      end

      if def[BLOCK_INDEXES.RECORD.INTERFACES] and extract_userdata_from_interface_list(ps, i, def[BLOCK_INDEXES.RECORD.INTERFACES]) then
         table.insert(def, new_block(ps, i, "userdata"))
      end
   end

   if ps.tokens[i].tk == "where" then
      i = i + 1
      i, def[BLOCK_INDEXES.RECORD.WHERE_CLAUSE] = read_where_clause(ps, i, def)
   end

   local fields = new_block(ps, i, "record_body")
   def[BLOCK_INDEXES.RECORD.FIELDS] = fields
   local meta_fields

   while not (ps.tokens[i].kind == "$EOF$" or ps.tokens[i].tk == "end") do
      local comment_blocks = collect_comment_blocks(ps, i)
      local tn = ps.tokens[i].tk
      local tn_kind = type_body_kinds[tn]
      if ps.tokens[i].tk == "userdata" and ps.tokens[i + 1].tk ~= ":" then
         for _, cb in ipairs(comment_blocks) do
            table.insert(def, cb)
         end
         table.insert(def, new_block(ps, i, "userdata"))
         i = i + 1
      elseif ps.tokens[i].tk == "{" then
         return fail(ps, i, "syntax error: this syntax is no longer valid; declare array interface at the top with 'is {...}'")
      elseif ps.tokens[i].tk == "type" and ps.tokens[i + 1].tk ~= ":" then
         i = i + 1

         local lt
         i, lt = read_type_declaration(ps, i, "local_type")
         if not lt then
            return fail(ps, i, "expected a type definition")
         end

         for _, cb in ipairs(comment_blocks) do
            table.insert(fields, cb)
         end
         table.insert(fields, lt)
      elseif tn_kind and ps.tokens[i + 1].tk ~= ":" then
         if def.kind == "interface" and tn == "record" then
            i = failskip(ps, i, "interfaces cannot contain record definitions", skip_type_body)
         else
            local lt
            i, lt = read_nested_type(ps, i, tn_kind)
            if lt then
               for _, cb in ipairs(comment_blocks) do
                  table.insert(fields, cb)
               end
               table.insert(fields, lt)
            end
         end
      else
         local is_metamethod = false
         if ps.tokens[i].tk == "metamethod" and ps.tokens[i + 1].tk ~= ":" then
            is_metamethod = true
            i = i + 1
         end

         local v
         if ps.tokens[i].tk == "[" then
            i = i + 1
            i, v = read_literal(ps, i)
            if not v or v.kind ~= "string" then
               return fail(ps, i, "expected a string literal")
            end
            i = verify_tk(ps, i, "]")
         else
            i, v = verify_kind(ps, i, "identifier")
         end
         if not v then
            return fail(ps, i, "expected a variable name")
         end

         if ps.tokens[i].tk == ":" then
            i = i + 1
            local t
            i, t = read_type(ps, i)
            if not t then
               return fail(ps, i, "expected a type")
            end

            local field_name
            if v.kind == "string" then
               field_name = block.string_value(v)
            else
               field_name = v.tk
            end
            local current_fields = fields
            if is_metamethod then
               if not meta_fields then
                  meta_fields = new_block(ps, i, "record_body")
                  def[BLOCK_INDEXES.RECORD.META_FIELDS] = meta_fields
               end
               current_fields = meta_fields
               if not metamethod_names[field_name] then
                  fail(ps, i - 1, "not a valid metamethod: " .. field_name)
               end
            end

            for _, cb in ipairs(comment_blocks) do
               table.insert(current_fields, cb)
            end

            if ps.tokens[i].tk == "=" and ps.tokens[i + 1].tk == "macroexp" then
               local tt = t.kind == "generic_type" and t[BLOCK_INDEXES.GENERIC_TYPE.BASE] or t

               if tt.kind == "function" then
                  i, tt[BLOCK_INDEXES.FUNCTION_TYPE.MACROEXP] = read_macroexp(ps, i + 1, i + 2)
               else
                  fail(ps, i + 1, "macroexp must have a function type")
               end
            end

            local field = new_block(ps, i, "record_field")
            field[BLOCK_INDEXES.RECORD_FIELD.NAME] = v
            field[BLOCK_INDEXES.RECORD_FIELD.TYPE] = t
            table.insert(current_fields, field)
         elseif ps.tokens[i].tk == "=" then
            local next_word = ps.tokens[i + 1].tk
            if next_word == "record" or next_word == "enum" then
               return fail(ps, i, "syntax error: this syntax is no longer valid; use '" .. next_word .. " " .. v.tk .. "'")
            elseif next_word == "functiontype" then
               return fail(ps, i, "syntax error: this syntax is no longer valid; use 'type " .. v.tk .. " = function(...")
            else
               return fail(ps, i, "syntax error: this syntax is no longer valid; use 'type " .. v.tk .. " = '...")
            end
         else
            fail(ps, i, "syntax error: expected ':' for an attribute or '=' for a nested type")
         end
      end
   end
   return i, true
end

read_type_body_fns = {
   ["interface"] = read_record_body,
   ["record"] = read_record_body,
   ["enum"] = read_enum_body,
}

local function read_newtype(ps, i)
   local node = new_block(ps, i, "newtype")
   local def
   local tn = ps.tokens[i].tk
   local istart = i

   local tn_kind = type_body_kinds[tn]
   if tn_kind then
      i, def = read_type_body(ps, i + 1, istart, node, tn_kind)
   else
      i, def = read_type(ps, i)
   end
   if not def then
      return fail(ps, i, "expected a type")
   end

   node[BLOCK_INDEXES.NEWTYPE.TYPEDECL] = new_typedecl(ps, istart, def)

   return i, node
end

local function read_assignment_expression_list(ps, i, asgn)
   asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] = new_block(ps, i, "expression_list")
   repeat
      i = i + 1
      local val
      i, val = read_expression(ps, i)
      if not val then
         if #asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] == 0 then
            asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] = nil
         end
         return i
      end
      table.insert(asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS], val)
   until ps.tokens[i].tk ~= ","
   end_at(asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS], ps.tokens[i - 1])
   return i, asgn
end

do
   local compound_ops = {
      ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
      ["%="] = true, ["&="] = true, ["|="] = true, ["~="] = true,
      ["<<="] = true, [">>="] = true, ["~>>="] = true, ["..="] = true,
   }

   local function read_variable(ps, i)
      local node
      i, node = read_expression(ps, i)
      return i, node
   end

   read_call_or_assignment = function(ps, i)
      local exp
      local istart = i
      i, exp = read_prefix_expression(ps, i)
      if not exp then
         return i
      end

      local assignment_op = ps.tokens[i].tk
      local macro_target = exp.kind == "macro_invocation" and
      (assignment_op == "=" or assignment_op == "," or compound_ops[assignment_op])
      if reader.node_is_funcall(exp) and not macro_target then
         return i, exp
      end

      if not macro_target and exp.kind ~= "identifier" and exp.kind ~= "op_index" and exp.kind ~= "op_dot" and exp.kind ~= "macro_var" then
         return fail(ps, i, "syntax error")
      end

      local asgn = new_block(ps, istart, "assignment")
      asgn[BLOCK_INDEXES.ASSIGNMENT.VARS] = new_block(ps, istart, "variable_list")
      asgn[BLOCK_INDEXES.ASSIGNMENT.VARS][1] = exp
      if ps.tokens[i].tk == "," then
         i = i + 1
         i = read_trying_list(ps, i, asgn[BLOCK_INDEXES.ASSIGNMENT.VARS], read_variable)
         if #asgn[BLOCK_INDEXES.ASSIGNMENT.VARS] < 2 then
            return fail(ps, i, "syntax error")
         end
      end

      end_at(asgn[BLOCK_INDEXES.ASSIGNMENT.VARS], ps.tokens[i - 1])

      assignment_op = ps.tokens[i].tk
      if compound_ops[assignment_op] then
         asgn[BLOCK_INDEXES.ASSIGNMENT.OPERATOR] = new_block(ps, i, "compound_operator")
         if #asgn[BLOCK_INDEXES.ASSIGNMENT.VARS] ~= 1 then
            fail(ps, i, "compound assignment requires a single variable")
         end
      elseif assignment_op ~= "=" then
         verify_tk(ps, i, "=")
         return i
      end

      i, asgn = read_assignment_expression_list(ps, i, asgn)
      if asgn and asgn[BLOCK_INDEXES.ASSIGNMENT.OPERATOR] and #asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] ~= 1 then
         fail(ps, i - 1, "compound assignment requires a single expression")
      end
      return i, asgn
   end
end

local function read_variable_declarations(ps, i, node_name)
   local asgn = new_block(ps, i, node_name)

   asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS] = new_block(ps, i, "variable_list")
   i = read_trying_list(ps, i, asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS], read_variable_name)
   if #asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS] == 0 then
      return fail(ps, i, "expected a local variable definition")
   end

   end_at(asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS], ps.tokens[i - 1])

   i, asgn[BLOCK_INDEXES.LOCAL_DECLARATION.DECL] = read_type_list(ps, i, "decltuple")

   if ps.tokens[i].tk == "=" then

      local next_word = ps.tokens[i + 1].tk
      local tn = next_word
      if read_type_body_fns[tn] then
         local scope = node_name == "local_declaration" and "local" or "global"
         return failskip(ps, i + 1, "syntax error: this syntax is no longer valid; use '" .. scope .. " " .. next_word .. " " .. asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS][1].tk .. "'", skip_type_body)
      elseif next_word == "functiontype" then
         local scope = node_name == "local_declaration" and "local" or "global"
         return failskip(ps, i + 1, "syntax error: this syntax is no longer valid; use '" .. scope .. " type " .. asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS][1].tk .. " = function('...", read_function_type)
      end

      i, asgn = read_assignment_expression_list(ps, i, asgn)
   end
   return i, asgn
end

local function read_type_require(ps, i, asgn)
   local istart = i
   local BIDX = asgn.kind == "local_type" and BLOCK_INDEXES.LOCAL_TYPE or BLOCK_INDEXES.GLOBAL_TYPE
   i, asgn[BIDX.VALUE] = read_expression(ps, i)
   if not asgn[BIDX.VALUE] then
      return i
   end
   if asgn[BIDX.VALUE].kind ~= "op_funcall" and asgn[BIDX.VALUE].kind ~= "op_dot" and asgn[BIDX.VALUE].kind ~= "identifier" then
      fail(ps, istart, "require() in type declarations cannot be part of larger expressions")
      return i
   end
   if not reader.node_is_require_call(asgn[BIDX.VALUE]) then
      fail(ps, istart, "require() for type declarations must have a literal argument")
      return i
   end
   return i, asgn
end

local function read_special_type_declaration(ps, i, asgn)
   if ps.tokens[i].tk == "require" then
      return true, read_type_require(ps, i, asgn)
   elseif ps.tokens[i].tk == "pcall" then
      fail(ps, i, "pcall() cannot be used in type declarations")
      return true, i
   end
   return false, i, asgn
end

read_type_declaration = function(ps, i, node_name)
   local asgn = new_block(ps, i, node_name)
   local var
   local BIDX = node_name == "local_type" and BLOCK_INDEXES.LOCAL_TYPE or BLOCK_INDEXES.GLOBAL_TYPE

   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a type name")
      end
      local macro_var = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
      var = macro_var
   else
      i, var = verify_kind(ps, i, "identifier")
      if not var then
         return fail(ps, i, "expected a type name")
      end
   end
   local typeargs
   local itypeargs = i
   i, typeargs = read_typeargs_if_any(ps, i)

   asgn[BIDX.VAR] = var

   if node_name == "global_type" and ps.tokens[i].tk ~= "=" then
      return i, asgn
   end

   i = verify_tk(ps, i, "=")

   if ps.tokens[i].kind == "identifier" then
      local is_done
      is_done, i, asgn = read_special_type_declaration(ps, i, asgn)
      if is_done then
         return i, asgn
      end
   end

   i, asgn[BIDX.VALUE] = read_newtype(ps, i)
   if not asgn[BIDX.VALUE] then
      return i
   end

   if typeargs and asgn[BIDX.VALUE][BLOCK_INDEXES.NEWTYPE.TYPEDECL] and asgn[BIDX.VALUE][BLOCK_INDEXES.NEWTYPE.TYPEDECL][BLOCK_INDEXES.TYPEDECL.TYPE] then
      asgn[BIDX.VALUE][BLOCK_INDEXES.NEWTYPE.TYPEDECL][BLOCK_INDEXES.TYPEDECL.TYPE] = new_generic(ps, itypeargs, typeargs, asgn[BIDX.VALUE][BLOCK_INDEXES.NEWTYPE.TYPEDECL][BLOCK_INDEXES.TYPEDECL.TYPE])
   end

   return i, asgn
end

local function read_type_constructor(ps, i, node_name, tn)
   local asgn = new_block(ps, i, node_name)
   local nt = new_block(ps, i, "newtype")
   local BIDX = node_name == "local_type" and BLOCK_INDEXES.LOCAL_TYPE or BLOCK_INDEXES.GLOBAL_TYPE
   asgn[BIDX.VALUE] = nt
   local istart = i
   local def

   i = i + 2

   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a type name")
      end
      local macro_var = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
      asgn[BIDX.VAR] = macro_var
   else
      i, asgn[BIDX.VAR] = verify_kind(ps, i, "identifier")
      if not asgn[BIDX.VAR] then
         return fail(ps, i, "expected a type name")
      end
   end

   i, def = read_type_body(ps, i, istart, nt, tn)
   if not def then
      return i
   end

   table.insert(nt, new_typedecl(ps, istart, def))

   return i, asgn
end

local function skip_type_declaration(ps, i)
   return read_type_declaration(ps, i + 1, "local_type")
end

local function read_local_macroexp(ps, i)
   local istart = i
   i = i + 2
   local node = new_block(ps, i, "local_macroexp")
   i, node[BLOCK_INDEXES.LOCAL_MACROEXP.NAME] = read_identifier(ps, i)
   i, node[BLOCK_INDEXES.LOCAL_MACROEXP.EXP] = read_macroexp(ps, istart, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function read_macro_body(ps, i, node)
   local old_in_macro = ps.in_local_macro
   local old_allow = ps.allow_macro_vars
   ps.in_local_macro = true
   ps.allow_macro_vars = false
   i, node = read_function_args_rets_body(ps, i, node)
   ps.in_local_macro = old_in_macro
   ps.allow_macro_vars = old_allow
   return i, node
end

local function register_macro_signature(ps, node, key)
   if key then
      local signature = build_macro_sig(node[BLOCK_INDEXES.LOCAL_MACRO.ARGS], ps.errs, ps.filename, key)
      local spec = read_operator_annotation(ps, node, key)
      signature.operator = spec
      ps.macro_sigs[key] = signature
      if spec then
         node[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR] = operator_spec_block(node, spec)
         ps.macro_sigs[spec.binding] = signature
         if not node[BLOCK_INDEXES.LOCAL_MACRO.OWNER] then register_operator(ps, spec, node) end
      end
   end
end

local function bind_macro_alias(ps, node, signature)
   local name = node[BLOCK_INDEXES.LOCAL_MACRO.NAME]
   local symbol = macro_operator_symbol(name)
   if symbol and not signature.operator then
      operator_error(ps, name, "operator alias must target an operator macro")
      return
   elseif signature.operator and not symbol then
      operator_error(ps, name, "operator aliases must use a parenthesized operator name")
      return
   end
   if symbol then
      local original = signature.operator
      local spec = {
         symbol = symbol, fixity = original.fixity, precedence = original.precedence,
         right_associative = original.right_associative,
         binding = "@operator:" .. ps.filename .. ":" .. tostring(node.y) .. ":" .. tostring(node.x) .. ":" .. name.tk,
      }
      node[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR] = operator_spec_block(node, spec)
      node[BLOCK_INDEXES.LOCAL_MACRO.TARGET] = setmetatable({
         kind = "identifier", tk = original.binding, f = ps.filename, y = name.y, x = name.x,
      }, node_mt)
      signature = { kinds = signature.kinds, vararg = signature.vararg, operator = spec }
      ps.macro_sigs[spec.binding] = signature
      register_operator(ps, spec, node)
   end
   ps.macro_sigs[name.tk] = signature
end

local function read_macro_alias_target(ps, i, node)
   i = verify_tk(ps, i, "=")

   local target
   i, target = read_macro_name(ps, i)
   if not target then
      return i, node
   end

   while ps.tokens[i].tk == "." do
      local dot = new_block(ps, i, "op_dot")
      dot[BLOCK_INDEXES.OP.E1] = target
      i = i + 1
      i, dot[BLOCK_INDEXES.OP.E2] = read_macro_name(ps, i)
      if not dot[BLOCK_INDEXES.OP.E2] then
         return i, node
      end
      target = dot
   end

   i = verify_tk(ps, i, "!")
   node[BLOCK_INDEXES.LOCAL_MACRO.TARGET] = target
   local key = path_block_to_string(target)
   local signature = key and ps.macro_sigs[key]
   if not signature and key then
      local alias = key:match("^([^.]+)%.")
      if alias then ensure_required_alias_macros(ps, alias); signature = ps.macro_sigs[key] end
   end
   if signature then
      bind_macro_alias(ps, node, signature)
   end
   if not signature then table.insert(ps.macro_aliases, node) end
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function read_local_macro(ps, i)
   local istart = i
   i = verify_tk(ps, i, "local")
   i = verify_tk(ps, i, "macro")
   local node = new_block(ps, istart, "local_macro")
   i, node[BLOCK_INDEXES.LOCAL_MACRO.NAME] = read_macro_name(ps, i)
   i = verify_tk(ps, i, "!")
   if ps.tokens[i].tk == "=" then
      return read_macro_alias_target(ps, i, node)
   end

   i, node = read_macro_body(ps, i, node)
   if node[BLOCK_INDEXES.LOCAL_MACRO.NAME] and node[BLOCK_INDEXES.LOCAL_MACRO.NAME].kind == "identifier" then
      register_macro_signature(ps, node, node[BLOCK_INDEXES.LOCAL_MACRO.NAME].tk)
   end
   return i, node
end

local function read_attached_macro(ps, i)
   local istart = i
   i = verify_tk(ps, i, "macro")

   local names = {}
   local dot_pos = {}

   i, names[1] = read_identifier(ps, i)
   if not names[1] then
      return fail(ps, i, "expected macro owner path")
   end

   while ps.tokens[i] and ps.tokens[i].tk == "." do
      table.insert(dot_pos, i)
      i = i + 1
      local part
      i, part = read_macro_name(ps, i)
      if not part then
         return fail(ps, i, "expected macro name")
      end
      table.insert(names, part)
      if macro_operator_symbol(part) then break end
   end

   if #names < 2 then
      return fail(ps, i, "attached macros must use the form 'macro Record.name!()'")
   end

   local owner = names[1]
   for n = 2, #names - 1 do
      local dot = new_block(ps, dot_pos[n - 1], "op_dot")
      dot[BLOCK_INDEXES.OP.E1] = owner
      dot[BLOCK_INDEXES.OP.E2] = names[n]
      owner = dot
   end

   local node = new_block(ps, istart, "local_macro")
   node[BLOCK_INDEXES.LOCAL_MACRO.OWNER] = owner
   node[BLOCK_INDEXES.LOCAL_MACRO.NAME] = names[#names]

   i = verify_tk(ps, i, "!")

   i, node = read_macro_body(ps, i, node)

   local owner_key = path_block_to_string(node[BLOCK_INDEXES.LOCAL_MACRO.OWNER])
   local name = node[BLOCK_INDEXES.LOCAL_MACRO.NAME] and node[BLOCK_INDEXES.LOCAL_MACRO.NAME].tk
   if owner_key and name then
      register_macro_signature(ps, node, owner_key .. "." .. name)
   end

   return i, node
end

local function resolve_macro_aliases(ps)
   local pending = ps.macro_aliases

   while #pending > 0 do
      local unresolved = {}
      local resolved_any = false

      for _, node in ipairs(pending) do
         local name = node[BLOCK_INDEXES.LOCAL_MACRO.NAME]
         local target = node[BLOCK_INDEXES.LOCAL_MACRO.TARGET]
         local target_key = path_block_to_string(target)
         local sig = target_key and ps.macro_sigs[target_key]

         if not sig and target_key then
            local require_alias = target_key:match("^([^.]+)%.")
            if require_alias then
               ensure_required_alias_macros(ps, require_alias)
               sig = ps.macro_sigs[target_key]
            end
         end

         if name and sig then
            if not ps.macro_sigs[name.tk] or not node[BLOCK_INDEXES.LOCAL_MACRO.OPERATOR] then bind_macro_alias(ps, node, sig) end
            resolved_any = true
         else
            table.insert(unresolved, node)
         end
      end

      if #unresolved == 0 then
         return
      end
      if not resolved_any then
         for _, node in ipairs(unresolved) do
            local target = node[BLOCK_INDEXES.LOCAL_MACRO.TARGET]
            table.insert(ps.errs, {
               filename = ps.filename,
               y = target.y,
               x = target.x,
               msg = "unknown macro '" .. (path_block_to_string(target) or "") .. "'",
            })
         end
         return
      end

      pending = unresolved
   end
end

local function read_local(ps, i)
   local ntk = ps.tokens[i + 1].tk
   if ntk == "function" then
      return read_local_function(ps, i)
   elseif ntk == "type" and (ps.tokens[i + 2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i + 2].tk == "$")) then
      return read_type_declaration(ps, i + 2, "local_type")
   elseif ntk == "macro" and (ps.tokens[i + 2].kind == "identifier" or ps.tokens[i + 2].tk == "(") then
      return read_local_macro(ps, i)
   elseif ntk == "macroexp" and ps.tokens[i + 2].kind == "identifier" then
      return read_local_macroexp(ps, i)
   elseif type_body_kinds[ntk] and (ps.tokens[i + 2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i + 2].tk == "$")) then
      local ntk_kind = type_body_kinds[ntk]
      return read_type_constructor(ps, i, "local_type", ntk_kind)
   end
   return read_variable_declarations(ps, i + 1, "local_declaration")
end

local function read_global(ps, i)
   local ntk = ps.tokens[i + 1].tk
   if ntk == "function" then
      i = verify_tk(ps, i, "global")
      i = verify_tk(ps, i, "function")
      local func_start = i - 1
      local fn = new_block(ps, i - 2, "global_function")
      i, fn[BLOCK_INDEXES.GLOBAL_FUNCTION.NAME] = read_identifier(ps, i)
      if ps.tokens[i].tk == "." or ps.tokens[i].tk == ":" then
         local ni = skip_any_function(ps, func_start)
         fail(ps, func_start, "record functions cannot be annotated as 'global'")
         return ni
      end
      return read_function_args_rets_body(ps, i, fn)
   elseif ntk == "type" and ps.tokens[i + 2].kind == "identifier" then
      return read_type_declaration(ps, i + 2, "global_type")
   elseif type_body_kinds[ntk] and (ps.tokens[i + 2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i + 2].tk == "$")) then
      local ntk_kind = type_body_kinds[ntk]
      return read_type_constructor(ps, i, "global_type", ntk_kind)
   elseif ps.tokens[i + 1].kind == "identifier" then
      return read_variable_declarations(ps, i + 1, "global_declaration")
   end
   return read_call_or_assignment(ps, i)
end

read_record_function = function(ps, i)
   i = verify_tk(ps, i, "function")

   local fn = new_block(ps, i - 1, "record_function")

   local names = {}
   local dot_pos = {}

   local function read_name_piece(ps2, ii)
      if ps2.allow_macro_vars and ps2.tokens[ii].tk == "$" then
         local dtk = ps2.tokens[ii]
         ii = ii + 1
         local ident
         ii, ident = read_identifier(ps2, ii)
         if not ident then
            return fail(ps2, ii, "syntax error, expected identifier")
         end
         local macro_var = { f = ps2.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
         return ii, macro_var
      end
      local nii
      local nb
      nii, nb = read_identifier(ps2, ii)
      return nii, nb
   end

   i, names[1] = read_name_piece(ps, i)

   while ps.tokens[i] and ps.tokens[i].tk == "." do
      table.insert(dot_pos, i)
      i = i + 1
      i, names[#names + 1] = read_name_piece(ps, i)
   end

   if ps.tokens[i] and ps.tokens[i].tk == ":" then
      fn.tk = ":"
      i = i + 1
      i, names[#names + 1] = read_identifier(ps, i)
   end

   if #names > 1 or fn.tk == ":" then
      local owner = names[1]
      for n = 2, #names - 1 do
         local dot_block = new_block(ps, dot_pos[n - 1], "op_dot")
         dot_block[BLOCK_INDEXES.OP.E1] = owner
         dot_block[BLOCK_INDEXES.OP.E2] = names[n]
         owner = dot_block
      end
      fn[BLOCK_INDEXES.RECORD_FUNCTION.OWNER] = owner
      fn[BLOCK_INDEXES.RECORD_FUNCTION.NAME] = names[#names]
   else
      fn[BLOCK_INDEXES.RECORD_FUNCTION.OWNER] = names[1]
   end

   local istart = i - 1
   i, fn[BLOCK_INDEXES.RECORD_FUNCTION.TYPEARGS] = read_typeargs_if_any(ps, i)
   i, fn[BLOCK_INDEXES.RECORD_FUNCTION.ARGS] = read_argument_list(ps, i)
   i, fn[BLOCK_INDEXES.RECORD_FUNCTION.RETS] = read_return_types(ps, i)
   i, fn[BLOCK_INDEXES.RECORD_FUNCTION.BODY] = read_statements(ps, i)

   end_at(fn, ps.tokens[i])
   i = verify_end(ps, i, istart, fn)
   return i, fn
end

local function read_pragma(ps, i)
   i = i + 1
   local pragma = new_block(ps, i, "pragma")

   if ps.tokens[i].kind ~= "pragma_identifier" then
      return fail(ps, i, "expected pragma name")
   end
   pragma[BLOCK_INDEXES.PRAGMA.KEY] = new_block(ps, i, "identifier")
   pragma[BLOCK_INDEXES.PRAGMA.KEY].tk = ps.tokens[i].tk
   i = i + 1

   if ps.tokens[i].kind ~= "pragma_identifier" then
      return fail(ps, i, "expected pragma value")
   end
   pragma[BLOCK_INDEXES.PRAGMA.VALUE] = new_block(ps, i, "identifier")
   pragma[BLOCK_INDEXES.PRAGMA.VALUE].tk = ps.tokens[i].tk
   i = i + 1

   return i, pragma
end

read_statement_fns = {
   ["--#pragma"] = read_pragma,
   ["::"] = read_label,
   ["do"] = read_do,
   ["if"] = read_if,
   ["for"] = read_for,
   ["goto"] = read_goto,
   ["const"] = function(ps, i)
      if ps.tokens[i + 1].tk ~= "function" and ps.tokens[i + 1].kind ~= "identifier" then
         return read_call_or_assignment(ps, i)
      end
      local node
      i, node = read_local(ps, i)
      if node and node.kind == "local_function" then
         node[BLOCK_INDEXES.LOCAL_FUNCTION.CONST] = new_block(ps, i, "native_const")
      elseif node and node.kind == "local_declaration" then
         node[BLOCK_INDEXES.LOCAL_DECLARATION.CONST] = new_block(ps, i, "native_const")
      end
      return i, node
   end,
   ["continue"] = function(ps, i)
      local next_tk = ps.tokens[i + 1]
      if next_tk.tk == ";" or next_tk.kind == "$EOF$" or stop_statement_list[next_tk.tk] then
         return i + 1, new_block(ps, i, "continue")
      end
      return read_call_or_assignment(ps, i)
   end,
   ["local"] = read_local,
   ["while"] = read_while,
   ["break"] = read_break,
   ["global"] = read_global,
   ["repeat"] = read_repeat,
   ["return"] = read_return,
   ["function"] = read_record_function,
}

local function type_needs_local_or_global(ps, i)
   local tk = ps.tokens[i].tk
   return failskip(ps, i, ("%s needs to be declared with 'local %s' or 'global %s'"):format(tk, tk, tk), skip_type_body)
end

needs_local_or_global = {
   ["type"] = function(ps, i)
      return failskip(ps, i, "types need to be declared with 'local type' or 'global type'", skip_type_declaration)
   end,
   ["record"] = type_needs_local_or_global,
   ["enum"] = type_needs_local_or_global,
}

read_statements = function(ps, i, toplevel)
   local outer_operators = ps.custom_operators
   local outer_macro_sigs = ps.macro_sigs
   ps.macro_sigs = {}
   for key, signature in pairs(outer_macro_sigs) do ps.macro_sigs[key] = signature end
   local outer_local_operators = ps.local_operators
   ps.local_operators = {}
   local operators = { prefix = {}, infix = {}, postfix = {} }
   for fixity, bindings in pairs(outer_operators) do
      for symbol, spec in pairs(bindings) do operators[fixity][symbol] = spec end
   end
   ps.custom_operators = operators
   local node = new_block(ps, i, "statements")
   local item
   while true do
      while ps.tokens[i].kind == ";" do
         i = i + 1
         table.insert(node, new_block(ps, i - 1, ";"))
      end

      if ps.tokens[i].kind == "$EOF$" then
         break
      end
      local tk = ps.tokens[i].tk
      local comment_blocks = collect_comment_blocks(ps, i)
      for _, cb in ipairs(comment_blocks) do
         table.insert(node, cb)
      end

      if (not toplevel) and stop_statement_list[tk] then
         break
      end

      if tk == "macro" then
         if not toplevel then
            i = fail(ps, i, "attached macro declarations are only allowed at top level")
            item = nil
         else
            i, item = read_attached_macro(ps, i)
         end
      else
         local fn = read_statement_fns[tk]
         if not fn then
            local skip_fn = needs_local_or_global[tk]
            if skip_fn and ps.tokens[i + 1].kind == "identifier" then
               fn = skip_fn
            else
               fn = read_call_or_assignment
            end
         end

         i, item = fn(ps, i)
      end

      if item then
         table.insert(node, item)
         if toplevel and (item.kind == "local_declaration" or item.kind == "local_type") then
            local alias, module_name = local_require_alias(item)
            if alias and module_name then
               ps.require_aliases[alias] = module_name
            end
         end
      elseif i > 1 then

         local lasty = ps.tokens[i - 1].y
         while ps.tokens[i].kind ~= "$EOF$" and ps.tokens[i].y == lasty do
            i = i + 1
         end
      end
   end

   end_at(node, ps.tokens[i])
   ps.custom_operators = outer_operators
   ps.local_operators = outer_local_operators
   if not toplevel then ps.macro_sigs = outer_macro_sigs end
   return i, node
end

function reader.read_program(tokens, errs, filename, read_lang, allow_macro_vars, skip_macro_expand, operator_context, in_macro_quote)
   if read_program_depth == 0 then
      module_macro_cache = {}
      module_macro_missing = {}
      module_macro_loading = {}
   end
   read_program_depth = read_program_depth + 1

   errs = errs or {}
   filename = filename or "input"
   read_lang = read_lang or lang_heuristic(filename)
   if allow_macro_vars == nil then
      allow_macro_vars = true
   end
   local ps = {
      tokens = tokens,
      errs = errs,
      filename = filename,
      read_lang = read_lang,
      allow_macro_vars = allow_macro_vars or false,
      in_local_macro = false,
      in_macro_quote = in_macro_quote or false,
      custom_operators = operator_context or { prefix = {}, infix = {}, postfix = {} },
      local_operators = {},
      macro_sigs = {},
      require_aliases = {},
      imported_macro_decls = {},
      imported_macro_keys = {},
      macro_aliases = {},
   }
   if operator_context then
      for _, fixity in ipairs({ "prefix", "postfix", "infix" }) do
         for symbol, spec in pairs(operator_context[fixity] or {}) do
            local signature = { kinds = { "expr" }, vararg = "", operator = spec }
            if fixity == "infix" then signature.kinds[2] = "expr" end
            ps.macro_sigs["(" .. symbol .. ")"] = signature
            ps.macro_sigs[spec.binding] = signature
         end
      end
   end
   local i = 1
   local hashbang
   if ps.tokens[i].kind == "hashbang" then
      hashbang = ps.tokens[i].tk
      i = i + 1
   end
   local _, node = read_statements(ps, i, true)
   if hashbang then
      table.insert(node, 1, new_block(ps, 1, "hashbang"))
   end
   resolve_macro_aliases(ps)

   for _, decl in ipairs(ps.imported_macro_decls) do
      table.insert(node, decl)
   end

   validate_attached_macro_owners(node, errs, filename)

   local seen = setmetatable({}, { __mode = "k" })

   local function check_macro_arity(b)
      if seen[b] then return end
      seen[b] = true
      if b.kind == "macro_invocation" then
         local m = b[BLOCK_INDEXES.MACRO_INVOCATION.MACRO]
         local args = b[BLOCK_INDEXES.MACRO_INVOCATION.ARGS]
         local name, has_colon = macro_target_key(m)
         if has_colon then
            table.insert(ps.errs, {
               filename = ps.filename,
               y = m.y,
               x = m.x,
               msg = "method-style macro invocation is not supported; use owner.macro!()",
            })
         elseif name then
            local sig = ps.macro_sigs[name]
            if not sig then
               local alias = name:match("^([^.]+)%.")
               if alias then
                  ensure_required_alias_macros(ps, alias)
                  sig = ps.macro_sigs[name]
               end
            end
            if sig then
               local provided = args and #args or 0
               local required = #sig.kinds
               local has_vararg = sig.vararg ~= ""
               if provided < required or ((not has_vararg) and provided > required) then
                  local msg = "macro '" .. name .. "' expects " .. tostring(required) .. (required == 1 and " argument" or " arguments") .. ", got " .. tostring(provided)
                  table.insert(ps.errs, { filename = ps.filename, y = m.y, x = m.x, msg = msg })
               end
            end
         end
      end
      for i2 = 1, block.child_limit(b) do
         local child = b[i2]
         if child then
            check_macro_arity(child)
         end
      end
   end

   check_macro_arity(node)

   local lang = read_lang or "tl"


   if not skip_macro_expand and #errs == 0 then
      local function parse_expression(source)
         local program, parse_errors = reader.read("return " .. source, filename, lang, false, true)
         if #parse_errors > 0 then error("invalid expression: " .. parse_errors[1].msg, 0) end
         if #program ~= 1 or program[1].kind ~= "return" then
            error("expected a single expression", 0)
         end
         local expressions = program[1][BLOCK_INDEXES.RETURN.EXPS]
         if not expressions or #expressions ~= 1 then error("expected a single expression", 0) end
         return expressions[1]
      end
      node = macro_eval.compile_all_and_expand(node, filename, lang, errs, parse_expression)
   elseif not skip_macro_expand then




      local recovered = {}
      local function recover_macro_declarations(b)
         if recovered[b] then return end
         recovered[b] = true
         if b.kind == "local_macro" then
            for j = 1, block.child_limit(b) do b[j] = nil end
            b.kind = "error_block"
         else
            for j = 1, block.child_limit(b) do
               if b[j] then recover_macro_declarations(b[j]) end
            end
         end
      end
      recover_macro_declarations(node)
   end

   local validating_continue = {}
   local function validate_continue(b, loop, pending)
      if validating_continue[b] then return end
      validating_continue[b] = true
      if b.kind == "function" or b.kind == "local_function" or b.kind == "global_function" or b.kind == "record_function" then
         loop = nil
         pending = {}
      elseif b.kind == "while" or b.kind == "fornum" or b.kind == "forin" or b.kind == "repeat" then
         loop = b
         pending = {}
      elseif b.kind == "continue" then
         if not loop then
            table.insert(errs, { filename = filename, y = b.y, x = b.x, msg = "continue outside a loop" })
         elseif loop.kind == "repeat" then
            table.insert(pending, b)
         end
      end
      local indexes = {}
      for key, _ in pairs(b) do
         if not (type(key) == "string") then table.insert(indexes, key) end
      end
      table.sort(indexes)
      for _, j in ipairs(indexes) do
         local child = b[j]
         if b.kind == "statements" and (child.kind == "local_declaration" or child.kind == "local_function" or child.kind == "local_type") and loop and loop.kind == "repeat" and b == loop[BLOCK_INDEXES.REPEAT.BODY] then
            for _, jump in ipairs(pending) do
               table.insert(errs, { filename = filename, y = jump.y, x = jump.x, msg = "continue jumps into scope of a local variable" })
            end
         end
         if child.kind == "continue" then
            local following = b[j + 1]
            while following and following.kind == ";" do j = j + 1; following = b[j + 1] end
            if following then
               table.insert(errs, { filename = filename, y = child.y, x = child.x, msg = "continue must be the last statement of its block" })
            end
         end
         validate_continue(child, loop, pending)
      end
      validating_continue[b] = nil
   end
   if read_program_depth == 1 and not skip_macro_expand then validate_continue(node, nil, {}) end

   errors.clear_redundant_errors(errs)
   read_program_depth = read_program_depth - 1
   return node
end

function reader.read(input, filename, read_lang, allow_macro_vars, skip_macro_expand, operator_context, in_macro_quote)
   filename = filename or "input"
   read_lang = read_lang or lang_heuristic(filename, input)
   local tokens, errs = lexer.lex(input, filename)
   local node = reader.read_program(tokens, errs, filename, read_lang, allow_macro_vars, skip_macro_expand, operator_context, in_macro_quote)
   return node, errs
end

return reader

end

-- module teal.traversal from teal/traversal.lua
package.preload["teal.traversal"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local table = _tl_compat and _tl_compat.table or table; local type = type



local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG

local types = require("teal.types")













local show_type = types.show_type





local traversal = { VisitorCallbacks = {}, Visitor = {} }





































function traversal.fields_of(t, meta)
   local i = 1
   local field_order, fields
   if meta then
      field_order, fields = t.meta_field_order, t.meta_fields
   else
      field_order, fields = t.field_order, t.fields
   end
   if not fields then
      return function()
      end
   end
   return function()
      local name = field_order[i]
      if not name then
         return nil
      end
      i = i + 1
      return name, fields[name]
   end
end


local recurse_type

local function aggregate_type_walker(s, ast, visit)
   local xs = {}
   for i, child in ipairs(ast.types) do
      xs[i] = recurse_type(s, child, visit)
   end
   return xs
end

local function record_like_type_walker(s, ast, visit)
   local xs = {}
   if ast.interface_list then
      for _, child in ipairs(ast.interface_list) do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   if ast.elements then
      table.insert(xs, recurse_type(s, ast.elements, visit))
   end
   if ast.fields then
      for _, child in traversal.fields_of(ast) do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   if ast.meta_fields then
      for _, child in traversal.fields_of(ast, "meta") do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end

   if ast.types then
      for _, child in ipairs(ast.types) do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   return xs
end

local type_walkers = {
   ["typevar"] = false,
   ["unresolved_typearg"] = false,
   ["unresolvable_typearg"] = false,
   ["self"] = false,
   ["enum"] = false,
   ["boolean"] = false,
   ["string"] = false,
   ["nil"] = false,
   ["thread"] = false,
   ["userdata"] = false,
   ["number"] = false,
   ["integer"] = false,
   ["circular_require"] = false,
   ["boolean_context"] = false,
   ["emptytable"] = false,
   ["unresolved_emptytable_value"] = false,
   ["any"] = false,
   ["unknown"] = false,
   ["invalid"] = false,
   ["none"] = false,
   ["*"] = false,

   ["generic"] = function(s, ast, visit)
      local xs = {}
      for _, child in ipairs(ast.typeargs) do
         table.insert(xs, recurse_type(s, child, visit))
      end
      table.insert(xs, recurse_type(s, ast.t, visit))
      return xs
   end,
   ["tuple"] = function(s, ast, visit)
      local xs = {}
      for i, child in ipairs(ast.tuple) do
         xs[i] = recurse_type(s, child, visit)
      end
      return xs
   end,
   ["union"] = aggregate_type_walker,
   ["tupletable"] = aggregate_type_walker,
   ["poly"] = aggregate_type_walker,
   ["map"] = function(s, ast, visit)
      return {
         recurse_type(s, ast.keys, visit),
         recurse_type(s, ast.values, visit),
      }
   end,
   ["record"] = record_like_type_walker,
   ["interface"] = record_like_type_walker,
   ["function"] = function(s, ast, visit)
      local xs = {}
      if ast.args then
         for _, child in ipairs(ast.args.tuple) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      if ast.rets then
         for _, child in ipairs(ast.rets.tuple) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      return xs
   end,
   ["nominal"] = function(s, ast, visit)
      local xs = {}
      if ast.typevals then
         for _, child in ipairs(ast.typevals) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      return xs
   end,
   ["typearg"] = function(s, ast, visit)
      return {
         ast.constraint and recurse_type(s, ast.constraint, visit),
      }
   end,
   ["array"] = function(s, ast, visit)
      return {
         recurse_type(s, ast.elements, visit),
      }
   end,
   ["literal_table_item"] = function(s, ast, visit)
      return {
         recurse_type(s, ast.ktype, visit),
         recurse_type(s, ast.vtype, visit),
      }
   end,
   ["typedecl"] = function(s, ast, visit)
      return {
         recurse_type(s, ast.def, visit),
      }
   end,
}

recurse_type = function(s, ast, visit)
   local kind = ast.typename

   if TL_DEBUG then
      tldebug.indent_push("---", ast.y, ast.x, "[%s] = %s", kind, show_type(ast))
   end

   local cbs = visit.cbs
   local cbkind = cbs and cbs[kind]
   if cbkind then
      local cbkind_before = cbkind.before
      if cbkind_before then
         cbkind_before(s, ast)
      end
   end

   local xs
   local walker = type_walkers[ast.typename]
   if not (type(walker) == "boolean") then
      xs = walker(s, ast, visit)
   end

   local ret
   local cbkind_after = cbkind and cbkind.after
   if cbkind_after then
      ret = cbkind_after(s, ast, xs)
   end
   local visit_after = visit.after
   if visit_after then
      ret = visit_after(s, ast, xs, ret)
   end

   if TL_DEBUG then
      tldebug.indent_pop("---", "---", ast.y, ast.x)
   end

   return ret
end

local function recurse_typeargs(s, ast, visit_type)
   if ast.typeargs then
      for _, typearg in ipairs(ast.typeargs) do
         recurse_type(s, typearg, visit_type)
      end
   end
end

local function extra_callback(name,
   s,
   ast,
   xs,
   visit_node)
   local cbs = visit_node.cbs
   if not cbs then return end
   local nbs = cbs[ast.kind]
   if not nbs then return end
   local bs = nbs[name]
   if not bs then return end
   bs(s, ast, xs)
end

local no_traverse_nodes = {
   ["..."] = true,
   ["nil"] = true,
   ["cast"] = true,
   ["goto"] = true,
   ["break"] = true,
   ["continue"] = true,
   ["label"] = true,
   ["number"] = true,
   ["pragma"] = true,
   ["string"] = true,
   ["boolean"] = true,
   ["integer"] = true,
   ["variable"] = true,
   ["error_node"] = true,
   ["identifier"] = true,
   ["type_identifier"] = true,
}

function traversal.traverse_nodes(s, root,
   visit_node,
   visit_type)
   if not root then

      return
   end

   local recurse

   local function walk_children(ast, xs)
      local callbacks = visit_node.cbs and visit_node.cbs[ast.kind]
      local order = callbacks and callbacks.child_order and callbacks.child_order(s, ast)
      if order then
         for _, i in ipairs(order) do
            if callbacks.before_child then callbacks.before_child(s, ast, xs, i) end
            xs[i] = recurse(ast[i])
         end
         return
      end
      for i, child in ipairs(ast) do
         if callbacks and callbacks.before_child then callbacks.before_child(s, ast, xs, i) end
         xs[i] = recurse(child)
      end
   end

   local function walk_vars_exps(ast, xs)
      xs[1] = recurse(ast.vars)
      if ast.decltuple then
         xs[2] = recurse_type(s, ast.decltuple, visit_type)
      end
      extra_callback("before_exp", s, ast, xs, visit_node)
      if ast.exps then
         xs[3] = recurse(ast.exps)
      end
   end

   local function walk_named_function(ast, xs)
      recurse_typeargs(s, ast, visit_type)
      xs[1] = recurse(ast.name)
      xs[2] = recurse(ast.args)
      xs[3] = recurse_type(s, ast.rets, visit_type)
      extra_callback("before_statements", s, ast, xs, visit_node)
      xs[4] = recurse(ast.body)
   end

   local walkers = {
      ["conditional"] = function(ast, xs)
         xs[1] = recurse(ast.e1)
         extra_callback("before_e2", s, ast, xs, visit_node)
         xs[2] = recurse(ast.e2)
         extra_callback("before_e3", s, ast, xs, visit_node)
         xs[3] = recurse(ast.e3)
      end,
      ["op"] = function(ast, xs)
         xs[1] = recurse(ast.e1)
         local p1 = ast.e1.op and ast.e1.op.prec or nil
         if ast.op.op == ":" and ast.e1.kind == "string" then
            p1 = -999
         end
         xs[2] = p1
         if ast.op.arity == 2 then
            extra_callback("before_e2", s, ast, xs, visit_node)
            if ast.op.op == "is" or ast.op.op == "as" then
               xs[3] = recurse_type(s, ast.e2.casttype, visit_type)
            else
               xs[3] = recurse(ast.e2)
            end
            xs[4] = (ast.e2.op and ast.e2.op.prec)
         end
      end,

      ["statements"] = walk_children,
      ["argument_list"] = walk_children,
      ["literal_table"] = walk_children,
      ["variable_list"] = walk_children,
      ["expression_list"] = walk_children,

      ["literal_table_item"] = function(ast, xs)
         xs[1] = recurse(ast.key)
         xs[2] = recurse(ast.value)
         if ast.itemtype then
            xs[3] = recurse_type(s, ast.itemtype, visit_type)
         end
      end,

      ["assignment"] = walk_vars_exps,
      ["local_declaration"] = walk_vars_exps,
      ["global_declaration"] = walk_vars_exps,

      ["local_type"] = function(ast, xs)


         xs[1] = recurse(ast.var)
         xs[2] = recurse(ast.value)
      end,

      ["global_type"] = function(ast, xs)


         xs[1] = recurse(ast.var)
         if ast.value then
            xs[2] = recurse(ast.value)
         end
      end,

      ["if"] = function(ast, xs)
         for _, e in ipairs(ast.if_blocks) do
            table.insert(xs, recurse(e))
         end
      end,

      ["if_block"] = function(ast, xs)
         if ast.exp then
            xs[1] = recurse(ast.exp)
         end
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[2] = recurse(ast.body)
      end,

      ["while"] = function(ast, xs)
         xs[1] = recurse(ast.exp)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[2] = recurse(ast.body)
      end,

      ["repeat"] = function(ast, xs)
         xs[1] = recurse(ast.body)
         xs[2] = recurse(ast.exp)
      end,

      ["macroexp"] = function(ast, xs)
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.args)
         xs[2] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_exp", s, ast, xs, visit_node)
         xs[3] = recurse(ast.exp)
      end,

      ["function"] = function(ast, xs)
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.args)
         xs[2] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[3] = recurse(ast.body)
      end,
      ["local_function"] = walk_named_function,
      ["global_function"] = walk_named_function,
      ["record_function"] = function(ast, xs)
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.fn_owner)
         xs[2] = recurse(ast.name)
         extra_callback("before_arguments", s, ast, xs, visit_node)
         xs[3] = recurse(ast.args)
         xs[4] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[5] = recurse(ast.body)
      end,
      ["local_macroexp"] = function(ast, xs)

         xs[1] = recurse(ast.name)
         xs[2] = recurse(ast.macrodef.args)
         xs[3] = recurse_type(s, ast.macrodef.rets, visit_type)
         extra_callback("before_exp", s, ast, xs, visit_node)
         xs[4] = recurse(ast.macrodef.exp)
      end,

      ["forin"] = function(ast, xs)
         xs[1] = recurse(ast.vars)
         xs[2] = recurse(ast.exps)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[3] = recurse(ast.body)
      end,

      ["fornum"] = function(ast, xs)
         xs[1] = recurse(ast.var)
         xs[2] = recurse(ast.from)
         xs[3] = recurse(ast.to)
         xs[4] = ast.step and recurse(ast.step)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[5] = recurse(ast.body)
      end,

      ["return"] = function(ast, xs)
         xs[1] = recurse(ast.exps)
      end,

      ["do"] = function(ast, xs)
         xs[1] = recurse(ast.body)
      end,

      ["paren"] = function(ast, xs)
         xs[1] = recurse(ast.e1)
      end,

      ["newtype"] = function(ast, xs)
         xs[1] = recurse_type(s, ast.newtype, visit_type)
      end,

      ["argument"] = function(ast, xs)
         if ast.argtype then
            xs[1] = recurse_type(s, ast.argtype, visit_type)
         end
      end,
   }

   if not visit_node.allow_missing_cbs and not visit_node.cbs then
      error("missing cbs in visit_node")
   end
   local visit_after = visit_node.after

   recurse = function(ast)
      local xs = {}
      local kind = assert(ast.kind)
      local kprint

      local cbs = visit_node.cbs
      local cbkind = cbs and cbs[kind]
      if cbkind then
         if cbkind.before then
            cbkind.before(s, ast)
         end
      end

      if TL_DEBUG then
         if ast.y > tldebug.TL_DEBUG_MAXLINE then
            error("Halting execution at input line " .. ast.y)
         end
         kprint = kind == "op" and "op " .. ast.op.op or
         kind == "identifier" and "identifier " .. ast.tk or
         kind
         tldebug.indent_push("{{{", ast.y, ast.x, "[%s]", kprint)
      end

      local fn = walkers[kind]
      if fn then
         fn(ast, xs)
      else
         assert(no_traverse_nodes[kind], kind)
      end

      local ret
      local cbkind_after = cbkind and cbkind.after
      if cbkind_after then
         ret = cbkind_after(s, ast, xs)
      end
      if visit_after then
         ret = visit_after(s, ast, xs, ret)
      end

      if TL_DEBUG then
         local typ = ast.debug_type and " = " .. show_type(ast.debug_type) or ""
         tldebug.indent_pop("}}}", "***", ast.y, ast.x, "[%s]%s", kprint, typ)
      end

      return ret
   end

   return recurse(root)
end

return traversal

end

-- module teal.type_errors from teal/type_errors.lua
package.preload["teal.type_errors"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local type = type
local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG

local types = require("teal.types")







local a_type = types.a_type

local parser = require("teal.parser")









local variables = require("teal.variables")


local has_var_been_used = variables.has_var_been_used

local type_errors = { Errors = {} }













local Errors = type_errors.Errors

function Errors.new(filename)
   local self = {
      errors = {},
      warnings = {},
      unknown_dots = {},
      filename = filename,
   }
   return setmetatable(self, { __index = Errors })
end

local function insert_error(self, y, x, f, err)
   err.y = assert(y)
   err.x = assert(x)
   err.filename = assert(f)

   if TL_DEBUG then
      tldebug.write("ERROR:" .. err.y .. ":" .. err.x .. ": " .. err.msg .. "\n")
   end

   table.insert(self.errors, err)
end

function Errors:add(w, msg, t, ...)
   local e
   if t then
      e = types.error(msg, t, ...)
   else
      e = { msg = msg }
   end
   if e then
      insert_error(self, w.y, w.x, w.f, e)
   end
end

type_errors.context_name = {
   ["local_declaration"] = "in local declaration",
   ["global_declaration"] = "in global declaration",
   ["assignment"] = "in assignment",
   ["literal_table_item"] = "in table item",
}

function Errors:node_context(ctx, name)
   assert(ctx)
   local ec = ctx.expected_context
   local cn = type_errors.context_name[ec and ec.kind or ctx.kind]
   return (cn and cn .. ": " or "") .. (ec and ec.name and ec.name .. ": " or "") .. (name and name .. ": " or "")
end

function Errors:string_context(ctx, name)
   assert(ctx)
   local cn = ctx
   return (cn .. ": " or "") .. (name and name .. ": " or "")
end

function Errors:get_context(ctx, name)
   assert(ctx)
   local ec = (ctx.kind ~= nil) and ctx.expected_context
   local cn = (type(ctx) == "string") and ctx or
   (ctx.kind ~= nil) and type_errors.context_name[ec and ec.kind or ctx.kind]
   return (cn and cn .. ": " or "") .. (ec and ec.name and ec.name .. ": " or "") .. (name and name .. ": " or "")
end

function Errors:add_in_context(w, ctx, msg, ...)
   if ctx then
      local prefix = self:get_context(ctx)
      msg = prefix .. msg
   end
   return self:add(w, msg, ...)
end


function Errors:collect(errs)
   for _, e in ipairs(errs) do
      insert_error(self, e.y, e.x, e.filename, e)
   end
end

function Errors:add_warning(tag, w, fmt, ...)
   assert(w.y)
   table.insert(self.warnings, {
      y = w.y,
      x = w.x,
      msg = fmt:format(...),
      filename = assert(w.f),
      tag = tag,
   })
end

function Errors:invalid_at(w, msg, ...)
   self:add(w, msg, ...)
   return a_type(w, "invalid", {})
end

function Errors:add_unknown(w, name)
   self:add_warning("unknown", w, "unknown variable: %s", name)
end

function Errors:redeclaration_warning(at, var_name, var_kind, old_var)
   if var_name:sub(1, 1) == "_" then return end

   local short_error = var_kind .. " shadows previous declaration of '%s'"
   if old_var and old_var.declared_at and (not old_var.is_global) then
      self:add_warning("redeclaration", at, short_error .. " (originally declared at %d:%d)", var_name, old_var.declared_at.y, old_var.declared_at.x)
   else
      self:add_warning("redeclaration", at, short_error, var_name)
   end
end

local function var_should_be_ignored_for_warnings(name, var)
   local prefix = name:sub(1, 1)
   return (not var.declared_at) or
   var.is_global or
   var.is_specialized == "narrow" or
   prefix == "_" or
   prefix == "@"
end

local function user_facing_variable_description(var)
   local t = var.t
   return var.is_func_arg and "argument" or
   t.typename == "function" and "function" or
   t.typename == "typedecl" and "type" or
   "variable"
end

function Errors:unused_warning(name, var)
   if var_should_be_ignored_for_warnings(name, var) then
      return
   end
   self:add_warning(
   "unused",
   var.declared_at,
   "unused %s %s: %s",
   user_facing_variable_description(var),
   name,
   types.show_type(var.t))

end

function Errors:add_prefixing(w, src, prefix, dst)
   if not src then
      return
   end

   for _, err in ipairs(src) do
      err.msg = prefix .. err.msg
      if w and (
         (err.filename ~= w.f) or
         (not err.y) or
         (w.y > err.y or (w.y == err.y and w.x > err.x))) then

         err.y = w.y
         err.x = w.x
         err.filename = w.f
      end

      if dst then
         table.insert(dst, err)
      else
         insert_error(self, err.y, err.x, err.filename, err)
      end
   end
end

local function ensure_not_abstract_type(def, node)
   if def.typename == "record" then
      return true
   elseif def.typename == "generic" then
      return ensure_not_abstract_type(def.t)
   elseif node and parser.node_is_require_call(node) then
      return nil, "module type is abstract: " .. tostring(def)
   elseif def.typename == "interface" then
      return nil, "interfaces are abstract; consider using a concrete record"
   end
   return nil, "cannot use a type definition as a concrete value"
end

function type_errors.ensure_not_abstract(t, node)
   if t.typename == "function" and t.macroexp then
      return nil, "macroexps are abstract; consider using a concrete function"
   elseif t.typename == "generic" then
      return type_errors.ensure_not_abstract(t.t, node)
   elseif t.typename == "typedecl" then
      return ensure_not_abstract_type(t.def, node)
   end
   return true
end














local function check_var_usage(scope)
   local vars = scope.vars
   if not next(vars) then
      return
   end
   local usage_warnings
   for name, var in pairs(vars) do
      local t = var.t
      if not var_should_be_ignored_for_warnings(name, var) then
         if var.has_been_written_to and not var.has_been_read_from then
            usage_warnings = usage_warnings or {}
            table.insert(usage_warnings, {
               y = var.declared_at.y,
               x = var.declared_at.x,
               name = name,
               var = var,
               kind = "written but not read",
            })
         end

      end

      if var.declared_at and not has_var_been_used(var) and not var.is_global then
         if var.used_as_type then
            var.declared_at.elide_type = true
         else
            if t.typename == "typedecl" then
               var.declared_at.elide_type = true
            end
            usage_warnings = usage_warnings or {}
            table.insert(usage_warnings, { y = var.declared_at.y, x = var.declared_at.x, name = name, var = var, kind = "unused" })
         end
      elseif has_var_been_used(var) and t.typename == "typedecl" and var.aliasing then
         var.aliasing.has_been_written_to = var.has_been_written_to
         var.aliasing.has_been_read_from = var.has_been_read_from
         if type_errors.ensure_not_abstract(t) then
            var.aliasing.declared_at.elide_type = false
         end
      end
   end
   if usage_warnings then
      table.sort(usage_warnings, function(a, b)
         return a.y < b.y or (a.y == b.y and a.x < b.x)
      end)
   end
   return usage_warnings
end

function Errors:check_var_usage(scope)
   local usage_warnings = check_var_usage(scope)
   if usage_warnings then
      for _, u in ipairs(usage_warnings) do
         if u.kind == "unused" then
            self:unused_warning(u.name, u.var)
         elseif u.kind == "written but not read" then
            self:add_warning(
            "unread",
            u.var.declared_at,
            "%s %s (of type %s) is never read",
            user_facing_variable_description(u.var),
            u.name,
            types.show_type(u.var.t))

         end
      end
   end

   if scope.labels then
      for name, node in pairs(scope.labels) do
         if not node.used_label then
            self:add_warning("unused", node, "unused label ::%s::", name)
         end
      end
   end
end

function Errors:add_unknown_dot(w, name)
   if not self.unknown_dots[name] then
      self.unknown_dots[name] = true
      self:add_unknown(w, name)
   end
end

function Errors:fail_unresolved_labels(scope)
   if scope.pending_labels then
      for name, nodes in pairs(scope.pending_labels) do
         for _, node in ipairs(nodes) do
            self:add(node, "no visible label '" .. name .. "' for goto")
         end
      end
   end
end

function Errors:fail_unresolved_nominals(scope, global_scope)
   if global_scope and scope.pending_nominals then
      for name, typs in pairs(scope.pending_nominals) do
         if not global_scope.pending_global_types[name] then
            for _, typ in ipairs(typs) do
               assert(typ.x)
               assert(typ.y)
               self:add(typ, "unknown type %s", typ)
            end
         end
      end
   end
end

function Errors:check_redeclared_key(w, ctx, seen_keys, key)
   if key ~= nil then
      local s = seen_keys[key]
      if s then
         self:add_in_context(w, ctx, "redeclared key " .. tostring(key) .. " (previously declared at " .. self.filename .. ":" .. s.y .. ":" .. s.x .. ")")
      else
         seen_keys[key] = w
      end
   end
end

return type_errors

end

-- module teal.type_reporter from teal/type_reporter.lua
package.preload["teal.type_reporter"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local types = require("teal.types")












local show_type = types.show_type







local util = require("teal.util")
local binary_search = util.binary_search
local sorted_keys = util.sorted_keys

local type_reporter = { TypeCollector = { Symbol = {} }, TypeInfo = { Location = {} }, TypeReport = {}, TypeReporter = {} }













































































local TypeReport = type_reporter.TypeReport
local TypeReporter = type_reporter.TypeReporter












local typecodes = {

   NIL = 0x00000001,
   NUMBER = 0x00000002,
   BOOLEAN = 0x00000004,
   STRING = 0x00000008,
   TABLE = 0x00000010,
   FUNCTION = 0x00000020,
   USERDATA = 0x00000040,
   THREAD = 0x00000080,

   INTEGER = 0x00010002,
   ENUM = 0x00010004,
   EMPTY_TABLE = 0x00000008,
   ARRAY = 0x00010008,
   RECORD = 0x00020008,
   MAP = 0x00040008,
   TUPLE = 0x00080008,
   INTERFACE = 0x00100008,
   SELF = 0x00200008,
   POLY = 0x20000020,
   UNION = 0x40000000,

   NOMINAL = 0x10000000,
   TYPE_VARIABLE = 0x08000000,

   ANY = 0xffffffff,
   UNKNOWN = 0x80008000,
   INVALID = 0x80000000,
}





local typename_to_typecode = {
   ["typevar"] = typecodes.TYPE_VARIABLE,
   ["typearg"] = typecodes.TYPE_VARIABLE,
   ["unresolved_typearg"] = typecodes.TYPE_VARIABLE,
   ["unresolvable_typearg"] = typecodes.TYPE_VARIABLE,
   ["function"] = typecodes.FUNCTION,
   ["array"] = typecodes.ARRAY,
   ["map"] = typecodes.MAP,
   ["tupletable"] = typecodes.TUPLE,
   ["interface"] = typecodes.INTERFACE,
   ["self"] = typecodes.SELF,
   ["record"] = typecodes.RECORD,
   ["enum"] = typecodes.ENUM,
   ["boolean"] = typecodes.BOOLEAN,
   ["string"] = typecodes.STRING,
   ["nil"] = typecodes.NIL,
   ["thread"] = typecodes.THREAD,
   ["userdata"] = typecodes.USERDATA,
   ["number"] = typecodes.NUMBER,
   ["integer"] = typecodes.INTEGER,
   ["union"] = typecodes.UNION,
   ["nominal"] = typecodes.NOMINAL,
   ["circular_require"] = typecodes.NOMINAL,
   ["boolean_context"] = typecodes.BOOLEAN,
   ["emptytable"] = typecodes.EMPTY_TABLE,
   ["unresolved_emptytable_value"] = typecodes.EMPTY_TABLE,
   ["poly"] = typecodes.POLY,
   ["any"] = typecodes.ANY,
   ["unknown"] = typecodes.UNKNOWN,
   ["invalid"] = typecodes.INVALID,

   ["none"] = typecodes.UNKNOWN,
   ["tuple"] = typecodes.UNKNOWN,
   ["literal_table_item"] = typecodes.UNKNOWN,
   ["typedecl"] = typecodes.UNKNOWN,
   ["generic"] = typecodes.UNKNOWN,
   ["*"] = typecodes.UNKNOWN,
}

local skip_types = {
   ["none"] = true,
   ["tuple"] = true,
   ["literal_table_item"] = true,
}


local function mark_array(x)
   local arr = x
   arr[0] = false
   return x
end

function type_reporter.new()
   local self = setmetatable({
      next_num = 1,
      typeid_to_num = {},
      typename_to_num = {},
      tr = setmetatable({
         by_pos = {},
         member_receivers = {},
         types = {},
         symbols_by_file = {},
         globals = {},
         macro_expansions = {},
      }, { __index = TypeReport }),
   }, { __index = TypeReporter })

   local names = {}
   for name, _ in pairs(types.simple_types) do
      table.insert(names, name)
   end
   table.sort(names)

   for _, name in ipairs(names) do
      local ti = {
         t = assert(typename_to_typecode[name]),
         str = name,
      }
      local n = self.next_num
      self.typename_to_num[name] = n
      self.tr.types[n] = ti
      self.next_num = self.next_num + 1
   end

   return self
end

function TypeReporter:store_function(ti, rt)
   local args = {}
   for _, fnarg in ipairs(rt.args.tuple) do
      table.insert(args, mark_array({ self:get_typenum(fnarg), nil }))
   end
   ti.args = mark_array(args)
   local rets = {}
   for _, fnarg in ipairs(rt.rets.tuple) do
      table.insert(rets, mark_array({ self:get_typenum(fnarg), nil }))
   end
   ti.rets = mark_array(rets)
   ti.vararg = not not rt.args.is_va
   ti.varret = not not rt.rets.is_va
end

function TypeReporter:get_typenum(t)

   local n = self.typename_to_num[t.typename]
   if n then
      return n
   end

   assert(t.typeid)

   n = self.typeid_to_num[t.typeid]
   if n then
      return n
   end

   local tr = self.tr


   n = self.next_num

   local rt = t
   if rt.typename == "tuple" and #rt.tuple == 1 then
      rt = rt.tuple[1]
   end

   if rt.typename == "typedecl" then
      return self:get_typenum(rt.def)
   end

   local typeargs
   if rt.typename == "generic" then
      typeargs = mark_array({})
      for _, typearg in ipairs(rt.typeargs) do
         local tn
         if typearg.constraint then
            tn = self:get_typenum(typearg.constraint)
         end
         table.insert(typeargs, mark_array({ typearg.typearg, tn }))
      end
      rt = rt.t
   end

   local ti = {
      t = assert(typename_to_typecode[rt.typename]),
      str = show_type(t, true),
      file = t.f,
      y = t.y,
      x = t.x,
      typeargs = typeargs,
   }
   tr.types[n] = ti
   self.typeid_to_num[t.typeid] = n
   self.next_num = self.next_num + 1

   if t.typename == "nominal" then
      if t.found then
         ti.ref = self:get_typenum(t.found)
      end
      if t.resolved then
         rt = t
      end
   end
   assert(not (rt.typename == "typedecl"))

   if rt.fields then

      local r = {}
      for _, k in ipairs(rt.field_order) do
         local v = rt.fields[k]
         r[k] = self:get_typenum(v)
      end
      ti.fields = r
      local locations = {}
      for name, location in pairs(rt.field_locations or {}) do
         locations[name] = { file = location.f, y = location.y, x = location.x }
      end
      ti.field_locations = locations
      if rt.meta_fields then

         local m = {}
         for _, k in ipairs(rt.meta_field_order) do
            local v = rt.meta_fields[k]
            m[k] = self:get_typenum(v)
         end
         ti.meta_fields = m
         local meta_locations = {}
         for name, location in pairs(rt.meta_field_locations or {}) do
            meta_locations[name] = { file = location.f, y = location.y, x = location.x }
         end
         ti.meta_field_locations = meta_locations
      end
   end

   if rt.elements then
      ti.elements = self:get_typenum(rt.elements)
   end

   if rt.typename == "map" then
      ti.keys = self:get_typenum(rt.keys)
      ti.values = self:get_typenum(rt.values)
   elseif rt.typename == "enum" then
      ti.enums = mark_array(sorted_keys(rt.enumset))
   elseif rt.typename == "function" then
      self:store_function(ti, rt)
   elseif rt.types then
      local tis = {}
      for _, pt in ipairs(rt.types) do
         table.insert(tis, self:get_typenum(pt))
      end
      ti.types = mark_array(tis)
   end

   return n
end

function TypeReporter:add_field(rtype, fname, ftype)
   local n = self:get_typenum(rtype)
   local ti = self.tr.types[n]
   assert(ti.fields)
   ti.fields[fname] = self:get_typenum(ftype)
end

function TypeReporter:set_ref(nom, resolved)
   local n = self:get_typenum(nom)
   local ti = self.tr.types[n]
   ti.ref = self:get_typenum(resolved)
end

function TypeReporter:get_collector(filename)
   local collector = {
      filename = filename,
      symbol_list = {},
   }

   local ft = {}
   self.tr.by_pos[filename] = ft
   local receivers = {}
   self.tr.member_receivers[filename] = receivers
   local expansions = {}
   self.tr.macro_expansions[filename] = expansions

   local symbol_list = collector.symbol_list
   local symbol_list_n = 0

   collector.store_type = function(y, x, typ)
      if not typ or skip_types[typ.typename] then
         return
      end

      local yt = ft[y]
      if not yt then
         yt = {}
         ft[y] = yt
      end

      yt[x] = self:get_typenum(typ)
   end

   collector.store_member_receiver = function(y, x, typ)
      if not typ then return end
      typ = types.untuple(typ)
      if skip_types[typ.typename] then return end
      receivers[y] = receivers[y] or {}
      receivers[y][x] = self:get_typenum(typ)
   end

   collector.store_macro_expansion = function(y, x, expansion)
      expansions[y] = expansions[y] or {}
      expansions[y][x] = expansion
   end

   collector.reserve_symbol_list_slot = function(node)
      symbol_list_n = symbol_list_n + 1
      node.symbol_list_slot = symbol_list_n
   end

   collector.add_to_symbol_list = function(node, name, t)
      if not node then
         return
      end
      local slot
      if node.symbol_list_slot then
         slot = node.symbol_list_slot
      else
         symbol_list_n = symbol_list_n + 1
         slot = symbol_list_n
      end
      symbol_list[slot] = { y = node.y, x = node.x, name = name, typ = t }
   end

   collector.begin_symbol_list_scope = function(node)
      symbol_list_n = symbol_list_n + 1
      symbol_list[symbol_list_n] = { y = node.y, x = node.x, name = "@{" }
   end

   collector.rollback_symbol_list_scope = function()
      while symbol_list[symbol_list_n].name ~= "@{" do
         symbol_list[symbol_list_n] = nil
         symbol_list_n = symbol_list_n - 1
      end
   end

   collector.end_symbol_list_scope = function(node)
      if symbol_list[symbol_list_n].name == "@{" then
         symbol_list[symbol_list_n] = nil
         symbol_list_n = symbol_list_n - 1
      else
         symbol_list_n = symbol_list_n + 1
         symbol_list[symbol_list_n] = { y = assert(node.yend), x = assert(node.xend), name = "@}" }
      end
   end

   return collector
end

function TypeReporter:store_result(collector, globals)
   local tr = self.tr

   local filename = collector.filename
   local symbol_list = collector.symbol_list

   tr.by_pos[filename][0] = nil


   do
      local n = 0
      local p = 0
      local n_stack, p_stack = {}, {}
      local level = 0
      for i, s in ipairs(symbol_list) do
         if s.typ then
            n = n + 1
         elseif s.name == "@{" then
            level = level + 1
            n_stack[level], p_stack[level] = n, p
            n, p = 0, i
         else
            if n == 0 then
               symbol_list[p].skip = true
               s.skip = true
            end
            n, p = n_stack[level], p_stack[level]
            level = level - 1
         end
      end
   end

   local symbols = mark_array({})
   tr.symbols_by_file[filename] = symbols


   do
      local stack = {}
      local level = 0
      local i = 0
      for _, s in ipairs(symbol_list) do
         if not s.skip then
            i = i + 1
            local id
            if s.typ then
               id = self:get_typenum(s.typ)
            elseif s.name == "@{" then
               level = level + 1
               stack[level] = i
               id = -1
            else
               local other = stack[level]
               level = level - 1
               symbols[other][4] = i
               id = other - 1
            end
            local sym = mark_array({ s.y, s.x, s.name, id })
            table.insert(symbols, sym)
         end
      end
   end

   local gkeys = sorted_keys(globals)
   for _, name in ipairs(gkeys) do
      if name:sub(1, 1) ~= "@" then
         local var = globals[name]
         tr.globals[name] = self:get_typenum(var.t)
      end
   end

   if not tr.symbols then
      tr.symbols = tr.symbols_by_file[filename]
   end
end

function TypeReporter:get_report()
   return self.tr
end


function TypeReporter:discard_unused_types()
   local tr = self.tr
   local live = {}
   local pending = {}
   local function keep(id)
      local info = id and tr.types[id]
      if info and not live[id] then
         live[id] = info
         table.insert(pending, info)
      end
   end
   for _, id in pairs(self.typename_to_num) do keep(id) end
   for _, id in pairs(tr.globals) do keep(id) end
   for _, positions in ipairs({ tr.by_pos, tr.member_receivers }) do
      for _, lines in pairs(positions) do
         for _, row in pairs(lines) do
            for _, id in pairs(row) do keep(id) end
         end
      end
   end
   local function keep_symbols(symbols)
      for _, symbol in ipairs(symbols or {}) do
         if symbol[3] ~= "@{" and symbol[3] ~= "@}" then keep(symbol[4]) end
      end
   end
   for _, symbols in pairs(tr.symbols_by_file) do keep_symbols(symbols) end
   keep_symbols(tr.symbols)
   while #pending > 0 do
      local info = table.remove(pending)
      keep(info.ref)
      keep(info.keys)
      keep(info.values)
      keep(info.elements)
      for _, id in pairs(info.fields or {}) do keep(id) end
      for _, id in pairs(info.meta_fields or {}) do keep(id) end
      for _, id in ipairs(info.types or {}) do keep(id) end
      for _, parameter in ipairs(info.args or {}) do keep(parameter[1]) end
      for _, ret in ipairs(info.rets or {}) do keep(ret[1]) end
      for _, type_parameter in ipairs(info.typeargs or {}) do keep(type_parameter[2]) end
   end
   local numbers = {}
   for typeid, id in pairs(self.typeid_to_num) do
      if live[id] then numbers[typeid] = id end
   end
   tr.types = live
   self.typeid_to_num = numbers
end





function TypeReport:symbols_in_scope(filename, y, x)
   local function find(symbols, at_y, at_x)
      local function le(a, b)
         return a[1] < b[1] or
         (a[1] == b[1] and a[2] <= b[2])
      end
      return binary_search(symbols, { at_y, at_x }, le) or 0
   end

   local ret = {}

   local symbols = self.symbols_by_file[filename]
   if not symbols then
      return ret
   end

   local n = find(symbols, y, x)

   while n >= 1 do
      local s = symbols[n]
      local symbol_name = s[3]
      if symbol_name == "@{" then
         n = n - 1
      elseif symbol_name == "@}" then
         n = s[4]
      else
         if ret[symbol_name] == nil then
            ret[symbol_name] = s[4]
         end
         n = n - 1
      end
   end

   return ret
end

return type_reporter

end

-- module teal.types from teal/types.lua
package.preload["teal.types"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local assert = _tl_compat and _tl_compat.assert or assert; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table
local tldebug = require("teal.debug")
local TL_DEBUG = tldebug.TL_DEBUG











local types = { GenericType = {}, StringType = {}, IntegerType = {}, NumberType = {}, BooleanType = {}, BooleanContextType = {}, TypeDeclType = {}, LiteralTableItemType = {}, NominalType = {}, SelfType = {}, ArrayType = {}, RecordType = {}, InterfaceType = {}, InvalidType = {}, UnknownType = {}, TupleType = {}, UnresolvedTypeArgType = {}, UnresolvableTypeArgType = {}, TypeVarType = {}, MapType = {}, NilType = {}, EmptyTableType = {}, UnresolvedEmptyTableValueType = {}, FunctionType = {}, UnionType = {}, TupleTableType = {}, PolyType = {}, EnumType = {} }






















































































































































































































































































































































































































function is_numeric_type(t)
   return t.typename == "number" or t.typename == "integer"
end

types.lua_primitives = {
   ["function"] = "function",
   ["enum"] = "string",
   ["boolean"] = "boolean",
   ["string"] = "string",
   ["nil"] = "nil",
   ["number"] = "number",
   ["integer"] = "number",
   ["thread"] = "thread",
}

local simple_types = {
   ["nil"] = true,
   ["any"] = true,
   ["number"] = true,
   ["string"] = true,
   ["thread"] = true,
   ["boolean"] = true,
   ["integer"] = true,
   ["self"] = true,
}


local no_nested_types = {
   ["string"] = true,
   ["number"] = true,
   ["integer"] = true,
   ["boolean"] = true,
   ["thread"] = true,
   ["any"] = true,
   ["enum"] = true,
   ["nil"] = true,
   ["unknown"] = true,
}

local table_types = {
   ["array"] = true,
   ["map"] = true,
   ["record"] = true,
   ["interface"] = true,
   ["self"] = true,
   ["emptytable"] = true,
   ["tupletable"] = true,

   ["generic"] = false,
   ["typedecl"] = false,
   ["typevar"] = false,
   ["typearg"] = false,
   ["function"] = false,
   ["enum"] = false,
   ["boolean"] = false,
   ["string"] = false,
   ["nil"] = false,
   ["thread"] = false,
   ["userdata"] = false,
   ["number"] = false,
   ["integer"] = false,
   ["union"] = false,
   ["nominal"] = false,
   ["literal_table_item"] = false,
   ["unresolved_emptytable_value"] = false,
   ["unresolved_typearg"] = false,
   ["unresolvable_typearg"] = false,
   ["circular_require"] = false,
   ["boolean_context"] = false,
   ["tuple"] = false,
   ["poly"] = false,
   ["any"] = false,
   ["unknown"] = false,
   ["invalid"] = false,
   ["none"] = false,
   ["*"] = false,
}

local show_type

local function is_unknown(t)
   return t.typename == "unknown" or
   t.typename == "unresolved_emptytable_value"
end

local function show_typevar(typevar, what)
   return TL_DEBUG and
   (what .. " " .. typevar) or
   typevar:gsub("@.*", "")
end

local function show_fields(t, show)
   if t.declname then
      return " " .. t.declname
   end

   local out = {}
   table.insert(out, " (")
   if t.elements then
      table.insert(out, "{" .. show(t.elements) .. "}")
   end
   if t.types then
      local tuple_types = {}
      for _, child in ipairs(t.types) do
         table.insert(tuple_types, show(child))
      end
      table.insert(out, "{" .. table.concat(tuple_types, ", ") .. "}")
   end
   local fs = {}
   for _, k in ipairs(t.field_order) do
      local v = t.fields[k]
      table.insert(fs, k .. ": " .. show(v))
   end
   table.insert(out, table.concat(fs, "; "))
   table.insert(out, ")")
   return table.concat(out)
end

local function show_type_base(t, short, seen)

   if seen[t] then
      return seen[t]
   end
   seen[t] = "..."

   local function show(typ)
      return show_type(typ, short, seen)
   end

   if t.typename == "nominal" then
      local ret
      if t.typevals then
         local out = { table.concat(t.names, "."), "<" }
         local vals = {}
         for _, v in ipairs(t.typevals) do
            table.insert(vals, show(v))
         end
         table.insert(out, table.concat(vals, ", "))
         table.insert(out, ">")
         ret = table.concat(out)
      else
         ret = table.concat(t.names, ".")
      end
      if TL_DEBUG then
         ret = "nominal " .. ret
      end
      return ret
   elseif t.typename == "self" then
      if t.display_type then
         local ret = show_type_base(t.display_type, short, seen)
         if TL_DEBUG then
            ret = "self " .. ret
         end
         return ret
      end
      return "self"
   elseif t.typename == "tuple" then
      local out = {}
      for _, v in ipairs(t.tuple) do
         table.insert(out, show(v))
      end
      local list = table.concat(out, ", ")
      if t.is_va then
         list = list .. "..."
      end
      if short then
         return list
      end
      return "(" .. list .. ")"
   elseif t.typename == "tupletable" then
      local out = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return "{" .. table.concat(out, ", ") .. "}"
   elseif t.typename == "poly" then
      local out = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return "polymorphic function (with types " .. table.concat(out, " and ") .. ")"
   elseif t.typename == "union" then
      local out = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return table.concat(out, " | ")
   elseif t.typename == "emptytable" then
      return "{}"
   elseif t.typename == "map" then
      return "{" .. show(t.keys) .. " : " .. show(t.values) .. "}"
   elseif t.typename == "array" then
      return "{" .. show(t.elements) .. "}"
   elseif t.typename == "enum" then
      return t.declname or "enum"
   elseif t.fields then
      return short and (t.declname or t.typename) or t.typename .. show_fields(t, show)
   elseif t.typename == "function" then
      local out = { "function(" }
      local args = {}
      for i, v in ipairs(t.args.tuple) do
         table.insert(args, ((i == #t.args.tuple and t.args.is_va) and "...: " or
         (i > t.min_arity) and "? " or
         "") .. show(v))
      end
      table.insert(out, table.concat(args, ", "))
      table.insert(out, ")")
      if t.rets.tuple and #t.rets.tuple > 0 then
         table.insert(out, ": ")
         local rets = {}
         if #t.rets.tuple > 1 then
            table.insert(out, "(")
         end
         for i, v in ipairs(t.rets.tuple) do
            table.insert(rets, show(v) .. (i == #t.rets.tuple and t.rets.is_va and "..." or ""))
         end
         table.insert(out, table.concat(rets, ", "))
         if #t.rets.tuple > 1 then
            table.insert(out, ")")
         end
      end
      return table.concat(out)
   elseif t.typename == "generic" then
      local out = {}
      local name, rest
      local tt = t.t
      if tt.typename == "record" or tt.typename == "interface" or tt.typename == "function" then
         name, rest = show(tt):match("^(%a+)(.*)")
         table.insert(out, name)
      else
         rest = " " .. show(tt)
         table.insert(out, "generic")
      end
      table.insert(out, "<")
      local typeargs = {}
      for _, v in ipairs(t.typeargs) do
         table.insert(typeargs, show(v))
      end
      table.insert(out, table.concat(typeargs, ", "))
      table.insert(out, ">")
      table.insert(out, rest)
      return table.concat(out)
   elseif t.typename == "string" then
      if short then
         return "string"
      else
         return t.typename ..
         (t.literal and string.format(" %q", t.literal) or "")
      end
   elseif t.typename == "number" then
      if short then
         return t.typename
      else
         local lit = t.literal ~= nil and (" " .. tostring(t.literal)) or ""
         return t.typename .. lit
      end
   elseif t.typename == "integer" then
      if short then
         return t.typename
      else
         local lit = t.literal ~= nil and (" " .. tostring(t.literal)) or ""
         return t.typename .. lit
      end
   elseif t.typename == "boolean" then
      if short then
         return t.typename
      else
         local lit = t.literal ~= nil and (" " .. tostring(t.literal)) or ""
         return t.typename .. lit
      end
   elseif t.typename == "thread" then
      return t.typename
   elseif t.typename == "typevar" then
      return show_typevar(t.typevar, "typevar")
   elseif t.typename == "typearg" then
      local out = show_typevar(t.typearg, "typearg")
      if t.constraint then
         out = out .. " is " .. show(t.constraint)
      end
      return out
   elseif t.typename == "unresolvable_typearg" then
      return show_typevar(t.typearg, "typearg") .. " (unresolved generic)"
   elseif is_unknown(t) then
      return "<unknown type>"
   elseif t.typename == "invalid" then
      return "<invalid type>"
   elseif t.typename == "any" then
      return "<any type>"
   elseif t.typename == "nil" then
      return "nil"
   elseif t.typename == "boolean_context" then
      return "boolean"
   elseif t.typename == "none" then
      return ""
   elseif t.typename == "typedecl" then
      return (t.is_alias and "type alias to " or "type ") .. show(t.def)
   else
      return "<" .. t.typename .. ">"
   end
end

local function inferred_msg(t, prefix)
   return " (" .. (prefix or "") .. "inferred at " .. t.inferred_at.f .. ":" .. t.inferred_at.y .. ":" .. t.inferred_at.x .. ")"
end

show_type = function(t, short, seen)
   seen = seen or {}
   if seen[t] then
      return seen[t]
   end
   local ret = show_type_base(t, short, seen)
   if t.inferred_at then
      ret = ret .. inferred_msg(t)
   end
   seen[t] = ret
   return ret
end

local type_mt = {
   __tostring = function(t)
      return show_type(t)
   end,
}


local fresh_typevar_ctr = 1
local fresh_typeid_ctr = 0

local function new_typeid()
   fresh_typeid_ctr = fresh_typeid_ctr + 1
   return fresh_typeid_ctr
end

local function a_type(w, typename, t)
   t.typeid = new_typeid()
   t.f = w.f
   t.x = w.x
   t.y = w.y
   t.typename = typename
   do
      local ty = t
      setmetatable(ty, type_mt)
   end
   return t
end

local function a_function(w, t)
   assert(t.min_arity)
   return a_type(w, "function", t)
end





local function a_vararg(w, t)
   local typ = a_type(w, "tuple", { tuple = t })
   typ.is_va = true
   return typ
end

local function raw_type(f, y, x, typename)
   local t = setmetatable({}, type_mt)
   t.typeid = new_typeid()
   t.f = f
   t.x = x
   t.y = y
   t.typename = typename
   return t
end

local function shallow_copy_new_type(t)
   local copy = {}
   for k, v in pairs(t) do
      copy[k] = v
   end
   copy.typeid = new_typeid()
   do
      local ty = copy
      setmetatable(ty, type_mt)
   end
   return copy
end

local function edit_type(w, t, typename)
   t.typeid = new_typeid()
   t.f = w.f
   t.x = w.x
   t.y = w.y
   t.typename = typename
   setmetatable(t, type_mt)
   return t
end

local function type_for_union(t)
   if t.typename == "typedecl" then
      return type_for_union(t.def)
   elseif t.typename == "tuple" then
      return type_for_union(t.tuple[1]), t.tuple[1]
   elseif t.typename == "nominal" then
      local typedecl = t.found
      if not typedecl then
         return "invalid"
      end
      return type_for_union(typedecl)
   elseif t.fields then
      if t.is_userdata then
         return "userdata", t
      end
      return "table", t
   elseif t.typename == "generic" then
      return type_for_union(t.t)
   elseif table_types[t.typename] then
      return "table", t
   else
      return t.typename, t
   end
end

function types.is_valid_union(typ)


   local n_table_types = 0
   local n_table_is_types = 0
   local n_function_types = 0
   local n_userdata_types = 0
   local n_userdata_is_types = 0
   local n_string_enum = 0
   local has_primitive_string_type = false
   for _, t in ipairs(typ.types) do
      local ut, rt = type_for_union(t)
      if ut == "userdata" then
         assert(rt.fields)
         if rt.meta_fields and rt.meta_fields["__is"] then
            n_userdata_is_types = n_userdata_is_types + 1
            if n_userdata_types > 0 then
               return false, "cannot mix userdata types with and without __is metamethod: %s"
            end
         else
            n_userdata_types = n_userdata_types + 1
            if n_userdata_types > 1 then
               return false, "cannot discriminate a union between multiple userdata types: %s"
            end
            if n_userdata_is_types > 0 then
               return false, "cannot mix userdata types with and without __is metamethod: %s"
            end
         end
      elseif ut == "table" then
         if rt.fields and rt.meta_fields and rt.meta_fields["__is"] then
            n_table_is_types = n_table_is_types + 1
            if n_table_types > 0 then
               return false, "cannot mix table types with and without __is metamethod: %s"
            end
         else
            n_table_types = n_table_types + 1
            if n_table_types > 1 then
               return false, "cannot discriminate a union between multiple table types: %s"
            end
            if n_table_is_types > 0 then
               return false, "cannot mix table types with and without __is metamethod: %s"
            end
         end
      elseif ut == "function" then
         n_function_types = n_function_types + 1
         if n_function_types > 1 then
            return false, "cannot discriminate a union between multiple function types: %s"
         end
      elseif ut == "enum" or (ut == "string" and not has_primitive_string_type) then
         n_string_enum = n_string_enum + 1
         if n_string_enum > 1 then
            return false, "cannot discriminate a union between multiple string/enum types: %s"
         end
         if ut == "string" then
            has_primitive_string_type = true
         end
      elseif ut == "invalid" then
         return false, nil
      end
   end
   return true
end

function types.error(msg, t1, t2, t3)
   local s1, s2, s3
   if t1.typename == "invalid" then
      return nil
   end
   s1 = show_type(t1)
   if t2 then
      if t2.typename == "invalid" then
         return nil
      end
      s2 = show_type(t2)
   end
   if t3 then
      if t3.typename == "invalid" then
         return nil
      end
      s3 = show_type(t3)
   end
   msg = msg:format(s1, s2, s3)
   return {
      msg = msg,
      x = t1.x,
      y = t1.y,
      filename = t1.f,
   }
end

types.map = function(self, ty, fns)
   local errs
   local seen = {}
   local resolve

   resolve = function(t, all_same)
      local same = true


      if no_nested_types[t.typename] or (t.typename == "nominal" and not t.typevals) then
         return t, all_same
      end

      if seen[t] then
         return seen[t], all_same
      end

      local orig_t = t
      local fn = fns[t.typename]
      if fn then
         local rt, is_resolved = fn(self, t, resolve)
         if rt ~= t then
            if is_resolved then
               seen[t] = rt
               return rt, false
            end
            return resolve(rt, false)
         end
      end

      local copy = {}
      seen[orig_t] = copy

      setmetatable(copy, type_mt)
      copy.typename = t.typename
      copy.f = t.f
      copy.x = t.x
      copy.y = t.y

      if t.typename == "generic" then
         assert(copy.typename == "generic")

         local ct = {}
         for i, tf in ipairs(t.typeargs) do
            ct[i], same = resolve(tf, same)
         end
         copy.typeargs = ct
         copy.t, same = resolve(t.t, same)
      elseif t.typename == "array" then
         assert(copy.typename == "array")

         copy.elements, same = resolve(t.elements, same)

      elseif t.typename == "typearg" then
         assert(copy.typename == "typearg")
         copy.typearg = t.typearg
         if t.constraint then
            copy.constraint, same = resolve(t.constraint, same)
         end
      elseif t.typename == "unresolvable_typearg" then
         assert(copy.typename == "unresolvable_typearg")
         copy.typearg = t.typearg
      elseif t.typename == "unresolved_emptytable_value" then
         assert(copy.typename == "unresolved_emptytable_value")
         copy.emptytable_type = t.emptytable_type
      elseif t.typename == "typevar" then
         assert(copy.typename == "typevar")
         copy.typevar = t.typevar
         if t.constraint then
            copy.constraint, same = resolve(t.constraint, same)
         end
      elseif t.typename == "typedecl" then
         assert(copy.typename == "typedecl")
         copy.def, same = resolve(t.def, same)
         copy.is_alias = t.is_alias
         copy.is_nested_alias = t.is_nested_alias
      elseif t.typename == "nominal" then
         assert(copy.typename == "nominal")
         copy.names = t.names
         copy.typevals = {}
         for i, tf in ipairs(t.typevals) do
            copy.typevals[i], same = resolve(tf, same)
         end
         copy.found = t.found
      elseif t.typename == "function" then
         assert(copy.typename == "function")
         copy.macroexp = t.macroexp
         copy.min_arity = t.min_arity
         copy.is_method = t.is_method
         copy.is_record_function = t.is_record_function
         copy.args, same = resolve(t.args, same)
         copy.rets, same = resolve(t.rets, same)
         copy.special_function_handler = t.special_function_handler
      elseif t.fields then
         assert(copy.typename == "record" or copy.typename == "interface")
         copy.declname = t.declname


         if t.elements then
            copy.elements, same = resolve(t.elements, same)
         end


         if t.types then
            copy.types = {}
            for i, v in ipairs(t.types) do
               copy.types[i], same = resolve(v, same)
            end
         end

         if t.interface_list then
            copy.interface_list = {}
            for i, v in ipairs(t.interface_list) do
               copy.interface_list[i], same = resolve(v, same)
            end
         end

         copy.is_userdata = t.is_userdata
         copy.native_pointer = t.native_pointer

         copy.fields = {}
         copy.field_order = {}
         for i, k in ipairs(t.field_order) do
            copy.field_order[i] = k
            copy.fields[k], same = resolve(t.fields[k], same)
         end

         if t.meta_fields then
            copy.meta_fields = {}
            copy.meta_field_order = {}
            for i, k in ipairs(t.meta_field_order) do
               copy.meta_field_order[i] = k
               copy.meta_fields[k], same = resolve(t.meta_fields[k], same)
            end
         end
      elseif t.typename == "map" then
         assert(copy.typename == "map")
         copy.keys, same = resolve(t.keys, same)
         copy.values, same = resolve(t.values, same)
      elseif t.typename == "union" then
         assert(copy.typename == "union")
         copy.types = {}
         for i, tf in ipairs(t.types) do
            copy.types[i], same = resolve(tf, same)
         end

         local _, err = types.is_valid_union(copy)
         if err then
            errs = errs or {}
            table.insert(errs, types.error(err, copy))
         end
      elseif t.typename == "poly" then
         assert(copy.typename == "poly")
         copy.types = {}
         for i, tf in ipairs(t.types) do
            copy.types[i], same = resolve(tf, same)
         end
      elseif t.typename == "tupletable" then
         assert(copy.typename == "tupletable")
         copy.inferred_at = t.inferred_at
         copy.types = {}
         for i, tf in ipairs(t.types) do
            copy.types[i], same = resolve(tf, same)
         end
      elseif t.typename == "tuple" then
         assert(copy.typename == "tuple")
         copy.is_va = t.is_va
         copy.tuple = {}
         for i, tf in ipairs(t.tuple) do
            copy.tuple[i], same = resolve(tf, same)
         end
      elseif t.typename == "self" then
         assert(copy.typename == "self")
         if t.display_type ~= nil then
            copy.display_type, same = resolve(t.display_type, same)
         end
      end

      copy.typeid = same and t.typeid or new_typeid()
      return copy, same and all_same
   end

   local copy = resolve(ty, true)
   if errs then
      return a_type(ty, "invalid", {}), errs
   end

   return copy
end

do
   function types.internal_typevar_ctr()
      return fresh_typevar_ctr
   end


   local fresh_typevar_fns = {
      ["typevar"] = function(typeargs, t, resolve)
         for _, ta in ipairs(typeargs) do
            if ta.typearg == t.typevar then
               return a_type(t, "typevar", {
                  typevar = (t.typevar:gsub("@.*", "")) .. "@" .. fresh_typevar_ctr,
                  constraint = t.constraint and resolve(t.constraint, false),
               }), true
            end
         end
         return t, false
      end,
      ["typearg"] = function(typeargs, t, resolve)
         for _, ta in ipairs(typeargs) do
            if ta.typearg == t.typearg then
               return a_type(t, "typearg", {
                  typearg = (t.typearg:gsub("@.*", "")) .. "@" .. fresh_typevar_ctr,
                  constraint = t.constraint and resolve(t.constraint, false),
               }), true
            end
         end
         return t, false
      end,
   }

   function types.fresh_typeargs(g)
      fresh_typevar_ctr = fresh_typevar_ctr + 1

      local newg, errs = types.map(g.typeargs, g, fresh_typevar_fns)
      if newg.typename == "invalid" then
         return newg, errs
      end

      assert(newg.typename == "generic", "Internal Compiler Error: error creating fresh type variables")
      assert(newg ~= g)
      newg.fresh = true

      return newg
   end
end







function types.untuple(t)
   local rt = t
   if rt.typename == "tuple" then
      rt = rt.tuple[1]
   end
   if rt == nil then
      return a_type(t, "nil", {})
   end
   return rt
end

function types.unite(w, typs, flatten_constants, implicit_nil)
   if #typs == 1 then
      return typs[1]
   end

   if implicit_nil == nil then
      implicit_nil = true
   end

   local ts = {}
   local stack = {}


   local types_seen = {}

   if implicit_nil then
      types_seen["nil"] = true
   end

   local i = 1
   while typs[i] or stack[1] do
      local t
      if stack[1] then
         t = table.remove(stack)
      else
         t = typs[i]
         i = i + 1
      end
      t = types.untuple(t)
      if t.typename == "union" then
         for _, s in ipairs(t.types) do
            table.insert(stack, s)
         end
      else
         local is_literal =
         (t.typename == "string" and t.literal) or
         (t.typename == "number" and t.literal ~= nil) or
         (t.typename == "integer" and t.literal ~= nil) or
         (t.typename == "boolean" and t.literal ~= nil)

         if types.lua_primitives[t.typename] and (flatten_constants or not is_literal) then
            if flatten_constants and is_literal then
               t = types.drop_constant_value(t)
            end
            if not types_seen[t.typename] then
               types_seen[t.typename] = true
               table.insert(ts, t)
            end
         else
            local typeid = t.typeid
            if t.typename == "nominal" and t.found then
               typeid = t.found.typeid
            end
            if not types_seen[typeid] then
               types_seen[typeid] = true
               table.insert(ts, t)
            end
         end
      end
   end

   if types_seen["invalid"] then
      return a_type(w, "invalid", {})
   end

   if #ts == 1 then
      return ts[1]
   else
      return a_type(w, "union", { types = ts })
   end
end

function types.resolve_for_special_function(t)
   if t.typename == "poly" then
      t = t.types[1]
   end
   if t.typename == "generic" then
      t = t.t
   end
   if t.typename == "function" then
      return t
   end
end

function types.drop_constant_value(t)
   if t.typename == "string" and t.literal then
      local ret = shallow_copy_new_type(t)
      ret.literal = nil
      return ret
   elseif t.typename == "number" and t.literal ~= nil then
      local ret = shallow_copy_new_type(t)
      ret.literal = nil
      return ret
   elseif t.typename == "integer" and t.literal ~= nil then
      local ret = shallow_copy_new_type(t)
      ret.literal = nil
      return ret
   elseif t.typename == "boolean" and t.literal ~= nil then
      local ret = shallow_copy_new_type(t)
      ret.literal = nil
      return ret
   elseif t.needs_compat then
      local ret = shallow_copy_new_type(t)
      ret.needs_compat = nil
      return ret
   end
   return t
end

function types.drop_constant_values(t, keep_typedecls)
   local function has_constant(typ, seen, in_typedecl)
      if seen[typ] then
         return false
      end
      seen[typ] = true

      if typ.typename == "string" and typ.literal then
         if not (keep_typedecls and in_typedecl) then
            return true
         end
      elseif typ.typename == "number" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            return true
         end
      elseif typ.typename == "integer" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            return true
         end
      elseif typ.typename == "boolean" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            return true
         end
      elseif typ.needs_compat then
         return true
      end

      if no_nested_types[typ.typename] or (typ.typename == "nominal" and not typ.typevals) then
         return false
      end

      if typ.typename == "generic" then
         for _, tf in ipairs(typ.typeargs) do
            if has_constant(tf, seen, in_typedecl) then
               return true
            end
         end
         return has_constant(typ.t, seen, in_typedecl)
      elseif typ.typename == "array" then
         return has_constant(typ.elements, seen, in_typedecl)
      elseif typ.typename == "typearg" then
         if typ.constraint then
            return has_constant(typ.constraint, seen, in_typedecl)
         end
      elseif typ.typename == "typevar" then
         if typ.constraint then
            return has_constant(typ.constraint, seen, in_typedecl)
         end
      elseif typ.typename == "typedecl" then
         return has_constant(typ.def, seen, true)
      elseif typ.typename == "nominal" then
         if typ.typevals then
            for _, tf in ipairs(typ.typevals) do
               if has_constant(tf, seen, in_typedecl) then
                  return true
               end
            end
         end
      elseif typ.typename == "function" then
         return has_constant(typ.args, seen, in_typedecl) or has_constant(typ.rets, seen, in_typedecl)
      elseif typ.fields then
         local record_in_typedecl = in_typedecl or (keep_typedecls and typ.declname ~= nil)
         if typ.elements and has_constant(typ.elements, seen, record_in_typedecl) then
            return true
         end
         if typ.interface_list then
            for _, v in ipairs(typ.interface_list) do
               if has_constant(v, seen, record_in_typedecl) then
                  return true
               end
            end
         end
         for _, k in ipairs(typ.field_order) do
            if has_constant(typ.fields[k], seen, record_in_typedecl) then
               return true
            end
         end
         if typ.meta_fields then
            for _, k in ipairs(typ.meta_field_order) do
               if has_constant(typ.meta_fields[k], seen, record_in_typedecl) then
                  return true
               end
            end
         end
      elseif typ.typename == "map" then
         return has_constant(typ.keys, seen, in_typedecl) or has_constant(typ.values, seen, in_typedecl)
      elseif typ.typename == "union" then
         for _, tf in ipairs(typ.types) do
            if has_constant(tf, seen, in_typedecl) then
               return true
            end
         end
      elseif typ.typename == "poly" then
         for _, tf in ipairs(typ.types) do
            if has_constant(tf, seen, in_typedecl) then
               return true
            end
         end
      elseif typ.typename == "tupletable" then
         for _, tf in ipairs(typ.types) do
            if has_constant(tf, seen, in_typedecl) then
               return true
            end
         end
      elseif typ.typename == "tuple" then
         for _, tf in ipairs(typ.tuple) do
            if has_constant(tf, seen, in_typedecl) then
               return true
            end
         end
      elseif typ.typename == "self" then
         if typ.display_type ~= nil then
            return has_constant(typ.display_type, seen, in_typedecl)
         end
      end

      return false
   end

   if not has_constant(t, {}, false) then
      return t
   end

   local seen = {}

   local function drop(typ, in_typedecl)
      if seen[typ] then
         return seen[typ]
      end

      if typ.typename == "string" and typ.literal then
         if not (keep_typedecls and in_typedecl) then
            local ret = shallow_copy_new_type(typ)
            ret.literal = nil
            return ret
         end
      elseif typ.typename == "number" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            local ret = shallow_copy_new_type(typ)
            ret.literal = nil
            return ret
         end
      elseif typ.typename == "integer" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            local ret = shallow_copy_new_type(typ)
            ret.literal = nil
            return ret
         end
      elseif typ.typename == "boolean" and typ.literal ~= nil then
         if not (keep_typedecls and in_typedecl) then
            local ret = shallow_copy_new_type(typ)
            ret.literal = nil
            return ret
         end
      end
      if typ.needs_compat then
         local ret = shallow_copy_new_type(typ)
         ret.needs_compat = nil
         return ret
      end

      if no_nested_types[typ.typename] or (typ.typename == "nominal" and not typ.typevals) then
         return typ
      end

      local copy = shallow_copy_new_type(typ)
      seen[typ] = copy

      if typ.typename == "generic" then
         assert(copy.typename == "generic")
         copy.typeargs = {}
         for i, tf in ipairs(typ.typeargs) do
            copy.typeargs[i] = drop(tf, in_typedecl)
         end
         copy.t = drop(typ.t, in_typedecl)
      elseif typ.typename == "array" then
         assert(copy.typename == "array")
         copy.elements = drop(typ.elements, in_typedecl)
      elseif typ.typename == "typearg" then
         assert(copy.typename == "typearg")
         copy.typearg = typ.typearg
         if typ.constraint then
            copy.constraint = drop(typ.constraint, in_typedecl)
         end
      elseif typ.typename == "unresolvable_typearg" then
         assert(copy.typename == "unresolvable_typearg")
         copy.typearg = typ.typearg
      elseif typ.typename == "unresolved_emptytable_value" then
         assert(copy.typename == "unresolved_emptytable_value")
         copy.emptytable_type = typ.emptytable_type
      elseif typ.typename == "typevar" then
         assert(copy.typename == "typevar")
         copy.typevar = typ.typevar
         if typ.constraint then
            copy.constraint = drop(typ.constraint, in_typedecl)
         end
      elseif typ.typename == "typedecl" then
         assert(copy.typename == "typedecl")
         copy.def = drop(typ.def, true)
         copy.is_alias = typ.is_alias
         copy.is_nested_alias = typ.is_nested_alias
      elseif typ.typename == "nominal" then
         assert(copy.typename == "nominal")
         copy.names = typ.names
         if typ.typevals then
            copy.typevals = {}
            for i, tf in ipairs(typ.typevals) do
               copy.typevals[i] = drop(tf, in_typedecl)
            end
         end
         copy.found = typ.found
      elseif typ.typename == "function" then
         assert(copy.typename == "function")
         copy.macroexp = typ.macroexp
         copy.min_arity = typ.min_arity
         copy.is_method = typ.is_method
         copy.is_record_function = typ.is_record_function
         copy.args = drop(typ.args, in_typedecl)
         copy.rets = drop(typ.rets, in_typedecl)
         copy.special_function_handler = typ.special_function_handler
      elseif typ.fields then
         assert(copy.typename == "record" or copy.typename == "interface")
         copy.declname = typ.declname
         local record_in_typedecl = in_typedecl or (keep_typedecls and typ.declname ~= nil)
         if typ.elements then
            copy.elements = drop(typ.elements, record_in_typedecl)
         end
         if typ.interface_list then
            copy.interface_list = {}
            for i, v in ipairs(typ.interface_list) do
               copy.interface_list[i] = drop(v, record_in_typedecl)
            end
         end
         copy.is_userdata = typ.is_userdata
         copy.native_pointer = typ.native_pointer
         copy.fields = {}
         copy.field_order = {}
         for i, k in ipairs(typ.field_order) do
            copy.field_order[i] = k
            copy.fields[k] = drop(typ.fields[k], record_in_typedecl)
         end
         if typ.meta_fields then
            copy.meta_fields = {}
            copy.meta_field_order = {}
            for i, k in ipairs(typ.meta_field_order) do
               copy.meta_field_order[i] = k
               copy.meta_fields[k] = drop(typ.meta_fields[k], record_in_typedecl)
            end
         end
      elseif typ.typename == "map" then
         assert(copy.typename == "map")
         copy.keys = drop(typ.keys, in_typedecl)
         copy.values = drop(typ.values, in_typedecl)
      elseif typ.typename == "union" then
         local out_types = {}
         for _, tf in ipairs(typ.types) do
            table.insert(out_types, drop(tf, in_typedecl))
         end
         local u = types.unite(typ, out_types, true, false)
         seen[typ] = u
         return u
      elseif typ.typename == "poly" then
         assert(copy.typename == "poly")
         copy.types = {}
         for i, tf in ipairs(typ.types) do
            copy.types[i] = drop(tf, in_typedecl)
         end
      elseif typ.typename == "tupletable" then
         assert(copy.typename == "tupletable")
         copy.inferred_at = typ.inferred_at
         copy.types = {}
         for i, tf in ipairs(typ.types) do
            copy.types[i] = drop(tf, in_typedecl)
         end
      elseif typ.typename == "tuple" then
         assert(copy.typename == "tuple")
         copy.is_va = typ.is_va
         copy.tuple = {}
         for i, tf in ipairs(typ.tuple) do
            copy.tuple[i] = drop(tf, in_typedecl)
         end
      elseif typ.typename == "self" then
         assert(copy.typename == "self")
         if typ.display_type ~= nil then
            copy.display_type = drop(typ.display_type, in_typedecl)
         end
      end

      return copy
   end

   return drop(t, false)
end

function types.type_at(w, t)
   t.x = w.x
   t.y = w.y
   return t
end

function types.wrap_generic_if_typeargs(typeargs, t)
   if not typeargs then
      return t
   end

   assert(not (t.typename == "typedecl"))

   local gt = a_type(t, "generic", { t = t })
   gt.typeargs = typeargs
   return gt
end

function types.show_arity(f)
   local nfargs = #f.args.tuple
   if f.min_arity < nfargs then
      if f.min_arity > 0 then
         return "at least " .. f.min_arity .. (f.args.is_va and "" or " and at most " .. nfargs)
      else
         return (f.args.is_va and "any number" or "at most " .. nfargs)
      end
   else
      return tostring(nfargs or 0)
   end
end

function types.typedecl_to_nominal(w, name, t, resolved)
   local typevals
   local def = t.def
   if def.typename == "generic" then
      typevals = {}
      for _, a in ipairs(def.typeargs) do
         table.insert(typevals, a_type(a, "typevar", {
            typevar = a.typearg,
            constraint = a.constraint,
         }))
      end
   end
   local nom = a_type(w, "nominal", { names = { name } })
   nom.typevals = typevals
   nom.found = t
   nom.resolved = resolved
   return nom
end

local function ensure_not_method(t)
   if t.typename == "generic" then
      local tt = ensure_not_method(t.t)
      if tt ~= t.t then
         local gg = shallow_copy_new_type(t)
         gg.t = tt
         return gg
      end
   end

   if t.typename == "function" and t.is_method then
      t = shallow_copy_new_type(t);
      (t).is_method = false
   end
   return t
end

function types.internal_get_state()
   return fresh_typeid_ctr, fresh_typevar_ctr
end

function types.internal_force_state(typeid_ctr, typevar_ctr)
   fresh_typeid_ctr = typeid_ctr
   fresh_typevar_ctr = typevar_ctr
end

types.globals_typeid = new_typeid()
types.simple_types = simple_types
types.table_types = table_types
types.a_type = a_type
types.a_function = a_function
types.a_vararg = a_vararg
types.edit_type = edit_type
types.ensure_not_method = ensure_not_method
types.is_unknown = is_unknown
types.inferred_msg = inferred_msg
types.raw_type = raw_type
types.shallow_copy_new_type = shallow_copy_new_type
types.show_type = show_type
types.show_typevar = show_typevar
types.show_type_base = show_type_base

return types

end

-- module teal.util from teal/util.lua
package.preload["teal.util"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local pairs = _tl_compat and _tl_compat.pairs or pairs; local table = _tl_compat and _tl_compat.table or table



local util = {}


math.type = math.type or function(n)
   if type(n) ~= "number" then return nil end
   if n % 1 == 0 then
      return "integer"
   else
      return "float"
   end
end

function util.binary_search(list, item, cmp)
   local len = #list
   local mid
   local s, e = 1, len
   while s <= e do
      mid = math.floor((s + e) / 2)
      local val = list[mid]
      local res = cmp(val, item)
      if res then
         if mid == len then
            return mid, val
         else
            if not cmp(list[mid + 1], item) then
               return mid, val
            end
         end
         s = mid + 1
      else
         e = mid - 1
      end
   end
end

function util.shallow_copy_table(t)
   local copy = {}
   for k, v in pairs(t) do
      copy[k] = v
   end
   return copy
end

function util.sorted_keys(m)
   local keys = {}
   for k, _ in pairs(m) do
      table.insert(keys, k)
   end
   table.sort(keys)
   return keys
end

return util

end

-- module teal.variables from teal/variables.lua
package.preload["teal.variables"] = function(...)
local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local pairs = _tl_compat and _tl_compat.pairs or pairs












local variables = { Variable = {}, Scope = {} }






































function variables.has_var_been_used(var)
   return var.has_been_read_from or var.has_been_written_to
end

local function close_nested_records(t)
   if t.closed then
      return
   end
   local tdef = t.def
   if tdef.fields then
      t.closed = true
      for _, ft in pairs(tdef.fields) do
         if ft.typename == "typedecl" then
            close_nested_records(ft)
         end
      end
   end
end

function variables.close_types(scope)
   for _, var in pairs(scope.vars) do
      local t = var.t
      if t.typename == "typedecl" then
         close_nested_records(t)
      end
   end
end

return variables

end

return require("teal.init")
