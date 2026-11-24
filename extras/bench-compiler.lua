local stage = arg[1]
assert(stage == "lex" or stage == "parse" or stage == "check" or stage == "gen",
   "use lex, parse, check, or gen as the first argument")
local rounds = assert(tonumber(arg[2]), "specify the number of rounds")
assert(rounds >= 1 and rounds % 1 == 0, "use a positive integer for the number of rounds")
local list = assert(arg[3], "specify a file with one source path per line")
local runtime = arg[4] or "."
package.path = runtime .. "/?.lua;" .. runtime .. "/?/init.lua;" .. package.path

local teal = require("teal.init")
local lexer = require("teal.lexer")
local parser = require("teal.parser")

local sources = {}
for path in io.lines(list) do
   local file = assert(io.open(path, "rb"))
   local text = assert(file:read("*a"))
   file:close()
   sources[#sources + 1] = { path = path, text = text }
end

local function require_no_errors(errs)
   if errs and errs[1] then
      local err = errs[1]
      error(("%s:%d:%d: %s"):format(err.filename, err.y, err.x, err.msg), 0)
   end
end

local function run_round()
   local compiler = teal.compiler({ gen_target = "5.1", gen_compat = "optional" })
   local count = 0
   for _, source in ipairs(sources) do
      if stage == "lex" then
         local tokens, errs = lexer.lex(source.text, source.path)
         require_no_errors(errs)
         count = count + #tokens
      elseif stage == "parse" then
         local ast, errs = parser.parse(source.text, source.path)
         require_no_errors(errs)
         count = count + #ast
      else
         local module, errs = compiler:recall(source.path)
         if not module then
            local input = assert(compiler:input(source.text, source.path))
            local name = source.path:gsub("%.tl$", ""):gsub("/", ".")
            module, errs = input:check(name)
         end
         require_no_errors(errs.syntax_errors)
         require_no_errors(errs.type_errors)
         count = count + #errs.warnings
         if stage == "gen" then
            count = count + #assert(module:gen())
         end
      end
   end
   return count
end

local start = os.clock()
local count = 0
for _ = 1, rounds do
   count = count + run_round()
end
print(("%s %d files x %d %.6f s %d"):format(stage, #sources, rounds, os.clock() - start, count))
