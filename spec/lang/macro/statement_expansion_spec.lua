local tl = require('tl')
local lua_generator = require('teal.gen.lua_generator')

describe('macro expansion contexts', function()
   local function rejects(code, message, line)
      local _, errors = tl.parse(code, 'macro_context.tl')
      assert.equals(1, #errors)
      assert.matches(message, errors[1].msg, 1, true)
      assert.equals('macro_context.tl', errors[1].filename)
      assert.equals(line, errors[1].y)
   end

   local function generates(code)
      local ast, errors = tl.parse(code, 'macro_context.tl')
      assert.same({}, errors)
      local out, err = lua_generator.generate(ast, '5.1')
      assert.is_nil(err)
      local chunk, load_error = (loadstring or load)(out)
      assert.is_function(chunk, load_error)
      return out
   end

   for _, expression in ipairs({'1 + 2', '42', 'value', '{}', 'obj.field', 'obj[1]', 'true and print("hi")'}) do
      it('rejects a standalone expansion to ' .. expression, function()
         rejects('local macro emit!() return `' .. expression .. '` end\nemit!()',
            "macro 'emit' returned an expression that cannot be used as a statement", 2)
      end)
   end

   it('rejects a bare expression in a statement quote', function()
      local _, errors = tl.parse('local macro emit!()\nreturn ```1 + 2```\nend\nemit!()', 'macro_context.tl')
      assert.is_true(#errors > 0)
      assert.matches('macro quote error', errors[1].msg, 1, true)
      assert.equals(2, errors[1].y)
   end)

   it('accepts expression expansions when assigned or returned', function()
      generates([[
         local macro value!() return `1 + 2` end
         local n = value!()
         return value!() + n
      ]])
   end)

   it('accepts ordinary and parenthesized call statements', function()
      for _, expression in ipairs({'print("hi")', '(print("hi"))', '((print("hi")))'}) do
         generates('local macro emit!() return `' .. expression .. '` end\nemit!()')
      end
   end)

   it('rejects expressions inserted into a statement block', function()
      rejects([[local macro emit!()
   local out = block('statements')
   table.insert(out, `1 + 2`)
   return out
end
emit!()]], 'cannot be used as a statement', 6)
   end)

   it('checks nested statement blocks manufactured by a macro', function()
      rejects([[local macro emit!()
   local out = ```do print("hi") end```
   table.insert(out[1][BLOCK_INDEXES.DO.BODY], `1 + 2`)
   return out
end
emit!()]], 'cannot be used as a statement', 6)
   end)

   it('checks nested macro expansions in statement position', function()
      rejects([[local macro value!() return `1 + 2` end
local macro emit!(value: Expression) return value end
emit!(value!())]], 'cannot be used as a statement', 3)
   end)

   it('checks statement bodies inside returned function expressions', function()
      rejects([[local macro make!()
   local out = `function() print("hi") end`
   table.insert(out[BLOCK_INDEXES.FUNCTION.BODY], `1 + 2`)
   return out
end
local fn = make!()]], 'cannot be used as a statement', 6)
   end)

   it('accepts statement sequences, including type declarations and loop control', function()
      generates([[
         local macro emit!()
            return ```
               local type Item = number
               local n: Item = 0
               while true do
                  n = n + 1
                  break
               end
               print(n)
            ```
         end
         emit!()
      ]])
   end)

   it('rejects record declarations in an assignment expression', function()
      rejects([[local macro declare!(name: Expression)
   return ```local record $name end```
end
local _ = declare! (Item);]], "macro 'declare' returned statements in an expression context", 4)
   end)

   it('accepts a record declaration in statement position', function()
      generates([[
         local macro declare!(name: Expression)
            return ```local record $name end```
         end
         declare!(Item)
         local value: Item = {}
      ]])
   end)

   it('rejects single statement blocks and direct statements in expression position', function()
      for _, statement in ipairs({'local type Item = number', 'global type Item = number', 'local n = 1'}) do
         rejects('local macro declare!() return ```' .. statement .. '``` end\nlocal x = declare!()',
            'returned statements in an expression context', 2)
         rejects('local macro declare!() local out = ```' .. statement .. '```; return out[1] end\nlocal x = declare!()',
            'returned statements in an expression context', 2)
      end
   end)

   it('accepts type aliases returned directly in statement position', function()
      generates([[
         local macro declare!()
            local out = ```local type Item = number```
            return out[1]
         end
         declare!()
         local value: Item = 1
      ]])
   end)

   it('preserves a single-expression block used in expression position', function()
      generates([[
         local macro value!()
            local out = block('statements')
            table.insert(out, `1 + 2`)
            return out
         end
         local n = value!()
      ]])
   end)
end)
