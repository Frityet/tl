local lexer = require('teal.lexer')
local reader = require('teal.reader')
local slots = require('teal.block').BLOCK_INDEXES

local function read(code, operators)
   local tokens, errors = lexer.lex(code, 'frontend-reader.tl')
   local initial_count = #tokens
   local tree = reader.read_program(tokens, errors, 'frontend-reader.tl', 'tl', true, true, operators)
   assert.same({}, errors)
   return tree, tokens, initial_count
end

local function argument(invocation)
   return invocation[slots.MACRO_INVOCATION.ARGS][1]
end

describe('reader frontend state', function()
   it('commits nested generic closers from successful expression probes', function()
      local tree, tokens, count = read([[
         local macro keep!(value: Expression | Statement) return value end
         local value = keep!(nil as Box<Box<integer>>)
      ]])
      local invocation = tree[2][slots.LOCAL_DECLARATION.EXPS][1]
      assert.equals('op_as', argument(invocation).kind)
      assert.equals(count, #tokens)
      for _, token in ipairs(tokens) do assert.not_equals('>>', token.tk) end
   end)

   it('rolls back successful inner probes when an outer argument is a statement', function()
      local tree, tokens, count = read([[
         local macro keep!(value: Expression | Statement) return value end
         local macro echo!(value: Expression | Statement) return value end
         keep!(echo!(nil as Box<Box<integer>>) f())
      ]])
      local statements = argument(tree[3])
      assert.equals('statements', statements.kind)
      assert.equals(2, #statements)
      assert.equals('macro_invocation', statements[1].kind)
      assert.equals('op_as', argument(statements[1]).kind)
      assert.equals('op_funcall', statements[2].kind)
      assert.equals(count, #tokens)
   end)

   it('rolls back generic closers parsed through an inner statement token slice', function()
      local tree, tokens, count = read([[
         local macro keep!(value: Expression | Statement) return value end
         local macro statement!(value: Statement) return value end
         keep!(statement!(f(nil as Box<Box<integer>>)) f())
      ]])
      local statements = argument(tree[3])
      assert.equals('statements', statements.kind)
      assert.equals(2, #statements)
      local call = argument(statements[1])
      assert.equals('op_funcall', call.kind)
      assert.equals('op_as', call[slots.OP.E2][1].kind)
      assert.equals('op_funcall', statements[2].kind)
      assert.equals(count, #tokens)
   end)

   it('does not leak speculative newline separators into the caller token array', function()
      local tree, tokens, count = read([[
         local macro keep!(value: Expression | Statement) return value end
         keep!(f()
            (g()))
      ]])
      local statements = argument(tree[2])
      assert.equals('statements', statements.kind)
      assert.same({'op_funcall', ';', 'paren'}, {
         statements[1].kind, statements[2].kind, statements[3].kind,
      })
      assert.equals(count, #tokens)
      for _, token in ipairs(tokens) do assert.not_equals(';', token.tk) end
   end)

   it('restores outer macro signatures after a nested declaration', function()
      local tree = read([[
         local macro keep!(value: Expression) return value end
         do
            local macro keep!(value: Statement) return value end
            keep!(f())
         end
         keep!(f())
      ]])
      local inner = tree[2][slots.DO.BODY][2]
      assert.equals('statements', argument(inner).kind)
      assert.equals('op_funcall', argument(tree[3]).kind)
   end)

   it('restores outer operators after nested shadowing', function()
      local tree = read([[
         local macro (@)!(a: Expression, b: Expression): Operator<infix, additive>
            return `$a + $b`
         end
         do
            local macro (@)!(a: Expression, b: Expression): Operator<infix, multiplicative>
               return `$a * $b`
            end
            local inner = 1 @ 2 * 3
         end
         local outer = 1 @ 2 * 3
      ]])
      local inner = tree[2][slots.DO.BODY][2][slots.LOCAL_DECLARATION.EXPS][1]
      local outer = tree[3][slots.LOCAL_DECLARATION.EXPS][1]
      assert.equals('op_mul', inner.kind)
      assert.equals('macro_invocation', inner[slots.OP.E1].kind)
      assert.equals('macro_invocation', outer.kind)
      assert.equals('op_mul', outer[slots.MACRO_INVOCATION.ARGS][2].kind)
   end)

   it('observes changes to a caller-owned operator context on the next parse', function()
      local operators = {prefix = {}, postfix = {}, infix = {}}
      operators.infix['@'] = {
         symbol = '@', fixity = 'infix', precedence = 9,
         right_associative = false, binding = '@outer',
      }
      local first = read('local value = 1 @ 2 * 3', operators)
      assert.equals('macro_invocation', first[1][slots.LOCAL_DECLARATION.EXPS][1].kind)
      operators.infix['@'] = {
         symbol = '@', fixity = 'infix', precedence = 10,
         right_associative = false, binding = '@changed',
      }
      local second = read('local value = 1 @ 2 * 3', operators)
      local expression = second[1][slots.LOCAL_DECLARATION.EXPS][1]
      assert.equals('op_mul', expression.kind)
      assert.equals('@changed', expression[slots.OP.E1][slots.MACRO_INVOCATION.MACRO].tk)
   end)

   it('matches equivalent contiguous operator token segmentations', function()
      local tokens, errors = lexer.lex('return 1 >>> 2', 'operators.tl')
      assert.same({}, errors)
      assert.equals('>>', tokens[3].tk)
      assert.equals('>', tokens[4].tk)
      tokens[3].tk = '>'
      tokens[4].tk = '>>'
      tokens[4].x = tokens[3].x + 1
      local operators = {prefix = {}, postfix = {}, infix = {
         ['>>>'] = {symbol = '>>>', fixity = 'infix', precedence = 9,
            right_associative = false, binding = '@shift'},
      }}
      local tree = reader.read_program(tokens, errors, 'operators.tl', 'tl', true, true, operators)
      assert.same({}, errors)
      assert.equals('macro_invocation', tree[1][slots.RETURN.EXPS][1].kind)
   end)

   it('accepts a partial caller-owned operator context', function()
      local operators = {infix = {
         ['@'] = {symbol = '@', fixity = 'infix', precedence = 9,
            right_associative = false, binding = '@external'},
      }}
      local tree = read([[
         local value = 1 @ 2
         local macro (@@)!(x: Expression): Operator<prefix, unary> return x end
      ]], operators)
      assert.equals('macro_invocation', tree[1][slots.LOCAL_DECLARATION.EXPS][1].kind)
      assert.is_nil(operators.prefix)
      assert.is_nil(operators.postfix)
   end)

   it('matches operators whose spelling resembles a leading hashbang', function()
      local tree = read([[
         local macro (#!)!(a: Expression, b: Expression): Operator<infix, additive>
            return `$a + $b`
         end
         local value = 1 #! 2
      ]])
      assert.equals('macro_invocation', tree[2][slots.LOCAL_DECLARATION.EXPS][1].kind)
   end)

   it('validates sparse children returned by macro code beyond fixed slots', function()
      local _, errors = reader.read([[
         local macro sparse!()
            local out = block('return')
            out[1] = block('expression_list')
            out[64] = block('continue')
            return out
         end
         sparse!()
      ]], 'sparse-continue.tl')
      assert.equals(1, #errors)
      assert.equals('continue outside a loop', errors[1].msg)
   end)
end)
