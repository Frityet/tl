local util = require('spec.util')

describe('LSP parser recovery', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it('serves requests for damaged macros and recovers after edits', function()
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
