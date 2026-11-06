local util = require('spec.util')
local lsp = require('spec.lsp_util')

describe('LSP parser recovery', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   for _, body in ipairs({'', 'return `print($expr)`'}) do
      it('reports syntax without macro implementation errors: ' .. body, function()
         local dir = util.write_tmp_dir(finally, {
            ['diagnostic_fixture.d.tl'] = 'local record API value: integer end\nreturn API',
         })
         util.do_in(dir, function()
            local source = 'local dependency = require("diagnostic_fixture")\n'
               .. 'local macro (emit)!(expr: Expression): Operator<prefix, unary>\n'
               .. body .. '\nend\nlocal value = emit []\nprint(dependency)'
            local document = lsp.document(finally, source)
            local repaired = [[local dependency = require("diagnostic_fixture")
local macro (emit)!(expr: Expression): Operator<prefix, unary> return `$expr` end
local value = emit 1
print(dependency, value)]]
            local responses = lsp.exchange(finally, {
               {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
               {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
               {jsonrpc = '2.0', id = 2, method = 'textDocument/diagnostic', params = {textDocument = {uri = document.uri}}},
               {jsonrpc = '2.0', method = 'textDocument/didChange', params = {
                  textDocument = {uri = document.uri, version = 2}, contentChanges = {{text = repaired}},
               }},
               {jsonrpc = '2.0', id = 3, method = 'textDocument/diagnostic', params = {textDocument = {uri = document.uri}}},
               {jsonrpc = '2.0', id = 4, method = 'shutdown', params = {}},
               {jsonrpc = '2.0', method = 'exit', params = {}},
            })
            local diagnostics = responses[2].items
            assert.equals(1, #diagnostics)
            assert.equals('syntax', diagnostics[1].code)
            assert.equals('syntax error', diagnostics[1].message)
            assert.equals(4, diagnostics[1].range.start.line)
            assert.equals(19, diagnostics[1].range.start.character)
            assert.same({}, responses[3].items)
         end)
      end)
   end

   it('serves requests for damaged macros and recovers after edits', function()
      local uri = require('spec.lsp_util').document(finally, '').uri
      local messages = {
         [[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}]],
         [[{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl","languageId":"teal","version":1,"text":"local macro broken!(x: Expression)\nlocal t = {value = }"}}}]],
         [[{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"},"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":0}},"context":{"diagnostics":[]}}}]],
         [[{"jsonrpc":"2.0","id":3,"method":"textDocument/documentColor","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"}}}]],
         [[{"jsonrpc":"2.0","id":4,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"}}}]],
         [[{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"},"position":{"line":1,"character":0}}}]],
         [[{"jsonrpc":"2.0","id":8,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"}}}]],
         [[{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl","version":2},"contentChanges":[{"text":"local value = 1\nprint(value)"}]}}]],
         [[{"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"},"position":{"line":1,"character":6}}}]],
         [[{"jsonrpc":"2.0","id":9,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///tmp/tl-lsp-recovery.tl"}}}]],
         [[{"jsonrpc":"2.0","id":7,"method":"shutdown","params":{}}]],
         [[{"jsonrpc":"2.0","method":"exit","params":{}}]],
      }
      local framed = {}
      for _, message in ipairs(messages) do
         message = message:gsub('file:///tmp/tl%-lsp%-recovery%.tl', function() return uri end)
         framed[#framed + 1] = 'Content-Length: ' .. #message .. '\r\n\r\n' .. message
      end
      local input = util.write_tmp_file(finally, table.concat(framed), '.jsonrpc')
      local process = io.popen(util.tl_cmd('lsp', '--stdio') .. '< ' .. string.format('%q', input) .. ' 2>&1', 'r')
      local output = process:read('*a')
      util.assert_popen_close(0, process:close())
      assert.not_matches('"error":', output, 1, true)
      assert.not_matches('compiler-crash', output, 1, true)
      local responses = {}
      local position = 1
      while position <= #output do
         local _, _, length, start = output:find('Content%-Length: (%d+)\r\n\r\n()', position)
         assert.is_not_nil(start, output)
         local body = output:sub(start, start + tonumber(length) - 1)
         position = start + tonumber(length)
         local id = body:match('"id":(%d+)')
         if id then responses[tonumber(id)] = body end
      end
      for id = 1, 9 do assert.is_not_nil(responses[id], output) end
      assert.matches('"code":"syntax"', responses[8], 1, true)
      assert.matches('"items":[]', responses[9], 1, true)
   end)
end)
