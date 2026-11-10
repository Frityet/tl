local teal = require("teal")
local tl = require("tl")
local util = require("spec.util")
local load_chunk = loadstring or load

describe("conditional compilation", function()
   it("includes enabled code in the enclosing scope and skips inactive code", function()
      local compiler = teal.compiler({ defines = { PROFILE = "debug", LEVEL = 2, DISABLED = false } })
      local input = assert(compiler:input(([===[
--[[
#if MISSING then
this is not valid Teal !!!
#end
]]
--[=[
#if TL_NG and not DISABLED and (PROFILE == "debug" and LEVEL == 2) then
local answer: integer = 40
--[==[
#if STRICT_NIL then
answer = answer + 2
#end
]==]
#end
]=]
return answer
]===]):gsub("\n", "\r\n"), "enabled.tl"))
      local code, _, err = input:gen()
      assert.same({}, err.syntax_errors)
      assert.same({}, err.type_errors)
      assert.equals(42, assert(load_chunk(code))())
   end)

   it("honours strict-nil defaults and preceding pragmas", function()
      local env = assert(tl.new_env({ defaults = { feat_strict_nil = "off", defines = { OFFSET = 2 } } }))
      local code, result = tl.gen([==[
--[=[
#if not STRICT_NIL and OFFSET == 2 then
local result: integer = 40
#end
]=]
--#pragma strict_nil on
--[=[
#if STRICT_NIL then
result = result + 2
#end
]=]
return result
]==], env)
      assert.same({}, result.syntax_errors)
      assert.same({}, result.type_errors)
      assert.equals(42, assert(load_chunk(code))())
   end)

   it("finds guarded macros in imported modules", function()
      util.mock_io(finally, {
         ["macs.tl"] = [==[
local record Macros end
--[=[
#if EXTRA and not STRICT_NIL then
macro Macros.answer!(): Expression
   return `42`
end
#end
]=]
return Macros
]==],
      })
      local compiler = teal.compiler({ defines = { EXTRA = true } })
      local input = assert(compiler:input([[
--#pragma strict_nil off
local macros = require("macs")
return macros.answer!()
]], "main.tl"))
      local code, _, err = input:gen()
      assert.same({}, err.syntax_errors)
      assert.same({}, err.type_errors)
      assert.matches("return 42", code, 1, true)
   end)

   it("keeps source positions inside an enabled block", function()
      local env = assert(tl.new_env({ defaults = { defines = { ENABLED = true } } }))
      local result = tl.check_string([==[
--[=[
#if ENABLED then
   local n: number = "wrong"
#end
]=]
]==], env)
      assert.same({}, result.syntax_errors)
      assert.equals(3, result.type_errors[1].y)
      assert.equals(22, result.type_errors[1].x)
   end)

   it("reports malformed directives at the header", function()
      local _, errs = tl.lex([==[
--[=[
   #if TL_NG then
print("missing footer")
]=]
--[=[
   #if print("never executed") then
#end
]=]
]==], "invalid.tl")
      assert.equals(2, #errs)
      assert.same({ 2, 4 }, { errs[1].y, errs[1].x })
      assert.matches("expected '#end'", errs[1].msg, 1, true)
      assert.same({ 6, 4 }, { errs[2].y, errs[2].x })
      assert.matches("invalid conditional compilation condition", errs[2].msg, 1, true)
   end)

   it("leaves directive-looking text in Lua comments and Teal strings alone", function()
      local source = [===[
--[=[
#if TL_NG then
invalid code !!!
#end
]=]
return [==[
--[=[
#if TL_NG then
this is a string
#end
]=]
]==]
]===]
      local tokens, errs = tl.lex(source, "compat.lua")
      assert.same({}, errs)
      assert.equals("return", tokens[1].tk)
      assert.matches("this is a string", tokens[2].tk, 1, true)
      tokens, errs = tl.lex(source:sub((source:find("return", 1, true))), "string.tl")
      assert.same({}, errs)
      assert.matches("this is a string", tokens[2].tk, 1, true)
   end)
end)
