local tl = require("teal.api.v2")
local testing = require("auxlib.testing")

local function run_teal(source)
   local filename = "testing-fixture.tl"
   local ast, syntax_errors = tl.parse(source, filename)
   assert.same({}, syntax_errors)
   local checked = tl.check(ast, filename, { gen_target = "5.1", gen_compat = "off", feat_strict_nil = "on" })
   assert.same({}, checked.type_errors)
   local lua = assert(tl.generate(checked.ast, "5.1"))
   return assert(loadstring(lua, "@" .. filename))()
end

describe("auxlib.testing", function()
   it("registers ordered case expressions and evaluates each operand once at run time", function()
      local before, after, summary = run_teal([[
local testing = require("auxlib.testing")
local macro tests! = testing.tests!
local __testing_library = testing.suite("Numbers")
local __testing_group = 3
local order = ""
local function read(n: integer): integer
   order = order .. tostring(n)
   return n
end
tests!(__testing_library, "Arithmetic", {
   tests = {
      ["captures operands"] = (read(1) == read(2)),
      ["runs after a failure"] = read(3) ~= read(2),
      ["preserves caller bindings"] = __testing_group == 3,
      ["supports truthy expressions"] = read(4),
      ["supports inline callbacks"] = function(ctx: testing.Context)
         ctx:detail("Inputs", "5 and 6")
         testing.expect!(read(5) == read(6))
      end,
   },
})
local before = order
local summary = __testing_library:run({ format = "silent" })
return before, order, summary
]])
      assert.equals("", before)
      assert.equals("1232456", after)
      assert.equals(3, summary.passed)
      assert.equals(2, summary.failed)
      local first = summary.results[1]
      assert.equals("Arithmetic / captures operands", first.full_name)
      assert.matches("^testing%-fixture%.tl:12:%d+$", first.source)
      assert.same({
         { label = "Expected", value = "2" },
         { label = "Actual", value = "1" },
      }, first.failures[1].details)
      assert.same({ { label = "Inputs", value = "5 and 6" } }, summary.results[5].details)
   end)

   it("accepts a typed checker and constructs it once for a group", function()
      local factories, summary = run_teal([[
local testing = require("auxlib.testing")
local record Input
   text: string
end
local suite = testing.suite("Strings")
local factories = 0
local function checker(): function(testing.Context, Input, integer)
   factories = factories + 1
   return function(ctx: testing.Context, input: Input, length: integer)
      ctx:detail("Text", input.text)
      testing.equal(#input.text, length)
   end
end
testing.tests!(suite, "Bytes", {
   check = checker(),
   tests = {
      ["empty"] = { text = "" } == 0,
      ["mixed"] = { text = "teal" } == 3,
   },
})
return factories, suite:run({ format = "silent" })
]])
      assert.equals(1, factories)
      assert.equals(1, summary.passed)
      assert.equals(1, summary.failed)
      assert.equals("teal", summary.results[2].details[1].value)
      assert.equals("4", summary.results[2].failures[1].details[2].value)
   end)

   it("reports malformed suite specifications at compile time", function()
      local _, errors = tl.parse([[
local testing = require("auxlib.testing")
local suite = testing.suite("Example")
testing.tests!(suite, "Bad spec", { tests = { true } })
]], "invalid-tests.tl")
      assert.equals(1, #errors)
      assert.matches("each case needs a literal string name", errors[1].msg, 1, true)
      assert.equals(3, errors[1].y)
   end)

   it("runs nested hooks and deferred cleanups after a failed case", function()
      local suite = testing.suite("Lifecycle")
      local child = suite:group("Child")
      local order = {}
      local function mark(label)
         return function() order[#order + 1] = label end
      end
      suite:before_each(mark("outer setup"))
      suite:after_each(mark("outer teardown"))
      child:before_each(mark("inner setup"))
      child:after_each(mark("first teardown"))
      child:after_each(function()
         mark("second teardown")()
         error("teardown broke", 0)
      end)
      child:test("fails", function(ctx)
         mark("body")()
         ctx:defer(mark("first cleanup"))
         ctx:defer(function()
            mark("second cleanup")()
            error("cleanup broke", 0)
         end)
         testing.equal(2, 3)
      end)
      suite:test("still runs", mark("later case"))

      local summary = suite:run({ format = "silent" })
      assert.same({
         "outer setup", "inner setup", "body", "second teardown",
         "first teardown", "outer teardown", "second cleanup", "first cleanup",
         "outer setup", "later case", "outer teardown",
      }, order)
      assert.equals(1, summary.failed)
      assert.equals(1, summary.passed)
      assert.equals(1, summary.exit_code)
      local failures = summary.results[1].failures
      assert.equals(3, #failures)
      assert.equals("test", failures[1].phase)
      assert.equals("after_each", failures[2].phase)
      assert.equals("teardown broke", failures[2].message)
      assert.equals("cleanup", failures[3].phase)
      assert.matches("stack traceback", failures[3].traceback, 1, true)
   end)

   it("tears down entered groups if setup skips and retains static skips and todos", function()
      local suite = testing.suite("Fixtures")
      local child = suite:group("Unavailable")
      local nested = child:group("Nested")
      local cleaned = {}
      suite:after_each(function() cleaned[#cleaned + 1] = "suite" end)
      child:before_each(function(ctx)
         ctx:defer(function() cleaned[#cleaned + 1] = "deferred" end)
         testing.skip("service unavailable")
      end)
      child:after_each(function() cleaned[#cleaned + 1] = "child" end)
      nested:after_each(function() error("never entered", 0) end)
      nested:test("never called", function() error("setup should stop the body", 0) end)
      suite:skip("optional feature", "disabled")
      suite:todo("remaining case")

      local summary = suite:run({ format = "silent" })
      assert.same({ "child", "suite", "deferred" }, cleaned)
      assert.equals(0, summary.exit_code)
      assert.equals(2, summary.skipped)
      assert.equals(1, summary.todo)
      assert.equals("service unavailable", summary.results[1].reason)
      assert.equals("disabled", summary.results[2].reason)
   end)

   it("reports deep mismatch paths, string differences, and numeric tolerances", function()
      local suite = testing.suite("Assertions")
      suite:test("structural", function()
         local found = { item = { [2] = { label = "Found" } } }
         local wanted = { item = { [2] = { label = "Wanted" } } }
         found.loop, wanted.loop = found, wanted
         testing.same(found, wanted)
      end)
      suite:test("text", function() testing.equal("a\nb", "a\nc") end)
      suite:test("near", function() testing.near(10, 7, 2) end)
      suite:test("supports cycles without reading metatables", function()
         local a, b = {}, {}
         a.self, b.self = a, b
         setmetatable(a, { __index = function() error("unwanted read", 0) end })
         testing.same(a, b)
         testing.contains(testing.inspect(a), "<cycle>")
      end)
      suite:test("raises returns the original error", function()
         local thrown = { message = "missing input" }
         testing.equal(testing.raises(function() error(thrown, 0) end, "missing input"), thrown)
         testing.matches("AB-23", "^%u+%-%d+$")
      end)
      suite:test("detects an unexpectedly successful call", function()
         testing.raises(function() return 1 end)
      end)

      local summary = suite:run({ format = "silent" })
      assert.equals(4, summary.failed)
      assert.equals(2, summary.passed)
      assert.same({
         { label = "Path", value = "$.item[2].label" },
         { label = "Expected", value = '"Wanted"' },
         { label = "Actual", value = '"Found"' },
      }, summary.results[1].failures[1].details)
      assert.equals('"a\\nc"', summary.results[2].failures[1].details[1].value)
      assert.equals("First differing byte: 3", summary.results[2].failures[1].details[3].value)
      assert.equals("2", summary.results[3].failures[1].details[4].value)
      assert.matches("function returned", summary.results[6].failures[1].message, 1, true)
   end)

   it("keeps report modes and run filters independent of case registration", function()
      local suite = testing.suite("Report")
      local child = suite:group("CLI")
      child:test("passes", function() end)
      child:test("fails", function(ctx)
         ctx:detail("Input", "a\n# TODO fake")
         error("unexpected", 0)
      end, "checks.tl:9")
      child:skip("skipped", "host unavailable")
      child:todo("pending", "write spec")
      suite:test("excluded", function() end)

      local function run(options)
         local lines = {}
         options.write = function(line) lines[#lines + 1] = line end
         local summary = suite:run(options)
         return table.concat(lines, "\n"), summary
      end

      local plain, filtered = run({ format = "plain", filter = "CLI /", show_passes = false })
      assert.equals(4, filtered.total)
      assert.equals(1, filtered.filtered)
      assert.matches("FAIL fails", plain, 1, true)
      assert.matches("checks.tl:9", plain, 1, true)
      assert.not_matches("PASS passes", plain, 1, true)
      assert.not_matches("\27[", plain, 1, true)
      assert.not_matches("stack traceback", plain, 1, true)

      local pretty, unfiltered = run({ color = true, timings = true, tracebacks = true })
      assert.equals(5, unfiltered.total)
      assert.matches("◆ CLI", pretty, 1, true)
      assert.matches("\27[1;31m", pretty, 1, true)
      assert.matches("stack traceback", pretty, 1, true)
      assert.matches("ms CPU", pretty, 1, true)

      local tap = run({ format = "tap", filter = "CLI /" })
      assert.matches("^TAP version 13\n1%.%.4\n", tap)
      assert.matches("ok 1 - CLI / passes", tap, 1, true)
      assert.matches("not ok 2 - CLI / fails", tap, 1, true)
      assert.matches("ok 3 - CLI / skipped # SKIP host unavailable", tap, 1, true)
      assert.matches("not ok 4 - CLI / pending # TODO write spec", tap, 1, true)
      assert.matches("a\\n# TODO fake", tap, 1, true)
      local empty_tap, empty = run({ format = "tap", filter = "no match" })
      assert.equals(5, empty.filtered)
      assert.equals(0, empty.exit_code)
      assert.matches("1..0 # SKIP", empty_tap, 1, true)
      local silent, machine = run({ format = "silent" })
      assert.equals("", silent)
      assert.equals(1, machine.exit_code)
      assert.equals(5, #machine.results)
   end)
end)
