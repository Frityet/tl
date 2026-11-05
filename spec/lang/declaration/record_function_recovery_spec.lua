local tl = require('teal.api.v2')

describe('record function owner recovery', function()
   for _, owner in ipairs({'Root.missing', 'Root.missing.nested'}) do
      for _, separator in ipairs({'.', ':'}) do
         it('reports an undeclared owner ' .. owner .. separator .. 'run', function()
            local result = tl.check_string('local record Root end\nfunction ' .. owner .. separator .. 'run() end', nil, 'owner.tl')
            assert.same({}, result.syntax_errors)
            assert.is_true(#result.type_errors > 0)
            assert.matches("invalid key 'missing'", result.type_errors[1].msg, 1, true)
            for _, err in ipairs(result.type_errors) do
               assert.not_matches('compiler recovery', err.msg, 1, true)
            end
         end)
      end
   end

   it('handles incomplete method declarations in editor analysis', function()
      local env = assert(tl.new_env())
      env.keep_going = true
      env.report_types = true
      local result = tl.check_string('local record Root end\nfunction Root.missing: Item end', env, 'owner.tl')
      assert.is_true(#result.syntax_errors > 0)
   end)
end)
