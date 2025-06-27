local reader = require("teal.reader")
local type Block = reader.Block
local errors = require("teal.errors")
local type Error = errors.Error

local types = require("teal.types")
local type Type = types.Type
local type GenericType = types.GenericType
local type FirstOrderType = types.FirstOrderType
local type StructuralType = types.StructuralType
local type TypeDeclType = types.TypeDeclType
local type NominalType = types.NominalType
local type SelfType = types.SelfType
local type ArrayType = types.ArrayType
local type RecordLikeType = types.RecordLikeType
local type RecordType = types.RecordType
local type InterfaceType = types.InterfaceType
local type TupleType = types.TupleType
local type TypeArgType = types.TypeArgType
local type MapType = types.MapType
local type NilType = types.NilType
local type FunctionType = types.FunctionType
local type UnionType = types.UnionType
local type TupleTableType = types.TupleTableType
local type PolyType = types.PolyType
local type EnumType = types.EnumType
local type FirstClassType = types.FirstClassType
local type TypeName = types.TypeName
local type Where = types.Where
local a_type = types.a_type
local raw_type = types.raw_type
local simple_types = types.simple_types

local facts = require("teal.facts")
local type Fact = facts.Fact

local lexer = require("teal.lexer")
local type Token = lexer.Token
local type TokenKind = lexer.TokenKind

local enum NodeKind
   "op"
   "nil"
   "string"
   "number"
   "integer"
   "boolean"
   "literal_table"
   "literal_table_item"
   "function"
   "expression_list"
   "if"
   "if_block"
   "while"
   "fornum"
   "forin"
   "goto"
   "label"
   "repeat"
   "do"
   "break"
   "return"
   "newtype"
   "argument"
   "type_identifier"
   "variable"
   "variable_list"
   "statements"
   "assignment"
   "argument_list"
   "local_function"
   "global_function"
   "local_type"
   "global_type"
   "record_function"
   "local_declaration"
   "global_declaration"
   "identifier"
   "cast"
   "..."
   "paren"
   "macroexp"
   "local_macroexp"
   "interface"
   "pragma"
   "error_node"
end

local record Node
   is {Node}, types.Node, Where
   where self.kind ~= nil

   record ExpectedContext
      kind: NodeKind
      name: string
   end

   tk: string
   kind: NodeKind
   symbol_list_slot: integer
   semicolon: boolean
   hashbang: string

   is_longstring: boolean

   yend: integer
   xend: integer

   known: Fact

   -- bidirectional inference
   expected: Type
   expected_context: Node.ExpectedContext

   key: Node
   value: Node
   key_parsed: KeyParsed

   typeargs: {TypeArgType}
   min_arity: integer
   args: Node
   rets: TupleType
   body: Node
   implicit_global_function: boolean
   is_predeclared_local_function: boolean

   name: Node

   -- statements list in a `repeat`, delay closing scope
   is_repeat: boolean

   -- var declaration
   attribute: Attribute

   fn_owner: Node
   is_method: boolean

   exp: Node
   if_parent: Node
   if_block_n: integer
   if_blocks: {Node}
   if_widens: {string: boolean}
   block_returns: boolean

   -- fornum
   var: Node
   from: Node
   to: Node
   step: Node

   -- forin
   vars: Node
   exps: Node

   -- newtype
   newtype: TypeDeclType
   elide_type: boolean

   -- expressions
   op: Operator
   e1: Node
   e2: Node
   constnum: number
   conststr: string
   failstore: boolean
   discarded_tuple: boolean
   receiver: Type

   -- table literal
   array_len: integer
   is_total: boolean
   missing: {string}

   -- goto
   label: string

   -- label
   used_label: boolean

   casttype: Type

   -- variable
   is_lvalue: boolean

   -- macroexp
   macrodef: Node
   expanded: Node

   argtype: Type
   itemtype: Type
   decltuple: TupleType

   -- pragma
   pkey: string
   pvalue: string

   opt: boolean

   debug_type: Type
end

local enum ParseLang
   "lua"
   "tl"
end

local record Operator
   y: integer
   x: integer
   arity: integer
   op: string
   prec: integer
end

local enum KeyParsed
   "short"
   "long"
   "implicit"
end

local enum Attribute
   "const"
   "close"
   "total"
end


local record block_parser
   type Attribute = Attribute
   type Node = Node
   type NodeKind = NodeKind
   type ParseLang = ParseLang

   parse: function(input: Block, filename: string, parse_lang?: ParseLang): types.Node, {Error}, {string}
   operator: function(Node, integer, string): Operator
end

local attributes <total>: {Attribute: boolean} = {
   ["const"] = true,
   ["close"] = true,
   ["total"] = true,
}
local is_attribute <const>: {string:boolean} = attributes as {string:boolean}

local precedences: {integer:{string:integer}} = {
   [1] = {
      ["not"] = 11,
      ["#"] = 11,
      ["-"] = 11,
      ["~"] = 11,
   },
   [2] = {
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
local record OpKind
   op: string
   arity: integer
end
local op_kinds: {string: OpKind} = {
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

local record ParseState
   block: Block
   errs: {Error}
   filename: string
   end_alignment_hint: Error

   required_modules: {string}
   parse_lang: ParseLang
end

local node_mt: metatable<Node> = {
   __tostring = function(n: Node): string
      return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
   end
}

local function new_node(ps: ParseState, b: Block, kind?: NodeKind): Node
   local node = setmetatable({ f = ps.filename, y = b.y, x = b.x, tk = b.tk, kind = kind or (b.kind as NodeKind) } as Node, node_mt)
   node.yend = b.yend
   node.xend = b.xend
   return node
end

local parse_block: function(state: ParseState, block: Block): Node
local parse_expression: function(state: ParseState, block: Block): Node

local function parse_list(state: ParseState, block: Block, node: Node, parse_fn: function(ParseState, Block):Node): Node
   if not block then return node end
   for _, item_block in ipairs(block) do
      table.insert(node, parse_fn(state, item_block))
   end
   return node
end

local function parse_expression_list(state: ParseState, block: Block): Node
   local node = new_node(state, block, "expression_list")
   return parse_list(state, block, node, parse_expression)
end

local function parse_variable_list(state: ParseState, block: Block): Node
   local node = new_node(state, block, "variable_list")
   for _, var_block in ipairs(block) do
      local var_node = new_node(state, var_block, "variable")
      --TODO: attributes
      table.insert(node, var_node)
   end
   return node
end

local function parse_argument_list(state: ParseState, block: Block): Node
   local node = new_node(state, block, "argument_list")
   node.min_arity = 0
   local opts = false
   for _, arg_block in ipairs(block) do
      local arg_node = new_node(state, arg_block, "argument")
      --TODO: handle optional params
      -- if arg_block.opt then
      --    arg_node.opt = true
      --    opts = true
      -- elseif opts then
      --    -- error: non-optional argument follows optional argument
      --    table.insert(state.errs, {
      --       filename = state.filename,
      --       y = arg_node.y,
      --       x = arg_node.x,
      --       msg = "non-optional arguments cannot follow optional arguments",
      --    })
      -- else
      -- end
      node.min_arity = node.min_arity + 1
      table.insert(node, arg_node)
   end
   return node
end

local function parse_statements(state: ParseState, block: Block): Node
   local node = new_node(state, block, "statements")
   
   return parse_list(state, block, node, parse_block)
end

parse_expression = function(state: ParseState, block: Block): Node
   if not block then return nil end

   local kind = block.kind as string
   local op_info = op_kinds[kind]

   if op_info then
      local node = new_node(state, block, "op")
      node.op = {
         y = block.y,
         x = block.x,
         arity = op_info.arity,
         op = op_info.op,
         prec = precedences[op_info.arity][op_info.op]
      }
      node.e1 = parse_expression(state, block[1])
      if op_info.arity == 2 then
         if op_info.op == "@funcall" then
            node.e2 = parse_expression_list(state, block[2])
         elseif op_info.op == "as" or op_info.op == "is" then
            node.e2 = new_node(state, block[2], "cast")
            -- block[2][1] is the type, ignore for now
         else
            node.e2 = parse_expression(state, block[2])
         end
      end
      return node
   end

   local node = new_node(state, block)

   if kind == "string" then
      node.conststr = block.conststr
   elseif kind == "number" or kind == "integer" then
      node.constnum = block.constnum
   elseif kind == "paren" then
      node.e1 = parse_expression(state, block[1])
   elseif kind == "literal_table" then
      for _, item_block in ipairs(block) do
         local item_node = new_node(state, item_block, "literal_table_item")
         item_node.key = parse_expression(state, item_block[1])
         item_node.value = parse_expression(state, item_block[2])
         table.insert(node, item_node)
      end
   elseif kind == "function" then
      node.args = parse_argument_list(state, block[3])
      node.body = parse_statements(state, block[5])
   end
   return node
end

local type ParseFn = function(state: ParseState, block: Block): Node
local parse_fns: {string: ParseFn} = {}

parse_fns.local_declaration = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.vars = parse_variable_list(state, block[1])
   local next_child = 2
   if block[next_child] and block[next_child].kind == "tuple_type" then
      next_child = 3
   end
   if block[next_child] then
      node.exps = parse_expression_list(state, block[next_child])
   end
   return node
end
parse_fns.global_declaration = parse_fns.local_declaration

parse_fns.assignment = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.vars = parse_variable_list(state, block[1])
   node.exps = parse_expression_list(state, block[2])
   return node
end

parse_fns["if"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.if_blocks = {}
   for i, if_block_block in ipairs(block) do
      local if_block_node = new_node(state, if_block_block, "if_block")
      if_block_node.if_parent = node
      if_block_node.if_block_n = i
      if #if_block_block == 2 then -- if or elseif
         if_block_node.exp = parse_expression(state, if_block_block[1])
         if_block_node.body = parse_statements(state, if_block_block[2])
      else -- else
         if_block_node.body = parse_statements(state, if_block_block[1])
      end
      table.insert(node.if_blocks, if_block_node)
   end
   return node
end

parse_fns["while"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.exp = parse_expression(state, block[1])
   node.body = parse_statements(state, block[2])
   return node
end

parse_fns.fornum = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.var = parse_expression(state, block[1])
   node.from = parse_expression(state, block[2])
   node.to = parse_expression(state, block[3])
   if block[4] then
      node.step = parse_expression(state, block[4])
   end
   node.body = parse_statements(state, block[5])
   return node
end

parse_fns.forin = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.vars = parse_variable_list(state, block[1])
   node.exps = parse_expression_list(state, block[2])
   node.body = parse_statements(state, block[3])
   return node
end

parse_fns["repeat"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.body = parse_statements(state, block[1])
   node.body.is_repeat = true
   node.exp = parse_expression(state, block[2])
   return node
end

parse_fns["do"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.body = parse_statements(state, block[1])
   return node
end

parse_fns["return"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.exps = parse_expression_list(state, block[1])
   return node
end

parse_fns["break"] = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end

parse_fns["goto"] = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.label = block[1].tk
   return node
end

parse_fns.label = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.label = block[1].tk
   return node
end

parse_fns.local_function = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.name = parse_expression(state, block[1])
   node.args = parse_argument_list(state, block[3])
   node.body = parse_statements(state, block[5])
   return node
end

parse_fns.global_function = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   node.name = parse_expression(state, block[1])
   node.args = parse_argument_list(state, block[3])
   node.body = parse_statements(state, block[5])
   return node
end

parse_fns.record_function = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   local owner_block = block[1]
   local name_block = block[2]
   --TODO: Check if method

   node.fn_owner = parse_expression(state, owner_block)
   node.name = parse_expression(state, name_block)

   node.args = parse_argument_list(state, block[4])
   node.body = parse_statements(state, block[6])
   return node
end

parse_fns.pragma = function(state: ParseState, block: Block): Node
   local node = new_node(state, block)
   --pkey should be [1] and pvalue should be [2]
   return node
end

parse_fns.local_type = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end
parse_fns.global_type = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end
parse_fns.interface = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end
parse_fns.local_macroexp = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end
parse_fns.macroexp = function(state: ParseState, block: Block): Node
   return new_node(state, block)
end

parse_block = function(state: ParseState, block: Block): Node
   if not block then return nil end
   local f = parse_fns[block.kind]
   if f then
      return f(state, block)
   else
      return parse_expression(state, block)
   end
end

function block_parser.parse(input: Block, filename: string, parse_lang?: ParseLang): types.Node, {Error}, {string}
   local state: ParseState = {
      block = input,
      errs = {},
      filename = filename,
      end_alignment_hint = nil,
      required_modules = {},
      parse_lang = parse_lang or "tl",
   }

   local nodes = parse_statements(state, input)
   if #state.errs > 0 then
      return nil, state.errs, {}
   end

   return nodes, {}, state.required_modules
end

return block_parser

