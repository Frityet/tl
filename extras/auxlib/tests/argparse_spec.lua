local argparse = require("auxlib.argparse")
local tl = require("teal.api.v2")

describe("auxlib argparse", function()
   it("converts signed integers and rejects invalid or out-of-range values", function()
      assert.equals(-7, argparse.integer("-007"))
      assert.equals(12, argparse.integer("+12"))
      assert.same({ nil, "expected a whole number" }, { argparse.integer("1.5") })
      assert.same({ nil, "whole number is out of range" }, { argparse.integer("18446744073709551616") })
   end)

   it("parses aliases, flags, defaults, repeated options and positional values", function()
      local command = argparse.new({
         name = "copy",
         arguments = {{ name = "path" }},
         options = {
            { name = "-n --copies", default = "1", convert = argparse.integer },
            { name = "--mode", choices = { "fast", "safe" }, count = 1 },
            { name = "-t --tag", target = "tags", count = "*" },
         },
         flags = {
            { name = "--dry-run", default = false },
            { name = "-v --verbose", count = "*" },
         },
      })

      local values, message, status = command:parse({
         "-n2", "--mode=safe", "--tag", "one", "-t", "two", "--dry-run", "-vv", "--", "-path",
      })
      assert.same({ copies = 2, mode = "safe", tags = { "one", "two" }, dry_run = true,
         verbose = 2, path = "-path" }, values)
      assert.is_nil(message)
      assert.equals(0, status)

      values = command:parse({ "--mode", "fast", "src" })
      assert.same({ copies = 1, mode = "fast", tags = {}, dry_run = false, verbose = 0, path = "src" }, values)
   end)

   it("returns validation errors and help with the appropriate status", function()
      local command = argparse.new({
         name = "copy",
         description = "Copy files.",
         arguments = {{ name = "path", metavar = "FILE" }},
         options = {{ name = "--copies", convert = argparse.integer }},
      })

      local values, message, status = command:parse({ "--copies", "1.5", "path" })
      assert.is_nil(values)
      assert.matches("expected a whole number", message, 1, true)
      assert.equals(2, status)

      values, message, status = command:parse({})
      assert.is_nil(values)
      assert.matches("missing argument 'path'", message, 1, true)
      assert.equals(2, status)

      values, message, status = command:parse({ "--help" })
      assert.is_nil(values)
      assert.equals(command:help(), message)
      assert.matches(command:usage(), message, 1, true)
      assert.matches("Copy files.", message, 1, true)
      assert.matches("FILE", message, 1, true)
      assert.equals(0, status)
   end)

   it("dispatches nested commands and uses their help and validation", function()
      local command = argparse.new({
         name = "tool",
         command_target = "group",
         commands = {{
            name = "cache c",
            command_target = "action",
            commands = {{
               name = "get",
               description = "Read a cached value.",
               arguments = {{ name = "key", target = "id", convert = argparse.integer }},
            }},
         }},
      })

      local values, message, status = command:parse({ "c", "get", "42" })
      assert.same({ group = "cache", action = "get", id = 42, cache = true, get = true }, values)
      assert.is_nil(message)
      assert.equals(0, status)

      values, message, status = command:parse({ "cache", "get", "-h" })
      assert.is_nil(values)
      assert.matches("Usage: tool cache get", message, 1, true)
      assert.matches("Read a cached value.", message, 1, true)
      assert.equals(0, status)

      values, message, status = command:parse({ "cache" })
      assert.is_nil(values)
      assert.matches("a command is required", message, 1, true)
      assert.equals(2, status)
   end)

   it("accepts advanced backend configuration", function()
      local command = argparse.new({
         name = "tool",
         configure = function(parser)
            local quiet = parser:flag("--quiet")
            local verbose = parser:flag("--verbose")
            parser:mutex(quiet, verbose)
         end,
      })

      local values, message, status = command:parse({ "--quiet", "--verbose" })
      assert.is_nil(values)
      assert.matches("can not be used together", message, 1, true)
      assert.equals(2, status)
   end)

   it("generates typed parse, help and usage functions for a decorated record", function()
      local ast, syntax_errors = tl.parse([[
         local cli = require("auxlib.argparse")
         local macro parser! = cli.parser!
         local record options<parser!({
            name = "copy",
            options = {{ name = "-n --copies", default = "1", convert = cli.integer }},
         })>
            copies: integer
         end
         local values, message, status = options.parse({"-n", "2"})
         assert(values and message == nil and status == 0)
         local count: integer = values.copies
         assert(count == 2)
         assert(options.help():find(options.usage(), 1, true))
      ]], "argparse-fixture.tl")
      assert.same({}, syntax_errors)
      local result = tl.check(ast, "argparse-fixture.tl", {
         gen_target = "5.1", gen_compat = "off", feat_strict_nil = "on",
      })
      assert.same({}, result.type_errors)
      assert(loadstring((tl.generate(result.ast, "5.1"))))()
   end)
end)
