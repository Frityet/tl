# Test suites with `auxlib.testing`

Create a suite to register tests, run them, and get a report. A failed case
ends its own body, and the runner continues through the other cases. With
the tl checkout's compiler, run the example below using `./tl run example.tl`.
Xmake projects get the module from the `tl.auxlib` target.

```teal
local testing = require("auxlib.testing")
local macro tests! = testing.tests!
local macro expect! = testing.expect!

local function first_word(text: string): string?
   return text:match("^%a+")
end

local suite = testing.suite("Token reader")
tests!(suite, "Words", {
   tests = {
      ["reads the first word"] = first_word("hello world") == "hello",
      ["ignores digits"] = first_word("123") == nil,
      ["checks the token shape"] = function(ctx: testing.Context)
         local input = "Hi 42"
         ctx:detail("Input", input)
         local word = first_word(input)
         expect!(word ~= nil)
         testing.matches(word or "", "^%u%l+$")
      end,
   },
})

local result = suite:run({ filter = arg[1] })
os.exit(result.exit_code)
```

`tests!` registers cases in the order they appear. For `==` and `~=` checks,
the operands are evaluated once at run time. The report shows their values on
failure. Other expressions must be truthy. An inline function receives a
`testing.Context`, which can record diagnostic fields or schedule cleanup.
Use `expect!(expression)` inside a callback for the same comparison diagnostics.

## Callbacks and fixtures

Use `suite:test(name, callback)` to register a callback directly, and
`suite:group(name)` to create a nested suite. Cases and groups run in
declaration order. Names must be unique within their immediate group.
The runtime API also works from Lua with the compiled `auxlib/testing.lua`
on `package.path`.

```teal
local testing = require("auxlib.testing")
local suite = testing.suite("Counter")
local count = 0

suite:before_each(function()
   count = 0
end)

local increments = suite:group("Increment")
increments:test("starts at zero", function(ctx: testing.Context)
   local initial = count
   ctx:defer(function() count = initial end)
   count = count + 1
   testing.equal(count, 1)
end)

increments:skip("platform event", "This fixture is disabled")
increments:todo("counter overflow")

local result = suite:run()
os.exit(result.exit_code)
```

Setup runs from the outer group inward, in registration order. A setup
failure or skip prevents the body from running. Each group whose setup was
entered still runs its `after_each` hooks, from the innermost group outward
and in reverse registration order. Functions registered with `ctx:defer`
run last, in reverse order. A teardown error makes the case fail and is
reported alongside any earlier failure in that case.

`testing.skip(reason)` skips a running case from its body or setup.
`suite:skip(name, reason)` and `suite:todo(name, reason)` record cases
without running their bodies or hooks.

### Custom table-driven checks

Give `tests!` a `check` callback to use `input == expected` as a row of
data. The callback receives the context and both operands and decides what
to assert. A checker factory in the `check` field runs once when the group
is registered.

```teal
local testing = require("auxlib.testing")
local suite = testing.suite("Text")

local function check_bytes(ctx: testing.Context, input: string, expected: integer)
   ctx:detail("Text", testing.inspect(input))
   testing.equal(#input, expected, "Byte count differs")
end

testing.tests!(suite, "Byte count", {
   check = check_bytes,
   tests = {
      ["empty"] = "" == 0,
      ["ASCII"] = "abc" == 3,
      ["UTF-8"] = "é" == 2,
   },
})

os.exit(suite:run().exit_code)
```

## Assertions

| Helper | What it checks |
| --- | --- |
| `ok(value, message?)` | The value is truthy. |
| `equal(actual, expected, message?)` | Lua equality. String failures show the first differing byte. |
| `not_equal(actual, other, message?)` | Lua inequality. |
| `same(actual, expected, message?)` | Recursive comparison that handles cycles and reports the first mismatch path. It compares table keys by identity and ignores metatables. |
| `near(actual, expected, tolerance, message?)` | Absolute numeric difference within a finite, nonnegative tolerance. |
| `contains(actual, substring, message?)` | Literal substring. |
| `matches(actual, pattern, message?)` | Lua pattern match. |
| `raises(callback, substring?)` | The callback throws. Optionally checks its message and returns the original error object. |
| `fail(message, details?)` | Record a custom failure. Details are an array of `{ label = ..., value = ... }` string pairs. |

`testing.inspect(value)` renders values for custom diagnostics. It escapes
control characters and limits how much of a table it prints.

## Reports and results

Pass options to `suite:run` to choose a report or select cases.

| Option | Behavior |
| --- | --- |
| `format` | `"pretty"` uses Unicode and optional color. `"plain"` uses ASCII report markers. `"tap"` writes TAP 13 for automated tools. `"silent"` returns results without writing a report. |
| `filter` | A literal substring of the group path and case name, joined with ` / `. |
| `show_passes` | Set to `false` to hide passing cases in pretty and plain reports. |
| `color` | Explicitly enable or disable color in pretty mode. By default, color requires a usable `TERM`, no `NO_COLOR`, and the default writer. |
| `timings` | Show per-case and total CPU time in pretty and plain reports. |
| `tracebacks` | Include stack traces in the report for unexpected errors when Lua's debug library is available. |
| `write` | Receive each report line without its trailing newline. Defaults to `print`. |

For TAP, direct any logging from the test bodies to a separate stream so
the report can be parsed on its own.

A run returns a fresh summary with `passed`, `failed`, `skipped`, `todo`,
`filtered`, `total`, `seconds`, `exit_code`, and ordered `results`. Each
result has its case name, group path, status, source when available, CPU
seconds, context details, and failures. Failures include the phase, message,
diagnostic fields, and any recorded traceback. Pass `result.exit_code` to
`os.exit` in a test script. A run with failures returns `1`; skips, todos,
and an empty selection return `0` if there are no failures.
