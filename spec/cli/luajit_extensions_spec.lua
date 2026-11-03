local util = require('spec.util')

describe('LuaJIT extension target in the CLI', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it('accepts the command-line target and checks generated code', function()
      local source = util.write_tmp_file(finally, [[
         const N: integer = 1_000
         local increment: function(integer): integer = x -> x + 1
         local n = 1
         n += 2
         print(N, increment(n), true ? false : true)
      ]])
      local output = source:gsub('%.tl$', '.lua')
      local process = io.popen(util.tl_cmd('gen', '--check', '--gen-target=luajit', source, '-o', output) .. ' 2>&1', 'r')
      local report = process:read('*a')
      util.assert_popen_close(0, process:close())
      assert.matches('Wrote:', report, 1, true)
      local code = util.read_file(output)
      assert.matches('const N = 1000', code, 1, true)
      assert.matches('n += 2', code, 1, true)
      assert.matches('function(x)', code, 1, true)
      assert.matches(' ? ', code, 1, true)
   end)

   it('accepts the target from tlconfig.lua', function()
      local directory = util.write_tmp_dir(finally, {
         ['tlconfig.lua'] = 'return {gen_target="luajit"}',
         ['main.tl'] = 'local n = 1; n += 2; print(n ?? 0)',
      })
      util.do_in(directory, function()
         local process = io.popen(util.tl_cmd('gen', '--check', 'main.tl') .. ' 2>&1', 'r')
         local report = process:read('*a')
         util.assert_popen_close(0, process:close())
         assert.matches('Wrote:', report, 1, true)
         assert.matches('n += 2', util.read_file('main.lua'), 1, true)
      end)
   end)
end)
