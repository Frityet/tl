local tl = require('teal.api.v2')
local function run(source)
   local ast, errors = tl.parse(source, 'parse-expression-fixture.tl')
   assert.same({}, errors)
   local checked = tl.check(ast, 'parse-expression-fixture.tl', {gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on'})
   assert.same({}, checked.type_errors)
   return assert(loadstring(tl.generate(checked.ast, '5.1')))()
end

describe('macro expression parsing', function()
   it('parses one expression and resolves its names in the caller', function()
      assert.equals(7, run([[
local macro expression!(): Expression return parse_expression("value + 2") end
local value = 5
return expression!()
]]))
   end)

   it('does not execute parsed calls during macro expansion', function()
      assert.same({1, 1}, {run([[
local macro expression!(): Expression return parse_expression("tick()") end
local calls = 0
local function tick(): integer calls = calls + 1; return calls end
local result = expression!()
return result, calls
]])})
   end)

   for _, source in ipairs({'', '1, 2', '1; print("not executed")', 'local x = 1'}) do
      it('rejects non-expression input ' .. string.format('%q', source), function()
         local _, errors = tl.parse('local macro expression!(): Expression return parse_expression(' .. string.format('%q', source) .. ') end\nreturn expression!()', 'parse-expression-fixture.tl')
         assert.is_true(#errors > 0)
         assert.matches('expression', errors[1].msg, 1, true)
      end)
   end
end)
