local tl = require('teal.api.v2')

local function errors(source, mode)
   local ast, syntax = tl.parse('--#pragma strict_nil ' .. mode .. '\n' .. source, 'stdlib-contract.tl')
   assert.same({}, syntax)
   return tl.check(ast, 'stdlib-contract.tl', {feat_strict_nil = mode}).type_errors
end

describe('standard library nil contracts', function()
   for _, source in ipairs({
      "local x: number = tonumber('bad')",
      "local x: string = os.getenv('MISSING')",
      "local x: FILE = io.open('missing')",
      "local x: string = io.read()",
      "local x: integer = table.remove({1})",
      "local x: string = string.match('a', '(b)')",
      "local x: integer = string.find('a', 'b')",
      "local t: {string:integer} = {}; local x: integer = rawget(t, 'missing')",
      "local x: integer = string.byte('', 1)",
      "for i = string.byte(''), 10 do print(i) end",
   }) do
      it('rejects an unchecked nullable result: ' .. source, function()
         assert.is_true(#errors(source, 'on') > 0)
      end)
   end

   it('accepts explicitly narrowed results', function()
      assert.same({}, errors([[
         local f = io.open('missing')
         if f ~= nil then f:close() end
         local n = tonumber('42')
         if n ~= nil then local x: number = n end
         local m = string.match('a', '(a)')
         if m ~= nil then local x: string = m end
      ]], 'on'))
   end)

   it('preserves implicit nil behavior when strict nil is off', function()
      assert.same({}, errors([[
         local f = io.open('missing')
         f:read()
         local s = os.getenv('PATH')
         print(s:len())
         for i = string.byte('a'), string.byte('z') do
            local x: integer = i
         end
      ]], 'off'))
   end)
end)
