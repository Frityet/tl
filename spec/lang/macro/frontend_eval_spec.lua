local parser = require('teal.parser')
local reader = require('teal.reader')
local macro_eval = require('teal.macro_eval')
local generator = require('teal.gen.lua_generator')
local block = require('teal.block')
local util = require('spec.util')

local function generate(source, filename)
   local tree, errors = parser.parse(source, filename)
   assert.same({}, errors)
   local output, err = generator.generate(tree, '5.1', generator.fast_opts)
   assert.is_nil(err)
   return output:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

describe('macro frontend evaluation', function()
   it('recreates sandbox state when a compiled declaration is reused', function()
      local source = [[
         local macro counter!()
            counter_value = (counter_value or 0) + 1
            return parse_expression(tostring(counter_value))
         end
         local first = counter!()
         local second = counter!()
      ]]
      for _ = 1, 4 do
         assert.same('local first = 1 local second = 2', generate(source, 'cache-sandbox.tl'))
      end
   end)

   it('recompiles edits at the same declaration location', function()
      local source = 'local macro value!() return `VALUE` end\nlocal result = value!()'
      assert.same('local result = 1', generate(source:gsub('VALUE', '1'), 'cache-edit.tl'))
      assert.same('local result = 2', generate(source:gsub('VALUE', '2'), 'cache-edit.tl'))
      assert.same('local result = 1', generate(source:gsub('VALUE', '1'), 'cache-edit.tl'))
   end)

   it('keeps declaration snapshots independent of mutable input blocks', function()
      local source = 'local macro value!() return `11` end\nlocal result = value!()'
      local program, errors = reader.read(source, 'cache-snapshot.tl', 'tl', true, true)
      assert.same({}, errors)
      local declaration = program[1]
      macro_eval.compile_all_and_expand(program, 'cache-snapshot.tl', 'tl', errors)
      assert.same({}, errors)
      local function mutate(b)
         if b.kind == 'integer' and b.tk == '11' then b.tk = '22' end
         for i = 1, block.child_limit(b) do
            if b[i] then mutate(b[i]) end
         end
      end
      mutate(declaration)
      assert.same('local result = 11', generate(source, 'cache-snapshot.tl'))
   end)

   it('binds reused macro code to the current expression parser', function()
      local source = [[
         local macro expression!()
            return parse_expression('ignored')
         end
         local result = expression!()
      ]]
      for i = 1, 3 do
         local program, errors = reader.read(source, 'cache-parser.tl', 'tl', true, true)
         assert.same({}, errors)
         macro_eval.compile_all_and_expand(program, 'cache-parser.tl', 'tl', errors, function()
            return { kind = 'integer', tk = tostring(i), y = 1, x = 1, yend = 1, xend = 1 }
         end)
         assert.same({}, errors)
         local expressions = program[1][block.BLOCK_INDEXES.LOCAL_DECLARATION.EXPS]
         assert.same(tostring(i), expressions[1].tk)
      end
   end)

   it('preserves statement order across expanding and empty macros', function()
      local source = [[
         local macro twice!(statement: Statement)
            return ```
                  $statement
                  $statement
               ```
         end
         local macro empty!()
            return block('statements')
         end
         print(0)
         empty!()
         twice!(print(1))
         empty!()
         twice!(print(2))
         print(3)
      ]]
      local output = generate(source, 'linear-expansion.tl'):gsub(';', '')
      assert.same('print(0) print(1) print(1) print(2) print(2) print(3)', output)
   end)

   it('retains only imports that still have runtime references', function()
      util.mock_io(finally, {
         ['front_a.tl'] = [[
            local record M end
            macro M.twice!(statement: Statement)
               return ```
                  $statement
                  $statement
               ```
            end
            return M
         ]],
         ['front_b.tl'] = [[
            local record M
               runtime: integer
            end
            macro M.twice!(statement: Statement)
               return ```
                  $statement
                  $statement
               ```
            end
            return M
         ]],
      })
      local output = generate([[
         local a = require('front_a')
         local b = require('front_b')
         a.twice!(print(1))
         b.twice!(print(2))
         print(b.runtime)
      ]], 'linear-imports.tl')
      assert.is_nil(output:find("require('front_a')", 1, true))
      assert.is_truthy(output:find("require('front_b')", 1, true))
      assert.is_truthy(output:find('print(b.runtime)', 1, true))
      local cascaded = generate([[
         local a = require('front_a')
         local b: a.SomeType = require('front_b')
         a.twice!(print(1))
         b.twice!(print(2))
      ]], 'linear-import-cascade.tl')
      assert.is_nil(cascaded:find('require', 1, true))
   end)

   it('checks sparse quoted children when reusing compiled declarations', function()
      local source = 'local macro value!() return `1` end\nlocal result = value!()'
      for value = 2, 3 do
         local program, errors = reader.read(source, 'cache-sparse.tl', 'tl', true, true)
         assert.same({}, errors)
         local function add_sparse_child(b)
            if b.kind == 'macro_quote' then
               b[block.BLOCK_INDEXES.MACRO_QUOTE.BLOCK][64] = {
                  kind = 'integer', tk = tostring(value), y = 1, x = 1,
               }
               return
            end
            for i = 1, block.child_limit(b) do
               if b[i] then add_sparse_child(b[i]) end
            end
         end
         add_sparse_child(program[1])
         macro_eval.compile_all_and_expand(program, 'cache-sparse.tl', 'tl', errors)
         assert.same({}, errors)
         local expressions = program[1][block.BLOCK_INDEXES.LOCAL_DECLARATION.EXPS]
         assert.same(tostring(value), expressions[1][64].tk)
      end
   end)

   it('reports an oversized macro argument list without escaping the compiler', function()
      local source = 'local macro many!(...: Expression) return `1` end\nlocal result = many!()'
      local program, errors = reader.read(source, 'large-macro-args.tl', 'tl', true, true)
      assert.same({}, errors)
      local invocation = program[2][block.BLOCK_INDEXES.LOCAL_DECLARATION.EXPS][1]
      local args = invocation[block.BLOCK_INDEXES.MACRO_INVOCATION.ARGS]
      local value = { kind = 'integer', tk = '1', y = 1, x = 1 }
      for i = 1, 100000 do args[i] = value end
      local ok, err = pcall(macro_eval.compile_all_and_expand, program, 'large-macro-args.tl', 'tl', errors)
      assert.is_true(ok, tostring(err))
      assert.is_true(#errors > 0)
      assert.same('large-macro-args.tl', errors[1].filename)
   end)

   it('keeps independent cloned arguments across repeated invocations', function()
      local source = [[
         local macro plus!(value: Expression)
            local result = `$value + 1`
            result[BLOCK_INDEXES.OP.E1].tk = '7'
            return result
         end
         local first = plus!(2)
         local second = plus!(3)
      ]]
      for _ = 1, 2 do
         assert.same('local first = 7 + 1 local second = 7 + 1', generate(source, 'cache-clones.tl'))
      end
   end)
end)
