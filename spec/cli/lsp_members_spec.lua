local util = require('spec.util')
local lsp = require('spec.lsp_util')

describe('LSP member completion', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   local module_source = [[
      local record Child
         leaf: integer
      end
      local record API
         exported: function(integer): integer
         nested: Child
         make: function(): Child
      end
      return API
   ]]

   local function completions(source)
      local dir = util.write_tmp_dir(finally, {['completion_fixture.d.tl'] = module_source})
      return util.do_in(dir, function()
         local document = lsp.document(finally, 'local record Noise unrelated: string end\n' .. source)
         local lines = {}
         for line in document.text:gmatch('[^\n]+') do lines[#lines + 1] = line end
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', id = 2, method = 'textDocument/completion', params = {
               textDocument = {uri = document.uri}, position = {line = #lines - 1, character = #lines[#lines]}}},
            {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         local labels = {}
         for _, item in ipairs(responses[2].items) do labels[#labels + 1] = item.label end
         table.sort(labels)
         return labels
      end)
   end

   for _, source in ipairs({
      'local value = require("completion_fixture").',
      'local value = require("completion_fixture").ex',
      'local api = require("completion_fixture")\nlocal value = api.',
      'local value = (require("completion_fixture")).',
      'local macro proxy!(value: Expression): Expression return `$value` end\nlocal value = proxy!(require("completion_fixture")).',
   }) do
      it('resolves the receiver of ' .. source:gsub('\n.*', ''), function()
         assert.same({'exported', 'make', 'nested'}, completions(source))
      end)
   end

   for _, source in ipairs({
      'local value = require("completion_fixture").make().',
      'local value = require("completion_fixture").nested.',
   }) do
      it('resolves chained expression results: ' .. source, function()
         assert.same({'leaf'}, completions(source))
      end)
   end

   it('does not guess unrelated record fields for an unknown receiver', function()
      assert.same({}, completions('local value: any = {}\nlocal result = value.'))
   end)

   it('resolves types introduced by statement operator expansions', function()
      assert.same({'generated'}, completions([[
         local macro (declare)!(name: Expression): Operator<prefix, unary>
            return ```local record $name generated: integer end```
         end
         declare Item
         local value: Item = {generated = 42}
         local result = value.
      ]]))
   end)

   it('lists parenthesized local and attached operator macros', function()
      local labels = completions([[
         local macro (@)!(a: Expression, b: Expression): Operator<infix, additive> return `$a + $b` end
         local record Export end
         macro Export.(|>)!(a: Expression, b: Expression): Operator<infix, additive> return `$a + $b` end
      ]])
      local found = {}
      for _, label in ipairs(labels) do found[label] = true end
      assert.is_true(found['(@)!'])
      assert.is_true(found['Export.(|>)!'])
   end)
end)
