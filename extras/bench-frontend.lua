-- Reproducible frontend benchmark. Run from the source tree, for example:
--   luajit extras/bench-frontend.lua parse compiler . 5 7 3
--   TL_FRONTEND_RUNTIME=/path/to/other/build luajit extras/bench-frontend.lua parse compiler . 5 7 3
-- Arguments: stage, corpus, source root, rounds/sample, samples, warmup rounds.
-- Stages: lex, read (lex + blocks + macros), ast (prebuilt blocks), parse (all),
-- check (frontend + type checker), gen (frontend + type checker + generator).
-- Corpora: compiler, applications, macros, macro-definitions, macro-uncached,
-- macro-statements, or a path list.
-- Use the same source root for before/after comparisons. Initial frontend module
-- loads and primary source reads are outside the timer; demand-loaded imports
-- stay inside it. GC is enabled during samples. A fresh process with one round,
-- one sample, and zero warmups measures a cold frontend invocation.
local stage = arg[1] or "parse"
local corpus_name = arg[2] or "compiler"
local source_root = arg[3] or "."
local rounds = tonumber(arg[4]) or 5
local samples = tonumber(arg[5]) or 7
local warmups = tonumber(arg[6]) or 3
assert(stage == "lex" or stage == "read" or stage == "ast" or stage == "parse" or stage == "check" or stage == "gen", "unknown stage")
assert(rounds >= 1 and rounds % 1 == 0, "rounds must be a positive integer")
assert(samples >= 1 and samples % 1 == 0, "samples must be a positive integer")
assert(warmups >= 0 and warmups % 1 == 0, "warmups must be a nonnegative integer")

local runtime = os.getenv("TL_FRONTEND_RUNTIME") or "."
package.path = runtime .. "/?.lua;" .. runtime .. "/?/init.lua;" .. package.path
local lexer = require("teal.lexer")
local reader = require("teal.reader")
local ast = require("teal.ast")
local parser = require("teal.parser")
local teal = (stage == "check" or stage == "gen") and require("teal.init")

local sources = {}
local total_bytes = 0
local function add_source(name, source)
   sources[#sources + 1] = { name = name, source = source }
   total_bytes = total_bytes + #source
end

local function add_file(path)
   local file = assert(io.open(source_root .. "/" .. path, "rb"))
   local source = assert(file:read("*a"))
   file:close()
   add_source(path, source)
end

if corpus_name == "compiler" then
   for _, path in ipairs({
      "teal/lexer.tl", "teal/reader.tl", "teal/ast.tl", "teal/parser.tl",
      "teal/macro_eval.tl", "teal/types.tl", "teal/input.tl", "teal/environment.tl",
      "teal/check/type_checker.tl", "teal/check/node_checker.tl",
      "teal/gen/lua_generator.tl", "teal/check/relations.tl",
   }) do
      add_file(path)
   end
elseif corpus_name == "applications" then
   -- Uses the checked-in applications and their dependencies. Set TL_PATH to
   -- include source_root/extras/?.tl and source_root/?.tl when comparing builds.
   add_file("example/showcase.tl")
   add_file("example/triage/main.tl")
elseif corpus_name == "macros" then
   local source = {
      "local macro twice!(x: Expression) return `($x) + ($x)` end",
      "local macro keep!(x: Statement | Expression) return x end",
      "local macro decorate!(x: Statement) return x end",
   }
   for i = 1, 256 do
      source[#source + 1] = ("local function f%d<decorate!><T>(x: T): T return x end"):format(i)
      source[#source + 1] = ("local v%d = keep!(twice!(f%d(%d)))"):format(i, i, i)
   end
   add_source("bench_macros.tl", table.concat(source, "\n"))
elseif corpus_name == "macro-definitions" or corpus_name == "macro-uncached" then
   -- The 512-definition corpus measures repeated declarations that fit in the
   -- compilation cache. The 2048-definition corpus exceeds its 1024-entry limit,
   -- so a sequential pass must compile every body, including after warmup.
   local source = {}
   local definitions = corpus_name == "macro-uncached" and 2048 or 512
   for i = 1, definitions do
      source[#source + 1] = ("local macro m%d!(x: Expression) return `($x) + %d` end\nlocal x%d = m%d!(%d)"):format(i, i, i, i, i)
   end
   add_source("bench_macro_definitions.tl", table.concat(source, "\n"))
elseif corpus_name == "macro-statements" then
   local source = { [=[
local macro emit!(x: Expression): Statement
   return ``` print($x); print($x); print($x); print($x)
              print($x); print($x); print($x); print($x) ```
end
]=] }
   for i = 1, 512 do
      source[#source + 1] = ("emit!(%d)"):format(i)
   end
   add_source("bench_macro_statements.tl", table.concat(source, "\n"))
else
   for path in io.lines(corpus_name) do
      if path ~= "" then add_file(path) end
   end
end

local function no_errors(errs)
   if errs and errs[1] then
      local e = errs[1]
      error(("%s:%s:%s: %s"):format(e.filename or "?", e.y or "?", e.x or "?", e.msg or "?"), 0)
   end
end

if stage == "ast" then
   for _, source in ipairs(sources) do
      local errs
      source.blocks, errs = reader.read(source.source, source.name)
      no_errors(errs)
   end
end

local function run_round()
   local count = 0
   local compiler = teal and teal.compiler({ gen_target = "5.1", gen_compat = "optional" })
   for i = 1, #sources do
      local source = sources[i]
      local result, errs
      if compiler then
         result, errs = compiler:recall(source.name)
         if not result then
            local input = assert(compiler:input(source.source, source.name))
            result, errs = input:check(source.name:gsub("%.tl$", ""):gsub("/", "."))
         end
         no_errors(errs.syntax_errors)
         no_errors(errs.type_errors)
         if stage == "gen" then
            count = count + #assert(result:gen())
         else
            count = count + 1 + #errs.warnings
         end
      elseif stage == "lex" then
         result, errs = lexer.lex(source.source, source.name)
      elseif stage == "read" then
         result, errs = reader.read(source.source, source.name)
      elseif stage == "ast" then
         result, errs = ast.parse_blocks(source.blocks, source.name)
      else
         result, errs = parser.parse(source.source, source.name)
      end
      if not compiler then
         no_errors(errs)
         count = count + #result
      end
   end
   return count
end

collectgarbage("restart")
for _ = 1, warmups do run_round() end
local times, count = {}, 0
for sample = 1, samples do
   -- Prevent results from earlier samples influencing the starting heap, while
   -- charging allocations and normal collection during each measured sample.
   collectgarbage("collect")
   local start = os.clock()
   for _ = 1, rounds do count = count + run_round() end
   times[sample] = os.clock() - start
end
local ordered = {}
for i = 1, #times do ordered[i] = times[i] end
table.sort(ordered)
local median = ordered[math.floor((#ordered + 1) / 2)]
if #ordered % 2 == 0 then median = (median + ordered[#ordered / 2 + 1]) / 2 end
local result = {
   stage = stage, corpus = corpus_name, runtime = runtime,
   files = #sources, bytes = total_bytes, rounds = rounds,
   warmups = warmups, samples = times, median_seconds = median,
   milliseconds_per_round = median * 1000 / rounds,
   mebibytes_per_second = total_bytes * rounds / median / 1048576,
   checksum = count,
}
local json = require("dkjson")
print(json.encode(result))
