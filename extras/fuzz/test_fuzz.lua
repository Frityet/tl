

local script_source = debug.getinfo(1, "S").source:sub(2)
local here = script_source:match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../?.lua;" .. here .. "/../../?/init.lua;" .. package.path
local generator = require("extras.fuzz.generator")
local runner = require("extras.fuzz.runner")
local system = require("extras.fuzz.system")
local json = require("extras.fuzz.json")
local sha256 = require("extras.fuzz.hash")

local globals = _G
local loadstring = globals.loadstring, string
local root = system.absolute(here .. "/../..")
here = system.absolute(here)
local supervisor = assert(system.executable(arg[-1] or "luajit"))
local lua = system.executable("lua") or supervisor
local base = system.tempdir()
local files = {}
local dirs = { base }
local function mkdir(path)
   system.mkdir(path); dirs[#dirs + 1] = path
end
local function write(path, data)
   system.write(path, data); files[#files + 1] = path
end
local function config(target, interpreter, compiler, timeout)
   return { root = compiler or root, here = here, lua = interpreter or lua, target = target or "5.1", timeout = timeout or 3, memory_mb = 0 }
end
local function case(source, expected)
   return { source = source, expected = expected, profile = expected ~= nil and "grammar" or "corpus", seed = 7, index = 9 }
end
local function equal(a, b)
   assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function okay(result)
   assert(result.status == "ok", json.encode(result))
end
local function fixture(name, body)
   local dir = base .. "/" .. name
   mkdir(dir); mkdir(dir .. "/teal"); mkdir(dir .. "/teal/api")
   write(dir .. "/teal/api/v2.lua", body)
   return dir
end
local fixture_prefix = [[
local api={}
function api.lex() return {},{} end
function api.parse() return {},{} end
function api.new_env() return {opts={}} end
]]
local function cli(argv, name)
   local dir = base .. "/" .. name; mkdir(dir)
   local args = { supervisor, here .. "/fuzz.lua" }
   for _, value in ipairs(argv) do args[#args + 1] = value end
   local p = system.spawn(args, root, dir .. "/stdout", dir .. "/stderr", 5, 0)
   while not system.poll(p) do system.pause(5) end
   files[#files + 1] = dir .. "/stdout"; files[#files + 1] = dir .. "/stderr"
   return p.status, system.read(dir .. "/stdout") or ""
end




local tests = {}
local function test(name, run)
   tests[#tests + 1] = { name = name, run = run }
end

test("deterministic independently addressed profiles and seeds", function()
   local profiles = {}
   for i = 63, 0, -1 do
      local a = generator.case_for(42, i, { "return 1" })
      local b = generator.case_for(42, i, { "return 1" })
      equal(a.source, b.source); equal(a.expected, b.expected); profiles[a.profile] = true
   end
   local n = 0; for _ in pairs(profiles) do n = n + 1 end; equal(n, 8)
   assert(generator.case_for(42, 0, {}).source ~= generator.case_for(43, 0, {}).source)
end)
test("independent arithmetic oracle", function()
   for seed = 0, 99 do
      local expr, expected = generator.expression(generator.rng(seed, 0), 3)
      local fn = assert(loadstring("return " .. expr))
      equal(fn(), expected)
   end
end)
test("SHA-256 known binary vectors", function()
   equal(sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
   equal(sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
   equal(sha256(("a"):rep(1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
end)
test("JSON legacy null, Unicode and binary controls", function()
   local decoded = assert(json.decode('{"expected":null,"text":"\\u96ea","nested":[true,false,0]}'))
   equal(decoded.expected, json.null); equal(decoded.text, "雪")
   local text = json.encode({ source = "\0\1\n\t\\\"" })
   local again = assert(json.decode(text)); equal(again.source, "\0\1\n\t\\\"")
end)
test("bounded reducer retains actual predicate", function()
   local reduced, calls = runner.minimize("prefix CRASH suffix", function(s) return s:find("CRASH", 1, true) ~= nil end, 100, 2)
   equal(reduced, "CRASH"); assert(calls <= 100)
   local unchanged, count = runner.minimize("abcdef", function() return false end, 2, 2)
   equal(unchanged, "abcdef"); equal(count, 2)
end)
test("empty reads, corpus files and directory reads", function()
   write(base .. "/empty.tl", "")
   equal(system.read(base .. "/empty.tl", 128), "")
   equal(system.read(base, 128), nil)
   equal(#system.files(base .. "/empty.tl"), 1)
   assert(#system.files(here .. "/corpus") >= 5)
end)
test("compiler grammar, mutations and deep inputs", function()
   local corpus = { "return 1", "local x: number = " }
   for i = 0, 47 do okay(runner.run_case(generator.case_for(20261105, i, corpus, 32), config())) end
end)
test("all portable and native dialect semantic templates", function()
   local reader = system.read(root .. "/teal/reader.lua") or ""
   if not reader:find("custom_operators", 1, true) then print("skip - optional tl-ng templates require tl-ng compiler"); return end
   local native_available = loadstring("return true ? 1 : 2") ~= nil
   for seed = 0, 1 do
      for _, feature in ipairs(generator.portable) do
         local text, expected = generator.tlng_program(generator.rng(seed, 0), feature)
         local result = runner.run_case(case(text, expected), config())
         okay(result); equal(result.executed, 1)
      end
      if native_available then
         for feature = 0, generator.features - 1 do
            local text, expected = generator.tlng_program(generator.rng(seed, 0), feature, true)
            local result = runner.run_case(case(text, expected), config("luajit", supervisor))
            okay(result); equal(result.executed, 1)
         end
      end
   end
end)
test("semantic mismatch, normal parser rejection, closed execution", function()
   local wrong = runner.run_case(case("return 2", 1), config())
   equal(wrong.status, "failure"); equal(wrong.stage, "execute"); assert(wrong.message:find("expected 1, got 2", 1, true))
   local malformed = runner.run_case(case("local x: number = "), config())
   okay(malformed); equal(malformed.disposition, "rejected")
   local nonterminating = runner.run_case(case("while true do end"), config())
   okay(nonterminating); equal(nonterminating.executed, 0)
end)
test("independent reference compiler mismatch is reported", function()
   local reference = fixture("reference", fixture_prefix .. [[
function api.check_string() return {syntax_errors={{x=1,y=1,msg="controlled reference rejection"}},type_errors={}} end
return api
]])
   local options = config(); options.reference_root = reference
   local result = runner.run_case(case("return 1"), options)
   equal(result.status, "failure"); equal(result.stage, "differential")
   equal(result.candidate.disposition, "accepted"); equal(result.reference.disposition, "rejected")
end)
test("wall timeout kills compiler and its descendant process group", function()
   local heartbeat = base .. "/heartbeat"
   local hanging = fixture("hanging", fixture_prefix .. string.format([=[
function api.check_string()
 local ffi=require('ffi')
 ffi.cdef[[int fork(void); int usleep(unsigned int);]]
 local pid=ffi.C.fork()
 if pid==0 then
  for i=1,50 do local f=assert(io.open(%q,'ab'));f:write('x');f:close();ffi.C.usleep(20000) end
  os.exit(0)
 end
 while true do ffi.C.usleep(10000) end
end
return api
]=], heartbeat))
   local before = system.now()
   local result = runner.run_case(case("return 1"), config("5.1", supervisor, hanging, 0.2))
   equal(result.status, "failure"); equal(result.stage, "timeout"); assert(system.now() - before < 2)
   local first = assert(system.read(heartbeat)); assert(#first > 0)
   system.pause(100); equal(system.read(heartbeat), first)
   files[#files + 1] = heartbeat
end)
test("worker process crash is reported", function()
   local crashing = fixture("crashing", fixture_prefix .. [[
function api.check_string() os.exit(17) end
return api
]])
   local result = runner.run_case(case("return 1"), config("5.1", supervisor, crashing))
   equal(result.status, "failure"); equal(result.stage, "process")
end)
test("legacy replay binary/oracle preservation and minimization refusal", function()
   local repro = base .. "/legacy.tl"
   write(repro, "return 2\n")
   write(base .. "/legacy.json", '{"version":1,"expected":1,"seed":77,"index":3,"profile":"grammar","target":"5.1","sha256":"legacy"}')
   local status = cli({ "--replay", repro, "--minimize", "--output", base .. "/legacy-out" }, "legacy-cli")
   equal(status, 256)
   equal(system.read(repro), "return 2\n")
   local f = io.open(base .. "/legacy-out/minimized", "rb"); assert(not f)
   os.remove(base .. "/legacy-out")
   local out = base .. "/binary"; mkdir(out)
   local c = case("\0\255return 1", 1)
   local path = runner.save_failure(out, c, { status = "failure", stage = "test" }, config())
   equal(system.read(path), c.source)
   local meta = assert(json.decode(assert(system.read(path:sub(1, -4) .. ".json"))))
   equal(meta.expected, 1); equal(meta.sha256, sha256(c.source))
   files[#files + 1] = path; files[#files + 1] = path:sub(1, -4) .. ".json"
end)
test("relative interpreter, missing interpreter and invalid root", function()
   local status = cli({ "--lua", "/nonexistent/teal-fuzz-lua", "--cases", "0" }, "missing-cli")
   equal(status, 512)
   status = cli({ "--root", base, "--cases", "0" }, "root-cli"); equal(status, 512)

   local depth = 0; for _ in root:gmatch("[^/]+") do depth = depth + 1 end
   local relative = ("../"):rep(depth) .. supervisor:sub(2)
   status = cli({ "--lua", relative, "--cases", "0", "--output", base .. "/relative-out" }, "relative-cli")
   equal(status, 0)
   files[#files + 1] = base .. "/relative-out/summary.json"; files[#files + 1] = base .. "/relative-out/results.jsonl"; dirs[#dirs + 1] = base .. "/relative-out"
end)
test("revision supports .git directories and linked-worktree files", function()
   for _, kind in ipairs({ "main", "linked" }) do
      local dir = base .. "/revision-" .. kind
      mkdir(dir); mkdir(dir .. "/teal"); mkdir(dir .. "/teal/api")
      write(dir .. "/teal/api/v2.lua", "return {}")
      local git = dir .. "/.git"
      if kind == "linked" then
         git = base .. "/linked-git"; mkdir(git); write(dir .. "/.git", "gitdir: " .. git .. "\n")
      else mkdir(git) end
      write(git .. "/HEAD", "0123456789012345678901234567890123456789\n")
      local output = dir .. "/out"
      local status = cli({ "--root", dir, "--cases", "0", "--output", output }, "revision-cli-" .. kind)
      equal(status, 0)
      local summary = assert(json.decode(assert(system.read(output .. "/summary.json"))))
      equal(summary.compiler_revision, "0123456789012345678901234567890123456789")
      files[#files + 1] = output .. "/summary.json"; files[#files + 1] = output .. "/results.jsonl"; dirs[#dirs + 1] = output
   end
end)

local failures = 0
for _, entry in ipairs(tests) do
   local outcomes = { xpcall(entry.run, debug.traceback) }
   local ok, err = outcomes[1], outcomes[2]
   if ok then print("ok - " .. entry.name)
   else failures = failures + 1; io.stderr:write("FAIL - " .. entry.name .. "\n" .. tostring(err) .. "\n"); runner.shutdown() end
end
runner.shutdown()
for i = #files, 1, -1 do os.remove(files[i]) end
for i = #dirs, 1, -1 do os.remove(dirs[i]) end
print(#tests .. " tests, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
