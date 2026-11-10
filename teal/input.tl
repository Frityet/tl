--#pragma strict_nil off
local check = require("teal.check.check")

local parser = require("teal.parser")
local type Node = parser.Node

local type environment = require("teal.environment")
local type Env = environment.Env
local type Result = environment.Result

local record input
end

function input.check(env: Env, filename: string, code: string, mode?: environment.CheckMode): Result
   local cached = env.loaded and env.loaded[filename]
   if cached and (mode ~= "native_import" or not cached.ast or cached.ast.native_checked ~= nil) then
      return cached
   end

   local program, syntax_errors = parser.parse(code, filename)

   if (not env.keep_going) and #syntax_errors > 0 then
      return environment.register_failed(env, filename, syntax_errors)
   end

   local result = check.check(program as Node, env, filename, mode)

   result.syntax_errors = syntax_errors

   return result
end

return input
