local tl = require('teal.api.v2')
local prefix = [[local format = require('auxlib.format')
local macro f! = format.f!
]]
local function compile(source)
   local ast, errors = tl.parse(prefix .. source, 'format-fixture.tl')
   return ast, errors
end
local function run(source)
   local ast, errors = compile(source)
   assert.same({}, errors)
   local checked = tl.check(ast, 'format-fixture.tl', {gen_target = '5.1', gen_compat = 'off', feat_strict_nil = 'on'})
   assert.same({}, checked.type_errors)
   local output, err = tl.generate(checked.ast, '5.1')
   assert.is_nil(err)
   assert.not_matches('auxlib.format', output, 1, true)
   return assert(loadstring(output), output)()
end
local function rejects(source, message)
   local _, errors = compile(source)
   assert.is_true(#errors > 0, source)
   assert.matches(message, errors[1].msg, 1, true)
end

describe('auxlib format interpolation', function()
   it('interpolates local variables with the short string-call spelling', function()
      assert.equals('Hello Ada', run([[local name = 'Ada'; return f!"Hello {name}"]]))
      assert.equals('Hello Ada', run([[local name = 'Ada'; return format.f!('Hello {name}')]]))
   end)

   for _, case in ipairs({
      {[[return f!""]], ''},
      {[[return f!"Hello"]], 'Hello'},
      {[[return f!"{{}} {{value}}"]], '{} {value}'},
      {[[local name = 'Ada'; return f!"{{{name}}}"]], '{Ada}'},
      {[[return f!"100% {true} {false} {nil}"]], '100% true false nil'},
      {[=[return f!'quote " and \' slash \\ line\n\t\065\x42\u{1F600}']=], 'quote " and \' slash \\ line\n\tAB😀'},
      {[=[return f!"line\z   skipped"]=], 'lineskipped'},
      {[====[local name = 'Ada'; return f![=[
Hello {name}
raw\n]=]]====], 'Hello Ada\nraw\\n'},
      {[=[local row = {name = 'Ada'}; return f!"{row[\"name\"]}"]=], 'Ada'},
      {[====[return f![[{({value = "}"}).value}]]]====], '}'},
      {[====[return f![[{(function(): string return [=[}]=] end)()}]]]====], '}'},
      {[====[return f![[{(1 -- comment with }
+ 2)}]]]====], '3'},
      {[[local pi = 3.14159; return f!"{pi:.2f}"]], '3.14'},
      {[[return f!"{42:04d} {255:08x}"]], '0042 000000ff'},
      {[[return f!"{3:+6.2f}"]], ' +3.00'},
      {[[local word = 'cat'; return f!"[{word:6s}][{word:-6s}][{word:.2s}]"]], '[   cat][cat   ][ca]'},
      {[[return f!"{255:#x} {8:o} {65:c}"]], '0xff 10 A'},
      {[[return f!"{12.5:%.1f}"]], '12.5'},
      {[[return f!"{12.5:}"]], '12.5'},
      {[[return f!"100% {{{3:.2f}}} {false} {nil}"]], '100% {3.00} false nil'},
   }) do
      it('handles ' .. case[1]:gsub('\n', '\\n'), function()
         assert.equals(case[2], run(case[1]))
      end)
   end

   it('supports method calls and a format separator after the call', function()
      assert.equals('3.00', run([[
local record Counter end
function Counter:read(): integer return 3 end
return f!"{Counter:read():.2f}"
]]))
   end)

   it('supports arithmetic and function calls without executing them at compile time', function()
      assert.same({'3:1', 1}, {run([[
local calls = 0
local function increment(): integer calls = calls + 1; return calls end
local value = f!"{1 + 2}:{increment()}"
return value, calls
]])})
   end)

   it('evaluates fields and tostring methods once in left-to-right order', function()
      assert.same({'1:2:3', '123'}, {run([[
local order = ""
local function next_value(value: integer): integer
   order = order .. tostring(value)
   return value
end
local text = f!"{next_value(1)}:{next_value(2):d}:{next_value(3)}"
return text, order
]])})
   end)

   it('keeps temporary names from shadowing caller variables', function()
      assert.equals('7:8', run([[local __auxlib_format_1 = 7; local __auxlib_format_2 = 8; return f!"{__auxlib_format_1}:{__auxlib_format_2}"]]))
   end)

   it('supports scientific, general and quoted conversions', function()
      assert.equals(string.format('%e %g %q', 12.5, 12.5, 'a"b'), run([=[return f![[{12.5:e} {12.5:g} {'a"b':q}]]]=]))
   end)

   it('converts tostring metamethods once from left to right', function()
      local factory = run([[
return function(first: any, second: any): string return f!"{first}:{second}" end
]])
      local order = ''
      local function item(value)
         return setmetatable({}, {__tostring = function() order = order .. value; return value end})
      end
      assert.equals('a:b', factory(item('a'), item('b')))
      assert.equals('ab', order)
   end)

   it('takes only the first return value of a field expression', function()
      assert.equals('07', run([[
local function values(): (integer, integer) return 7, 9 end
return f!"{values():02d}"
]]))
   end)

   it('preserves strict-nil checks for formatted numeric fields', function()
      local source = [[return function(value: number | nil): string
return f!"{value:.2f}"
end]]
      local ast, errors = compile(source)
      assert.same({}, errors)
      local checked = tl.check(ast, 'format-fixture.tl', {feat_strict_nil = 'on'})
      assert.is_true(#checked.type_errors > 0)
      local guarded = run([[return function(value: number | nil): string
if value ~= nil then return f!"{value:.2f}" end
return "missing"
end]])
      assert.equals('1.25', guarded(1.25))
      assert.equals('missing', guarded(nil))
   end)

   it('rejects numeric formatting of a boolean during type checking', function()
      local ast, errors = compile([[local value = false; return f!"{value:d}"]])
      assert.same({}, errors)
      local checked = tl.check(ast, 'format-fixture.tl', {feat_strict_nil = 'on'})
      assert.is_true(#checked.type_errors > 0)
   end)

   it('type-checks field expressions in the caller scope', function()
      local ast, errors = compile([[return f!"{missing_name}"]])
      assert.same({}, errors)
      local checked = tl.check(ast, 'format-fixture.tl', {feat_strict_nil = 'on'})
      assert.is_true(#checked.type_errors > 0)
      assert.matches('missing_name', checked.type_errors[1].msg, 1, true)
   end)

   for _, case in ipairs({
      {[[local template = 'hello'; return f!(template)]], 'expected a literal string'},
      {[[return f!"{}"]], 'empty interpolation field'},
      {[[return f!"{x"]], "unmatched '{'"},
      {[[return f!"x}"]], "unmatched '}'"},
      {[[return f!"{(1]} q"]], 'mismatched delimiter'},
      {[[return f!"{1:z}"]], 'invalid format specifier'},
      {[[return f!"{1:*d}"]], 'invalid format specifier'},
      {[[return f!"{1:100d}"]], 'width and precision'},
      {[[return f!"{1:.100f}"]], 'width and precision'},
      {[[return f!"{1, 2}"]], 'single expression'},
      {[[return f!"{1; error('not executed')}"]], 'invalid expression'},
      {[[return f!"{1 +}"]], 'invalid expression'},
      {[====[return f![[{'unterminated}]] ]====], 'unterminated string'},
   }) do
      it('rejects ' .. case[1], function() rejects(case[1], case[2]) end)
   end
end)
