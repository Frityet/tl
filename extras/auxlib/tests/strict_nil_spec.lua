local tl = require('teal.api.v2')
local teal = require('teal.init')
local util = require('spec.util')

local function check(source)
   local ast, errors = tl.parse('--#pragma strict_nil on\n' .. source, 'auxlib-strict-nil.tl')
   assert.same({}, errors)
   local result = tl.check(ast, 'auxlib-strict-nil.tl', {
      gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on',
   })
   return result.type_errors
end

describe('auxlib strict nil contracts', function()
   for _, name in ipairs({'async', 'struct', 'tables'}) do
      it('type-checks ' .. name .. ' with strict nil enabled', function()
         local root = assert(util.tl_executable:match('^(.*)[/\\]tl$'))
         local path = root .. '/extras/auxlib/' .. name .. '.tl'
         local file = assert(io.open(path, 'rb'))
         local source = file:read('*a')
         file:close()
         assert.matches('--#pragma strict_nil on', source, 1, true)
         assert.not_matches('strict_nil off', source, 1, true)
         local compiler = teal.compiler({feat_strict_nil = 'on', gen_target = '5.1', gen_compat = 'off'})
         local input = assert(compiler:input(source, path))
         local module, errors = input:check()
         assert.is_not_nil(module)
         assert.same({}, errors.syntax_errors)
         assert.same({}, errors.type_errors)
      end)
   end

   it('requires a nil check before using a possibly missing table value', function()
      local prefix = [[local tables = require('auxlib.tables')
local values: {integer} = {1, 2}
local found = tables.find(values, |value, _| -> value > 3)
]]
      assert.is_true(#check(prefix .. 'local value: integer = found') > 0)
      assert.same({}, check(prefix .. 'if found ~= nil then local value: integer = found end'))
   end)

   it('preserves nullable task results across the generic task API', function()
      local prefix = [[local tasks = require('auxlib.async')
local pending: tasks.Task<string | nil> = tasks.start(function(): string | nil return nil end)
]]
      assert.is_true(#check(prefix .. 'local value: string = pending:result()') > 0)
      assert.same({}, check(prefix .. 'local value: string | nil = pending:result()'))
   end)

   it('preserves nullable generated struct fields', function()
      local prefix = [[local structs = require('auxlib.struct')
local macro (struct)! = structs.(struct)!
struct Sample {
   constructor(auto);
   value: string | nil = nil;
}
local sample = Sample:create()
]]
      assert.is_true(#check(prefix .. 'local value: string = sample.value') > 0)
      assert.same({}, check(prefix .. 'local value: string | nil = sample.value'))
   end)
end)
