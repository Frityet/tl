--#pragma strict_nil off
local type model = require("extras.fuzz.model")
local type api_types = require("teal.api.v2")
-- One case per process: the Teal supervisor owns wall-clock/resource limits.
-- This file deliberately uses Lua 5.1 syntax so LuaJIT can test upstream too.
local type Chunk = function(): any
local globals = _G as {string:any}
local loadstring = globals['loadstring'] as function(string, ? string): Chunk, string
local setfenv = globals['setfenv'] as function(Chunk, {string:any})
local root, filename, target, expected = arg[1], arg[2], arg[3], arg[4]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local stage = 'startup'
local function quote(s: any): string
   return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c: string): string
      return string.format('\\u%04x', string.byte(c))
   end) .. '"'
end
local function emit(t: model.Object)
   local out: {string} = {}
   for k, v in pairs(t) do
      out[#out + 1] = quote(k) .. ':' .. (type(v) == 'number' and tostring(v) or quote(v))
   end
   io.write('FUZZ_RESULT ', '{', table.concat(out, ','), '}\n')
end
local function ensure(ok: boolean, message: string)
   if not ok then error('invariant: ' .. message, 0) end
end
local function diagnostics(errors: {api_types.Error}): string
   errors = errors or {} -- Results with syntax errors do not populate type_errors/warnings.
   ensure(type(errors) == 'table', 'diagnostics must be a table')
   local rows: {string} = {}
   for i, e in ipairs(errors) do
      ensure(type(e.msg) == 'string', 'diagnostic message must be a string')
      ensure(type(e.x) == 'number' and e.x >= 1 and e.x % 1 == 0,
         'diagnostic x must be a positive integer')
      ensure(type(e.y) == 'number' and e.y >= 1 and e.y % 1 == 0,
         'diagnostic y must be a positive integer')
      rows[i] = e.y .. ':' .. e.x .. ':' .. e.msg
   end
   return table.concat(rows, '\n')
end
local function main(): model.Result
   local api = require('teal.api.v2')
   local f = assert(io.open(filename, 'rb'))
   local source = f:read('*a'); f:close()
   stage = 'lex'
   local tokens, lex_errors = api.lex(source, 'fuzz.tl')
   diagnostics(lex_errors)
   local last_y, last_x = 0, 0
   for _, token in ipairs(tokens) do
      ensure(token.y > last_y or (token.y == last_y and token.x >= last_x), 'token positions must be ordered')
      last_y, last_x = token.y, token.x
   end
   stage = 'parse'
   local _, parse_errors = api.parse(source, 'fuzz.tl')
   local _, again_errors = api.parse(source, 'fuzz.tl')
   ensure(diagnostics(parse_errors) == diagnostics(again_errors), 'parse diagnostics changed on repetition')
   if expected ~= '-' then
      ensure(#lex_errors == 0 and #parse_errors == 0, 'valid generator program rejected by parser: ' .. diagnostics(parse_errors))
   end
   local function check(): api_types.Result
      local env = assert(api.new_env({defaults = {gen_target = target as api_types.GenTarget, gen_compat = 'off'}}))
      -- Run the compiler's own consistency checks, when supported by this version.
      env.opts.run_internal_compiler_checks = true
      return assert(api.check_string(source, env, 'fuzz.tl'))
   end
   stage = 'check'
   local result = check()
   local signature = diagnostics(result.syntax_errors) .. '\n' .. diagnostics(result.type_errors)
   local repeated = check()
   ensure(signature == diagnostics(repeated.syntax_errors) .. '\n' .. diagnostics(repeated.type_errors),
      'checker diagnostics changed with fresh environment')
   diagnostics(result.warnings)
   if expected ~= '-' then
      ensure(#(result.syntax_errors or {}) == 0 and #(result.type_errors or {}) == 0,
         'valid generator program rejected by checker: ' .. signature)
   end
   if #(result.syntax_errors or {}) > 0 or #(result.type_errors or {}) > 0 then
      return {status = 'ok', stage = stage, disposition = 'rejected', tokens = #tokens,
         syntax_errors = #(result.syntax_errors or {}), type_errors = #(result.type_errors or {})}
   end
   stage = 'generate'
   local generated, gen_error = api.generate(result.ast as api_types.Node, target as api_types.GenTarget)
   ensure(type(generated) == 'string', 'accepted program failed generation: ' .. tostring(gen_error))
   local generated_again = assert(api.generate(repeated.ast as api_types.Node, target as api_types.GenTarget))
   ensure(generated == generated_again, 'lowering changed on repetition')
   -- Parse generated output through the compiler as Lua even when this host cannot load the target.
   local _, lua_errors = api.parse(generated, 'fuzz.lua', 'lua')
   ensure(#lua_errors == 0, 'generated Lua rejected by parser: ' .. diagnostics(lua_errors))
   local version = tonumber((_VERSION:gsub('Lua ', '')))
   local native = target == 'luajit'
   local can_load = native and type(globals['jit']) == 'table' and loadstring('return true ? 1 : 2') ~= nil
      or not native and (target == '5.1' or version >= tonumber(target))
   if can_load then
      stage = 'load'
      local fn: Chunk
      local load_error: string
      if _VERSION == 'Lua 5.1' then
         fn, load_error = loadstring(generated, '@generated.lua')
         if fn then setfenv(fn, {type = type}) end
      else
         fn, load_error = load(generated, '@generated.lua', 't', {type = type} as {any:any})
      end
      ensure(fn ~= nil, 'generated Lua failed to load: ' .. tostring(load_error))
      -- Only the grammar generator's closed programs are executed, never corpus or mutated input.
      if expected ~= '-' then
         stage = 'execute'
         local actual = fn()
         ensure(type(actual) == 'number' and actual == tonumber(expected),
            'semantic oracle: expected ' .. expected .. ', got ' .. tostring(actual))
      end
   end
   return {status = 'ok', stage = stage, disposition = 'accepted', tokens = #tokens,
      generated_bytes = #generated, executed = expected ~= '-' and can_load and 1 or 0}
end
local ok, result = xpcall(main, debug.traceback)
if ok then
   emit(result as model.Object)
else
   emit({status = 'failure', stage = stage, message = tostring(result)})
   os.exit(1)
end
