-- Worker for compare-frontends.py. Uses separate LuaJIT processes so module
-- caches, macro sandboxes, and generated bundles cannot cross-contaminate runs.
-- The canonical form includes sparse keys, graph sharing, and Lua's # operator.
-- Only process-global type IDs and host-error stack line numbers are normalized.
local runtime, manifest = assert(arg[1]), assert(arg[2])
package.path = runtime .. '/?.lua;' .. runtime .. '/?/init.lua;' .. package.path
local json = require('dkjson')
local lexer = require('teal.lexer')
local reader = require('teal.reader')
local parser = require('teal.parser')
local ast = require('teal.ast')
local f = assert(io.open(manifest, 'rb'))
local cases = assert(json.decode(f:read('*a')))
f:close()
local function canonical(value)
   local seen, out, nextid = {}, {}, 0
   local function emit(v)
      local t = type(v)
      if t == 'table' then
         if seen[v] then out[#out+1] = '@' .. seen[v]; return end
         nextid = nextid + 1; seen[v] = nextid
         out[#out+1] = '{' .. nextid .. '#' .. #v .. ':'
         local keys = {}
         for k in pairs(v) do
            if k ~= 'typeid' or not v.typename then keys[#keys+1] = k end
         end
         table.sort(keys, function(a,b)
            local at, bt = type(a), type(b)
            if at ~= bt then return at < bt end
            if at == 'number' or at == 'string' then return a < b end
            error('non-scalar key: '..at)
         end)
         for _, k in ipairs(keys) do
            emit(k); out[#out+1] = '='; emit(v[k]); out[#out+1] = ';'
         end
         out[#out+1] = '}'
      elseif t == 'string' then out[#out+1] = string.format('%q',v)
      elseif t == 'number' then out[#out+1] = string.format('%.17g',v)
      elseif t == 'function' then out[#out+1] = '<function>'
      else out[#out+1] = tostring(v) end
   end
   emit(value)
   return table.concat(out)
end
local function capture(fn,...)
   local v = {pcall(fn,...)}
   if not v[1] then
      local runtime_pattern = runtime:gsub('(%W)', '%%%1')
      v[2] = tostring(v[2]):gsub(runtime_pattern, '<runtime>'):gsub('%.lua:%d+:', '.lua:<line>:')
   end
   return canonical(v)
end
for i, case in ipairs(cases) do
   local row = { name=case.name }
   row.lex = capture(lexer.lex, case.source, case.name)
   row.read = capture(reader.read, case.source, case.name)
   row.raw = capture(reader.read, case.source, case.name, nil, nil, true)
   row.parse = capture(parser.parse, case.source, case.name)
   local ok, blocks = pcall(reader.read, case.source, case.name)
   if ok then
      local before = canonical(blocks)
      row.ast = capture(ast.parse_blocks, blocks, case.name)
      local after = canonical(blocks)
      row.blocks_unchanged = before == after
   end
   row.program = capture(function()
      local tokens, errs = lexer.lex(case.source, case.name)
      local blocks = reader.read_program(tokens, errs, case.name)
      return blocks, errs, tokens
   end)
   print(json.encode(row))
   if i % 100 == 0 then collectgarbage('collect') end
end
