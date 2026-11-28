local teal = require('teal')

describe('macro syntax recovery diagnostics', function()
   local function check(source)
      local compiler = teal.compiler()
      compiler:enable_type_reporting(true)
      local module, errors = compiler:input(source, 'recovery.tl'):check()
      assert(module)
      assert(compiler:get_type_report())
      return errors
   end

   for _, body in ipairs({'', 'return `print($expr)`'}) do
      it('reports only the invalid prefix operand with body: ' .. body, function()
         local errors = check('local macro (emit)!(expr: Expression): Operator<prefix, unary>\n'
            .. body .. '\nend\nlocal value = emit []')
         assert.equals(1, #errors.syntax_errors)
         assert.equals('syntax error', errors.syntax_errors[1].msg)
         assert.equals(4, errors.syntax_errors[1].y)
         assert.equals(20, errors.syntax_errors[1].x)
         assert.same({}, errors.type_errors)
         assert.same({}, errors.warnings)
      end)
   end

   for _, declaration in ipairs({
      'local macro echo!(expr: Expression): Expression return `$expr` end',
      'local macro declare!(): Statement return ```local value = {}; print(value)``` end',
      'do local macro echo!(expr: Expression): Expression return `$expr` end end',
      'local record Export end\nmacro Export.echo!(expr: Expression): Expression return `$expr` end\nprint(Export)',
      'local macro (emit)!(expr: Expression): Operator<prefix, unary> return `$expr` end',
   }) do
      it('keeps skipped macro bodies out of runtime checking: ' .. declaration, function()
         local errors = check(declaration .. '\nlocal invalid = []')
         assert.equals(1, #errors.syntax_errors)
         assert.same({}, errors.type_errors)
         assert.same({}, errors.warnings)
      end)
   end

   it('keeps independent type errors in valid code', function()
      local errors = check([=[
local macro (emit)!(expr: Expression): Operator<prefix, unary>
   return `print($expr)`
end
local invalid = emit []
local after: integer = "wrong"
print(after)
]=])
      assert.equals(1, #errors.syntax_errors)
      assert.equals(1, #errors.type_errors)
      assert.equals(5, errors.type_errors[1].y)
      assert.same({}, errors.warnings)
   end)

   it('still explains an entirely missing operand', function()
      local errors = check([[local macro (emit)!(expr: Expression): Operator<prefix, unary>
   return `$expr`
end
local value = emit]])
      assert.equals(1, #errors.syntax_errors)
      assert.matches("expected an operand for operator 'emit'", errors.syntax_errors[1].msg, 1, true)
      assert.same({}, errors.type_errors)
      assert.same({}, errors.warnings)
   end)

   it('preserves genuine unknown types outside a macro', function()
      local errors = check([=[local macro echo!(expr: Expression) return `$expr` end
local invalid = []
local after: Expression = nil
print(after)]=])
      assert.equals(1, #errors.syntax_errors)
      assert.equals(1, #errors.type_errors)
      assert.equals('unknown type Expression', errors.type_errors[1].msg)
      assert.equals(3, errors.type_errors[1].y)
      assert.same({}, errors.warnings)
   end)

   it('does not execute macros while recovering from syntax errors', function()
      local errors = check([=[local macro explode!()
   error("executed during recovery")
end
explode!()
local invalid = []]=])
      assert.equals(1, #errors.syntax_errors)
      assert.same({}, errors.type_errors)
      assert.same({}, errors.warnings)
   end)

   it('recovers from forbidden quoted invocations without executing macros', function()
      local errors = check([[local macro inner!()
   error("executed forbidden invocation")
end
local macro outer!() return `inner!()` end
outer!()
local after: integer = "wrong"
print(after)]])
      assert.equals(1, #errors.syntax_errors)
      assert.matches('macro invocations cannot appear inside macro quotes', errors.syntax_errors[1].msg, 1, true)
      assert.equals(1, #errors.type_errors)
      assert.equals(6, errors.type_errors[1].y)
      assert.same({}, errors.warnings)
   end)

   it('keeps macro bodies out of runtime checking after lexical errors', function()
      local errors = check([[local macro echo!(expr: Expression) return `$expr` end
local invalid = 2.e + 1]])
      assert.is_true(#errors.syntax_errors > 0)
      assert.same({}, errors.type_errors)
      assert.same({}, errors.warnings)
   end)

   for _, case in ipairs({
      {'macroexp body', 'emit!()', 'expand(1)'},
      {'macroexp argument', 'x', 'expand(1 + emit!())'},
   }) do
      it('recovers when an unexpanded macro is in a ' .. case[1], function()
         local source = ([[local macro emit!(): Expression return `1` end
local macroexp expand(x: integer): integer
   return %s
end
local invalid = []
print(%s)
local after: integer = "wrong"
print(after)]]):format(case[2], case[3])
         local errors = check(source)
         assert.equals(1, #errors.syntax_errors)
         assert.equals(5, errors.syntax_errors[1].y)
         assert.equals(1, #errors.type_errors)
         assert.equals(7, errors.type_errors[1].y)
      end)
   end

   it('recovers from a macroexp with a missing return expression', function()
      local errors = check([[local record Point
   tostring: function(self): string = macroexp(self: self): string]])
      assert.is_true(#errors.syntax_errors > 0)
      assert.same({}, errors.type_errors)
   end)
end)
