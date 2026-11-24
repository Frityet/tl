local util = require('spec.util')
local lsp = require('spec.lsp_util')

describe('LSP parser recovery', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it('places hints only on matching source identifiers', function()
      local document = lsp.document(finally, [=[
local inferred = 42
local annotated: integer = 1
local macro bind!(declaration: Statement): Statement
   return ```local generated = 2```
end
local function decorated()<bind!>: integer return annotated end
print(inferred)
]=])
      local responses = lsp.exchange(finally, {
         {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
         {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
         {jsonrpc = '2.0', id = 2, method = 'textDocument/inlayHint', params = {
            textDocument = {uri = document.uri},
            range = {start = {line = 0, character = 0}, ['end'] = {line = 7, character = 0}},
         }},
         {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
         {jsonrpc = '2.0', method = 'exit', params = {}},
      })
      assert.equals(1, #responses[2])
      assert.same({line = 0, character = 14}, responses[2][1].position)
      assert.equals(': integer', responses[2][1].label)
   end)

   it('navigates to required modules and visible local declarations', function()
      local dir = util.write_tmp_dir(finally, {
         ['tlconfig.lua'] = 'return { include_dir = {"vendor"} }',
         vendor = {
            ['shapes.tl'] = 'local record Export end\nreturn Export',
            package_fixture = { ['init.d.tl'] = 'local record Package end\nreturn Package' },
         },
      })
      util.do_in(dir, function()
         local document = lsp.document(finally, table.concat({
            'local outer = require("shapes")',
            'local package_fixture = require "package_fixture"',
            'do',
            '   local outer = package_fixture',
            '   print(outer)',
            'end',
            'print(outer)',
            'local missing = require("unresolved_module")',
         }, '\n'))
         local td = {uri = document.uri}
         local function definition(id, line, character)
            return {jsonrpc = '2.0', id = id, method = 'textDocument/definition',
               params = {textDocument = td, position = {line = line, character = character}}}
         end
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            definition(2, 0, 25),
            definition(3, 1, 36),
            definition(4, 4, 10),
            definition(5, 6, 7),
            definition(6, 7, 30),
            {jsonrpc = '2.0', id = 7, method = 'textDocument/documentLink', params = {textDocument = td}},
            {jsonrpc = '2.0', id = 8, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         assert.matches('/vendor/shapes%.tl$', responses[2].uri)
         assert.matches('/vendor/package_fixture/init%.d%.tl$', responses[3].uri)
         assert.equals(document.uri, responses[4].uri)
         assert.same({line = 3, character = 9}, responses[4].range.start)
         assert.equals(document.uri, responses[5].uri)
         assert.same({line = 0, character = 6}, responses[5].range.start)
         assert.is_nil(responses[6])
         assert.equals(2, #responses[7])
         assert.equals(responses[2].uri, responses[7][1].target)
         assert.equals(responses[3].uri, responses[7][2].target)
      end)
   end)

   it('keeps document highlights local without indexing unopened files', function()
      local dir = util.write_tmp_dir(finally, {
         ['tlconfig.lua'] = 'return { include_dir = {"types"} }',
         types = { ['unopened.tl'] = 'local marker = 2\nprint(marker)' },
      })
      util.do_in(dir, function()
         local document = lsp.document(finally, 'local marker = 11\nprint(marker)')
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize',
               params = {rootUri = 'file://' .. require('lfs').currentdir()}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', method = 'textDocument/didChange', params = {
               textDocument = {uri = document.uri, version = 2},
               contentChanges = {{range = {start = {line = 0, character = 16},
                  ['end'] = {line = 0, character = 17}}, text = ''}},
            }},
            {jsonrpc = '2.0', id = 2, method = 'textDocument/documentHighlight', params = {
               textDocument = {uri = document.uri}, position = {line = 1, character = 6},
            }},
            {jsonrpc = '2.0', id = 3, method = 'workspace/diagnostic', params = {}},
            {jsonrpc = '2.0', id = 4, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         assert.equals(2, #responses[2])
         assert.same({'.', ':', '<', '!'}, responses[1].capabilities.completionProvider.triggerCharacters)
         assert.is_true(responses[1].capabilities.diagnosticProvider.workspaceDiagnostics)
         assert.equals(1, #responses[3].items)
         assert.equals(document.uri, responses[3].items[1].uri)
         assert.equals(2, responses[3].items[1].version)
      end)
   end)

   it('finds workspace symbols without type-checking unopened files', function()
      local lfs = require('lfs')
      local dir = util.write_tmp_dir(finally, {
         ['tlconfig.lua'] = 'return { include_dir = {"types"}, lsp = {workspace_diagnostics = false} }',
         types = { ['unopened.tl'] = 'global workspace_only: integer = 1' },
      })
      util.do_in(dir, function()
         local document = lsp.document(finally, 'print(workspace_only)')
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize',
               params = {rootUri = 'file://' .. lfs.currentdir()}},
            {jsonrpc = '2.0', id = 2, method = 'workspace/symbol', params = {query = 'workspace_only'}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', id = 3, method = 'textDocument/diagnostic',
               params = {textDocument = {uri = document.uri}}},
            {jsonrpc = '2.0', id = 4, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         assert.is_false(responses[1].capabilities.diagnosticProvider.workspaceDiagnostics)
         assert.equals('workspace_only', responses[2][1].name)
         assert.matches('unknown variable', responses[3].items[1].message, 1, true)
      end)
   end)

   it('checks self-referencing interfaces alongside imported macros', function()
      local dir = util.write_tmp_dir(finally, {
         ['macro_fixture.tl'] = [[
            local record Export end
            macro Export.value!() return `7` end
            return Export
         ]],
      })
      util.do_in(dir, function()
         local document = lsp.document(finally, [[
            local fixture = require("macro_fixture")
            local macro value! = fixture.value!
            local interface Indexed where self.__index
               __index: self
            end
            local function read(_value: Indexed): integer
               return value!()
            end
            return read
         ]])
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', id = 2, method = 'textDocument/diagnostic',
               params = {textDocument = {uri = document.uri}}},
            {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         assert.same({}, responses[2].items)
      end)
   end)

   it('reports syntax errors when deleting a numeric for bound separator', function()
      local document = lsp.document(finally, 'for i = 1, 3 do\n   print(i)\nend')
      local responses = lsp.exchange(finally, {
         {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
         {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
         {jsonrpc = '2.0', method = 'textDocument/didChange', params = {
            textDocument = {uri = document.uri, version = 2},
            contentChanges = {{range = {start = {line = 0, character = 9},
               ['end'] = {line = 0, character = 10}}, text = ''}},
         }},
         {jsonrpc = '2.0', id = 2, method = 'textDocument/diagnostic',
            params = {textDocument = {uri = document.uri}}},
         {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
         {jsonrpc = '2.0', method = 'exit', params = {}},
      })
      assert.is_true(#responses[2].items > 0)
      for _, item in ipairs(responses[2].items) do
         assert.equals('syntax', item.code)
      end
   end)

   it('still reports a real invalid numeric for bound', function()
      local document = lsp.document(finally, 'for i = 1, nil do end')
      local responses = lsp.exchange(finally, {
         {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
         {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
         {jsonrpc = '2.0', id = 2, method = 'textDocument/diagnostic',
            params = {textDocument = {uri = document.uri}}},
         {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
         {jsonrpc = '2.0', method = 'exit', params = {}},
      })
      local found = false
      for _, item in ipairs(responses[2].items) do
         if item.code == 'type' and item.message == 'numeric for limit must be a non-nil number' then
            found = true
         end
      end
      assert.is_true(found)
   end)

   it('reuses a complete workspace manifest and rebuilds a partial one', function()
      local lfs = require('lfs')
      local dir = util.write_tmp_dir(finally, {
         ['tlconfig.lua'] = 'return { include_dir = {"types"} }',
         types = { ['cache entry.tl'] = 'local record CacheEntry end\nreturn CacheEntry' },
      })
      util.do_in(dir, function()
         local function search()
            local responses = lsp.exchange(finally, {
               {jsonrpc = '2.0', id = 1, method = 'initialize',
                  params = {rootUri = 'file://' .. lfs.currentdir()}},
               {jsonrpc = '2.0', id = 2, method = 'workspace/symbol', params = {query = 'CacheEntry'}},
               {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
               {jsonrpc = '2.0', method = 'exit', params = {}},
            })
            assert.equals('CacheEntry', responses[2][1].name)
         end
         local path = '.cache/tl-lsp/workspace-index.paths'
         search()
         local earlier = os.time() - 10
         assert(lfs.touch(path, earlier, earlier))
         search()
         assert.equals(earlier, lfs.attributes(path, 'modification'))

         local file = assert(io.open(path, 'wb'))
         file:write('partial manifest')
         file:close()
         search()
         file = assert(io.open(path, 'rb'))
         assert.matches('cache entry.tl\0\0', file:read('*a'), 1, true)
         file:close()
      end)
   end)

   it('diagnoses forbidden quoted macro calls and recovers after edits', function()
      local source = [[local macro inner!(value: Expression) return `$value` end
local macro outer!() return `inner!(1)` end
local value = outer!()
print(value)]]
      local document = lsp.document(finally, source)
      local repaired = source:gsub('`inner!%(1%)`', '`1`')
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
      assert.equals(1, #responses[2].items)
      assert.equals('syntax', responses[2].items[1].code)
      assert.matches('macro invocations cannot appear inside macro quotes', responses[2].items[1].message, 1, true)
      assert.equals(1, responses[2].items[1].range.start.line)
      assert.same({}, responses[3].items)
   end)

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
