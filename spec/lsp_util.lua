local util = require('spec.util')
local json = require('dkjson')
local assert = require('luassert')

local lsp = {}

function lsp.document(finally, source)
   local path = util.write_tmp_file(finally, source)
   local normalized = path:gsub('\\', '/')
   if normalized:sub(1, 1) ~= '/' then normalized = '/' .. normalized end
   local uri = 'file://' .. normalized:gsub('[^%w%-%._~/:]', function(c)
      return string.format('%%%02X', c:byte())
   end)
   return {uri = uri, languageId = 'teal', version = 1, text = source}
end

function lsp.exchange(finally, messages)
   local framed = {}
   for _, message in ipairs(messages) do
      local body = assert(json.encode(message))
      framed[#framed + 1] = 'Content-Length: ' .. #body .. '\r\n\r\n' .. body
   end
   local input = util.write_tmp_file(finally, table.concat(framed), 'jsonrpc')
   local process = io.popen(util.tl_cmd('lsp', '--stdio') .. '< ' .. string.format('%q', input) .. ' 2>&1', 'r')
   local output = process:read('*a')
   util.assert_popen_close(0, process:close())
   local responses, notifications = {}, {}
   local position = 1
   while position <= #output do
      local start, _, length, body_start = output:find('Content%-Length: (%d+)\r\n\r\n()', position)
      assert.equals(position, start, output)
      local body = output:sub(body_start, body_start + tonumber(length) - 1)
      position = body_start + tonumber(length)
      local message, _, err = json.decode(body)
      assert.is_nil(err, body)
      assert.is_nil(message.error, body)
      if message.id then responses[message.id] = message.result
      else notifications[#notifications + 1] = message end
   end
   return responses, notifications
end

return lsp
