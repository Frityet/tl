local tl = require('teal.api.v2')

describe('macro invocation restrictions', function()
   local ordinary = 'local macro inner!(value: Expression): Expression return `$value` end\n'
   local function rejects(source, context)
      local _, errors = tl.parse(source, 'nested-macros.tl')
      assert.equals(1, #errors)
      assert.matches('macro invocations cannot appear inside ' .. context, errors[1].msg, 1, true)
      assert.equals('nested-macros.tl', errors[1].filename)
   end

   for _, call in ipairs({'inner!(1)', 'missing!(1)', 'Export.inner!(1)'}) do
      it('rejects ' .. call .. ' in a macro body, even if unused', function()
         rejects(ordinary .. 'local macro outer!() return ' .. call .. ' end', 'macro bodies')
      end)
      it('rejects ' .. call .. ' in expression quotes', function()
         rejects(ordinary .. 'local macro outer!() return `' .. call .. '` end', 'macro quotes')
      end)
      it('rejects ' .. call .. ' in statement quotes', function()
         rejects(ordinary .. 'local macro outer!() return ```local value = ' .. call .. '``` end', 'macro quotes')
      end)
   end

   for _, operator in ipairs({
      {declaration = 'local macro (@)!(a: Expression, b: Expression): Operator<infix, additive> return `$a + $b` end\n', use = '1 @ 2'},
      {declaration = 'local macro (@)!(a: Expression): Operator<prefix, unary> return `$a + 1` end\n', use = '@ 1'},
      {declaration = 'local macro (@)!(a: Expression): Operator<postfix, postfix> return `$a + 1` end\n', use = '1 @'},
      {declaration = 'local macro (combine)!(a: Expression, b: Expression): Operator<infix, additive> return `$a + $b` end\n', use = '(combine)!(1, 2)'},
   }) do
      it('rejects operator macro use in a body: ' .. operator.use, function()
         rejects(operator.declaration .. 'local macro outer!() return ' .. operator.use .. ' end', 'macro bodies')
      end)
      it('rejects operator macro use in a quote: ' .. operator.use, function()
         rejects(operator.declaration .. 'local macro outer!() return `' .. operator.use .. '` end', 'macro quotes')
      end)
   end

   it('rejects invocations inside functions nested within a macro body', function()
      rejects(ordinary .. [[local macro outer!()
         local function helper() return inner!(1) end
         return helper()
      end]], 'macro bodies')
   end)

   it('rejects invocations inside function bodies in quotes', function()
      rejects(ordinary .. 'local macro outer!() return `function() return inner!(1) end` end', 'macro quotes')
   end)

   it('keeps quote diagnostics at the offending call site', function()
      local _, errors = tl.parse('local macro outer!()\n   return `missing!(1)`\nend', 'nested-macros.tl')
      assert.equals(1, #errors)
      assert.equals(2, errors[1].y)
      assert.equals(12, errors[1].x)
      assert.matches('inside macro quotes', errors[1].msg, 1, true)
   end)

   it('keeps ordinary helper calls and quotes usable', function()
      local source = [[local macro outer!(value: Expression): Expression
         local function helper(n: integer): integer return math.abs(n) end
         local n = block("integer")
         n.tk = tostring(helper(-2))
         return `$value + $n`
      end
      return outer!(3)]]
      local ast, errors = tl.parse(source, 'nested-macros.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'nested-macros.tl', {gen_target = '5.1', gen_compat = 'off'})
      assert.same({}, result.type_errors)
      assert.equals(5, assert(loadstring(tl.generate(result.ast, '5.1')))())
   end)

   it('passes expanded expressions and operator operands to the outer macro', function()
      local ast, errors = tl.parse(ordinary .. [[
         local macro (@)!(lhs: Expression, rhs: Expression): Operator<infix, additive>
            expect(lhs, "integer")
            return `$lhs + $rhs`
         end
         local macro outer!(value: Expression)
            expect(value, "paren")
            expect(value[BLOCK_INDEXES.PAREN.EXP], "op_add")
            return value
         end
         return outer!(inner!(7) @ inner!(2))
      ]], 'nested-macros.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'nested-macros.tl', {gen_target = '5.1', gen_compat = 'off'})
      assert.same({}, result.type_errors)
      assert.equals(9, assert(loadstring(tl.generate(result.ast, '5.1')))())
   end)

   it('reports errors from nested invocations even when the argument is discarded', function()
      local _, errors = tl.parse([[local macro bad!() error("inner failed", 0) end
local macro ignore!(value: Expression) return `0` end
return ignore!(
   bad!()
)]], 'nested-macros.tl')
      assert.equals(1, #errors)
      assert.equals(4, errors[1].y)
      assert.matches('inner failed', errors[1].msg, 1, true)
   end)

   it('expands nested macros in statement arguments before passing the block', function()
      local ast, errors = tl.parse([[
         local macro declare!() return ```local x = 7``` end
         local macro forward!(body: Statement)
            expect(body[1], "local_declaration")
            return body
         end
         forward!(declare!())
         return x
      ]], 'nested-macros.tl')
      assert.same({}, errors)
      assert.equals(7, assert(loadstring(tl.generate(ast, '5.1')))())
   end)
end)
