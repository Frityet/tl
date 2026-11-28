local lfs = require("lfs")
local lsp = require("spec.lsp_util")
local util = require("spec.util")

local function command(status, ...)
   local pd = assert(io.popen(util.tl_cmd(...) .. "2>&1", "r"))
   local output = assert(pd:read("*a"))
   util.assert_popen_close(status, pd:close())
   return output
end

describe("tl check diagnostics", function()
   it("validates rule names and uses check as the CLI entry point", function()
      local dir = util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = 'return {diagnostics = {lua = {typo = "info"}}}',
         ["example.tl"] = 'print(1)',
      })
      util.do_in(dir, function()
         local reason = command(1, "check", "example.tl")
         assert.match('unknown diagnostic selector "lua/typo"', reason, 1, true)
         assert.match("unknown command", command(1, "diagnostics"), 1, true)
      end)
   end)

   it("validates the project diagnostics table and pack tables", function()
      local cases = {
         { 'diagnostics = true', 'in key "diagnostics": Use a table of diagnostic packs.' },
         { 'diagnostics = { [1] = {} }', 'Use pack names as string keys.' },
         { 'diagnostics = { luajitt = {} }', 'Unknown diagnostic pack "luajitt".' },
         { 'diagnostics = { lua = true }', 'in key "diagnostics.lua": Use a table of diagnostic rules.' },
         { 'diagnostics = { lua = { [1] = "off" } }', 'Use rule names as string keys.' },
         { 'diagnostics = { lua = { all = "note" } }', 'invalid level for "lua"' },
         { 'lua = { all = true }', 'Move this pack to the diagnostics table.' },
      }
      for _, case in ipairs(cases) do
         local dir = util.write_tmp_dir(finally, {
            ["tlconfig.lua"] = 'return { ' .. case[1] .. ' }',
            ["example.tl"] = 'print(1)',
         })
         util.do_in(dir, function()
            assert.match(case[2], command(1, "check", "example.tl"), 1, true)
         end)
      end
   end)

   it("uses local rule names and limits diagnostic errors to check", function()
      local dir = util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = [[return {
            diagnostics = {
               teal = { ["cast-can-hide-nil"] = "error" },
               lua = { all = "error", ["truthy-zero-or-empty"] = "off" },
            },
         }]],
         ["example.tl"] = [[local function f(x: number | nil): number
   return x as number
end
if 0 then print(f(1)) end]],
      })
      util.do_in(dir, function()
         local out = command(1, "check", "example.tl")
         assert.match("error [teal/cast-can-hide-nil]", out, 1, true)
         assert.is_nil(out:find("lua/truthy-zero-or-empty", 1, true))
         local generated = command(0, "gen", "example.tl", "-o", "generated.lua")
         assert.is_nil(generated:find("teal/cast-can-hide-nil", 1, true))
         assert.equals("file", lfs.attributes("generated.lua", "mode"))
      end)
   end)

   it("infers the LuaJIT analysis target from the selected packs", function()
      local dir = util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = 'return {gen_target = "5.1", diagnostics = {luajit = { ["hot-print"] = "warning" }}}',
         ["example.tl"] = 'for i = 1, 100 do print(i) end',
      })
      util.do_in(dir, function()
         assert.match("warning [luajit/hot-print]", command(0, "check", "example.tl"), 1, true)
      end)
   end)

   it("enables LuaJIT FFI diagnostics through the FFI pack table", function()
      local dir = util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = [[return {
            gen_target = "5.1",
            diagnostics = { ["luajit-ffi"] = { ["cdef-preprocessor"] = "warning" } },
         }]],
         ["example.tl"] = [[local ffi = require("ffi")
ffi.cdef("#define SIZE 1")]],
      })
      util.do_in(dir, function()
         assert.match("warning [luajit-ffi/cdef-preprocessor]", command(0, "check", "example.tl"), 1, true)
      end)
   end)

   it("maps stable rule codes, severities and UTF-16 ranges into LSP diagnostics", function()
      local dir = util.write_tmp_dir(finally, {
         ["tlconfig.lua"] = [[return {
            diagnostics = {
               lua = { ["truthy-zero-or-empty"] = "hint" },
               luajit = { ["loop-closure"] = "warning" },
            },
            lsp = { diagnostics_debounce_ms = 0 },
         }]],
      })
      util.do_in(dir, function()
         local prefix = 'print("🚀") if '
         local document = lsp.document(finally, prefix .. [[0 then end
for i = 1, 64 do
   local function item(): integer return i end
   print(item())
end
error("the fixture must only be checked")]])
         local responses, notifications = lsp.exchange(finally, {
            {jsonrpc = "2.0", id = 1, method = "initialize", params = {}},
            {jsonrpc = "2.0", method = "textDocument/didOpen", params = {textDocument = document}},
            {jsonrpc = "2.0", id = 2, method = "textDocument/diagnostic", params = {textDocument = {uri = document.uri}}},
            {jsonrpc = "2.0", id = 3, method = "shutdown", params = {}},
            {jsonrpc = "2.0", method = "exit", params = {}},
         })
         local findings = responses[2].items
         assert.equals(2, #findings)
         local finding = findings[1]
         assert.equals("lua/truthy-zero-or-empty", finding.code)
         assert.equals(4, finding.severity)
         assert.same({start = {line = 0, character = #prefix - 2}, ["end"] = {line = 0, character = #prefix - 1}}, finding.range)
         assert.equals("luajit/loop-closure", findings[2].code)
         assert.equals(2, findings[2].severity)
         local published
         for _, notification in ipairs(notifications) do
            if notification.method == "textDocument/publishDiagnostics" then
               published = notification.params.diagnostics
            end
         end
         assert.same(findings, published)
      end)
   end)
end)
