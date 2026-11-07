local util = require('spec.util')
local lsp = require('spec.lsp_util')

-- @H@ marks a hover position and is removed before sending source to the LSP.
local function hover(source, files, delta)
   local cursor = assert(source:find('@H@', 1, true))
   source = source:sub(1, cursor - 1) .. source:sub(cursor + 3)
   local prefix = source:sub(1, cursor - 1)
   local _, line = prefix:gsub('\n', '')
   local character = #(prefix:match('[^\n]*$')) + (delta or 0)
   local dir = util.write_tmp_dir(finally, files or {})
   return util.do_in(dir, function()
      local document = lsp.document(finally, source)
      local responses = lsp.exchange(finally, {
         {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
         {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
         {jsonrpc = '2.0', id = 2, method = 'textDocument/hover', params = {
            textDocument = {uri = document.uri}, position = {line = line, character = character},
         }},
         {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
         {jsonrpc = '2.0', method = 'exit', params = {}},
      })
      return responses[2]
   end)
end

local function text(result)
   assert.is_table(result)
   assert.equals('markdown', result.contents.kind)
   return result.contents.value
end

describe('LSP TealDoc hover', function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)

   it('renders line comments, continuation lines, tags, and Markdown without changing code fences', function()
      local result = text(hover([=[
-- An ordinary comment before the documentation must not hide it.
--- Identity summary.
-- A second line in the same paragraph.
--
-- - a list item
--   with a continuation
--
-- ```teal
-- local value = 2
-- @literal_in_example
-- ```
-- @param value The input.
--   More about the input.
-- @return The unchanged value.
-- @see other_function
local function identity(value: integer): integer return value end
return @H@identity(2)
]=]))
      assert.matches('Identity summary.\nA second line', result, 1, true)
      assert.matches('- a list item\n  with a continuation', result, 1, true)
      assert.matches('```teal\nlocal value = 2\n@literal_in_example\n```', result, 1, true)
      assert.matches('**Parameter `value`:** The input.\n  More about the input.', result, 1, true)
      assert.matches('**Returns:** The unchanged value.', result, 1, true)
      assert.matches('**@see:** other_function', result, 1, true)
      assert.not_matches('ordinary comment before', result, 1, true)
   end)

   for _, delimiters in ipairs({{'--[[--', ']]--'}, {'--[=[--', ']=]--'}}) do
      it('renders and dedents TealDoc block comments using ' .. delimiters[1], function()
         local source = delimiters[1] .. [[

    Block summary.

    ```teal
    local value = 1
       print(value)
    ```
    @param value Input value.
]] .. delimiters[2] .. [[

local function identity(value: integer): integer return value end
return @H@identity(1)
]]
         local result = text(hover(source))
         assert.matches('Block summary.', result, 1, true)
         assert.matches('```teal\nlocal value = 1\n   print(value)\n```', result, 1, true)
         assert.matches('**Parameter `value`:** Input value.', result, 1, true)
      end)
   end

   it('does not attach documentation separated from its declaration by a blank line', function()
      local result = text(hover([[
--- This documents nothing.

local function identity(value: integer): integer return value end
return @H@identity(1)
]]))
      assert.not_matches('This documents nothing.', result, 1, true)
   end)

   it('follows imported function declarations', function()
      local result = text(hover([[
local api = require('hover_fixture')
return api.@H@identity(1)
]], {['hover_fixture.tl'] = [[
local record API end
--- Imported identity summary.
-- @param value The imported input.
function API.identity(value: integer): integer return value end
return API
]]}))
      assert.matches('Imported identity summary.', result, 1, true)
      assert.matches('**Parameter `value`:** The imported input.', result, 1, true)
   end)

   it('documents named local macros at invocation sites', function()
      local result = text(hover([[
--- Local macro summary.
-- @param value Expression to keep.
local macro identity!(value: Expression): Expression return `$value` end
return @H@identity!(1)
]]))
      assert.matches('Local macro summary.', result, 1, true)
      assert.matches('**Parameter `value`:** Expression to keep.', result, 1, true)
   end)

   it('documents fields using their declaration comments', function()
      local value = text(hover([[
local record Item
   --- Field summary.
   value: integer
end
local item: Item = {value = 2}
return item.@H@value
]]))
      assert.matches('Field summary.', value, 1, true)
   end)

   it('reads docs at the declaration of an unopened generic method field', function()
      local value = text(hover([[
local api = require('hover_fixture')
local function inspect(scope: api.Scope)
   return scope.@H@spawn
end
]], {['hover_fixture.tl'] = [[
local record API
   record Scope
      --- Generic method field summary.
      spawn: function<T>(self: Scope, factory: function(): T): T
      _state: boolean
   end
end
return API
]]}))
      assert.matches('Generic method field summary.', value, 1, true)
   end)

   it('finds declaration comments across a split function header', function()
      local value = text(hover([[
--- Multiline function summary.
local function
identity(value: integer): integer return value end
return @H@identity(2)
]]))
      assert.matches('Multiline function summary.', value, 1, true)
   end)

   local fixture = [[
local record API end
--- Imported operator summary.
--
-- ```teal
-- local total = 1 +=> 2
-- ```
-- @param left Left operand.
-- @param right Right operand.
macro API.(+=>)!(left: Expression, right: Expression): Operator<infix, additive>
   return `$left + $right`
end
--- Imported named macro summary.
macro API.identity!(value: Expression): Expression return `$value` end
return API
]]

   for delta = 0, 2 do
      it('resolves imported operator docs on byte ' .. (delta + 1) .. ' of +=>', function()
         local result = hover([[
local api = require('hover_fixture')
local macro (+=>)! = api.(+=>)!
return 1 @H@+=> 2
]], {['hover_fixture.tl'] = fixture}, delta)
         local value = text(result)
         assert.matches('Imported operator summary.', value, 1, true)
         assert.matches('macro API.(+=>)!', value, 1, true)
         assert.matches('```teal\nlocal total = 1 +=> 2\n```', value, 1, true)
         assert.equals(3, result.range['end'].character - result.range.start.character)
      end)
   end

   for _, expression in ipairs({'(@H@+=>)! = api.(+=>)!', '(+=>)! = api.(@H@+=>)!'}) do
      it('resolves documentation on both sides of an operator alias: ' .. expression, function()
         local result = hover("local api = require('hover_fixture')\nlocal macro " .. expression,
            {['hover_fixture.tl'] = fixture})
         local value = text(result)
         assert.matches('Imported operator summary.', value, 1, true)
         assert.not_matches('@operator:', value, 1, true)
         assert.not_matches('**Macro expansion**', value, 1, true)
         assert.is_true(result.range['end'].character <= #'local macro (+=>)! = api.(+=>)!')
      end)
   end

   it('follows imported named macro aliases', function()
      local result = text(hover([[
local api = require('hover_fixture')
local macro copy! = api.identity!
return @H@copy!(1)
]], {['hover_fixture.tl'] = fixture}))
      assert.matches('Imported named macro summary.', result, 1, true)
   end)

   it('distinguishes scoped operators with the same spelling', function()
      local result = text(hover([[
--- Outer operator summary.
local macro (@)!(left: Expression, right: Expression): Operator<infix, additive> return `$left + $right` end
local outer = 1 @ 2
do
   --- Inner operator summary.
   local macro (@)!(left: Expression, right: Expression): Operator<infix, additive> return `$left * $right` end
   local inner = 2 @H@@ 3
end
return outer
]]))
      assert.matches('Inner operator summary.', result, 1, true)
      assert.not_matches('Outer operator summary.', result, 1, true)
   end)

   it('shows docs when hovering an operator definition', function()
      local result = text(hover([[
--- Declaration operator summary.
local macro (@H@@)!(left: Expression, right: Expression): Operator<infix, additive> return `$left + $right` end
return 1 @ 2
]]))
      assert.matches('Declaration operator summary.', result, 1, true)
   end)
   it('uses UTF-16 ranges after a non-BMP character', function()
      local result = hover([[
local api = require('hover_fixture')
local macro (+=>)! = api.(+=>)!
local title = "😀"; return 1 @H@+=> 2
]], {['hover_fixture.tl'] = fixture}, -2)
      assert.matches('Imported operator summary.', text(result), 1, true)
      assert.equals(#'local title = "😀"; return 1 ' - 2, result.range.start.character)
      assert.equals(3, result.range['end'].character - result.range.start.character)
   end)

   it('refreshes macro documentation after an unsaved edit', function()
      local before = [=[--- Before edit.
local macro identity!(value: Expression): Expression return `$value` end
return identity!(1)
]=]
      local document = lsp.document(finally, before)
      local position = {line = 2, character = 8}
      local responses = lsp.exchange(finally, {
         {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
         {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
         {jsonrpc = '2.0', id = 2, method = 'textDocument/hover', params = {textDocument = {uri = document.uri}, position = position}},
         {jsonrpc = '2.0', method = 'textDocument/didChange', params = {
            textDocument = {uri = document.uri, version = 2},
            contentChanges = {{text = before:gsub('Before edit', 'After edit')}},
         }},
         {jsonrpc = '2.0', id = 3, method = 'textDocument/hover', params = {textDocument = {uri = document.uri}, position = position}},
         {jsonrpc = '2.0', id = 4, method = 'shutdown', params = {}},
         {jsonrpc = '2.0', method = 'exit', params = {}},
      })
      assert.matches('Before edit.', text(responses[2]), 1, true)
      assert.matches('After edit.', text(responses[3]), 1, true)
      assert.not_matches('Before edit.', text(responses[3]), 1, true)
   end)

   it('reads imported macro documentation from an open unsaved buffer', function()
      local dir = util.write_tmp_dir(finally, {['hover_fixture.tl'] = fixture})
      util.do_in(dir, function()
         local imported = {
            uri = 'file://' .. require('lfs').currentdir() .. '/hover_fixture.tl',
            languageId = 'teal', version = 1,
            text = '\n\n' .. fixture:gsub('Imported operator summary.', 'Unsaved operator summary.'),
         }
         local document = lsp.document(finally, [[
local api = require('hover_fixture')
local macro (+=>)! = api.(+=>)!
return 1 +=> 2
]])
         local responses = lsp.exchange(finally, {
            {jsonrpc = '2.0', id = 1, method = 'initialize', params = {}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = imported}},
            {jsonrpc = '2.0', method = 'textDocument/didOpen', params = {textDocument = document}},
            {jsonrpc = '2.0', id = 2, method = 'textDocument/hover', params = {
               textDocument = {uri = document.uri}, position = {line = 2, character = 10},
            }},
            {jsonrpc = '2.0', id = 3, method = 'shutdown', params = {}},
            {jsonrpc = '2.0', method = 'exit', params = {}},
         })
         assert.matches('Unsaved operator summary.', text(responses[2]), 1, true)
         assert.not_matches('Imported operator summary.', text(responses[2]), 1, true)
      end)
   end)

   for _, case in ipairs({
      {'+=>', 'Sum projected entries', 'return values @H@+=> |_, value| -> value'},
      {'?>', 'Filter a table', 'return values @H@?> |_, value| -> value > 1'},
      {'||>', 'Map an array', 'return values @H@||> |value, idx| -> tostring(value + idx)'},
   }) do
      it('shows the bundled ' .. case[1] .. ' usage documentation at an operator use', function()
         local root = assert(util.tl_executable:match('^(.*)[/\\]tl$'))
         local file = assert(io.open(root .. '/extras/auxlib/tables.tl', 'rb'))
         local module = file:read('*a')
         file:close()
         local source = [[
local tables = require('auxlib.tables')
local macro (+=>)! = tables.(+=>)!
local macro (?>)! = tables.(?>)!
local macro (||>)! = tables.(||>)!
local values: {integer} = {1, 2}
]] .. case[3]
         local value = text(hover(source, {['tlconfig.lua'] = 'return {include_dir = {"extras"}}', extras = {auxlib = {['tables.tl'] = module}}}))
         assert.matches(case[2], value, 1, true)
         assert.matches('local tables = require("auxlib.tables")', value, 1, true)
         assert.matches('**Parameter `source`:**', value, 1, true)
      end)
   end

end)
