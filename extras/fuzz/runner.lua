
local generator = require("extras.fuzz.generator")
local json = require("extras.fuzz.json")
local system = require("extras.fuzz.system")
local sha256 = require("extras.fuzz.hash")


local runner = { Job = {} }
























runner.active = {}
local function object(value)
   return value
end
local function arguments(job, root)
   return { job.config.lua, job.config.here .. "/worker.lua", root,
   job.dir .. "/input.tl", job.config.target,
   job.case.expected ~= nil and tostring(job.case.expected) or "-", }
end
local function launch(job, root)
   return system.spawn(arguments(job, root), job.dir, job.dir .. "/stdout", job.dir .. "/stderr", job.config.timeout, job.config.memory_mb)
end
function runner.start(case, config)
   local job = { case = case, config = config, dir = system.tempdir(), started = system.now(), done = false, reference = false }
   system.write(job.dir .. "/input.tl", case.source)
   job.process = launch(job, config.root)
   runner.active[#runner.active + 1] = job
   return job
end
local function process_result(job)
   if job.process.timed_out then
      return { status = "failure", stage = "timeout", message = "exceeded " .. job.config.timeout .. "s" }
   end
   local stdout = system.tail(job.dir .. "/stdout", 65536)
   local stderr = system.tail(job.dir .. "/stderr", 65536)
   local result
   for line in (stdout .. "\n"):gmatch("([^\n]*)\n") do
      local payload = line:match("^FUZZ_RESULT (.*)$")
      if payload then
         local decoded, err = json.decode(payload)
         if not err and decoded and type(decoded.status) == "string" and type(decoded.stage) == "string" then result = decoded end
      end
   end
   if not result or (job.process.status ~= 0 and result.status == "ok") then
      return { status = "failure", stage = "process", message = "wait status " .. job.process.status, stdout = stdout, stderr = stderr }
   end
   return result
end
function runner.poll(job)
   if job.done then return true end
   if not system.poll(job.process) then return false end
   local result = process_result(job)
   if not job.reference and job.config.reference_root and result.status == "ok" then
      job.first = result; job.reference = true; job.process = launch(job, job.config.reference_root)
      return false
   end
   if job.reference then
      if result.status ~= "ok" then result = { status = "failure", stage = "differential-reference", reference = result }
      elseif result.disposition ~= job.first.disposition then result = { status = "failure", stage = "differential", candidate = job.first, reference = result }
      else result = job.first end
   end
   result.seconds = system.now() - job.started
   job.result = result; job.done = true
   system.cleanup(job.dir)
   for i, active in ipairs(runner.active) do if active == job then table.remove(runner.active, i); break end end
   return true
end
function runner.run_case(case, config)
   local job = runner.start(case, config)
   while not runner.poll(job) do system.pause(5) end
   return job.result
end
function runner.shutdown()
   for _, job in ipairs(runner.active) do system.kill(job.process); system.cleanup(job.dir) end
   runner.active = {}
end
function runner.fingerprint(result)
   local message = (result.message or ""):match("^[^\n]*") or ""
   message = message:gsub(":%d+:", ":LINE:")
   local invariant = message:match("invariant: ([^:]+)")
   return result.stage .. ":" .. (invariant or message)
end
function runner.minimize(source, predicate, attempts, seconds)
   local deadline = system.now() + seconds
   local calls, granularity = 0, 2
   while #source > 0 and calls < attempts and system.now() < deadline do
      local chunk = math.max(1, math.ceil(#source / granularity))
      local reduced = false
      for offset = 0, #source - 1, chunk do
         if calls >= attempts or system.now() >= deadline then break end
         local candidate = source:sub(1, offset) .. source:sub(offset + chunk + 1)
         calls = calls + 1
         if predicate(candidate) then source = candidate; granularity = math.max(2, granularity - 1); reduced = true; break end
      end
      if not reduced then
         if granularity >= #source then break end
         granularity = math.min(#source, granularity * 2)
      end
   end
   return source, calls
end
local function config_object(config)
   return { root = config.root, lua = config.lua, target = config.target, timeout = config.timeout, memory_mb = config.memory_mb,
   reference_root = config.reference_root or json.null, compiler_revision = config.compiler_revision or json.null,
   supervisor = "Teal/LuaJIT POSIX", version = generator.version, }
end
function runner.save_failure(directory, case, result, config)
   system.mkdir(directory)
   local digest = sha256(case.source)
   local stem = string.format("%d-%d-%s-%s", case.seed, case.index, (config.target:gsub("[^%w._-]", "_")), digest:sub(1, 16))
   local path = directory .. "/" .. stem .. ".tl"
   system.write(path, case.source)
   local metadata = config_object(config)
   metadata.seed = case.seed; metadata.index = case.index; metadata.profile = case.profile
   metadata.expected = case.expected ~= nil and case.expected or json.null
   metadata.sha256 = digest; metadata.result = object(result)
   system.write(path:sub(1, -4) .. ".json", json.encode(metadata) .. "\n")
   return path
end

























local help = [[
Teal compiler fuzzer (LuaJIT POSIX supervisor, selectable Lua worker)
  luajit extras/fuzz/fuzz.lua [options]
  --seed N --start N --cases N --seconds N --jobs N
  --lua PATH --root PATH --targets 5.1,5.3 --profile upstream|tl-ng
  --corpus PATH (repeatable) --max-input N --max-depth N
  --timeout SECONDS --memory-mb N --output PATH
  --reference-root PATH --stop-on-failure
  --replay FILE.tl --minimize --minimize-attempts N --minimize-seconds N
Each source/target is isolated. See extras/fuzz/README.md for replay and limits.
]]
local function parse(argv, here)
   local opts = { seed = 1, cases = 1000, start = 0, seconds = 0, timeout = 5, jobs = 1, lua = system.executable("lua") and "lua" or "luajit", root = system.absolute(here .. "/../.."), targets = "5.1,5.3", corpus = {}, profile = "upstream", max_input = 131072, max_depth = 128, memory_mb = 0, minimize_attempts = 100, minimize_seconds = 60 }
   local numerical = { seed = true, cases = true, start = true, seconds = true, timeout = true, jobs = true, max_input = true, max_depth = true, memory_mb = true, minimize_attempts = true, minimize_seconds = true }
   local flags = { minimize = true, stop_on_failure = true, help = true }
   local strings = { lua = true, root = true, reference_root = true, targets = true, profile = true, output = true, replay = true, corpus = true }
   local i = 1
   local dynamic = opts
   while i <= #argv do
      local name, value = argv[i]:match("^%-%-([%w-]+)=(.*)$")
      if not name then name = argv[i]:match("^%-%-([%w-]+)$") end
      assert(name, "unknown argument: " .. argv[i])
      name = name:gsub("-", "_")
      if flags[name] then
         assert(not value, "flag takes no value: " .. name); dynamic[name] = true
      else
         assert(numerical[name] or strings[name], "unknown option: " .. name)
         if value == nil then i = i + 1; value = argv[i] end
         assert(value, "missing value: " .. name)
         if numerical[name] then
            local n = tonumber(value); assert(n and n == n and math.abs(n) < math.huge, "invalid number: " .. name)
            dynamic[name] = n
         elseif name == "corpus" then opts.corpus[#opts.corpus + 1] = value
         else dynamic[name] = value end
      end
      i = i + 1
   end
   for _, name in ipairs({ "seed", "cases", "start", "jobs", "max_input", "max_depth", "memory_mb", "minimize_attempts" }) do
      local value = dynamic[name]
      assert(value % 1 == 0 and math.abs(value) <= 9007199254740991, "expected safe integer: " .. name)
   end
   assert(opts.cases >= 0 and opts.start >= 0 and opts.seconds >= 0 and opts.memory_mb >= 0 and opts.minimize_attempts >= 0 and opts.minimize_seconds >= 0, "budgets cannot be negative")
   assert(opts.jobs >= 1 and opts.timeout > 0 and opts.max_input >= 1 and opts.max_depth >= 1, "jobs/timeout/input/depth must be positive")
   assert(opts.profile == "upstream" or opts.profile == "tl-ng", "unknown grammar profile")
   if opts.help then return opts end
   opts.output = system.absolute(opts.output or opts.root .. "/_temp/fuzz")
   opts.root = system.absolute(opts.root)
   opts.lua = assert(system.executable(opts.lua), "Lua interpreter not found/executable: " .. opts.lua)
   if opts.reference_root then opts.reference_root = system.absolute(opts.reference_root) end
   return opts
end
local function make_config(opts, here, target)
   return { root = opts.root, here = here, lua = opts.lua, target = target, timeout = opts.timeout, memory_mb = opts.memory_mb, reference_root = opts.reference_root }
end
local function revision(root)

   local git = root .. "/.git"
   local pointer = system.read(git, 4096)
   if pointer then git = pointer:match("^gitdir: ([^\r\n]+)") or git end
   if git:sub(1, 1) ~= "/" then git = root .. "/" .. git end
   local head = system.read(git .. "/HEAD", 4096)
   if not head then return nil end
   local ref = head:match("^ref: ([^\r\n]+)")
   if not ref then return head:match("^([%da-f]+)") end
   local common = system.read(git .. "/commondir", 4096)
   if common then git = system.absolute(git .. "/" .. (common:match("[^\r\n]+") or "")) end
   local value = system.read(git .. "/" .. ref, 4096)
   if value then return value:match("^([%da-f]+)") end
   local packed = system.read(git .. "/packed-refs") or ""
   for hash, name in packed:gmatch("([%da-f]+) ([^\r\n]+)") do if name == ref then return hash end end
   return nil
end
function runner.main(argv, source_here)
   local here = system.absolute(source_here)
   local opts = parse(argv, here)
   if opts.help then io.write(help); return 0 end
   assert(system.read(opts.root .. "/teal/api/v2.lua", 4 * 1024 * 1024), "compiler root missing teal/api/v2.lua: " .. opts.root)
   if opts.reference_root then assert(system.read(opts.reference_root .. "/teal/api/v2.lua", 4 * 1024 * 1024), "reference root missing teal/api/v2.lua") end
   local targets = {}
   for target in (opts.targets .. ","):gmatch("(.-),") do
      assert(target == "5.1" or target == "5.2" or target == "5.3" or target == "5.4" or target == "5.5" or target == "luajit", "unsupported generation target: " .. target)
      targets[#targets + 1] = target
   end
   assert(#targets > 0, "no generation targets")
   system.mkdir(opts.output)
   local base = make_config(opts, here, targets[1]); base.compiler_revision = revision(opts.root)
   local function config(target)
      local value = make_config(opts, here, target); value.compiler_revision = base.compiler_revision; return value
   end
   if opts.replay then
      local source = assert(system.read(opts.replay), "cannot read replay")
      local encoded = system.read((opts.replay:gsub("%.tl$", ".json")))
      local meta = {}
      if encoded then
         local err
         local decoded
         decoded, err = json.decode(encoded); meta = decoded; assert(not err, "invalid replay metadata: " .. (err or ""))
      end
      local expected
      local saved_expected = meta.expected
      if type(saved_expected) == "number" then expected = saved_expected end
      local case = { source = source, profile = (meta.profile or "replay"), expected = expected, seed = (meta.seed or 0), index = (meta.index or 0) }
      local execution = config((meta.target or targets[1]))
      local result = runner.run_case(case, execution)
      io.write(json.encode(object(result)), "\n")
      if opts.minimize and result.status ~= "ok" then
         if case.expected ~= nil then
            io.stderr:write("Reduction refused: generated-program validity/semantic oracles cannot survive arbitrary source deletion.\n")
         else
            local signature = runner.fingerprint(result)
            local function fails(candidate)
               local probe = { source = candidate, profile = case.profile, seed = case.seed, index = case.index }
               local outcome = runner.run_case(probe, execution)
               return outcome.status ~= "ok" and runner.fingerprint(outcome) == signature
            end
            local reduced, calls = runner.minimize(case.source, fails, opts.minimize_attempts, opts.minimize_seconds)
            case.source = reduced; result = runner.run_case(case, execution)
            local path = runner.save_failure(opts.output .. "/minimized", case, result, execution)
            print("minimized to " .. #reduced .. " bytes in " .. calls .. " attempts: " .. path)
         end
      end
      return result.status == "ok" and 0 or 1
   end
   local corpus = {}
   local directories = { here .. "/corpus" }
   if opts.profile == "tl-ng" then
      directories[#directories + 1] = here .. "/profiles/tl-ng"
      directories[#directories + 1] = here .. "/../../extras/macros/struct_fuzz.tl"
   end
   for _, path in ipairs(opts.corpus) do directories[#directories + 1] = path end
   for _, directory in ipairs(directories) do
      for _, path in ipairs(system.files(directory)) do
         local data = system.read(path, opts.max_input)
         if data then corpus[#corpus + 1] = data end
      end
   end
   local log = assert(io.open(opts.output .. "/results.jsonl", "wb"))
   local started = system.now()
   local index, lane = opts.start, 1
   local completed, submitted, failures = 0, 0, 0
   local counts = {}
   local pending = {}
   local stopped = false
   while true do
      while not stopped and #pending < opts.jobs do
         if index >= opts.start + opts.cases or (opts.seconds > 0 and system.now() - started >= opts.seconds) then stopped = true; break end
         local target = targets[lane]
         local case = generator.case_for(opts.seed, index, corpus, opts.max_depth, opts.profile, target == "luajit")
         if #case.source > opts.max_input then case.source = case.source:sub(1, opts.max_input); case.expected = nil; case.profile = "truncated" end
         pending[#pending + 1] = runner.start(case, config(target)); submitted = submitted + 1
         lane = lane + 1
         if lane > #targets then lane = 1; index = index + 1 end
      end
      if #pending == 0 then break end
      local progress = false
      for i = #pending, 1, -1 do
         local job = pending[i]
         if runner.poll(job) then
            progress = true; table.remove(pending, i); completed = completed + 1
            counts[job.case.profile] = (counts[job.case.profile] or 0) + 1
            local row = object(job.result)
            row.seed = job.case.seed; row.index = job.case.index; row.profile = job.case.profile; row.target = job.config.target
            log:write(json.encode(row), "\n"); log:flush()
            if job.result.status ~= "ok" then
               failures = failures + 1
               local path = runner.save_failure(opts.output .. "/failures", job.case, job.result, job.config)
               print("FAIL " .. job.case.index .. "/" .. job.config.target .. " " .. job.result.stage .. ": " .. path)
               if opts.stop_on_failure then stopped = true end
            end
            if completed % 100 == 0 then print(completed .. " checks, " .. failures .. " failures, " .. string.format("%.1f", system.now() - started) .. "s") end
         end
      end
      if not progress then system.pause(5) end
   end
   log:close()
   local summary = config_object(base)
   summary.seed = opts.seed; summary.completed = completed; summary.failures = failures; summary.seconds = system.now() - started
   summary.profiles = counts; summary.targets = json.array(targets); summary.start = opts.start; summary.cases_requested = opts.cases
   summary.submitted = submitted; summary.max_depth = opts.max_depth; summary.corpus_entries = #corpus; summary.grammar_profile = opts.profile
   system.write(opts.output .. "/summary.json", json.encode(summary) .. "\n")
   print(json.encode(summary))
   return failures > 0 and 1 or 0
end
return runner
