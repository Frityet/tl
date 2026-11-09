local block = require('teal.block')
local reader = require('teal.reader')
local tl = require('teal.api.v2')
local B = block.BLOCK_INDEXES

describe('structural block metadata', function()
   it('represents reader syntax with kinds, tokens, and numeric children', function()
      local tree, errors = reader.read([[
         local macro (@)!(p: Expression): Operator<prefix, unary> return p end
         local macro (deref)! = (@)!
         const n = 1
         const function get(): integer return n end
         local data = {10, [2] = 20}
         local short = || -> data?.[1]
         data[1] += 2
         local value = deref data
         local text = [=[hello]=]
      ]], 'layout.tl', 'tl', false, true)
      assert.same({}, errors)

      local allowed = {kind = true, tk = true, f = true, y = true, x = true, yend = true, xend = true}
      local function check_shape(node)
         for key, child in pairs(node) do
            if type(key) == 'number' then
               check_shape(child)
            else
               assert.is_true(allowed[key], 'unexpected Block field ' .. key)
            end
         end
      end
      check_shape(tree)

      local operator = tree[1][B.LOCAL_MACRO.OPERATOR]
      assert.equals('operator_spec', operator.kind)
      assert.equals('@', operator.tk)
      assert.equals('prefix', operator[B.OPERATOR_SPEC.FIXITY].tk)
      assert.equals('deref', tree[2][B.LOCAL_MACRO.OPERATOR].tk)
      assert.equals('native_const', tree[3][B.LOCAL_DECLARATION.CONST].kind)
      assert.equals('native_const', tree[4][B.LOCAL_FUNCTION.CONST].kind)
      local items = tree[5][B.LOCAL_DECLARATION.EXPS][1]
      assert.equals('integer', items[1][B.LITERAL_TABLE_ITEM.KEY].kind)
      assert.equals('implicit_table_key', items[1][B.LITERAL_TABLE_ITEM.IMPLICIT_KEY].kind)
      assert.equals('integer', items[2][B.LITERAL_TABLE_ITEM.KEY].kind)
      assert.is_nil(items[2][B.LITERAL_TABLE_ITEM.IMPLICIT_KEY])
      local short = tree[6][B.LOCAL_DECLARATION.EXPS][1]
      assert.equals('short_function', short[B.FUNCTION.SHORT].kind)
      local optional_index = short[B.FUNCTION.BODY][1][B.RETURN.EXPS][1]
      assert.equals('?.', optional_index[B.OP.SAFE].tk)
      assert.equals('+=', tree[7][B.ASSIGNMENT.OPERATOR].tk)
      local use = tree[8][B.LOCAL_DECLARATION.EXPS][1]
      assert.equals('deref', use[B.MACRO_INVOCATION.OPERATOR].tk)
      local text = tree[9][B.LOCAL_DECLARATION.EXPS][1]
      assert.is_true(block.is_long_string(text))
      assert.equals('hello', block.string_value(text))
   end)

   it('preserves child metadata through quotes, splices, and clones', function()
      local ast, errors = tl.parse([==[
         local macro (@)!(p: Expression): Operator<prefix, unary> return `($p)[1]` end
         local macro forward!(target: Expression)
            local grouped = clone(target)
            assert(grouped[BLOCK_INDEXES.PAREN.OPERATOR_GROUPING].kind == "operator_grouping")
            return grouped
         end
         local macro maker!()
            local text = `[=[hello]=]`
            assert(string_value(text) == "hello")
            return `||: string -> $text`
         end
         const values = {1}
         forward!(@values) = 2
         local get = maker!()
         return @values, get()
      ]==], 'layout.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'layout.tl', {gen_target = '5.1', gen_compat = 'off'})
      assert.same({}, result.type_errors)
      local code = assert(tl.generate(result.ast, '5.1'))
      local run = assert((loadstring or load)(code))
      assert.same({2, 'hello'}, {run()})
   end)
end)
