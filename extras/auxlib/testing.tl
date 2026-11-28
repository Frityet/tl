--#pragma strict_nil on

local _format = require("auxlib.format")
local macro f! = _format.f!

--- Define test suites, make assertions, and report the results of a run.
local record Testing
   record Detail
      label: string
      value: string
   end

   enum Status
      "pass"
      "fail"
      "skip"
      "todo"
   end

   enum Phase
      "before_each"
      "test"
      "after_each"
      "cleanup"
   end

   enum ReportFormat
      "pretty"
      "plain"
      "tap"
      "silent"
   end

   record Context
      name: string
      full_name: string
      _details: {Detail}
      _cleanups: {function()}
   end

   type Callback = function(Context)

   record Failure
      phase: Phase
      message: string
      details: {Detail}
      traceback: string?
   end

   record Result
      name: string
      group: string
      full_name: string
      source: string?
      status: Status
      reason: string?
      details: {Detail}
      failures: {Failure}
      seconds: number
   end

   record Summary
      passed: integer
      failed: integer
      skipped: integer
      todo: integer
      filtered: integer
      total: integer
      seconds: number
      exit_code: integer
      results: {Result}
   end

   record Options
      format: ReportFormat?
      filter: string?
      color: boolean?
      show_passes: boolean?
      timings: boolean?
      tracebacks: boolean?
      write: (function(string))?
   end

   record Case
      name: string
      body: Callback?
      status: Status
      reason: string?
      source: string?
   end

   record Entry
      case: Case?
      group: Suite?
   end

   record Suite
      name: string
      _entries: {Entry}
      _names: {string:boolean}
      _before: {Callback}
      _after: {Callback}
   end
end

local type Detail = Testing.Detail
local type Suite = Testing.Suite
local type Context = Testing.Context
local type Callback = Testing.Callback
local type Case = Testing.Case
local type Result = Testing.Result
local type Summary = Testing.Summary
local type Options = Testing.Options
local type Phase = Testing.Phase

local type Map = {any:any}

local function escape_control(value: string): string
   return (value:gsub("[%z\1-\31\127]", function(c: string): string
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      local byte = c:byte() as integer
      return f!"\\x{byte:02x}"
   end))
end

local function quote(value: string): string
   local escaped = value:gsub("[\\\"]", "\\%0")
   return '"' .. escape_control(escaped) .. '"'
end

local function scalar(value: any): string
   local kind = type(value)
   if kind == "string" then return quote(value as string) end
   if kind == "nil" or kind == "boolean" or kind == "number" then return tostring(value) end
   return "<" .. kind .. ">"
end

local function keys(value: Map): {any}
   local list: {any} = {}
   for key in next, value do
      list[#list + 1] = key
   end
   table.sort(list, function(a: any, b: any): boolean
      local ka, kb = type(a), type(b)
      if ka ~= kb then return ka < kb end
      if ka == "number" then return (a as number) < (b as number) end
      if ka == "string" then return (a as string) < (b as string) end
      return scalar(a) < scalar(b)
   end)
   return list
end

local function key_path(key: any): string
   if type(key) == "string" and (key as string):match("^[%a_][%w_]*$") then
      return "." .. (key as string)
   end
   return "[" .. scalar(key) .. "]"
end

local function inspect(value: any, depth: integer, active: {Map:boolean}): string
   if type(value) ~= "table" then return scalar(value) end
   local fields = value as Map
   if active[fields] then return "<cycle>" end
   if depth == 0 then return "{...}" end

   active[fields] = true
   local parts: {string} = {}
   for i, key in ipairs(keys(fields)) do
      if i > 8 then
         parts[#parts + 1] = "..."
         break
      end
      local label = key_path(key):gsub("^%.", "")
      parts[#parts + 1] = label .. " = " .. inspect(rawget(fields, key), depth - 1, active)
   end
   active[fields] = false
   return "{" .. table.concat(parts, ", ") .. "}"
end

--- Render a value for diagnostics, with stable ordering for scalar table keys.
--- Display cycles and limit the depth and number of entries shown per table.
function Testing.inspect(value: any): string
   return inspect(value, 3, {})
end

local record Signal
   message: string
   details: {Detail}
   skipped: boolean
end

local signal_mt = {
   __tostring = function(s: Signal): string return s.message end,
} as metatable<Signal>

local function as_signal(value: any): Signal?
   if type(value) == "table" and rawequal(getmetatable(value), signal_mt) then
      return value as Signal
   end
end

local function raise(message: string, details: {Detail}, skipped: boolean)
   local signal: Signal = { message = message, details = details, skipped = skipped }
   local tagged = setmetatable(signal, signal_mt)
   error(tagged, 0)
end

--- Fail the current case with an optional list of diagnostic fields.
function Testing.fail(message: string, details?: {Detail})
   raise(message, details or {}, false)
end

--- Skip the current case from its body or a before_each hook.
function Testing.skip(reason?: string)
   raise(reason or "Skipped by the test", {}, true)
end

--- Require a truthy value. False and nil both fail.
function Testing.ok(value: any, message?: string)
   if not value then
      Testing.fail(message or "Expected a truthy value", {
         { label = "Actual", value = Testing.inspect(value) },
      })
   end
end

local function values(expected: any, actual: any): {Detail}
   return {
      { label = "Expected", value = Testing.inspect(expected) },
      { label = "Actual", value = Testing.inspect(actual) },
   }
end

--- Compare two values with Lua's equality operator.
function Testing.equal(actual: any, expected: any, message?: string)
   if actual == expected then return end
   local details = values(expected, actual)
   if type(actual) == "string" and type(expected) == "string" then
      local a, b = actual as string, expected as string
      local index = 1
      while index <= #a and index <= #b and a:byte(index) == b:byte(index) do
         index = index + 1
      end
      details[#details + 1] = { label = "Difference", value = f!"First differing byte: {index}" }
   end
   Testing.fail(message or "Values differ", details)
end

--- Require two values to differ under Lua's equality operator.
function Testing.not_equal(actual: any, other: any, message?: string)
   if actual == other then
      Testing.fail(message or "Values are equal", {
         { label = "Both values", value = Testing.inspect(actual) },
      })
   end
end

local record Difference
   path: string
   actual: any
   expected: any
end

local function difference(actual: any, expected: any, path: string, seen: {Map:{Map:boolean}}): Difference?
   if rawequal(actual, expected) then return nil end
   if type(actual) ~= "table" or type(expected) ~= "table" then
      return { path = path, actual = actual, expected = expected }
   end

   local a, b = actual as Map, expected as Map
   local targets = seen[a]
   if not targets then
      targets = {}
      seen[a] = targets
   end
   if targets[b] then return nil end
   targets[b] = true

   for _, key in ipairs(keys(b)) do
      local mismatch = difference(rawget(a, key), rawget(b, key), path .. key_path(key), seen)
      if mismatch then return mismatch end
   end
   for _, key in ipairs(keys(a)) do
      if rawget(b, key) == nil then
         return { path = path .. key_path(key), actual = rawget(a, key), expected = nil }
      end
   end
end

--- Compare table contents recursively, including cyclic tables.
--- Compare keys by identity and ignore metatables.
function Testing.same(actual: any, expected: any, message?: string)
   local mismatch = difference(actual, expected, "$", {})
   if mismatch then
      local details = values(mismatch.expected, mismatch.actual)
      table.insert(details, 1, { label = "Path", value = mismatch.path })
      Testing.fail(message or "Contents differ", details)
   end
end

--- Compare numbers using an absolute tolerance.
function Testing.near(actual: number, expected: number, tolerance: number, message?: string)
   if not (tolerance >= 0 and tolerance < math.huge) then
      Testing.fail("Tolerance must be a finite, nonnegative number", {
         { label = "Tolerance", value = Testing.inspect(tolerance) },
      })
   end
   if actual == expected then return end
   local delta = actual > expected and actual - expected or expected - actual
   -- A negative distance can only come from integer overflow on Lua 5.3+.
   if delta < 0 then delta = math.abs((actual + 0.0) - expected) end
   if delta <= tolerance then return end
   local details = values(expected, actual)
   details[#details + 1] = { label = "Difference", value = tostring(delta) }
   details[#details + 1] = { label = "Tolerance", value = tostring(tolerance) }
   Testing.fail(message or "Numbers differ by more than the tolerance", details)
end

--- Require a literal substring.
function Testing.contains(actual: string, fragment: string, message?: string)
   if not actual:find(fragment, 1, true) then
      Testing.fail(message or "Substring not found", {
         { label = "Substring", value = quote(fragment) },
         { label = "Actual", value = quote(actual) },
      })
   end
end

--- Require a match against a Lua pattern.
function Testing.matches(actual: string, pattern: string, message?: string)
   if not actual:find(pattern) then
      Testing.fail(message or "Pattern did not match", {
         { label = "Pattern", value = quote(pattern) },
         { label = "Actual", value = quote(actual) },
      })
   end
end

local function error_text(value: any): string
   if type(value) == "string" then return value as string end
   return Testing.inspect(value)
end

--- Require an error and optionally check for a literal message fragment.
--- Return the original error object.
function Testing.raises(action: function(), fragment?: string): any
   local ok, thrown = pcall(function(): any
      action()
      return nil
   end)
   if ok then
      Testing.fail("Expected an error, but the function returned")
   end
   local signal = as_signal(thrown)
   if signal and signal.skipped then error(thrown, 0) end
   if fragment then
      Testing.contains(signal and signal.message or error_text(thrown), fragment, "Error message differs")
   end
   return thrown
end

local context_mt = { __index = Testing.Context } as metatable<Context>
local suite_mt = { __index = Testing.Suite } as metatable<Suite>

--- Attach a named piece of context to the result and any failure report.
function Testing.Context:detail(label: string, value: string)
   self._details[#self._details + 1] = { label = label, value = value }
end

--- Register a cleanup to run after the after_each hooks. Cleanups run in reverse order.
function Testing.Context:defer(action: function())
   self._cleanups[#self._cleanups + 1] = action
end

--- Create an independent suite. Declare cases and groups before running it.
function Testing.suite(name: string): Suite
   assert(name ~= "", "Test suite names cannot be empty")
   local suite: Suite = { name = name, _entries = {}, _names = {}, _before = {}, _after = {} }
   return setmetatable(suite, suite_mt)
end

local function reserve(suite: Suite, name: string)
   assert(name ~= "", "Test and group names cannot be empty")
   assert(not suite._names[name], f!"Duplicate test or group name {quote(name)} in {quote(suite.name)}")
   suite._names[name] = true
end

--- Add a named subgroup. Cases and groups run in declaration order.
function Testing.Suite:group(name: string): Suite
   reserve(self, name)
   local child = Testing.suite(name)
   self._entries[#self._entries + 1] = { group = child }
   return child
end

local function callback_source(body: Callback): string?
   if debug and debug.getinfo then
      local info = debug.getinfo(body as function, "S")
      if info and info.linedefined > 0 then return f!"{info.short_src}:{info.linedefined}" end
   end
end

--- Register a callback. An explicit source location overrides the callback's definition location.
function Testing.Suite:test(name: string, body: Callback, source?: string)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, body = body, status = "pass", source = source or callback_source(body) },
   }
end

--- Register a skipped case without running any hooks.
function Testing.Suite:skip(name: string, reason?: string)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, status = "skip", reason = reason or "Skipped" },
   }
end

--- Record a planned case without running any hooks.
function Testing.Suite:todo(name: string, reason?: string)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, status = "todo", reason = reason or "Not implemented yet" },
   }
end

--- Add setup for cases in this group and its subgroups.
--- Setup runs from the outer group inward, in registration order.
function Testing.Suite:before_each(hook: Callback)
   self._before[#self._before + 1] = hook
end

--- Add teardown for cases in this group and its subgroups.
--- Teardown runs in reverse registration order, from the innermost entered group outward.
function Testing.Suite:after_each(hook: Callback)
   self._after[#self._after + 1] = hook
end

local function invoke(callback: Callback, context: Context, result: Result, phase: Phase): boolean
   local trace: string?
   local ok, thrown = xpcall(function()
      callback(context)
   end, function(err: any): any
      if not as_signal(err) and debug and debug.traceback then
         trace = debug.traceback("", 2)
      end
      return err
   end)
   if ok then return true end

   local signal = as_signal(thrown)
   if signal and signal.skipped and (phase == "before_each" or phase == "test") then
      result.status = "skip"
      result.reason = signal.message
   else
      local message = signal and signal.message or error_text(thrown)
      if signal and signal.skipped then message = "Cannot skip during teardown: " .. message end
      result.status = "fail"
      result.reason = nil
      result.failures[#result.failures + 1] = {
         phase = phase, message = message, details = signal and signal.details or {}, traceback = trace,
      }
   end
   return false
end

local function run_case(case: Case, group: string, full_name: string, scopes: {Suite}): Result
   local result: Result = {
      name = case.name, group = group, full_name = full_name, source = case.source,
      status = case.status, reason = case.reason, details = {}, failures = {}, seconds = 0,
   }
   local body = case.body
   if not body then return result end

   local state: Context = { name = case.name, full_name = full_name, _details = result.details, _cleanups = {} }
   local context = setmetatable(state, context_mt)
   local started = os.clock()
   local entered = 0
   local ready = true
   for i, scope in ipairs(scopes) do
      entered = i
      for _, hook in ipairs(scope._before) do
         if not invoke(hook, context, result, "before_each") then
            ready = false
            break
         end
      end
      if not ready then break end
   end
   if ready then invoke(body, context, result, "test") end
   for i = entered, 1, -1 do
      local hooks = scopes[i]._after
      for j = #hooks, 1, -1 do
         invoke(hooks[j], context, result, "after_each")
      end
   end
   while #context._cleanups > 0 do
      local cleanup = table.remove(context._cleanups)
      if cleanup then invoke(cleanup, context, result, "cleanup") end
   end
   result.seconds = os.clock() - started
   return result
end

local record Job
   case: Case
   group: string
   full_name: string
   scopes: {Suite}
end

local function collect(suite: Suite, path: string, ancestors: {Suite}, filter: string?, jobs: {Job}): integer
   local scopes: {Suite} = {}
   for i, scope in ipairs(ancestors) do scopes[i] = scope end
   scopes[#scopes + 1] = suite
   local filtered = 0
   for _, entry in ipairs(suite._entries) do
      local case, child = entry.case, entry.group
      if case then
         local full_name = path ~= "" and path .. " / " .. case.name or case.name
         if filter and not full_name:find(filter, 1, true) then
            filtered = filtered + 1
         else
            jobs[#jobs + 1] = { case = case, group = path, full_name = full_name, scopes = scopes }
         end
      elseif child then
         local group = path ~= "" and path .. " / " .. child.name or child.name
         filtered = filtered + collect(child, group, scopes, filter, jobs)
      end
   end
   return filtered
end

local function diagnostics(result: Result, traces: boolean): {Detail}
   local rows: {Detail} = {}
   local source = result.source
   if source then rows[#rows + 1] = { label = "Source", value = source } end
   for _, detail in ipairs(result.details) do rows[#rows + 1] = detail end
   for _, failure in ipairs(result.failures) do
      local label = failure.phase == "test" and "Failure" or failure.phase
      rows[#rows + 1] = { label = label, value = failure.message }
      for _, detail in ipairs(failure.details) do rows[#rows + 1] = detail end
      local trace = failure.traceback
      if traces and trace then
         for line in trace:gmatch("[^\r\n]+") do
            rows[#rows + 1] = { label = "", value = (line:gsub("^\t", "  ")) }
         end
      end
   end
   return rows
end

local function tap_text(line: string): string
   return (escape_control(line):gsub("#", "\\x23"))
end

local function tap_case(result: Result, index: integer, write: function(string), traces: boolean)
   local status = result.status
   local ok = (status == "pass" or status == "skip") and "ok" or "not ok"
   local text = f!"{ok} {index} - {tap_text(result.full_name)}"
   if status == "skip" or status == "todo" then
      local directive = status == "skip" and "SKIP" or "TODO"
      text = text .. f!" # {directive} {tap_text(result.reason or '')}"
   end
   write(text)
   if status == "fail" then
      for _, row in ipairs(diagnostics(result, traces)) do
         write(f!"# {escape_control(row.label)}: {escape_control(row.value)}")
      end
   end
end

local record Marks
   icon: string
   word: string
   color: string
end

local status_marks: {Testing.Status:Marks} = {
   pass = { icon = "✓", word = "PASS", color = "1;32" },
   fail = { icon = "✗", word = "FAIL", color = "1;31" },
   skip = { icon = "↷", word = "SKIP", color = "1;33" },
   todo = { icon = "◇", word = "TODO", color = "1;35" },
}

local record Reporter
   case: function(Result, integer)
   finish: function(Summary)
end

local function reporter(name: string, total: integer, options: Options): Reporter
   local mode = options.format or "pretty"
   local write = options.write or print
   local traces = options.tracebacks == true
   if mode == "silent" then
      return { case = function() end, finish = function() end }
   end
   if mode == "tap" then
      write("TAP version 13")
      write(total == 0 and "1..0 # SKIP No cases selected" or f!"1..{total}")
      return {
         case = function(result: Result, index: integer) tap_case(result, index, write, traces) end,
         finish = function() end,
      }
   end

   local pretty = mode == "pretty"
   local term = os.getenv("TERM")
   local colored = pretty and (options.color == true or
      (options.color == nil and not options.write and os.getenv("NO_COLOR") == nil and
      term ~= nil and term ~= "" and term ~= "dumb"))
   local function paint(code: string, value: string): string
      if not colored or value == "" then return value end
      return "\27[" .. code .. "m" .. value .. "\27[0m"
   end

   local title = escape_control(name)
   if pretty then
      write(paint("1;36", f!"╭─ ✦ {title}"))
      write(paint("2", f!"╰─ {total} selected"))
   else
      write(f!"{title} ({total} selected)")
   end

   local last_group: string?
   return {
      case = function(result: Result, _index: integer)
         if result.status == "pass" and options.show_passes == false then return end
         if result.group ~= last_group then
            write("")
            if result.group ~= "" then
               local heading = escape_control(result.group)
               write(pretty and paint("1;36", "◆ " .. heading) or "[" .. heading .. "]")
            end
            last_group = result.group
         end
         local marks = status_marks[result.status]
         local marker = pretty and paint(marks.color, marks.icon) or marks.word
         local reason = result.reason
         local reason_text = reason and ("  " .. escape_control(reason)) or ""
         local timing = options.timings and f!"  {result.seconds * 1000:.2f} ms" or ""
         write(f!"  {marker} {escape_control(result.name)}{paint('2', reason_text .. timing)}")
         if result.status ~= "fail" then return end

         local rows = diagnostics(result, traces)
         local width = 0
         for _, row in ipairs(rows) do width = math.max(width, #escape_control(row.label)) end
         for i, row in ipairs(rows) do
            local stem = pretty and (i == #rows and "╰─" or "│ ") or "  "
            local label = escape_control(row.label)
            local value = escape_control(row.value)
            if label == "Expected" then value = paint("32", value) end
            if label == "Actual" then value = paint("31", value) end
            write(f!"    {paint('2', stem)} {label}{string.rep(' ', width - #label)}  {value}")
         end
      end,
      finish = function(summary: Summary)
         write("")
         local counts: {string} = {}
         local function count(status: Testing.Status, n: integer, label: string)
            local marks = status_marks[status]
            local value = f!"{n} {label}"
            counts[#counts + 1] = pretty and paint(marks.color, marks.icon .. " " .. value) or value
         end
         count("pass", summary.passed, "passed")
         count("fail", summary.failed, "failed")
         if summary.skipped > 0 then count("skip", summary.skipped, "skipped") end
         if summary.todo > 0 then count("todo", summary.todo, "todo") end
         counts[#counts + 1] = f!"{summary.total} total"
         if summary.filtered > 0 then counts[#counts + 1] = f!"{summary.filtered} filtered" end
         if options.timings then counts[#counts + 1] = f!"{summary.seconds * 1000:.2f} ms CPU" end
         local rule = pretty and paint(summary.failed > 0 and "31" or "36", string.rep("━", 44)) or string.rep("-", 44)
         write(rule)
         write("  " .. table.concat(counts, pretty and "  ·  " or "  |  "))
         write(rule)
      end,
   }
end

--- Run every selected case and return counts, individual results, and an exit code.
--- The filter is a literal substring of the full group and case name.
--- Timings use CPU seconds. The caller controls whether to exit the process.
function Testing.Suite:run(options?: Options): Summary
   local opts: Options = options or {}
   local jobs: {Job} = {}
   local filtered = collect(self, "", {}, opts.filter, jobs)
   local summary: Summary = {
      passed = 0, failed = 0, skipped = 0, todo = 0, filtered = filtered,
      total = #jobs, seconds = 0, exit_code = 0, results = {},
   }
   local output = reporter(self.name, #jobs, opts)
   for i, job in ipairs(jobs) do
      local result = run_case(job.case, job.group, job.full_name, job.scopes)
      summary.results[i] = result
      summary.seconds = summary.seconds + result.seconds
      if result.status == "pass" then
         summary.passed = summary.passed + 1
      elseif result.status == "fail" then
         summary.failed = summary.failed + 1
         summary.exit_code = 1
      elseif result.status == "skip" then
         summary.skipped = summary.skipped + 1
      else
         summary.todo = summary.todo + 1
      end
      output.case(result, i)
   end
   output.finish(summary)
   return summary
end

--- Assert an expression. Equality and inequality show the two operands on failure.
--- Each operand is evaluated once, as part of the current case.
macro Testing.expect!(condition: Expression): Statement
   local B = BLOCK_INDEXES
   while condition.kind == "paren" do condition = condition[B.PAREN.EXP] end
   local left, right = condition[B.OP.E1], condition[B.OP.E2]
   if condition.kind == "op_eq" then
      return ```require("auxlib.testing").equal(($left), ($right))```
   elseif condition.kind == "op_ne" then
      return ```require("auxlib.testing").not_equal(($left), ($right))```
   end
   return ```require("auxlib.testing").ok(($condition))```
end

--- Register a group from an ordered table of named checks.
--- The spec contains `tests = { ["name"] = actual == expected, ... }`.
--- Cases can also be inequality checks, truthy expressions, or inline callbacks.
--- An optional `check` callback handles equality cases as `check(ctx, actual, expected)`.
macro Testing.tests!(suite: Expression, name: Expression, spec: Expression): Statement
   local B = BLOCK_INDEXES
   local item_slots = B.LITERAL_TABLE_ITEM
   if spec.kind ~= "literal_table" then error("tests!: expected a literal suite specification", 0) end
   local fields = {}
   for _, item in ipairs(spec) do
      local key = item[item_slots.KEY]
      local field = key.kind == "string" and string_value(key)
      if field ~= "tests" and field ~= "check" then
         error("tests!: suite fields are 'tests' and optional 'check'", 0)
      end
      if fields[field] then error("tests!: duplicate field '" .. field .. "'", 0) end
      fields[field] = item[item_slots.VALUE]
   end
   local cases, check = fields.tests, fields.check
   if not cases or cases.kind ~= "literal_table" then
      error("tests!: supply tests = { [\"case name\"] = expression, ... }", 0)
   end

   local used = {}
   local function visit(syntax)
      if syntax.kind == "identifier" or syntax.kind == "argument" then used[syntax.tk] = true end
      for _, child in pairs(syntax) do
         if type(child) == "table" and child.kind then visit(child) end
      end
   end
   visit(spec)
   visit(name)
   visit(suite)
   local function fresh(stem)
      local id = block("identifier")
      id.tk = "__testing_" .. stem
      while used[id.tk] do id.tk = id.tk .. "_" end
      used[id.tk] = true
      return id
   end
   local group = fresh("group")
   local library = fresh("library")
   local checker = fresh("check")
   local context = fresh("context")
   local out = ```do local $group = ($suite):group($name) end```
   local body = out[1][B.DO.BODY]
   local needs_library, needs_checker = false, false
   for _, item in ipairs(cases) do
      local label, expr = item[item_slots.KEY], item[item_slots.VALUE]
      if label.kind ~= "string" then error("tests!: each case needs a literal string name", 0) end
      while expr.kind == "paren" do expr = expr[B.PAREN.EXP] end
      local source = block("string")
      source.tk = string.format("%q", label.f .. ":" .. label.y .. ":" .. label.x)
      local left, right = expr[B.OP.E1], expr[B.OP.E2]
      local callback
      if expr.kind == "function" then
         callback = expr
      elseif expr.kind == "op_eq" and check then
         needs_library, needs_checker = true, true
         callback = `function(ctx: $library.Context) ($checker)($context, ($left), ($right)) end`
         callback[B.FUNCTION.ARGS][1].tk = context.tk
      elseif expr.kind == "op_eq" then
         needs_library = true
         callback = `function() $library.equal(($left), ($right)) end`
      elseif expr.kind == "op_ne" then
         needs_library = true
         callback = `function() $library.not_equal(($left), ($right)) end`
      else
         needs_library = true
         callback = `function() $library.ok(($expr)) end`
      end
      local call = ```($group):test($label, $callback, $source)```
      table.insert(body, call[1])
   end
   if needs_checker then
      local setup = ```local $checker = $check```
      table.insert(body, 2, setup[1])
   end
   if needs_library then
      local import = ```local $library = require("auxlib.testing")```
      table.insert(body, 1, import[1])
   end
   return out
end

return Testing
