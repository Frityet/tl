local reader = require('teal.reader')
local ast = require('teal.ast')
local block = require('teal.block')
local macro_eval = require('teal.macro_eval')
local generator = require('teal.gen.lua_generator')
local B = block.BLOCK_INDEXES

local function read_macro(source)
   local tree, errors = reader.read(source, 'compact-quote.tl', 'tl', false, true)
   assert.same({}, errors)
   return tree
end

local function compile(tree, compact)
   local lower = compact and ast.parse_macro or ast.parse_blocks
   local nodes, errors = lower(tree, 'compact-quote.tl', 'tl')
   assert.same({}, errors)
   local code = generator.generate(nodes, '5.1', generator.fast_opts)
   local env = macro_eval.new_env({})
   local chunk = assert(loadstring(code .. '\nreturn quoted'))
   setfenv(chunk, env.sandbox)
   return chunk(), nodes
end

describe('compact macro quote compilation', function()
   it('produces the same blocks and fresh splices as public AST lowering', function()
      local tree = read_macro([=[
         local macro quoted!(x: Expression)
            return ```
               local f = |v|: integer -> ($x) + v
               if true then print($x, f(3)) end
            ```
         end
      ]=])
      local ordinary = compile(tree, false)
      local compact = compile(tree, true)
      local input = { kind = 'integer', tk = '7', f = 'argument.tl', y = 8, x = 9, yend = 8, xend = 9 }
      local expected = ordinary(input)
      local actual = compact(input)
      assert.same(expected, actual)
      assert.same(actual, compact(input))
      assert.is_not.equal(actual, compact(input))
   end)

   it('preserves sparse numeric children and arbitrary string bytes', function()
      local tree = read_macro('local macro quoted!() return `1` end')
      local quote = tree[1][B.LOCAL_MACRO.BODY][1][B.RETURN.EXPS][1]
      local child = {
         kind = 'string', tk = 'quote" slash\\ newline\n carriage\r nul\0 digits123',
         y = 4, x = 2, yend = 9, xend = 7,
      }
      quote[B.MACRO_QUOTE.BLOCK] = {
         kind = 'literal_table', tk = '', y = 2, x = 3, yend = 10, xend = 4,
         [2] = child, [64] = { kind = 'nil', tk = 'nil', y = 11, x = 1 },
      }
      local ordinary = compile(tree, false)
      local compact = compile(tree, true)
      local expected, actual = ordinary(), compact()
      assert.same(expected, actual)
      assert.equals(child.tk, actual[2].tk)
      assert.is_nil(actual[1])
      assert.equals('nil', actual[64].kind)
   end)

   it('reports illegal quoted macro calls through the same diagnostic path', function()
      local tree = read_macro('local macro quoted!() return `1` end')
      local quote = tree[1][B.LOCAL_MACRO.BODY][1][B.RETURN.EXPS][1]
      quote[B.MACRO_QUOTE.BLOCK] = { kind = 'macro_invocation', tk = 'bad!', y = 12, x = 5 }
      local _, expected = ast.parse_blocks(tree, 'compact-quote.tl', 'tl')
      local _, actual = ast.parse_macro(tree, 'compact-quote.tl', 'tl')
      assert.same(expected, actual)
      assert.equals('macro invocations cannot appear inside macro quotes', actual[1].msg)
   end)
end)
