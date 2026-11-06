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

   it('keeps macro bodies out of runtime checking after lexical errors', function()
      local errors = check([[local macro echo!(expr: Expression) return `$expr` end
local invalid = 2.e + 1]])
      assert.is_true(#errors.syntax_errors > 0)
      assert.same({}, errors.type_errors)
      assert.same({}, errors.warnings)
   end)
end)
