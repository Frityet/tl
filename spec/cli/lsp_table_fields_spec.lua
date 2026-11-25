local util = require('spec.util')
local lsp = require('spec.lsp_util')

describe('LSP contextual table fields', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   local fixture = [[
      local record UI
         interface Global
            --- ID of the element.
            id: string | nil
            --- Accessible name.
            ["aria-label"]: string | nil
         end
         interface Input is Global
            --- Hint when the input is empty.
            placeholder: string | nil
         end
         interface Tag<A>
            metamethod __call: function(self, A): string
            metamethod __call: function(self, {string: string | nil}): string
         end
         input: Tag<Input>
      end
      return UI
   ]]

   local function request(method, input)
      local source = "local ui = require('table_fixture')\n" .. input
      local cursor = assert(source:find('@C@', 1, true))
      local prefix = source:sub(1, cursor - 1)
      local _, line = prefix:gsub('\n', '')
      local character = #prefix:match('[^\n]*$')
      source = prefix .. source:sub(cursor + 3)

      local dir = util.write_tmp_dir(finally, {['table_fixture.d.tl'] = fixture})
      return util.do_in(dir, function()
         local document = lsp.document(finally, source)
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', id = 2, method = 'textDocument/' .. method, params = {
               textDocument = {uri = document.uri}, position = {line = line, character = character},
            }},
            {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         return responses[2]
      end)
   end

   it('navigates from a callable literal to the inherited field declaration', function()
      local definition = request('definition', [[local id = "unrelated"
return ui.input { @C@id = "field" }
]])
      assert.matches('/table_fixture%.d%.tl$', definition.uri)
      assert.same({line = 3, character = 12}, definition.range.start)
   end)

   it('navigates from a quoted key to the inherited field declaration', function()
      local definition = request('definition', [[local attrs: ui.Input = { ["aria-@C@label"] = "Name" }]])
      assert.matches('/table_fixture%.d%.tl$', definition.uri)
      assert.same({line = 5, character = 13}, definition.range.start)
   end)
end)
