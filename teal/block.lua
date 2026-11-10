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
   ["ffi_cdef"] = true,
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
