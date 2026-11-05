local util = require('spec.util')
local tl = require('teal.api.v2')

local function declaration(symbol, expression, fixity, precedence, associativity)
   local params = (fixity or 'infix') == 'infix' and 'lhs: Expression, rhs: Expression' or 'lhs: Expression'
   return ('local macro apply!(%s): Operator<%q, %s, %s%s>\n return `%s`\nend\n'):format(
      params, symbol, fixity or 'infix', precedence or 'multiplicative',
      associativity and (', ' .. associativity) or '', expression or '$lhs * $rhs')
end

local function generate(code)
   local ast, errs = tl.parse(code, 'operators.tl')
   assert.same({}, errs)
   local result = assert(tl.check(ast, 'operators.tl', {gen_target = '5.1', gen_compat = 'off'}))
   assert.same({}, result.type_errors)
   return tl.generate(result.ast, '5.1')
end

local function run(code)
   local output = generate(code)
   return assert(loadstring(output), output)()
end

local function rejects(code, pattern)
   local _, errs = tl.parse(code, 'invalid-operator.tl')
   assert.is_true(#errs > 0, code)
   if pattern then
      for _, err in ipairs(errs) do if err.msg:match(pattern) then return end end
      error('expected diagnostic matching ' .. pattern)
   end
end

describe('custom operators declared by macros', function()
   it('accepts the requested matmul declaration and expands to a utility call', function()
      local output = generate([[
         local utils = {}
         function utils.matmul(lhs: integer, rhs: integer): integer return lhs * rhs + 1 end
         local macro matmul!(lhs: Expression, rhs: Expression): Operator<'@', infix, multiplicative>
            return `utils.matmul($lhs, $rhs)`
         end
         return 1 + 2 @ 3 * 4
      ]])
      assert.matches('utils.matmul(2, 3)', output, 1, true)
      assert.not_matches('Operator<', output, 1, true)
      assert.not_matches('matmul!', output, 1, true)
      assert.equals(29, assert(loadstring(output))())
   end)

   it('type-checks and executes matrix operands', function()
      assert.same({19, 22, 43, 50}, {run([[
         local type Matrix = {{integer}}
         local function matmul(a: Matrix, b: Matrix): Matrix
            return {
               {a[1][1]*b[1][1] + a[1][2]*b[2][1], a[1][1]*b[1][2] + a[1][2]*b[2][2]},
               {a[2][1]*b[1][1] + a[2][2]*b[2][1], a[2][1]*b[1][2] + a[2][2]*b[2][2]},
            }
         end
         local a: Matrix = {{1, 2}, {3, 4}}
         local b: Matrix = {{5, 6}, {7, 8}}
      ]] .. declaration('@', 'matmul($lhs, $rhs)') .. [[
         local product = a @ b
         return product[1][1], product[1][2], product[2][1], product[2][2]
      ]])})
   end)

   it('chooses the longest of overlapping active symbols', function()
      assert.equals(10, run(declaration('@', '$lhs + $rhs') .. declaration('@@') .. 'return 2 @@ 3 @ 4'))
   end)

   it('supports non-reserved identifier spellings', function()
      for _, word in ipairs({'matmul', 'cross_product', '_op', 'lhs2', 'Operator', 'Expression', 'const', 'continue', 'global', 'record', 'interface', 'enum', 'type', 'macro', 'macroexp', 'where', 'metamethod', 'userdata'}) do
         assert.equals(7, run(declaration(word, '$lhs + $rhs') .. 'return 2 ' .. word .. ' 5'))
      end
   end)

   it('supports unused single symbols, Unicode symbols, and escaped backslashes', function()
      for _, symbol in ipairs({'@', '\\', '×', '÷', '⊗', '√'}) do
         assert.equals(10, run(declaration(symbol) .. 'return 2 ' .. symbol .. ' 5'))
      end
   end)

   it('supports unused symbol sequences with longest matching', function()
      for _, symbol in ipairs({'**', '++', '%%', '<=>', '=>', '@@', '~>', '|>', '<|>', '?.@', '!=='}) do
         assert.equals(10, run(declaration(symbol) .. 'return 2 ' .. symbol .. ' 5'))
      end
   end)

   it('does not combine symbols separated by whitespace', function()
      rejects(declaration('<=>') .. 'return 2 < = > 3')
   end)

   it('does not split identifiers to find operator names', function()
      rejects(declaration('times') .. 'return 2 times_other 3')
   end)

   it('uses the multiplicative group alongside multiplication and addition', function()
      assert.equals(29, run(declaration('@', '$lhs * $rhs + 1') .. 'return 1 + 2 @ 3 * 4'))
      assert.equals(28, run(declaration('@', '$lhs * $rhs + 1') .. 'return 2 * 3 @ 4 + 3'))
   end)

   it('supports additive, shift, comparison, and logical precedence groups', function()
      assert.equals(17, run(declaration('@', '$lhs + $rhs', 'infix', 'additive') .. 'return 2 @ 3 * 5'))
      assert.equals(9, run(declaration('@', '$lhs + $rhs', 'infix', 'shift') .. 'return 1 + 2 @ 2 * 3'))
      assert.is_true(run(declaration('@', '$lhs < $rhs', 'infix', 'comparison') .. 'return 1 + 2 @ 4 and true'))
      assert.is_true(run(declaration('either', '$lhs or $rhs', 'infix', 'logical_or') .. 'return false either true and true'))
   end)

   it('defaults infix operators to left associativity', function()
      assert.equals(13, run(declaration('@', '$lhs - $rhs', 'infix', 'additive') .. 'return 20 @ 5 @ 2'))
   end)

   it('supports explicit right associativity', function()
      assert.equals(17, run(declaration('@', '$lhs - $rhs', 'infix', 'additive', 'right') .. 'return 20 @ 5 @ 2'))
   end)

   it('preserves expansion grouping when the returned expression has lower precedence', function()
      assert.equals(2, run(declaration('@', '$lhs + $rhs', 'infix', 'exponentiation') .. 'return 12 / 2 @ 4'))
      assert.equals(24, run(declaration('@', '$lhs + $rhs') .. 'return 4 * (2 @ 4)'))
   end)

   it('supports prefix symbols and identifiers', function()
      assert.equals(10, run(declaration('@', '$lhs + 1', 'prefix', 'unary') .. 'return @ 3 ^ 2'))
      assert.equals(8, run(declaration('twice', '$lhs * 2', 'prefix', 'unary') .. 'return twice 3 + 2'))
      assert.equals(9, run(declaration('@', '$lhs + 1', 'prefix', 'unary') .. 'return @ @ 7'))
   end)

   it('supports postfix symbols and identifiers', function()
      assert.equals(24, run(declaration('@@', '$lhs + 1', 'postfix', 'postfix') .. 'return 2 * 3 @@ + 16'))
      assert.equals(8, run(declaration('twice', '$lhs * 2', 'postfix', 'postfix') .. 'return 3 twice + 2'))
   end)

   it('can use one symbol for prefix and infix operators', function()
      local prefix = declaration('@', '$lhs + 1', 'prefix', 'unary'):gsub('apply!', 'prefix!')
      assert.equals(10, run(declaration('@', '$lhs * $rhs') .. prefix .. 'return @ 4 @ 2'))
   end)

   it('supports postfix results followed by indexing and calls', function()
      assert.equals(4, run(declaration('@@', '{$lhs}', 'postfix', 'postfix') .. 'return 4 @@ [1]'))
      assert.equals(4, run(declaration('@@', '$lhs', 'postfix', 'postfix') .. [[
         local function f(x: integer): integer return x + 1 end
         return f @@ (3)
      ]]))
   end)

   it('uses lexical scope and permits shadowing in inner blocks', function()
      assert.same({5, 6, 5}, {run(declaration('@', '$lhs + $rhs') .. [[
         local a = 2 @ 3
         local b = 0
         do
      ]] .. declaration('@', '$lhs * $rhs') .. [[
            b = 2 @ 3
         end
         return a, b, 2 @ 3
      ]])})
   end)

   it('does not leak declarations out of their block or between files', function()
      rejects('do\n' .. declaration('@') .. 'local x = 2 @ 3 end\nreturn 2 @ 3')
      generate(declaration('@') .. 'return 2 @ 3')
      rejects('return 2 @ 3')
   end)

   it('makes operators available in nested functions', function()
      assert.equals(6, run(declaration('@') .. 'local function f(): integer return 2 @ 3 end; return f()'))
   end)

   it('supports declarations inside functions', function()
      assert.equals(6, run('local function f(): integer\n' .. declaration('@') .. 'return 2 @ 3 end\nreturn f()'))
   end)

   it('requires a declaration before an operator is used', function()
      rejects('local n = 2 @ 3\n' .. declaration('@') .. 'return n')
   end)

   it('keeps ordinary macro invocation available', function()
      assert.equals(6, run(declaration('@') .. 'return apply!(2, 3)'))
   end)

   it('preserves operand evaluation order for the supplied call expansion', function()
      assert.same({6, 'lr'}, {run([[
         local order = ""
         local function left(): integer order = order .. "l"; return 2 end
         local function right(): integer order = order .. "r"; return 3 end
         local function multiply(a: integer, b: integer): integer return a * b end
      ]] .. declaration('@', 'multiply($lhs, $rhs)') .. 'local n = left() @ right(); return n, order')})
   end)

   it('treats operator results as single values', function()
      assert.equals(1, run([[
         local function pair(a: integer, b: integer): integer, integer return a, b end
      ]] .. declaration('@', 'pair($lhs, $rhs)') .. 'return select("#", 2 @ 3)'))
   end)

   it('type-checks expanded calls normally', function()
      local ast, errs = tl.parse([[
         local function multiply(a: integer, b: integer): integer return a * b end
      ]] .. declaration('@', 'multiply($lhs, $rhs)') .. 'return "bad" @ 3', 'bad-types.tl')
      assert.same({}, errs)
      local result = assert(tl.check(ast, 'bad-types.tl', {gen_target = '5.1', gen_compat = 'off'}))
      assert.is_true(#result.type_errors > 0)
      assert.matches('expected integer', result.type_errors[1].msg)
   end)

   it('imports an attached operator through an explicit macro alias', function()
      util.mock_io(finally, {
         ['ops.tl'] = [[
            local record Ops end
            macro Ops.multiply!(lhs: Expression, rhs: Expression): Operator<'@', infix, multiplicative>
               return `$lhs * $rhs`
            end
            return Ops
         ]],
      })
      assert.equals(6, run([[
         local ops = require('ops')
         local macro multiply! = ops.multiply!
         return 2 @ 3
      ]]))
   end)

   it('preserves lexical bindings for explicit macro calls', function()
      assert.same({5, 6, 5}, {run(declaration('@', '$lhs + $rhs') .. [[
         local a = apply!(2, 3)
         local b = 0
         do
      ]] .. declaration('@', '$lhs * $rhs') .. [[
            b = apply!(2, 3)
         end
         return a, b, apply!(2, 3)
      ]])})
   end)

   it('supports declared operators inside macro quotes', function()
      assert.equals(6, run(declaration('@') .. [[
         local macro multiply!(a: Expression, b: Expression)
            return `$a @ $b`
         end
         return multiply!(2, 3)
      ]]))
   end)

   it('supports operator expressions inside ordinary macro arguments', function()
      assert.equals(7, run(declaration('@') .. [[
         local macro inc!(value: Expression) return `$value + 1` end
         return inc!(2 @ 3)
      ]]))
   end)

   it('honors exponentiation precedence with built-in and custom unary operators', function()
      assert.equals(-3, run(declaration('@', '$lhs + 1', 'prefix', 'unary') .. 'return @ -2 ^ 2'))
      assert.equals(-4, run('return -2 ^ 2'))
   end)

   it('can discard a call expansion as a statement', function()
      assert.equals(6, run([[
         local n = 0
         local function multiply(a: integer, b: integer): integer n = a * b; return n end
      ]] .. declaration('@', 'multiply($lhs, $rhs)') .. '2 @ 3; return n'))
   end)

   it('rejects non-call operator expansions used as statements', function()
      rejects(declaration('@') .. '2 @ 3', 'cannot be used as a statement')
   end)

   it('preserves grouping for a single expression returned in a block', function()
      assert.equals(2, run([[local macro add!(lhs: Expression, rhs: Expression): Operator<'@', infix, exponentiation>
         local out = block('statements')
         table.insert(out, `$lhs + $rhs`)
         return out
      end
      return 12 / 2 @ 4]]))
   end)

   it('rejects built-in operators and reserved identifiers', function()
      for _, symbol in ipairs({'+', '-', '*', '/', '//', '~=', '??', '?.', '->', '..', '+=', 'and', 'if', 'local', 'is', 'as'}) do
         rejects(declaration(symbol), 'non%-reserved identifier or unused symbols')
      end
   end)

   it('rejects whitespace, delimiters, and comment-forming symbols', function()
      for _, symbol in ipairs({'', 'two words', '1op', '(', '[', '{', ';', '$', '-->', "'", 'a@'}) do
         rejects(declaration(symbol), 'non%-reserved identifier or unused symbols')
      end
   end)

   it('validates operator fixity, precedence, and associativity', function()
      rejects(declaration('@', '$lhs', 'around'), 'fixity')
      rejects(declaration('@', '$lhs', 'infix', 'unknown'), 'precedence')
      rejects(declaration('@', '$lhs', 'infix', 'additive', 'unknown'), 'associativity')
      rejects(declaration('@', '$lhs', 'prefix', 'unary', 'right'), 'only infix')
   end)

   it('requires the correct number of Expression parameters', function()
      rejects([[local macro f!(a: Expression): Operator<'@', infix, multiplicative> return `$a` end]], 'exactly 2')
      rejects([[local macro f!(a: Statement, b: Expression): Operator<'@', infix, multiplicative> return `$b` end]], 'Expression')
      rejects([[local macro f!(...: Expression): Operator<'@', prefix, unary> return `1` end]], 'exactly 1')
   end)

   it('rejects duplicate declarations and ambiguous infix/postfix bindings', function()
      rejects(declaration('@') .. declaration('@'), 'duplicate')
      rejects(declaration('@') .. declaration('@', '$lhs', 'postfix', 'postfix'), 'infix and postfix')
   end)

   it('rejects statement expansions in expressions', function()
      rejects([[local macro f!(a: Expression, b: Expression): Operator<'@', infix, multiplicative>
         return ```local n = $a + $b```
      end
      return 1 @ 2]], 'statements in an expression context')
   end)
end)
