-- Run with the target LuaJIT executable; this measures generated code, not parsing.
-- Store outputs in a persistent ring so JIT allocation sinking cannot discard them.
local rounds = tonumber(arg[1]) or 7
local iterations = tonumber(arg[2]) or 200000
assert(rounds >= 1 and rounds % 1 == 0, 'rounds must be a positive integer')
assert(iterations >= 256 and iterations % 1 == 0, 'iterations must be an integer of at least 256')
local cases = {
   {name = 'name', values = {'Ada'}, alternate = 'Grace', parts = {'Hello ', '!'}},
   {name = 'mixed-4', values = {'Ada', 42, false, nil}, alternate = 'Grace', parts = {'Hi ', ': ', ' ', ' ', '!'}},
   {name = 'numeric-2', values = {12.345, 42}, alternate = 98.765, specs = {'.2f', '04d'}, parts = {'Price ', ', count ', '.'}},
   {name = 'formatted-4', values = {'Ada', 12.345, 255, true}, alternate = 'Grace', specs = {false, '.2f', '08x'}, parts = {'User ', ', price ', ', hex ', ', active ', '.'}},
}
for _, count in ipairs({8, 32}) do
   for _, formatted in ipairs({false, true}) do
      local case = {name = (formatted and 'formatted-' or 'plain-') .. count, values = {}, alternate = 29, parts = {}, specs = {}}
      for i = 1, count do
         case.values[i] = i + 0.125
         case.parts[i] = '[' .. i .. '='
         case.specs[i] = formatted and '.2f' or false
      end
      case.parts[count + 1] = ']'
      cases[#cases + 1] = case
   end
end
local function quote(value) return string.format('%q', value) end
local function compile(case, strategy)
   local n = #case.parts - 1
   local parameters, strings, arguments, segments = {}, {}, {}, {}
   local pattern = ''
   for i = 1, n do
      local name = 'v' .. i
      parameters[i] = name
      local spec = case.specs and case.specs[i]
      local string_value = spec and ('string.format(' .. quote('%' .. spec) .. ', ' .. name .. ')') or ('tostring(' .. name .. ')')
      strings[i] = string_value
      arguments[i] = spec and name or ('tostring(' .. name .. ')')
      segments[#segments + 1] = quote(case.parts[i])
      segments[#segments + 1] = string_value
      pattern = pattern .. case.parts[i]:gsub('%%', '%%%%') .. '%' .. (spec or 's')
   end
   segments[#segments + 1] = quote(case.parts[n + 1])
   pattern = pattern .. case.parts[n + 1]:gsub('%%', '%%%%')
   local expression
   if strategy == 'concat' then expression = table.concat(segments, ' .. ')
   elseif strategy == 'format' then expression = 'string.format(' .. quote(pattern) .. ', ' .. table.concat(arguments, ', ') .. ')'
   else expression = 'table.concat({' .. table.concat(segments, ', ') .. '})' end
   local fn
   if strategy == 'f!' then
      local tl = require('tl')
      local template, typed = '', {}
      for i = 1, n do
         local value = case.values[i]
         local typename = type(value)
         if typename == 'number' and value == math.floor(value) then typename = 'integer' end
         typed[i] = parameters[i] .. ': ' .. typename
         template = template .. case.parts[i] .. '{' .. parameters[i] .. ((case.specs and case.specs[i]) and (':' .. case.specs[i]) or '') .. '}'
      end
      template = template .. case.parts[n + 1]
      local source = "local formatter = require('auxlib.format')\nlocal macro f! = formatter.f!\nreturn function(" .. table.concat(typed, ', ') .. '): string return f!' .. quote(template) .. ' end'
      local ast, errors = tl.parse(source, 'format-bench.tl')
      assert(#errors == 0, errors[1] and errors[1].msg)
      local checked = tl.check(ast, 'format-bench.tl', {gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on'})
      assert(#checked.type_errors == 0, checked.type_errors[1] and checked.type_errors[1].msg)
      fn = assert(loadstring(tl.generate(checked.ast, '5.1')))()
   else
      fn = assert(loadstring('return function(' .. table.concat(parameters, ', ') .. ') return ' .. expression .. ' end'))()
   end
   local actual = fn(unpack(case.values, 1, n))
   local runner_arguments = {}
   for i = 1, n do
      runner_arguments[i] = i == 1 and (type(case.values[1]) == 'number' and '(values[1] + i % 101)' or '(i % 2 == 0 and values[1] or alternate)') or ('values[' .. i .. ']')
   end
   local runner = assert(loadstring('return function(fn, values, alternate, n, sink) local checksum = 0 for i = 1, n do local result = fn(' .. table.concat(runner_arguments, ', ') .. ') sink[(i % 64) + 1] = result checksum = checksum + #result end return checksum end'))()
   return fn, runner, actual
end
local names = {'concat', 'format', 'table.concat', 'f!'}
print('runtime=' .. (jit and jit.version or _VERSION) .. ' jit=' .. tostring(jit and jit.status()) .. ' rounds=' .. rounds .. ' iterations=' .. iterations)
print('case\tconcat ns/op\tformat ns/op\ttable.concat ns/op\tf! ns/op\twinner of three')
for _, case in ipairs(cases) do
   local candidates, results = {}, {}
   for _, name in ipairs(names) do
      local fn, runner, output = compile(case, name)
      candidates[name] = {fn = fn, runner = runner, sink = {}}
      results[name] = {}
      if candidates.output then assert(output == candidates.output, case.name .. ': outputs differ') else candidates.output = output end
   end
   if jit then jit.flush() end
   for _, name in ipairs(names) do
      local candidate = candidates[name]
      candidate.runner(candidate.fn, case.values, case.alternate, 20000, candidate.sink)
   end
   local n = (#case.parts > 16) and math.floor(iterations / 4) or iterations
   for round = 1, rounds do
      for offset = 1, #names do
         local name = names[(round + offset - 2) % #names + 1]
         local candidate = candidates[name]
         collectgarbage('collect')
         local start = os.clock()
         local checksum = candidate.runner(candidate.fn, case.values, case.alternate, n, candidate.sink)
         local elapsed = os.clock() - start
         assert(checksum > 0 and type(candidate.sink[1]) == "string")
         results[name][#results[name] + 1] = elapsed / n * 1e9
      end
   end
   local best, row = nil, {case.name}
   for _, name in ipairs(names) do
      table.sort(results[name])
      local median = results[name][math.floor(#results[name] / 2) + 1]
      results[name].median = median
      row[#row + 1] = string.format('%.1f', median)
      if name ~= 'f!' and (not best or median < results[best].median) then best = name end
   end
   row[#row + 1] = best
   print(table.concat(row, '\t'))
end
