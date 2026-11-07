local tl = require('teal.api.v2')

describe('operator macro statement expansions', function()
   local function run(source)
      local ast, errors = tl.parse(source, 'statement-operators.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'statement-operators.tl', {gen_target = '5.1', gen_compat = 'off'})
      assert.same({}, result.type_errors)
      local code, err = tl.generate(result.ast, '5.1')
      assert.is_nil(err)
      return assert(loadstring(code), code)()
   end

   local declaration = [[
local macro (declare)!(name: Expression): Operator<prefix, unary>
   return ```local $name = 41```
end
]]

   it('introduces locals in the surrounding scope from prefix operators', function()
      assert.equals(42, run(declaration .. 'declare answer\nreturn answer + 1'))
   end)

   it('introduces locals from infix operators', function()
      assert.equals(42, run([[
         local macro (initialized)!(name: Expression, value: Expression): Operator<infix, additive>
            return ```local $name = $value```
         end
         answer initialized 42
         return answer
      ]]))
   end)

   it('introduces locals from postfix operators', function()
      assert.equals(42, run([[
         local macro (initialized)!(name: Expression): Operator<postfix, postfix>
            return ```local $name = 42```
         end
         answer initialized
         return answer
      ]]))
   end)

   it('splices multiple statements in source order', function()
      assert.equals(42, run([[
         local macro (declare)!(name: Expression): Operator<prefix, unary>
            return ```local $name = 40; $name = $name + 2```
         end
         declare answer
         return answer
      ]]))
   end)

   it('accepts empty statement blocks', function()
      assert.equals(42, run([[
         local macro (ignore)!(value: Expression): Operator<prefix, unary>
            return block('statements')
         end
         ignore undefined_syntax_name
         return 42
      ]]))
   end)

   it('accepts a single statement returned directly', function()
      assert.equals(42, run([[
         local macro (declare)!(name: Expression): Operator<prefix, unary>
            local out = ```local $name = 42```
            return out[1]
         end
         declare answer
         return answer
      ]]))
   end)

   it('supports explicit operator macro invocations', function()
      assert.equals(42, run(declaration .. '(declare)!(answer)\nreturn answer + 1'))
   end)

   it('supports attached operators and local macro imports', function()
      assert.equals(42, run([[
         local record Export end
         macro Export.(declare)!(name: Expression): Operator<prefix, unary>
            return ```local $name = 42```
         end
         local macro (declare)! = Export.(declare)!
         declare answer
         return answer
      ]]))
   end)

   it('introduces types usable by following declarations', function()
      assert.equals(42, run([[
         local macro (declare)!(name: Expression): Operator<prefix, unary>
            return ```local record $name value: integer end```
         end
         declare Item
         local item: Item = {value = 42}
         return item.value
      ]]))
   end)

   it('preserves lexical scopes and shadowing', function()
      assert.equals(42, run(declaration .. [[
         local answer = 1
         local total = 0
         do
            declare answer
            total = answer
         end
         return total + answer
      ]]))
   end)

   it('type-checks generated statements at the operator use', function()
      local source = [[local macro (declare)!(name: Expression): Operator<prefix, unary>
   return ```local $name: integer = "wrong"```
end
declare answer
print(answer)]]
      local ast, errors = tl.parse(source, 'statement-operators.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'statement-operators.tl')
      assert.equals(1, #result.type_errors)
      assert.equals(4, result.type_errors[1].y)
   end)

   it('allows return statements in generated function bodies', function()
      assert.equals(42, run([[
         local macro (finish)!(value: Expression): Operator<prefix, unary>
            return ```return $value```
         end
         local function calculate(): integer
            finish 42
         end
         return calculate()
      ]]))
   end)

   it('allows loop control in statement expansions', function()
      assert.equals(42, run([[
         local macro (stop)!(value: Expression): Operator<prefix, unary>
            return ```break```
         end
         local total = 0
         for i = 1, 100 do
            total = total + i
            stop i
         end
         return total + 41
      ]]))
   end)

   for _, usage in ipairs({'local value = declare answer', 'return declare answer', 'print(declare answer)'}) do
      it('rejects declarations in expression context: ' .. usage, function()
         local _, errors = tl.parse(declaration .. usage, 'statement-operators.tl')
         assert.equals(1, #errors)
         assert.matches('returned statements in an expression context', errors[1].msg, 1, true)
      end)
   end

   it('validates expressions inserted into generated statement lists', function()
      local _, errors = tl.parse([[
         local macro (bad)!(value: Expression): Operator<prefix, unary>
            local out = block('statements')
            table.insert(out, `$value + 1`)
            return out
         end
         bad 41
      ]], 'statement-operators.tl')
      assert.equals(1, #errors)
      assert.matches('cannot be used as a statement', errors[1].msg, 1, true)
   end)

   for _, usage in ipairs({
      'from source import { first, second }',
      'import { first, second } from source',
   }) do
      it('composes prefix and infix statement operators: ' .. usage, function()
         local function selection(symbol, parameters)
            return 'local macro (' .. symbol .. ')!(' .. parameters .. '): Operator<infix, comparison>\n' .. [[
               local out = block('statements')
               for _, item in ipairs(names) do
                  local name = expect(item[BLOCK_INDEXES.LITERAL_TABLE_ITEM.VALUE], 'identifier')
                  table.insert(out, ```local $name = $source.$name```)
               end
               return out
            end
            ]]
         end
         assert.equals(42, run([[
            local macro (from)!(value: Expression): Operator<prefix, conditional> return value end
            local macro (import)!(value: Expression): Operator<prefix, conditional> return value end
         ]] .. selection('import', 'source: Expression, names: Expression')
            .. selection('from', 'names: Expression, source: Expression') .. [[
            local source = {first = 19, second = 23};
         ]] .. usage .. '\nreturn first + second'))
      end)
   end
end)
