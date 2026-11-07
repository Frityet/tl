--#pragma strict_nil off
local errors = require("teal.errors")
local type Error = errors.Error

local lexer = require("teal.lexer")
local type Token = lexer.Token
local type TokenKind = lexer.TokenKind
local type Comment = lexer.Comment

local block = require("teal.block")
local type Block = block.Block
local type BlockKind = block.BlockKind
local type BlockLang = block.BlockLang
local type OperatorSpec = block.OperatorSpec
local macro_eval = require("teal.macro_eval")

local enum Attribute
   "const"
   "close"
   "total"
end

local record MacroSig
   kinds: {string}
   operator: OperatorSpec
   vararg: string -- empty string means 'no vararg'
end

local record reader
   type Attribute = Attribute
   type Block = Block
   type BlockKind = BlockKind
   type BlockLang = BlockLang

   BLOCK_INDEXES: {string : {string : integer}}
   read: function(input: string, filename: string, read_lang?: BlockLang, allow_macro_vars?: boolean, allow_macro_expand?: boolean, operator_context?: {string: {string: OperatorSpec}}, in_macro_quote?: boolean): Block, {Error}
   read_program: function(tokens: {Token}, errs: {Error}, filename?: string, read_lang?: BlockLang, allow_macro_vars?: boolean, allow_macro_expand?: boolean, operator_context?: {string: {string: OperatorSpec}}, in_macro_quote?: boolean): Block
end

local BLOCK_INDEXES <const> = block.BLOCK_INDEXES

reader.BLOCK_INDEXES = BLOCK_INDEXES

local record ModuleMacroExport
   key: string
   sig: MacroSig
   decl: Block
end

local record ModuleMacroInfo
   exports: {ModuleMacroExport}
end

local module_macro_cache: {string: ModuleMacroInfo} = {}
local module_macro_missing: {string: boolean} = {}
local module_macro_loading: {string: boolean} = {}
local read_program_depth = 0

local function lang_heuristic(filename?: string, input?: string): BlockLang
   if filename then
      local pattern <const> = "(.*)%.([a-z]+)$"
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

local function is_macro_quote_token(t: Token): boolean
   return t.kind == "`" or t.tk:sub(1, 1) == "`"
end

local function unquote(str: string): string, boolean
   local f = str:sub(1, 1)
   if f == '"' or f == "'" then
      return str:sub(2, -2), false
   end
   f = str:match("^%[=*%[")
   if not f then
      return str, false
   end
   local l = #f + 1
   return str:sub(l, -l), true
end

local attributes <total>: {Attribute: boolean} = {
   ["const"] = true,
   ["close"] = true,
   ["total"] = true,
}
local is_attribute <const> = attributes as {string:boolean}

function reader.node_is_require_call(n: Block): string
   if not (n[BLOCK_INDEXES.OP.E1] and n[BLOCK_INDEXES.OP.E2]) then
      return nil
   end
   if n.kind == "op_dot" then
      -- `require("str").something`
      return reader.node_is_require_call(n[BLOCK_INDEXES.OP.E1])
   elseif n[BLOCK_INDEXES.OP.E1].kind == "identifier" and n[BLOCK_INDEXES.OP.E1].tk == "require"
      and n[BLOCK_INDEXES.OP.E2].kind == "expression_list" and #n[BLOCK_INDEXES.OP.E2] == 1
      and n[BLOCK_INDEXES.OP.E2][1].kind == "string"
   then
      -- `require("str")`
      local arg_block = n[BLOCK_INDEXES.OP.E2][1]
      if arg_block.tk then
         local value: string = unquote(arg_block.tk)
         return value
      end
   end
   return nil -- table.insert cares about arity
end

function reader.node_is_funcall(node: Block): boolean
   if node.kind == "paren" and node[BLOCK_INDEXES.PAREN.EXP] then
      return reader.node_is_funcall(node[BLOCK_INDEXES.PAREN.EXP])
   end
   return node.kind == "op_funcall" or node.kind == "macro_invocation"
end

local function starts_with(str: string, prefix: string): boolean
   return str:sub(1, #prefix) == prefix
end

local function macro_target_key(node: Block): string, boolean
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

local function path_block_to_string(node: Block): string
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

local record ReadState
   tokens: {Token}
   errs: {Error}
   filename: string
   end_alignment_hint: Error
   read_lang: BlockLang
   allow_macro_vars: boolean
   in_local_macro: boolean
   in_macro_quote: boolean
   ternary_middle: boolean
   custom_operators: {string: {string: OperatorSpec}}
   local_operators: {string: boolean}
   macro_sigs: {string: MacroSig}
   require_aliases: {string: string}
   imported_macro_decls: {Block}
   imported_macro_keys: {string: boolean}
   macro_aliases: {Block}
end

local enum BlockTypeListMode
   "rets"
   "decltuple"
   "casttype"
end

local read_type_list: function(ReadState, integer, BlockTypeListMode): integer, Block
local read_typeargs_if_any: function(ps: ReadState, i: integer): integer, Block
local read_expression: function(ReadState, integer): integer, Block, integer
local read_prefix_expression: function(ReadState, integer): integer, Block
local read_short_function: function(ReadState, integer): integer, Block
local read_argument: function(ReadState, integer): integer, Block, integer
local read_expression_and_tk: function(ps: ReadState, i: integer, tk: string): integer, Block
local read_statements: function(ReadState, integer, ? boolean): integer, Block
local read_argument_list: function(ReadState, integer): integer, Block, integer
local read_argument_type_list: function(ReadState, integer): integer, Block, integer
local read_macro_quote: function(ReadState, integer): integer, Block
local read_type: function(ReadState, integer): integer, Block, integer
local read_type_declaration: function(ps: ReadState, i: integer, node_name: BlockKind): integer, Block
local read_interface_name: function(ps: ReadState, i: integer): integer, Block, integer
local read_statement_fns: {string : function(ReadState, integer):(integer, Block)}
local needs_local_or_global: {string : function(ReadState, integer):(integer, Block)}
local read_nested_type: function(ReadState, integer, BlockKind): integer, Block
local read_call_or_assignment: function(ReadState, integer): integer, Block
local read_record_function: function(ReadState, integer): integer, Block

local function read_nested_expression(ps: ReadState, i: integer): integer, Block, integer
   local middle = ps.ternary_middle
   ps.ternary_middle = false
   local next_i, expression, n = read_expression(ps, i)
   ps.ternary_middle = middle
   return next_i, expression, n
end

local type ParseBody = function(ps: ReadState, i: integer, def: Block): integer, boolean
local read_enum_body: function(ps: ReadState, i: integer, def: Block): integer, boolean
local read_record_body: function(ps: ReadState, i: integer, def: Block): integer, boolean
local read_type_body_fns: {string:ParseBody}
local type_body_kinds <const>: {string: BlockKind} = {
   ["interface"] = "interface",
   ["record"] = "record",
   ["enum"] = "enum",
}

local function fail(ps: ReadState, i: integer, msg: string): integer
   if not ps.tokens[i] then
      local eof = ps.tokens[#ps.tokens]
      table.insert(ps.errs, { filename = ps.filename, y = eof.y, x = eof.x, msg = msg or "unexpected end of file" })
      return #ps.tokens
   end
   table.insert(ps.errs, { filename = ps.filename, y = ps.tokens[i].y, x = ps.tokens[i].x, msg = assert(msg, "syntax error, but no error message provided") })
   return math.min(#ps.tokens, i + 1)
end

local function end_at(node: Block, tk: Token)
   node.yend = tk.y
   node.xend = tk.x + #tk.tk - 1
end

local function verify_tk(ps: ReadState, i: integer, tk: string): integer
   if ps.tokens[i].tk == tk then
      return i + 1
   end
   return fail(ps, i, "syntax error, expected '" .. tk .. "'")
end

local function verify_end(ps: ReadState, i: integer, istart: integer, node: Block): integer
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

local node_mt: metatable<Block> = {
   __tostring = function(n: Block): string
      return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
   end
}

local function new_block(ps: ReadState, i: integer, kind?: BlockKind): Block
   local token = ps.tokens[i]
   return setmetatable({
      f = ps.filename,
      y = token.y,
      x = token.x,
      tk = token.tk,
      kind = kind or (token.kind as BlockKind),
      yend = token.y,
      xend = token.x + #token.tk - 1,
   }, node_mt)
end

local function new_type(ps: ReadState, i: integer, typename: BlockKind): Block
   return new_block(ps, i, typename)
end

local function split_dotted_path(path: string): {string}
   local out: {string} = {}
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

local function build_path_block_from_parts(f: string, y: integer, x: integer, parts: {string}): Block
   local function mk_ident(name: string): Block
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
      local dot: Block = setmetatable({
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

local function clone_block_deep(b: Block): Block
   if not b then
      return nil
   end
   local copy: Block = {
      kind = b.kind,
      f = b.f,
      y = b.y,
      x = b.x,
      tk = b.tk,
      yend = b.yend,
      xend = b.xend,
      is_longstring = b.is_longstring,
      custom_operator = b.custom_operator,
      operator_use = b.operator_use,
      short_function = b.short_function,
      lj_const = b.lj_const,
      safe_navigation = b.safe_navigation,
      compound = b.compound,
   }
   local child_indexes: {integer} = {}
   for k, child in pairs(b as {string|integer: Block | nil}) do
      if k is integer and child then
         table.insert(child_indexes, k)
      end
   end
   table.sort(child_indexes)
   for _, idx in ipairs(child_indexes) do
      copy[idx] = clone_block_deep(b[idx])
   end
   return setmetatable(copy, node_mt)
end

local function make_comment_block(ps: ReadState, c: Comment): Block
   local text = c.text
   local _, newlines = string.gsub(text, "\n", "")
   local last_line = text:match("([^\n]*)$") or ""
  local cb: Block = {
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

local function collect_comment_blocks(ps: ReadState, i: integer): {Block}
   local t = ps.tokens[i]
   if not (t and t.comments) then
      return {}
   end
   local out: {Block} = {}
   for _, c in ipairs(t.comments) do
      table.insert(out, make_comment_block(ps, c))
   end
   return out
end

local function new_generic(ps: ReadState, i: integer, typeargs: Block, typ: Block): Block
   local gt = new_type(ps, i, "generic_type")
   gt[BLOCK_INDEXES.GENERIC_TYPE.TYPEARGS] = typeargs
   gt[BLOCK_INDEXES.GENERIC_TYPE.BASE] = typ
   return gt
end

local function new_typedecl(ps: ReadState, i: integer, def: Block): Block
   local t = new_type(ps, i, "typedecl")
   t[BLOCK_INDEXES.TYPEDECL.TYPE] = def
   return t
end

local function new_tuple(ps: ReadState, i: integer, typelist?: Block): Block, Block
   local t = new_type(ps, i, "tuple_type")
   t[1] = typelist or new_block(ps, i, "type_list")
   return t, t[1]
end

local function new_nominal(ps: ReadState, i: integer, name?: string): Block
   local t = new_type(ps, i, "nominal_type")
   if name then
      t[BLOCK_INDEXES.NOMINAL_TYPE.NAME] = new_block(ps, i, "identifier")
      t[BLOCK_INDEXES.NOMINAL_TYPE.NAME].tk = name
   end
   return t
end

local function verify_kind(ps: ReadState, i: integer, kind: TokenKind, node_kind?: BlockKind): integer, Block
   if ps.tokens[i].kind == kind then
      return i + 1, new_block(ps, i, node_kind)
   end
   return fail(ps, i, "syntax error, expected " .. kind)
end

local function build_macro_sig(args: Block, errs: {Error}, filename: string, macro_name: string): MacroSig
   local sig: MacroSig = { kinds = {}, vararg = "" }
   if not args then
      return sig
   end

   local idx = 1
   for _, ab in ipairs(args) do
      local annot = ab and ab[BLOCK_INDEXES.ARGUMENT.TYPE]
      local ok = false
      local mode: string
      if annot and annot.kind == "nominal_type"
         and annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME]
         and annot[BLOCK_INDEXES.NOMINAL_TYPE.NAME].kind == "identifier"
      then
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

local operator_precedences: {string: integer} = {
   conditional = 0, logical_or = 1, disjunction = 1, logical_and = 2, conjunction = 2,
   comparison = 3, relational = 3, bitwise_or = 4, bitwise_xor = 5, bitwise_and = 6,
   shift = 7, concatenation = 8, concatenative = 8, additive = 9,
   multiplicative = 10, unary = 11, exponentiation = 12, power = 12,
   postfix = 100, primary = 100,
}

local reserved_operator_tokens: {string: boolean} = {
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

local function operator_error(ps: ReadState, where: Block, message: string)
   table.insert(ps.errs, { filename = ps.filename, y = where.y, x = where.x, msg = message })
end

local function macro_operator_symbol(name: Block): string
   if name and name.kind == "identifier" and name.tk:sub(1, 1) == "(" and name.tk:sub(-1) == ")" then
      return name.tk:sub(2, -2)
   end
end

local function valid_operator_symbol(symbol: string): boolean
   local identifier = symbol:match("^[%a_][%w_]*$")
   return symbol ~= "" and not reserved_operator_tokens[symbol] and not symbol:find("--", 1, true) and
      (identifier ~= nil or symbol:find("[%w_%s%(%){%}%[%],;'\"`$]") == nil)
end

local function read_macro_name(ps: ReadState, i: integer): integer, Block
   if ps.tokens[i].kind == "identifier" then return i + 1, new_block(ps, i, "identifier") end
   local name = new_block(ps, i, "error_block")
   if ps.tokens[i].tk ~= "(" then return fail(ps, i, "expected a macro name or parenthesized operator"), name end
   local opening = i
   i = i + 1
   local parts: {string} = {}
   local previous: Token
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

local function operator_macro_call_at(ps: ReadState, i: integer): boolean
   if ps.tokens[i].tk ~= "(" then return false end
   local j = i + 1
   local parts: {string} = {}
   local previous: Token
   while ps.tokens[j].tk ~= ")" and ps.tokens[j].kind ~= "$EOF$" do
      local token = ps.tokens[j]
      if token.tk == "(" or (previous and (token.y ~= previous.y or token.x ~= previous.x + #previous.tk)) then return false end
      table.insert(parts, token.tk)
      previous = token
      j = j + 1
   end
   local symbol = table.concat(parts)
   if ps.tokens[j].tk ~= ")" or not ps.tokens[j + 1] or ps.tokens[j + 1].tk ~= "!" or not valid_operator_symbol(symbol) then return false end
   -- Preserve ordinary `(name)!(...)` calls unless an operator of that name exists.
   return ps.macro_sigs["(" .. symbol .. ")"] ~= nil or not symbol:match("^[%a_][%w_]*$")
end

local function register_operator(ps: ReadState, spec: OperatorSpec, where: Block)
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

local function operator_word(b: Block): string
   if b and b.kind == "nominal_type" and b[1] and not b[2] then return b[1].tk end
   return nil
end

local function read_operator_annotation(ps: ReadState, node: Block, key: string): OperatorSpec
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

local function find_operator(ps: ReadState, at: integer, fixity: string): OperatorSpec, integer
   local best: OperatorSpec
   local width = 0
   for symbol, spec in pairs(ps.custom_operators[fixity]) do
      local text = ""
      local previous: Token
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

local function forbidden_macro_invocation(ps: ReadState, y: integer, x: integer): boolean
   if ps.in_local_macro or ps.in_macro_quote then
      table.insert(ps.errs, {
         filename = ps.filename, y = y, x = x,
         msg = "macro invocations cannot appear inside " .. (ps.in_macro_quote and "macro quotes" or "macro bodies"),
      })
      return true
   end
   return false
end

local function operator_invocation(ps: ReadState, token: Token, spec: OperatorSpec, lhs: Block, rhs?: Block): Block
   if forbidden_macro_invocation(ps, token.y, token.x) then
      return { kind = "error_block", f = ps.filename, y = token.y, x = token.x, tk = token.tk }
   end
   local target: Block = { kind = "identifier", tk = spec.binding, f = ps.filename, y = token.y, x = token.x }
   local args: Block = { kind = "expression_list", tk = spec.symbol, f = ps.filename, y = token.y, x = token.x, lhs, rhs }
   return { kind = "macro_invocation", tk = spec.symbol, f = ps.filename, y = token.y, x = token.x,
      operator_use = true, [BLOCK_INDEXES.MACRO_INVOCATION.MACRO] = target, [BLOCK_INDEXES.MACRO_INVOCATION.ARGS] = args }
end

local function extract_macro_owner_from_newtype(nt: Block): Block
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
   if typ and ((typ.kind as string) == "record" or (typ.kind as string) == "interface") then
      return typ
   end
   return nil
end

local function collect_macro_owner_paths_in_scope(container: Block, prefix: string, out: {string:boolean})
   if not container then
      return
   end
   for _, child in ipairs(container) do
      if child and (child.kind == "local_type" or child.kind == "global_type") then
         local var: Block
         local val: Block
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

local function collect_macro_owner_paths(node: Block): {string:boolean}
   local out: {string:boolean} = {}
   collect_macro_owner_paths_in_scope(node, "", out)
   return out
end

local function validate_attached_macro_owners(node: Block, errs: {Error}, filename: string)
   local owners = collect_macro_owner_paths(node)
   for _, child in ipairs(node) do
      if child
         and child.kind == "local_macro"
         and child[BLOCK_INDEXES.LOCAL_MACRO.OWNER]
         and not child[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS]
      then
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

local type SkipFunction = function(ReadState, integer): integer, Block | boolean

local function skip(ps: ReadState, i: integer, skip_fn: SkipFunction): integer, Block | boolean
   local err_ps: ReadState = {
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

local function failskip(ps: ReadState, i: integer, msg: string, skip_fn: SkipFunction, starti?: integer): integer
   local skip_i = skip(ps, starti or i, skip_fn)
   fail(ps, i, msg)
   return skip_i
end

local function search_tl_module(module_name: string): string, string
   local path = os.getenv("TL_PATH") or package.path
   local slash_name = module_name:gsub("%.", "/")
   for _, suffix in ipairs({".tl", ".d.tl"}) do
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

local function top_level_return_path(node: Block): string
   local out: string
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

local function collect_module_macro_exports(node: Block, errs: {Error}, filename: string): {ModuleMacroExport}
   local exports: {ModuleMacroExport} = {}
   local owners = collect_macro_owner_paths(node)
   local return_path = top_level_return_path(node)

   for _, stmt in ipairs(node) do
      if stmt
         and stmt.kind == "local_macro"
         and stmt[BLOCK_INDEXES.LOCAL_MACRO.OWNER]
         and not stmt[BLOCK_INDEXES.LOCAL_MACRO.IMPORT_ALIAS]
      then
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
               sig.operator = stmt.custom_operator
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

local function load_module_macro_info(ps: ReadState, module_name: string): ModuleMacroInfo
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

   local info: ModuleMacroInfo = {
      exports = collect_module_macro_exports(mod_node, ps.errs, found),
   }

   module_macro_cache[module_name] = info
   module_macro_loading[module_name] = nil
   return info
end

local function local_require_alias(stmt: Block): string, string
   if not stmt then
      return nil
   end

   local var: Block
   local exp: Block

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

local function ensure_required_alias_macros(ps: ReadState, alias: string)
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

local function read_type_body(ps: ReadState, i: integer, istart: integer, node: Block, tn: BlockKind): integer, Block
   local typeargs: Block
   local def: Block
   i, typeargs = read_typeargs_if_any(ps, i)

   def = new_type(ps, istart, tn)

   local ok: boolean
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

local function skip_type_body(ps: ReadState, i: integer): integer, boolean
   local tn = assert(type_body_kinds[ps.tokens[i].tk], ps.tokens[i].tk .. " has no parse body function")
   i = i + 1
   local ii, tt = read_type_body(ps, i, i - 1, {}, tn)
   return ii, not not tt
end

local function read_table_value(ps: ReadState, i: integer): integer, Block, integer
   local next_word = ps.tokens[i].tk
   if next_word == "record" or next_word == "interface" then
      local skip_i, e = skip(ps, i, skip_type_body)
      if e then
         fail(ps, i, next_word == "record"
                     and "syntax error: this syntax is no longer valid; declare nested record inside a record"
                     or  "syntax error: cannot declare interface inside a table; use a statement")
         return skip_i, new_block(ps, i, "error_block")
      end
   elseif next_word == "enum" and ps.tokens[i + 1].kind == "string" then
      i = failskip(ps, i, "syntax error: this syntax is no longer valid; declare nested enum inside a record", skip_type_body)
      return i, new_block(ps, i - 1, "error_block")
   end

   local e: Block
   i, e = read_nested_expression(ps, i)
   if not e then
      e = new_block(ps, i - 1, "error_block")
   end
   return i, e
end

local function read_table_item(ps: ReadState, i: integer, n?: integer): integer, Block, integer
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
      if ps.tokens[i+1].tk == "=" then
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = verify_kind(ps, i, "identifier", "string")
         node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk = '"' .. node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk .. '"'
         i = verify_tk(ps, i, "=")
         i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_table_value(ps, i)
         return i, node, n
      elseif ps.tokens[i+1].tk == ":" then
         local orig_i = i
         local try_ps: ReadState = {
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
         -- backtrack:
         table.remove(node, BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE) -- remove type
         i = orig_i
      end
   end

   node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY] = new_block(ps, i, "integer")
   node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.KEY].tk = tostring(n)
   i, node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] = read_expression(ps, i)
   if not node[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE] then
      return fail(ps, i, "expected an expression")
   end
   return i, node, n + 1
end

local type ReadItem = function<T>(ReadState, integer, ? integer): integer, T, integer

local enum SeparatorMode
   "sep"
   "term"
end

local function read_list<T>(ps: ReadState, i: integer, list: {T}, close: {string:boolean}, sep: SeparatorMode, read_item: ReadItem<T>): integer, {T}
   local n = 1
   while ps.tokens[i].kind ~= "$EOF$" do
      if close[ps.tokens[i].tk] then
         end_at(list as Block, ps.tokens[i])
         break
      end
      local item: T
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
         local msg: string
         -- heuristic for parenthesized lists
         if first == ")" and ps.tokens[i].tk == "=" then
            msg = "syntax error, cannot perform an assignment here (did you mean '=='?)"
            i = failskip(ps, i, msg, read_expression, i + 1)
         else
            table.insert(options, "','")
            msg = "syntax error, expected one of: " .. table.concat(options, ", ")
            fail(ps, i, msg)
         end
         -- heuristic for error recovery to avoid a cascade of errors:
         -- * if we're parsing a bracketed list, assume the missing token is a separator;
         -- * otherwise, if we have a line break, insert expected terminator token.
         if first ~= "}" and ps.tokens[i].y ~= ps.tokens[i-1].y then
            -- FIXME closing token may not be a keyword (but non-keywords are checked with verify_tk, so it should work)
            table.insert(ps.tokens, i, { tk = first, y = ps.tokens[i-1].y, x = ps.tokens[i-1].x + 1, kind = "keyword" })
            return i, list
         end
      end
   end
   return i, list
end

local function read_bracket_list<T>(ps: ReadState, i: integer, list: {T}, open: string, close: string, sep: SeparatorMode, read_item: ReadItem<T>): integer, {T}
   i = verify_tk(ps, i, open)
   i = read_list(ps, i, list, { [close] = true }, sep, read_item)
   i = verify_tk(ps, i, close)
   return i, list
end

local function read_table_literal(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "literal_table")
   local middle = ps.ternary_middle
   ps.ternary_middle = false
   i, node = read_bracket_list(ps, i, node, "{", "}", "term", read_table_item)
   ps.ternary_middle = middle
   return i, node
end

local function read_macro_args_with_sig(ps: ReadState, i: integer, sig: MacroSig): integer, Block
   local node = new_block(ps, i, "expression_list")
   local function read_item(ps2: ReadState, ii: integer, n: integer): integer, Block, integer
      local expected: string
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
            local sblk: Block
            while read_type_body_fns[tk0] and ps2.tokens[curr_i + 1] and ps2.tokens[curr_i + 1].kind == "identifier" do
               local ni: integer
               local lt: Block
               local tn = assert(type_body_kinds[tk0])
               ni, lt = read_nested_type(ps2, curr_i, tn)
               if not sblk then sblk = new_block(ps2, curr_i, "statements") end
               table.insert(sblk, lt)
               curr_i = ni
               tk0 = ps2.tokens[curr_i].tk
            end

            local j = sblk and curr_i or ii
            local paren_depth = 0
            local best_j: integer
            local best_block: Block
            local need_do_end_error = false
            local can_split_on_comma = false
            if sig then
               local fixed = #sig.kinds
               local has_vararg_stmt = sig.vararg == "stmt"
               if (n <= fixed - 1) or has_vararg_stmt then
                  can_split_on_comma = true
               end
            end

            local function try_parse_until(jend: integer): boolean
               local slice: {Token} = {}
               local nt = 0
               for k = ii, jend - 1 do
                  nt = nt + 1
                  slice[nt] = ps2.tokens[k]
               end
               nt = nt + 1
               local eof_prev = ps2.tokens[math.max(ii, jend - 1)]
               slice[nt] = { x = eof_prev.x, y = eof_prev.y, tk = "$EOF$", kind = "$EOF$" }
               local errs2: {Error} = {}
               local block_ast = reader.read_program(slice, errs2, ps2.filename, ps2.read_lang, true, true)
               if #errs2 == 0 and block_ast then
                  if can_split_on_comma
                     and block_ast.kind == "statements"
                     and #block_ast == 1
                  then
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
               -- Fallback: parse everything until j (or before ')') even if errors, to surface them
               local slice: {Token} = {}
               local nt = 0
               for k = (sblk and curr_i or ii), j - 1 do
                  nt = nt + 1
                  slice[nt] = ps2.tokens[k]
               end
               nt = nt + 1
               local eof_prev = ps2.tokens[math.max(ii, j - 1)]
               slice[nt] = { x = eof_prev.x, y = eof_prev.y, tk = "$EOF$", kind = "$EOF$" }
               local errs2: {Error} = {}
               local block_fallback = reader.read_program(slice, errs2, ps2.filename, ps2.read_lang, true, true)
               for _, e in ipairs(errs2) do table.insert(ps2.errs, e) end
               best_block = block_fallback
               best_j = j
            end

            -- do...end wrapper for top level stmt with commas
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

local function read_trying_list<T>(ps: ReadState, i: integer, list: {T}, read_item: ReadItem<T>, ret_lookahead?: boolean): integer, {T}
   local try_ps: ReadState = {
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
   local tryi, item: integer, T = read_item(try_ps, i)
   if not item then
      return i, list
   end
   for _, e in ipairs(try_ps.errs) do
      table.insert(ps.errs, e)
   end
   i = tryi
   table.insert(list, item)
   while ps.tokens[i].tk == ","
   and (not ret_lookahead
        or (not (ps.tokens[i + 1].kind == "identifier"
                 and ps.tokens[i + 2] and ps.tokens[i + 2].tk == ":")))
   do
      i = i + 1
      i, item = read_item(ps, i)
      table.insert(list, item)
   end
   return i, list
end

local function read_anglebracket_list(ps: ReadState, i: integer, read_item: ReadItem<Block>): integer, Block
   local second = ps.tokens[i+1]
   if second.tk == ">" then
      return fail(ps, i+1, "type argument list cannot be empty")
   elseif second.tk == ">>" then
      -- tokenizer hack: consume one bracket from '>>', don't skip over it
      second.tk = ">"
      fail(ps, i+1, "type argument list cannot be empty")
      return i+1
   end

   local typelist: Block = new_type(ps, i, "type_list")
   i = verify_tk(ps, i, "<")
   i = read_list(ps, i, typelist, { [">"] = true, [">>"] = true, }, "sep", read_item)
   if ps.tokens[i].tk == ">" then
      i = i + 1
   elseif ps.tokens[i].tk == ">>" then
      -- tokenizer hack: consume one bracket from '>>', don't increment i
      ps.tokens[i].tk = ">"
   else
      return fail(ps, i, "syntax error, expected '>'")
   end
   return i, typelist
end

local function read_typearg(ps: ReadState, i: integer): integer, Block, integer
   local name = ps.tokens[i].tk
   local constraint: Block
   local t = new_type(ps, i, "typeargs")
   i = verify_kind(ps, i, "identifier")
   if ps.tokens[i].tk == "is" then
      i = i + 1
      i, constraint = read_interface_name(ps, i) -- FIXME what about generic interfaces
   end
   t[BLOCK_INDEXES.TYPEARG.NAME] = new_block(ps, i, "identifier")
   t[BLOCK_INDEXES.TYPEARG.NAME].tk = name
   t[BLOCK_INDEXES.TYPEARG.CONSTRAINT] = constraint
   return i, t
end

local function read_return_types(ps: ReadState, i: integer): integer, Block
   local iprev = i - 1
   local t: Block

   i, t = read_type_list(ps, i, "rets")
   local list = t[1]
   if list and #list == 0 then
      t.x = ps.tokens[iprev].x
      t.y = ps.tokens[iprev].y
   end
   return i, t
end

read_typeargs_if_any = function(ps: ReadState, i: integer): integer, Block
   if ps.tokens[i].tk == "<" then
      return read_anglebracket_list(ps, i, read_typearg)
   end
   return i
end

local function read_function_type(ps: ReadState, i: integer): integer, Block
  local typeargs: Block
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

local function read_simple_type_or_nominal(ps: ReadState, i: integer): integer, Block
   local tk = ps.tokens[i].tk
   if tk == "table" and ps.tokens[i + 1].tk ~= "."  then
      local typ = new_type(ps, i, "map_type")
      local any = new_type(ps, i, "nominal_type")
      any.tk = "any"
      typ[BLOCK_INDEXES.MAP_TYPE.KEYS] = any
      typ[BLOCK_INDEXES.MAP_TYPE.VALUES] = any
      return i + 1, typ
   end

   local typ: Block
   if ps.allow_macro_vars and tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident: Block
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "syntax error, expected identifier")
      end
      typ = new_nominal(ps, i - 1, nil)
      local mv: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident, tk = "$" }
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
         local ident: Block
         i, ident = verify_kind(ps, i, "identifier")
         if not ident then
            return fail(ps, i, "syntax error, expected identifier")
         end
         local nom: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident, tk = "$" }
         table.insert(typ, nom)
         i = i + 0
      else
         return fail(ps, i, "syntax error, expected identifier")
      end
   end

   if ps.tokens[i].tk == "<" then
      local t: Block
      i, t = read_anglebracket_list(ps, i, read_type)
      table.insert(typ, t)
   end
   return i, typ
end

local function read_base_type(ps: ReadState, i: integer): integer, Block, integer
   local tk = ps.tokens[i].tk
   if ps.tokens[i].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i].tk == "$") then
      return read_simple_type_or_nominal(ps, i)
   elseif ps.tokens[i].kind == "string" then
      local node = new_block(ps, i, "string")
      local _, is_long = unquote(tk)
      node.is_longstring = is_long
      return i + 1, node
   elseif ps.tokens[i].kind == "number" or ps.tokens[i].kind == "integer" then
      local node: Block
      i, node = verify_kind(ps, i, ps.tokens[i].kind)
      return i, node
   elseif tk == "true" or tk == "false" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "{" then
      local istart = i
      i = i + 1
      local t: Block
      i, t = read_type(ps, i)
      if not t then
         return i
      end
      if ps.tokens[i].tk == "}" then
         local decl = new_type(ps, istart, "array_type")
         decl[BLOCK_INDEXES.ARRAY_TYPE.ELEMENT] = t
         end_at(decl , ps.tokens[i])
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
         end_at(decl , ps.tokens[i])
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
         end_at(decl , ps.tokens[i])
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

read_type = function(ps: ReadState, i: integer): integer, Block, integer
   local bt: Block
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
   if ps.tokens[i].tk == "|" and ps.tokens[i + 1].tk ~= "->" then
      local u = new_type(ps, istart, "union_type")
      u[1] = bt
      while ps.tokens[i].tk == "|" and ps.tokens[i + 1].tk ~= "->" do
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

read_type_list = function(ps: ReadState, i: integer, mode: BlockTypeListMode): integer, Block
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
      -- Parentheses followed by a union pipe group one type rather than a tuple.
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

local function read_function_args_rets_body(ps: ReadState, i: integer, node: Block): integer, Block
   local istart = i - 1
   i, node[BLOCK_INDEXES.FUNCTION.TYPEARGS] = read_typeargs_if_any(ps, i)
   --node[2]will be typeargs
   i, node[BLOCK_INDEXES.FUNCTION.ARGS] --[[, node.min_arity]] = read_argument_list(ps, i)
   i, node[BLOCK_INDEXES.FUNCTION.RETS] = read_return_types(ps, i)
   --node[4] will be .rets
   local middle = ps.ternary_middle
   ps.ternary_middle = false
   i, node[BLOCK_INDEXES.FUNCTION.BODY] = read_statements(ps, i)
   ps.ternary_middle = middle
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_function_value(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "function")
   i = verify_tk(ps, i, "function")
   return read_function_args_rets_body(ps, i, node)
end

local function skip_any_function(ps: ReadState, i: integer): integer, Block
   i = verify_tk(ps, i, "function")

   while ps.tokens[i] and (ps.tokens[i].kind == "identifier" or ps.tokens[i].tk == "." or ps.tokens[i].tk == ":") do
      i = i + 1
   end
   local dummy = new_block(ps, i, "function")
   return read_function_args_rets_body(ps, i, dummy)
end

read_macro_quote = function(ps: ReadState, i: integer): integer, Block
   if not ps.in_local_macro then
      return fail(ps, i, "macro quotes can only be used inside macro statements")
   end
   local token = ps.tokens[i]
   local node = new_block(ps, i, "macro_quote")
   local tk = token.tk
   -- Determine if this is single (`...`) or triple (```...```) backtick
   local triple = tk:sub(1, 3) == "```"
   local delim = triple and 3 or 1
   local code = tk:sub(delim + 1, -(delim + 1))
   if code:match("^%s*$") then
      return fail(ps, i, "macro quotes cannot be empty")
   end

   local quoted_block: Block
   local errs: {Error}

   if triple then
      -- Triple backticks: treat content as a statements block
      -- here we allow bare `$block` lines to splice Statement args
      -- pre-scan the quoted code for such lines, remove them before parsing, then stitch the parsed statements together with the splices to preserve order
      -- this is all so we can do something like
      -- ```
      -- $expand
      -- function my_func_or_whatever() end
      -- ```
      --
      local splices = {}
      local kept_lines: {string} = {}
      local line_index = 1
      for line in (code .. "\n"):gmatch("([^\n]*)\n") do
         local ident = line:match("^%s*%$([%a_][%w_]*)%s*;?%s*$")
         if ident then
            local y = token.y + (line_index - 1)
            local x = token.x + delim
            local ident_block: Block = { f = ps.filename, y = y, x = x + 1, kind = "identifier", tk = ident }
            local mv: Block = { f = ps.filename, y = y, x = x, kind = "macro_var", [BLOCK_INDEXES.MACRO_VAR.NAME] = ident_block, tk = "$" }
            table.insert(splices, { idx = line_index, blk = mv })
            -- omit this line from kept_lines
         else
            table.insert(kept_lines, line)
         end
         line_index = line_index + 1
      end

      local kept_code = table.concat(kept_lines, "\n")
      local parsed_block: Block
      parsed_block, errs = reader.read(kept_code, ps.filename, ps.read_lang, true, true, ps.custom_operators, true)

      -- splices gotta be merge with parsed statements
      if #splices > 0 and parsed_block and parsed_block.kind == "statements" then
         local combined: Block = { f = ps.filename, y = token.y, x = token.x + delim, kind = "statements" }
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
      -- Single backtick: treat content strictly as an expression
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

   -- making syntax errors relative to the actual macro quote
   if errs and #errs > 0 then
      local x0 = token.x + delim -- first content column if error is on first internal line
      local y0 = token.y         -- first content line maps to token.y
      local ret_prefix = not triple and #("return ") or 0 -- exprs have "return " before
      for _, e in ipairs(errs) do
         local ey = e.y or 1
         local ex = e.x or 1
         local ny = y0 + (ey - 1)
         local nx: integer
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

local function read_literal(ps: ReadState, i: integer): integer, Block
   local tk = ps.tokens[i].tk
  local kind = ps.tokens[i].kind
   if (kind == "identifier" and ps.tokens[i + 1].tk == "->") or tk == "|" or tk == "||" then
      return read_short_function(ps, i)
   elseif kind == "identifier" then
      return verify_kind(ps, i, "identifier")
  elseif kind == "string" then
      local node = new_block(ps, i, "string")
      local _, is_long = unquote(tk)
      node.is_longstring = is_long
      return i + 1, node
   elseif kind == "number" or kind == "integer" then
      local node: Block
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
   local precedences: {integer:{string:integer}} = {
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

   local is_right_assoc: {string:boolean} = {
      ["^"] = true,
      [".."] = true,
   }

   local op_map: {integer: {string: BlockKind}} = {
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
      }
   }

   local args_starters: {TokenKind:boolean} = {
      ["("] = true,
      ["{"] = true,
      ["string"] = true,
   }

   local E: function(ReadState, integer, Block, integer): integer, Block

   local function after_valid_prefixexp(ps: ReadState, prevnode: Block, i: integer): boolean
      return prevnode.kind == "paren" or ps.tokens[i - 1].kind == ")" -- '(' exp ')'
         or prevnode.kind == "op_funcall"
         or prevnode.kind == "op_index"
         or prevnode.kind == "op_dot"
         or prevnode.kind == "op_colon"
         or prevnode.kind == "identifier"
         or prevnode.kind == "macro_invocation"
   end

   -- small hack: for the sake of `tl types`, parse an invalid binary exp
   -- as a paren to produce a unary indirection on e1 and save its location.
   local function failstore(ps: ReadState, tkop: Token, e1: Block): Block
      local paren: Block = { f = ps.filename, y = tkop.y, x = tkop.x, kind = "paren", [BLOCK_INDEXES.PAREN.EXP] = e1 }
      return paren
   end

   local function P(ps: ReadState, i: integer): integer, Block
      if ps.tokens[i].kind == "$EOF$" then
         return i
      end
      local e1: Block
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
         local ident: Block
         i, ident = verify_kind(ps, i, "identifier")
         if not ident then
            return i
         end
         local macro_var: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
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
         local paren: Block = { f = ps.filename, y = t1.y, x = t1.x, kind = "paren", [BLOCK_INDEXES.PAREN.EXP] = e1 }
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
         local safe_navigation = ps.tokens[i].tk == "?."
         local tkop = ps.tokens[i]
         if safe_navigation then
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
         if tkop.kind == "," or tkop.kind == ")" then -- check most common terminators first
            break
         end
         if tkop.tk == "." or tkop.tk == ":" then
            local op_kind = op_map[2][tkop.tk]

            local prev_i = i

            local key: Block
            i = i + 1
            if ps.tokens[i].tk == "(" and tkop.tk == "." then
               i, key = read_macro_name(ps, i)
            elseif ps.allow_macro_vars and ps.tokens[i].tk == "$" then
               local dtk = ps.tokens[i]
               i = i + 1
               local ident: Block
               i, ident = verify_kind(ps, i, "identifier")
               if not ident then
                  return i, failstore(ps, tkop, e1)
               end
               local macro_key: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
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
            local argument: Block
            local mname: string
            local has_colon: boolean
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
                  local _, is_long = unquote(next_tk.tk)
                  argument.is_longstring = is_long
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
            local inv: Block = { f = ps.filename, y = args.y, x = args.x, kind = "macro_invocation", [BLOCK_INDEXES.MACRO_INVOCATION.MACRO] = e1, [BLOCK_INDEXES.MACRO_INVOCATION.ARGS] = args, tk = tkop.tk }
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

            local idx: Block
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
            local argument: Block
            if tkop.kind == "string" then
               argument = new_block(ps, i, "string")
               local _, is_long = unquote(tkop.tk)
               argument.is_longstring = is_long
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
            local cast: Block
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
         if safe_navigation then
            e1.safe_navigation = true
         end
      end

      local reference = e1.kind == "op_dot" and e1[BLOCK_INDEXES.OP.E2] or e1
      if macro_operator_symbol(reference) then
         fail(ps, i, "operator macro references require '!()' or a local macro import")
      end
      return i, e1
   end

   read_prefix_expression = function(ps: ReadState, i: integer): integer, Block
      local lhs: Block
      i, lhs = P(ps, i)
      local tk = ps.tokens[i].tk
      if lhs and tk ~= "~=" then
         i, lhs = E(ps, i, lhs, 0)
      end
      return i, lhs
   end

   local function next_operator(ps: ReadState, i: integer): integer, boolean, OperatorSpec, integer, string
      local postfix, postfix_width = find_operator(ps, i, "postfix")
      local infix, infix_width = find_operator(ps, i, "infix")
      local spec = postfix or infix
      if infix and postfix and #infix.symbol > #postfix.symbol then spec = infix end
      if spec then return spec.precedence, spec.right_associative, spec, spec == postfix and postfix_width or infix_width, spec.fixity end
      local tk = ps.tokens[i].tk
      if ps.ternary_middle and tk == ":" then return nil end
      return precedences[2][tk], is_right_assoc[tk], nil, 1, "infix"
   end

   E = function(ps: ReadState, i: integer, lhs: Block, min_precedence: integer): integer, Block
      while true do
         local precedence, right, custom, width, fixity = next_operator(ps, i)
         if not precedence or precedence < min_precedence then break end
         local token = ps.tokens[i]
         i = i + width
         if fixity == "postfix" then
            lhs = operator_invocation(ps, token, custom, lhs)
         else
            local rhs: Block
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
                  [BLOCK_INDEXES.OP.E1] = lhs, [BLOCK_INDEXES.OP.E2] = rhs, tk = token.tk }
            end
         end
      end
      return i, lhs
   end

   read_expression = function(ps: ReadState, i: integer): integer, Block, integer
      local lhs: Block
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
      -- if cursor moved, a more specific error was already thrown
      if i == istart then
         i = fail(ps, i, "expected an expression")
      end
      return i
   end
end

read_short_function = function(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "function")
   node.short_function = true
   local args = new_block(ps, i, "argument_list")
   if ps.tokens[i].tk == "||" then
      i = i + 1
   elseif ps.tokens[i].tk == "|" then
      i = i + 1
      while ps.tokens[i].tk ~= "|" and ps.tokens[i].kind ~= "$EOF$" do
         local argument: Block
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
   i = verify_tk(ps, i, "->")
   if ps.tokens[i].tk == "do" then
      local middle = ps.ternary_middle
      ps.ternary_middle = false
      i, node[BLOCK_INDEXES.FUNCTION.BODY] = read_statements(ps, i + 1)
      ps.ternary_middle = middle
      end_at(node, ps.tokens[i])
      i = verify_tk(ps, i, "end")
   else
      local exp: Block
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

read_expression_and_tk = function(ps: ReadState, i: integer, tk: string): integer, Block
   local e: Block
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

      -- try to resync the reader for a bit
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

local function read_variable_name(ps: ReadState, i: integer): integer, Block, integer
   local node: Block
   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      i = i + 1
      local ident: Block
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
         local annotation: Block
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

read_argument = function(ps: ReadState, i: integer): integer, Block, integer
   local node: Block
   local vararg_name: Block
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
      local argtype: Block

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

read_argument_list = function(ps: ReadState, i: integer): integer, Block, integer
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

local function read_argument_type(ps: ReadState, i: integer): integer, Block, integer
   local opt = 0
   local is_va = false
   local argument_name: string | nil = nil

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

   local typ: Block; i, typ = read_type(ps, i)
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

read_argument_type_list = function(ps: ReadState, i: integer): integer, Block, integer
   local ars: Block = {}
   i = read_bracket_list(ps, i, ars, "(", ")", "sep", read_argument_type)
   local t, list = new_tuple(ps, i)

   local min_arity = 0
   for l, ar in ipairs(ars) do
      list[l] = ar
   end
   return i, t, min_arity
end

local function read_identifier(ps: ReadState, i: integer): integer, Block, integer
   if ps.tokens[i].kind == "identifier" then
      return i + 1, new_block(ps, i, "identifier")
   end
   i = fail(ps, i, "syntax error, expected identifier")
   return i, new_block(ps, i, "error_block")
end

local function read_local_function(ps: ReadState, i: integer): integer, Block
   i = verify_tk(ps, i, ps.tokens[i].tk == "const" and "const" or "local")
   i = verify_tk(ps, i, "function")
   local node = new_block(ps, i - 2, "local_function")
   i, node[BLOCK_INDEXES.LOCAL_FUNCTION.NAME] = read_identifier(ps, i)
   return read_function_args_rets_body(ps, i, node)
end

local function read_if_block(ps: ReadState, i: integer, node: Block, is_else?: boolean): integer, Block
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

local function read_if(ps: ReadState, i: integer): integer, Block
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

local function read_while(ps: ReadState, i: integer): integer, Block
   local istart = i
   local node = new_block(ps, i, "while")
   i = verify_tk(ps, i, "while")
   i, node[BLOCK_INDEXES.WHILE.COND] = read_expression_and_tk(ps, i, "do")
   i, node[BLOCK_INDEXES.WHILE.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_fornum(ps: ReadState, i: integer): integer, Block
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

local function read_forin(ps: ReadState, i: integer): integer, Block
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

local function read_for(ps: ReadState, i: integer): integer, Block
   if ps.tokens[i+1].kind == "identifier" and ps.tokens[i+2].tk == "=" then
      return read_fornum(ps, i)
   else
      return read_forin(ps, i)
   end
end

local function read_repeat(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "repeat")
   i = verify_tk(ps, i, "repeat")
   i, node[BLOCK_INDEXES.REPEAT.BODY] = read_statements(ps, i)
   i = verify_tk(ps, i, "until")
   i, node[BLOCK_INDEXES.REPEAT.COND] = read_expression(ps, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function read_do(ps: ReadState, i: integer): integer, Block
   local istart = i
   local node = new_block(ps, i, "do")
   i = verify_tk(ps, i, "do")
   i, node[BLOCK_INDEXES.DO.BODY] = read_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_break(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "break")
   i = verify_tk(ps, i, "break")
   return i, node
end

local function read_goto(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "goto")
   i = verify_tk(ps, i, "goto")
   node[BLOCK_INDEXES.GOTO.LABEL] = new_block(ps, i, "identifier")
   node[BLOCK_INDEXES.GOTO.LABEL].tk = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   return i, node
end

local function read_label(ps: ReadState, i: integer): integer, Block
   local node = new_block(ps, i, "label")
   i = verify_tk(ps, i, "::")
   node[BLOCK_INDEXES.LABEL.NAME] = new_block(ps, i, "identifier")
   node[BLOCK_INDEXES.LABEL.NAME].tk = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   i = verify_tk(ps, i, "::")
   return i, node
end

local stop_statement_list: {string:boolean} = {
   ["end"] = true,
   ["else"] = true,
   ["elseif"] = true,
   ["until"] = true,
}

local stop_return_list: {string:boolean} = {
   [";"] = true,
   ["$EOF$"] = true,
}

for k, v in pairs(stop_statement_list) do
   stop_return_list[k] = v
end

local function read_return(ps: ReadState, i: integer): integer, Block
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

read_nested_type = function(ps: ReadState, i: integer, tn: BlockKind): integer, Block
   local istart = i
   i = i + 1 -- skip 'record' or 'enum'

   local v: Block
   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident: Block
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a variable name")
      end
      local macro_var: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
      v = macro_var
   else
      i, v = verify_kind(ps, i, "identifier", "type_identifier")
      if not v then
         return fail(ps, i, "expected a variable name")
      end
   end

   local nt: Block = new_block(ps, istart, "newtype")

   local ndef: Block
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

read_enum_body = function(ps: ReadState, i: integer, def: Block): integer, boolean
   while ps.tokens[i].tk ~= "$EOF$" and ps.tokens[i].tk ~= "end" do
      local comment_blocks = collect_comment_blocks(ps, i)
      local item: Block
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

local metamethod_names: {string:boolean} = {
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

local function read_macroexp(ps: ReadState, istart: integer, iargs: integer): integer, Block
   local node = new_block(ps, istart, "macroexp")

   local i: integer
   local idx = 1
   if ps.tokens[istart + 1].tk == "<" then
      i, node[idx] = read_anglebracket_list(ps, istart + 1, read_typearg)
      idx = idx + 1
   else
      i = iargs
   end

   i, node[idx] --[[, node.min_arity]] = read_argument_list(ps, i)
   idx = idx + 1
   i, node[idx] = read_return_types(ps, i)
   idx = idx + 1
   i = verify_tk(ps, i, "return")
   i, node[idx] = read_expression(ps, i)
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function read_where_clause(ps: ReadState, i: integer, def: Block): integer, Block
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

read_interface_name = function(ps: ReadState, i: integer): integer, Block, integer
   local istart = i
   local typ: Block


   i, typ = read_simple_type_or_nominal(ps, i)
   if (not typ) or typ.kind ~= "nominal_type" then
      return fail(ps, istart, "expected an interface")
   end

   return i, typ

end

local function read_array_interface_type(ps: ReadState, i: integer): integer, Block
   local t: Block
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

local function extract_userdata_from_interface_list(ps: ReadState, i: integer, interface_list: Block): boolean
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

read_record_body = function(ps: ReadState, i: integer, def: Block): integer, boolean
   if ps.tokens[i].tk == "{" then
      local atype: Block
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
         local atype: Block
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
   local meta_fields: Block

   while not (ps.tokens[i].kind == "$EOF$" or ps.tokens[i].tk == "end") do
      local comment_blocks = collect_comment_blocks(ps, i)
      local tn = ps.tokens[i].tk
      local tn_kind = type_body_kinds[tn]
      if ps.tokens[i].tk == "userdata" and ps.tokens[i+1].tk ~= ":" then
         for _, cb in ipairs(comment_blocks) do
            table.insert(def, cb)
         end
         table.insert(def, new_block(ps, i, "userdata"))
         i = i + 1
      elseif ps.tokens[i].tk == "{" then
         return fail(ps, i, "syntax error: this syntax is no longer valid; declare array interface at the top with 'is {...}'")
      elseif ps.tokens[i].tk == "type" and ps.tokens[i + 1].tk ~= ":" then
         i = i + 1

         local lt: Block
         i, lt = read_type_declaration(ps, i, "local_type") -- local_type Block will be discarded
         if not lt then
            return fail(ps, i, "expected a type definition")
         end

         for _, cb in ipairs(comment_blocks) do
            table.insert(fields, cb)
         end
         table.insert(fields, lt)
      elseif tn_kind and ps.tokens[i+1].tk ~= ":" then
         if def.kind == "interface" and tn == "record" then
            i = failskip(ps, i, "interfaces cannot contain record definitions", skip_type_body)
         else
            local lt: Block
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
         if ps.tokens[i].tk == "metamethod" and ps.tokens[i+1].tk ~= ":" then
            is_metamethod = true
            i = i + 1
         end

         local v: Block
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
            local t: Block
            i, t = read_type(ps, i)
            if not t then
               return fail(ps, i, "expected a type")
            end

            local field_name: string
            if v.kind == "string" then
               field_name = unquote(v.tk)
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

local function read_newtype(ps: ReadState, i: integer): integer, Block
   local node: Block = new_block(ps, i, "newtype")
   local def: Block
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

local function read_assignment_expression_list(ps: ReadState, i: integer, asgn: Block): integer, Block
   asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] = new_block(ps, i, "expression_list")
   repeat
      i = i + 1
      local val: Block
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
   local function read_variable(ps: ReadState, i: integer): integer, Block, integer
      local node: Block
      i, node = read_expression(ps, i)
      return i, node
   end

   read_call_or_assignment = function(ps: ReadState, i: integer): integer, Block
      local exp: Block
      local istart = i
      i, exp = read_prefix_expression(ps, i)
      if not exp then
         return i
      end

      if reader.node_is_funcall(exp) then
         return i, exp
      end

      if exp.kind ~= "identifier" and exp.kind ~= "op_index" and exp.kind ~= "op_dot" and exp.kind ~= "macro_var" then
         return fail(ps, i, "syntax error")
      end

      local asgn: Block = new_block(ps, istart, "assignment")
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

      local compound_ops: {string: boolean} = {
         ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
         ["%="] = true, ["&="] = true, ["|="] = true, ["~="] = true,
         ["<<="] = true, [">>="] = true, ["~>>="] = true, ["..="] = true,
      }
      local assignment_op = ps.tokens[i].tk
      if compound_ops[assignment_op] then
         asgn.compound = assignment_op:sub(1, -2)
         if #asgn[BLOCK_INDEXES.ASSIGNMENT.VARS] ~= 1 then
            fail(ps, i, "compound assignment requires a single variable")
         end
      elseif assignment_op ~= "=" then
         verify_tk(ps, i, "=")
         return i
      end

      i, asgn = read_assignment_expression_list(ps, i, asgn)
      if asgn and asgn.compound and #asgn[BLOCK_INDEXES.ASSIGNMENT.EXPS] ~= 1 then
         fail(ps, i - 1, "compound assignment requires a single expression")
      end
      return i, asgn
   end
end

local function read_variable_declarations(ps: ReadState, i: integer, node_name: BlockKind): integer, Block
   local asgn: Block = new_block(ps, i, node_name)

   asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS] = new_block(ps, i, "variable_list")
   i = read_trying_list(ps, i, asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS], read_variable_name)
   if #asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS] == 0 then
      return fail(ps, i, "expected a local variable definition")
   end

   end_at(asgn[BLOCK_INDEXES.LOCAL_DECLARATION.VARS], ps.tokens[i - 1])

   i, asgn[BLOCK_INDEXES.LOCAL_DECLARATION.DECL] = read_type_list(ps, i, "decltuple")

   if ps.tokens[i].tk == "=" then
      -- produce nice error message when using <= 0.7.1 syntax
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

local function read_type_require(ps: ReadState, i: integer, asgn: Block): integer, Block
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

local function read_special_type_declaration(ps: ReadState, i: integer, asgn: Block): boolean, integer, Block
   if ps.tokens[i].tk == "require" then
      return true, read_type_require(ps, i, asgn)
   elseif ps.tokens[i].tk == "pcall" then
      fail(ps, i, "pcall() cannot be used in type declarations")
      return true, i
   end
   return false, i, asgn
end

read_type_declaration = function(ps: ReadState, i: integer, node_name: BlockKind): integer, Block
   local asgn: Block = new_block(ps, i, node_name)
   local var: Block
   local BIDX = node_name == "local_type" and BLOCK_INDEXES.LOCAL_TYPE or BLOCK_INDEXES.GLOBAL_TYPE

   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident: Block
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a type name")
      end
      local macro_var: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
      var = macro_var
   else
      i, var = verify_kind(ps, i, "identifier")
      if not var then
         return fail(ps, i, "expected a type name")
      end
   end
   local typeargs: Block
   local itypeargs = i
   i, typeargs = read_typeargs_if_any(ps, i)

   asgn[BIDX.VAR] = var

   if node_name == "global_type" and ps.tokens[i].tk ~= "=" then
      return i, asgn
   end

   i = verify_tk(ps, i, "=")

   if ps.tokens[i].kind == "identifier" then
      local is_done: boolean
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

local function read_type_constructor(ps: ReadState, i: integer, node_name: BlockKind, tn: BlockKind): integer, Block
   local asgn: Block = new_block(ps, i, node_name)
   local nt: Block = new_block(ps, i, "newtype")
   local BIDX = node_name == "local_type" and BLOCK_INDEXES.LOCAL_TYPE or BLOCK_INDEXES.GLOBAL_TYPE
   asgn[BIDX.VALUE] = nt
   local istart = i
   local def: Block

   i = i + 2 -- skip `local` or `global`, and the constructor name

   if ps.allow_macro_vars and ps.tokens[i].tk == "$" then
      local dtk = ps.tokens[i]
      i = i + 1
      local ident: Block
      i, ident = verify_kind(ps, i, "identifier")
      if not ident then
         return fail(ps, i, "expected a type name")
      end
      local macro_var: Block = { f = ps.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
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

local function skip_type_declaration(ps: ReadState, i: integer): integer, Block
   return read_type_declaration(ps, i + 1, "local_type")
end

local function read_local_macroexp(ps: ReadState, i: integer): integer, Block
   local istart = i
   i = i + 2 -- skip `local`
   local node = new_block(ps, i, "local_macroexp")
   i, node[BLOCK_INDEXES.LOCAL_MACROEXP.NAME] = read_identifier(ps, i)
   i, node[BLOCK_INDEXES.LOCAL_MACROEXP.EXP] = read_macroexp(ps, istart, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function read_macro_body(ps: ReadState, i: integer, node: Block): integer, Block
   local old_in_macro = ps.in_local_macro
   local old_allow = ps.allow_macro_vars
   ps.in_local_macro = true
   ps.allow_macro_vars = false
   i, node = read_function_args_rets_body(ps, i, node)
   ps.in_local_macro = old_in_macro
   ps.allow_macro_vars = old_allow
   return i, node
end

local function register_macro_signature(ps: ReadState, node: Block, key: string)
   if key then
      local signature = build_macro_sig(node[BLOCK_INDEXES.LOCAL_MACRO.ARGS], ps.errs, ps.filename, key)
      local spec = read_operator_annotation(ps, node, key)
      node.custom_operator = spec
      signature.operator = spec
      ps.macro_sigs[key] = signature
      if spec then
         ps.macro_sigs[spec.binding] = signature
         if not node[BLOCK_INDEXES.LOCAL_MACRO.OWNER] then register_operator(ps, spec, node) end
      end
   end
end

local function bind_macro_alias(ps: ReadState, node: Block, signature: MacroSig)
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
      local spec: OperatorSpec = {
         symbol = symbol, fixity = original.fixity, precedence = original.precedence,
         right_associative = original.right_associative,
         binding = "@operator:" .. ps.filename .. ":" .. tostring(node.y) .. ":" .. tostring(node.x) .. ":" .. name.tk,
      }
      node.custom_operator = spec
      node[BLOCK_INDEXES.LOCAL_MACRO.TARGET] = setmetatable({
         kind = "identifier", tk = original.binding, f = ps.filename, y = name.y, x = name.x,
      }, node_mt)
      signature = { kinds = signature.kinds, vararg = signature.vararg, operator = spec }
      ps.macro_sigs[spec.binding] = signature
      register_operator(ps, spec, node)
   end
   ps.macro_sigs[name.tk] = signature
end

local function read_macro_alias_target(ps: ReadState, i: integer, node: Block): integer, Block
   i = verify_tk(ps, i, "=")

   local target: Block
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

local function read_local_macro(ps: ReadState, i: integer): integer, Block
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

local function read_attached_macro(ps: ReadState, i: integer): integer, Block
   local istart = i
   i = verify_tk(ps, i, "macro")

   local names: {Block} = {}
   local dot_pos: {integer} = {}

   i, names[1] = read_identifier(ps, i)
   if not names[1] then
      return fail(ps, i, "expected macro owner path")
   end

   while ps.tokens[i] and ps.tokens[i].tk == "." do
      table.insert(dot_pos, i)
      i = i + 1
      local part: Block
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

local function resolve_macro_aliases(ps: ReadState)
   local pending = ps.macro_aliases

   while #pending > 0 do
      local unresolved: {Block} = {}
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
            if not ps.macro_sigs[name.tk] or not node.custom_operator then bind_macro_alias(ps, node, sig) end
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

local function read_local(ps: ReadState, i: integer): integer, Block
   local ntk = ps.tokens[i + 1].tk
   if ntk == "function" then
      return read_local_function(ps, i)
   elseif ntk == "type" and (ps.tokens[i + 2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i + 2].tk == "$")) then
      return read_type_declaration(ps, i + 2, "local_type")
   elseif ntk == "macro" and (ps.tokens[i+2].kind == "identifier" or ps.tokens[i+2].tk == "(") then
      return read_local_macro(ps, i)
   elseif ntk == "macroexp" and ps.tokens[i+2].kind == "identifier" then
      return read_local_macroexp(ps, i)
   elseif type_body_kinds[ntk] and (ps.tokens[i+2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i+2].tk == "$")) then
      local ntk_kind = type_body_kinds[ntk]
      return read_type_constructor(ps, i, "local_type", ntk_kind)
   end
   return read_variable_declarations(ps, i + 1, "local_declaration")
end

local function read_global(ps: ReadState, i: integer): integer, Block
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
   elseif type_body_kinds[ntk] and (ps.tokens[i+2].kind == "identifier" or (ps.allow_macro_vars and ps.tokens[i+2].tk == "$")) then
      local ntk_kind = type_body_kinds[ntk]
      return read_type_constructor(ps, i, "global_type", ntk_kind)
   elseif ps.tokens[i+1].kind == "identifier" then
      return read_variable_declarations(ps, i + 1, "global_declaration")
   end
   return read_call_or_assignment(ps, i) -- global is a soft keyword
end

read_record_function = function(ps: ReadState, i: integer): integer, Block
   i = verify_tk(ps, i, "function")

   local fn = new_block(ps, i - 1, "record_function")

   local names: {Block} = {}
   local dot_pos: {integer} = {}

   local function read_name_piece(ps2: ReadState, ii: integer): integer, Block
      if ps2.allow_macro_vars and ps2.tokens[ii].tk == "$" then
         local dtk = ps2.tokens[ii]
         ii = ii + 1
         local ident: Block
         ii, ident = read_identifier(ps2, ii)
         if not ident then
            return fail(ps2, ii, "syntax error, expected identifier")
         end
         local macro_var: Block = { f = ps2.filename, y = dtk.y, x = dtk.x, kind = "macro_var", [1] = ident, tk = "$" }
         return ii, macro_var
      end
      local nii: integer
      local nb: Block
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

local function read_pragma(ps: ReadState, i: integer): integer, Block
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
   ["const"] = function(ps: ReadState, i: integer): integer, Block
      if ps.tokens[i + 1].tk ~= "function" and ps.tokens[i + 1].kind ~= "identifier" then
         return read_call_or_assignment(ps, i)
      end
      local node: Block
      i, node = read_local(ps, i)
      if node then node.lj_const = true end
      return i, node
   end,
   ["continue"] = function(ps: ReadState, i: integer): integer, Block
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

local function type_needs_local_or_global(ps: ReadState, i: integer): integer, Block
   local tk = ps.tokens[i].tk
   return failskip(ps, i, ("%s needs to be declared with 'local %s' or 'global %s'"):format(tk, tk, tk), skip_type_body)
end

needs_local_or_global = {
   ["type"] = function(ps: ReadState, i: integer): integer, Block
      return failskip(ps, i, "types need to be declared with 'local type' or 'global type'", skip_type_declaration)
   end,
   ["record"] = type_needs_local_or_global,
   ["enum"] = type_needs_local_or_global,
}

read_statements = function(ps: ReadState, i: integer, toplevel?: boolean): integer, Block
   local outer_operators = ps.custom_operators
   local outer_macro_sigs = ps.macro_sigs
   ps.macro_sigs = {}
   for key, signature in pairs(outer_macro_sigs) do ps.macro_sigs[key] = signature end
   local outer_local_operators = ps.local_operators
   ps.local_operators = {}
   local operators: {string: {string: OperatorSpec}} = { prefix = {}, infix = {}, postfix = {} }
   for fixity, bindings in pairs(outer_operators) do
      for symbol, spec in pairs(bindings) do operators[fixity][symbol] = spec end
   end
   ps.custom_operators = operators
   local node = new_block(ps, i, "statements")
   local item: Block
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
         -- heuristic to resync at the next line after an invalid statement
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

function reader.read_program(tokens: {Token}, errs: {Error}, filename?: string, read_lang?: BlockLang, allow_macro_vars?: boolean, skip_macro_expand?: boolean, operator_context?: {string: {string: OperatorSpec}}, in_macro_quote?: boolean): Block
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
   local ps: ReadState = {
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
            local signature: MacroSig = { kinds = { "expr" }, vararg = "", operator = spec }
            if fixity == "infix" then signature.kinds[2] = "expr" end
            ps.macro_sigs["(" .. symbol .. ")"] = signature
            ps.macro_sigs[spec.binding] = signature
         end
      end
   end
   local i = 1
   local hashbang: string
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

   local function check_macro_arity(b: Block)
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
      for i2 = 1, #b do
         local child = b[i2]
         if child then
            check_macro_arity(child)
         end
      end
   end

   check_macro_arity(node)

   local lang: BlockLang = read_lang or "tl"
   -- Recovery blocks may have missing children. Do not compile or execute
   -- macros until the complete input has parsed successfully.
   if not skip_macro_expand and #errs == 0 then
      node = macro_eval.compile_all_and_expand(node, filename, lang, errs)
   elseif not skip_macro_expand then
      -- These declarations belong to the compiler host, not the runtime file.
      -- Expansion normally removes them. When syntax errors prevent expansion,
      -- keep them opaque so type reporting cannot check their annotations and
      -- quoted AST constructors as ordinary runtime functions/tables.
      local recovered: {Block: boolean} = {}
      local function recover_macro_declarations(b: Block)
         if recovered[b] then return end
         recovered[b] = true
         if b.kind == "local_macro" then
            b.kind = "error_block"
            for j = 1, math.max(5, #b) do b[j] = nil end
         else
            for j = 1, math.max(5, #b) do
               if b[j] then recover_macro_declarations(b[j]) end
            end
         end
      end
      recover_macro_declarations(node)
   end

   local validating_continue: {Block: boolean} = {}
   local function validate_continue(b: Block, loop: Block, pending: {Block})
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
      local indexes: {integer} = {}
      for key, _ in pairs(b as {string|integer: Block | nil}) do
         if not (key is string) then table.insert(indexes, key) end
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

function reader.read(input: string, filename: string, read_lang?: BlockLang, allow_macro_vars?: boolean, skip_macro_expand?: boolean, operator_context?: {string: {string: OperatorSpec}}, in_macro_quote?: boolean): Block, {Error}
   filename = filename or "input"
   read_lang = read_lang or lang_heuristic(filename, input)
   local tokens, errs = lexer.lex(input, filename)
   local node = reader.read_program(tokens, errs, filename, read_lang, allow_macro_vars, skip_macro_expand, operator_context, in_macro_quote)
   return node, errs
end

return reader
