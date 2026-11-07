local util = require('spec.util')

describe('custom operators in the CLI', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it('checks and lowers statement operators with visible generated locals', function()
      local source = util.write_tmp_file(finally, [[
         local macro (declare)!(name: Expression): Operator<prefix, unary>
            return ```local $name = 42```
         end
         declare answer
         return answer
      ]])
      local output = source:gsub('%.tl$', '.lua')
      local process = io.popen(util.tl_cmd('gen', '--check', '--gen-target=5.1', source, '-o', output) .. ' 2>&1', 'r')
      local report = process:read('*a')
      util.assert_popen_close(0, process:close())
      assert.matches('Wrote:', report, 1, true)
      local code = util.read_file(output)
      assert.not_matches('Operator<', code, 1, true)
      assert.equals(42, assert(loadstring(code))())
   end)

   it('reports only the syntax error for an invalid prefix operand', function()
      local source = util.write_tmp_file(finally, [=[local macro (emit)!(expr: Expression): Operator<prefix, unary>
   return `print($expr)`
end
local value = emit []]=])
      local process = io.popen(util.tl_cmd('check', source) .. ' 2>&1', 'r')
      local report = process:read('*a')
      util.assert_popen_close(1, process:close())
      assert.matches(':4:20:', report, 1, true)
      local _, occurrences = report:gsub(':%d+:%d+:[^\n]*syntax error', '')
      assert.equals(1, occurrences)
      assert.not_matches('expected an operand', report, 1, true)
      assert.not_matches('unknown type', report, 1, true)
      assert.not_matches('cannot determine type', report, 1, true)
   end)

   it('checks and lowers operator macros for a standard Lua target', function()
      local source = util.write_tmp_file(finally, [[
         local function multiply(a: integer, b: integer): integer return a * b end
         local macro (@)!(lhs: Expression, rhs: Expression): Operator<infix, multiplicative>
            return `multiply($lhs, $rhs)`
         end
         return 2 @ 3 + 1
      ]])
      local output = source:gsub('%.tl$', '.lua')
      local process = io.popen(util.tl_cmd('gen', '--check', '--gen-target=5.1', source, '-o', output) .. ' 2>&1', 'r')
      local report = process:read('*a')
      util.assert_popen_close(0, process:close())
      assert.matches('Wrote:', report, 1, true)
      local code = util.read_file(output)
      assert.matches('multiply(2, 3)', code, 1, true)
      assert.not_matches('Operator<', code, 1, true)
      assert.equals(7, assert(loadstring(code))())
   end)
end)
