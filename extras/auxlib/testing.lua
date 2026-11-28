





local Testing = { Detail = {}, Context = {}, Failure = {}, Result = {}, Summary = {}, Options = {}, Case = {}, Entry = {}, Suite = {} }














































































































local function escape_control(value)
   return (value:gsub("[%z\1-\31\127]", function(c)
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      local byte = c:byte()
      return string.format("\\x%02x", (byte))
   end))
end

local function quote(value)
   local escaped = value:gsub("[\\\"]", "\\%0")
   return '"' .. escape_control(escaped) .. '"'
end

local function scalar(value)
   local kind = type(value)
   if kind == "string" then return quote(value) end
   if kind == "nil" or kind == "boolean" or kind == "number" then return tostring(value) end
   return "<" .. kind .. ">"
end

local function keys(value)
   local list = {}
   for key in next, value do
      list[#list + 1] = key
   end
   table.sort(list, function(a, b)
      local ka, kb = type(a), type(b)
      if ka ~= kb then return ka < kb end
      if ka == "number" then return (a) < (b) end
      if ka == "string" then return (a) < (b) end
      return scalar(a) < scalar(b)
   end)
   return list
end

local function key_path(key)
   if type(key) == "string" and (key):match("^[%a_][%w_]*$") then
      return "." .. (key)
   end
   return "[" .. scalar(key) .. "]"
end

local function inspect(value, depth, active)
   if type(value) ~= "table" then return scalar(value) end
   local fields = value
   if active[fields] then return "<cycle>" end
   if depth == 0 then return "{...}" end

   active[fields] = true
   local parts = {}
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



function Testing.inspect(value)
   return inspect(value, 3, {})
end







local signal_mt = {
   __tostring = function(s) return s.message end,
}

local function as_signal(value)
   if type(value) == "table" and rawequal(getmetatable(value), signal_mt) then
      return value
   end
end

local function raise(message, details, skipped)
   local signal = { message = message, details = details, skipped = skipped }
   local tagged = setmetatable(signal, signal_mt)
   error(tagged, 0)
end


function Testing.fail(message, details)
   raise(message, details or {}, false)
end


function Testing.skip(reason)
   raise(reason or "Skipped by the test", {}, true)
end


function Testing.ok(value, message)
   if not value then
      Testing.fail(message or "Expected a truthy value", {
         { label = "Actual", value = Testing.inspect(value) },
      })
   end
end

local function values(expected, actual)
   return {
      { label = "Expected", value = Testing.inspect(expected) },
      { label = "Actual", value = Testing.inspect(actual) },
   }
end


function Testing.equal(actual, expected, message)
   if actual == expected then return end
   local details = values(expected, actual)
   if type(actual) == "string" and type(expected) == "string" then
      local a, b = actual, expected
      local index = 1
      while index <= #a and index <= #b and a:byte(index) == b:byte(index) do
         index = index + 1
      end
      details[#details + 1] = { label = "Difference", value = "First differing byte: " .. tostring((index)) }
   end
   Testing.fail(message or "Values differ", details)
end


function Testing.not_equal(actual, other, message)
   if actual == other then
      Testing.fail(message or "Values are equal", {
         { label = "Both values", value = Testing.inspect(actual) },
      })
   end
end







local function difference(actual, expected, path, seen)
   if rawequal(actual, expected) then return nil end
   if type(actual) ~= "table" or type(expected) ~= "table" then
      return { path = path, actual = actual, expected = expected }
   end

   local a, b = actual, expected
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



function Testing.same(actual, expected, message)
   local mismatch = difference(actual, expected, "$", {})
   if mismatch then
      local details = values(mismatch.expected, mismatch.actual)
      table.insert(details, 1, { label = "Path", value = mismatch.path })
      Testing.fail(message or "Contents differ", details)
   end
end


function Testing.near(actual, expected, tolerance, message)
   if not (tolerance >= 0 and tolerance < math.huge) then
      Testing.fail("Tolerance must be a finite, nonnegative number", {
         { label = "Tolerance", value = Testing.inspect(tolerance) },
      })
   end
   if actual == expected then return end
   local delta = actual > expected and actual - expected or expected - actual

   if delta < 0 then delta = math.abs((actual + 0.0) - expected) end
   if delta <= tolerance then return end
   local details = values(expected, actual)
   details[#details + 1] = { label = "Difference", value = tostring(delta) }
   details[#details + 1] = { label = "Tolerance", value = tostring(tolerance) }
   Testing.fail(message or "Numbers differ by more than the tolerance", details)
end


function Testing.contains(actual, fragment, message)
   if not actual:find(fragment, 1, true) then
      Testing.fail(message or "Substring not found", {
         { label = "Substring", value = quote(fragment) },
         { label = "Actual", value = quote(actual) },
      })
   end
end


function Testing.matches(actual, pattern, message)
   if not actual:find(pattern) then
      Testing.fail(message or "Pattern did not match", {
         { label = "Pattern", value = quote(pattern) },
         { label = "Actual", value = quote(actual) },
      })
   end
end

local function error_text(value)
   if type(value) == "string" then return value end
   return Testing.inspect(value)
end



function Testing.raises(action, fragment)
   local ok, thrown = pcall(function()
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

local context_mt = { __index = Testing.Context }
local suite_mt = { __index = Testing.Suite }


function Testing.Context:detail(label, value)
   self._details[#self._details + 1] = { label = label, value = value }
end


function Testing.Context:defer(action)
   self._cleanups[#self._cleanups + 1] = action
end


function Testing.suite(name)
   assert(name ~= "", "Test suite names cannot be empty")
   local suite = { name = name, _entries = {}, _names = {}, _before = {}, _after = {} }
   return setmetatable(suite, suite_mt)
end

local function reserve(suite, name)
   assert(name ~= "", "Test and group names cannot be empty")
   assert(not suite._names[name], "Duplicate test or group name " .. tostring((quote(name))) .. " in " .. tostring((quote(suite.name))))
   suite._names[name] = true
end


function Testing.Suite:group(name)
   reserve(self, name)
   local child = Testing.suite(name)
   self._entries[#self._entries + 1] = { group = child }
   return child
end

local function callback_source(body)
   if debug and debug.getinfo then
      local info = debug.getinfo(body, "S")
      if info and info.linedefined > 0 then return tostring((info.short_src)) .. ":" .. tostring((info.linedefined)) end
   end
end


function Testing.Suite:test(name, body, source)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, body = body, status = "pass", source = source or callback_source(body) },
   }
end


function Testing.Suite:skip(name, reason)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, status = "skip", reason = reason or "Skipped" },
   }
end


function Testing.Suite:todo(name, reason)
   reserve(self, name)
   self._entries[#self._entries + 1] = {
      case = { name = name, status = "todo", reason = reason or "Not implemented yet" },
   }
end



function Testing.Suite:before_each(hook)
   self._before[#self._before + 1] = hook
end



function Testing.Suite:after_each(hook)
   self._after[#self._after + 1] = hook
end

local function invoke(callback, context, result, phase)
   local trace
   local ok, thrown = xpcall(function()
      callback(context)
   end, function(err)
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

local function run_case(case, group, full_name, scopes)
   local result = {
      name = case.name, group = group, full_name = full_name, source = case.source,
      status = case.status, reason = case.reason, details = {}, failures = {}, seconds = 0,
   }
   local body = case.body
   if not body then return result end

   local state = { name = case.name, full_name = full_name, _details = result.details, _cleanups = {} }
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








local function collect(suite, path, ancestors, filter, jobs)
   local scopes = {}
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

local function diagnostics(result, traces)
   local rows = {}
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

local function tap_text(line)
   return (escape_control(line):gsub("#", "\\x23"))
end

local function tap_case(result, index, write, traces)
   local status = result.status
   local ok = (status == "pass" or status == "skip") and "ok" or "not ok"
   local text = tostring((ok)) .. " " .. tostring((index)) .. " - " .. tostring((tap_text(result.full_name)))
   if status == "skip" or status == "todo" then
      local directive = status == "skip" and "SKIP" or "TODO"
      text = text .. " # " .. tostring((directive)) .. " " .. tostring((tap_text(result.reason or '')))
   end
   write(text)
   if status == "fail" then
      for _, row in ipairs(diagnostics(result, traces)) do
         write("# " .. tostring((escape_control(row.label))) .. ": " .. tostring((escape_control(row.value))))
      end
   end
end







local status_marks = {
   pass = { icon = "✓", word = "PASS", color = "1;32" },
   fail = { icon = "✗", word = "FAIL", color = "1;31" },
   skip = { icon = "↷", word = "SKIP", color = "1;33" },
   todo = { icon = "◇", word = "TODO", color = "1;35" },
}






local function reporter(name, total, options)
   local mode = options.format or "pretty"
   local write = options.write or print
   local traces = options.tracebacks == true
   if mode == "silent" then
      return { case = function() end, finish = function() end }
   end
   if mode == "tap" then
      write("TAP version 13")
      write(total == 0 and "1..0 # SKIP No cases selected" or "1.." .. tostring((total)))
      return {
         case = function(result, index) tap_case(result, index, write, traces) end,
         finish = function() end,
      }
   end

   local pretty = mode == "pretty"
   local term = os.getenv("TERM")
   local colored = pretty and (options.color == true or
   (options.color == nil and not options.write and os.getenv("NO_COLOR") == nil and
   term ~= nil and term ~= "" and term ~= "dumb"))
   local function paint(code, value)
      if not colored or value == "" then return value end
      return "\27[" .. code .. "m" .. value .. "\27[0m"
   end

   local title = escape_control(name)
   if pretty then
      write(paint("1;36", "╭─ ✦ " .. tostring((title))))
      write(paint("2", "╰─ " .. tostring((total)) .. " selected"))
   else
      write(tostring((title)) .. " (" .. tostring((total)) .. " selected)")
   end

   local last_group
   return {
      case = function(result, _index)
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
         local timing = options.timings and string.format("  %.2f ms", (result.seconds * 1000)) or ""
         write("  " .. tostring((marker)) .. " " .. tostring((escape_control(result.name))) .. tostring((paint('2', reason_text .. timing))))
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
            write("    " .. tostring((paint('2', stem))) .. " " .. tostring((label)) .. tostring((string.rep(' ', width - #label))) .. "  " .. tostring((value)))
         end
      end,
      finish = function(summary)
         write("")
         local counts = {}
         local function count(status, n, label)
            local marks = status_marks[status]
            local value = tostring((n)) .. " " .. tostring((label))
            counts[#counts + 1] = pretty and paint(marks.color, marks.icon .. " " .. value) or value
         end
         count("pass", summary.passed, "passed")
         count("fail", summary.failed, "failed")
         if summary.skipped > 0 then count("skip", summary.skipped, "skipped") end
         if summary.todo > 0 then count("todo", summary.todo, "todo") end
         counts[#counts + 1] = tostring((summary.total)) .. " total"
         if summary.filtered > 0 then counts[#counts + 1] = tostring((summary.filtered)) .. " filtered" end
         if options.timings then counts[#counts + 1] = string.format("%.2f ms CPU", (summary.seconds * 1000)) end
         local rule = pretty and paint(summary.failed > 0 and "31" or "36", string.rep("━", 44)) or string.rep("-", 44)
         write(rule)
         write("  " .. table.concat(counts, pretty and "  ·  " or "  |  "))
         write(rule)
      end,
   }
end




function Testing.Suite:run(options)
   local opts = options or {}
   local jobs = {}
   local filtered = collect(self, "", {}, opts.filter, jobs)
   local summary = {
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




































































































return Testing
