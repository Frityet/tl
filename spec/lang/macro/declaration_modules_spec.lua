local tl = require('teal.api.v2')
local util = require('spec.util')

describe('macros exported by declaration modules', function()
   local function module(expression)
      return [[local record Export end
         macro Export.transform!(value: Expression): Expression return `]] .. expression .. [[` end
         return Export]]
   end
   local function run(files)
      util.mock_io(finally, files)
      local ast, errors = tl.parse([[local dependency = require('declaration_fixture')
         local macro transform! = dependency.transform!
         return transform!(7)]], 'declaration-import.tl')
      assert.same({}, errors)
      local result = tl.check(ast, 'declaration-import.tl', {gen_target = '5.1', gen_compat = 'off'})
      assert.same({}, result.type_errors)
      return assert(loadstring(tl.generate(result.ast, '5.1')))()
   end
   it('loads a standalone declaration file', function()
      assert.equals(8, run({['declaration_fixture.d.tl'] = module('$value + 1')}))
   end)
   it('loads a package declaration file', function()
      assert.equals(8, run({['declaration_fixture/init.d.tl'] = module('$value + 1')}))
   end)
   it('retains source macro exports when a declaration file also exists', function()
      assert.equals(8, run({
         ['declaration_fixture.d.tl'] = 'local record Export end; return Export',
         ['declaration_fixture.tl'] = module('$value + 1'),
      }))
   end)
   it('retains implementation-only macro imports', function()
      assert.equals(8, run({['declaration_fixture.tl'] = module('$value + 1')}))
   end)
end)
