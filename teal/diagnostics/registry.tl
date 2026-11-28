--#pragma strict_nil off
local type model = require("teal.diagnostics.model")
local type targets = require("teal.gen.targets")
local type Rule = model.Rule
local type Pack = model.Pack
local type Options = model.Options
local type Level = model.Level
local type GenTarget = targets.GenTarget

local record registry
end

local record Entry
   rule: Rule
   pack: Pack
end

local packs: {Pack} = { "teal", "lua", "luajit", "luajit-ffi" }

local function combine(a: {Rule}, b: {Rule}): {Rule}
   local result: {Rule} = {}
   for _, rule in ipairs(a) do result[#result + 1] = rule end
   for _, rule in ipairs(b) do result[#result + 1] = rule end
   return result
end

local loaders <total>: {Pack: function(): {Rule}} = {
   ["teal"] = function(): {Rule} return require("teal.diagnostics.teal") end,
   ["lua"] = function(): {Rule} return require("teal.diagnostics.lua") end,
   ["luajit"] = function(): {Rule}
      local trace_calls = require("teal.diagnostics.luajit")
      local loop_rules = require("teal.diagnostics.luajit_loops")
      return combine(trace_calls, loop_rules)
   end,
   ["luajit-ffi"] = function(): {Rule}
      local ffi = require("teal.diagnostics.luajit_ffi")
      local namespaces = require("teal.diagnostics.ffi_namespaces")
      return combine(ffi, namespaces)
   end,
}

local levels <total>: {Level: boolean} = {
   ["off"] = true,
   ["error"] = true,
   ["warning"] = true,
   ["info"] = true,
   ["hint"] = true,
}

local pack_names = loaders as {string: function(): {Rule}}
local level_names = levels as {string: boolean}
local entries: {Pack: {Entry}} = {}
local rules_by_id: {string: Entry} = {}

local function load_pack(pack: Pack): {Entry}
   if entries[pack] then return entries[pack] end
   local found: {Entry} = {}
   for _, rule in ipairs(loaders[pack]()) do
      assert(rule.id:sub(1, #pack + 1) == pack .. "/" and not rules_by_id[rule.id], rule.id)
      local entry = { rule = rule, pack = pack }
      rules_by_id[rule.id] = entry
      found[#found + 1] = entry
   end
   table.sort(found, function(a: Entry, b: Entry): boolean return a.rule.id < b.rule.id end)
   entries[pack] = found
   return found
end

function registry.validate(options: any): {string}
   local problems: {string} = {}
   if options == nil then return problems end
   if not options is table then
      return { "expected a table of diagnostic settings" }
   end
   for selector, level in pairs(options as {any: any}) do
      if not selector is string then
         problems[#problems + 1] = "expected string keys in diagnostic settings"
      else
         if selector ~= "all" and not pack_names[selector] then
            local pack = selector:match("^([^/]+)/")
            if pack and pack_names[pack] then load_pack(pack as Pack) end
            if not rules_by_id[selector] then
               problems[#problems + 1] = ("unknown diagnostic selector %q"):format(selector)
            end
         end
         if not (level is boolean) and not (level is string and level_names[level]) then
            problems[#problems + 1] = ("invalid level for %q (expected true, false, off, error, warning, info, or hint)"):format(selector)
         end
      end
   end
   table.sort(problems)
   return problems
end

local function validate(options: Options)
   local problems = registry.validate(options)
   if #problems > 0 then
      error("invalid diagnostics configuration:\n" .. table.concat(problems, "\n"), 3)
   end
end

local function available(pack: Pack, target: GenTarget): boolean
   return (pack ~= "luajit" and pack ~= "luajit-ffi") or target == "luajit"
end

local function configured_level(options: Options, pack: Pack, rule: Rule): Level
   local setting = options[rule.id]
   if setting == nil then setting = options[pack] end
   if setting == nil then setting = options["all"] end
   if setting == true then return rule.severity as Level end
   if not setting then return "off" end
   return setting as Level
end

function registry.catalog(options: Options, target: GenTarget): {model.RuleInfo}
   validate(options)
   options = options or {}
   local catalog: {model.RuleInfo} = {}
   for _, pack in ipairs(packs) do
      local compatible = available(pack, target)
      for _, entry in ipairs(load_pack(pack)) do
         local rule = entry.rule
         catalog[#catalog + 1] = {
            id = rule.id,
            pack = pack,
            description = rule.description,
            default_severity = rule.severity,
            available = compatible,
            level = compatible and configured_level(options, pack, rule) or "off",
         }
      end
   end
   return catalog
end

local function register<K>(routes: {K: {model.EnabledRule}}, key: K, rule: model.EnabledRule)
   local list = routes[key]
   if not list then
      list = {}
      routes[key] = list
   end
   list[#list + 1] = rule
end

function registry.plan(options: Options, target: GenTarget): model.Plan
   if options == nil then return nil end
   validate(options)

   local selected_packs: {Pack: boolean} = {}
   local all = options["all"]
   for selector, setting in pairs(options) do
      if setting and setting ~= "off" and selector ~= "all" then
         local entry = rules_by_id[selector]
         local pack = entry and entry.pack or selector as Pack
         selected_packs[pack] = true
      end
   end

   local plan: model.Plan
   for _, pack in ipairs(packs) do
      if available(pack, target) and (selected_packs[pack] or (all and all ~= "off")) then
         for _, entry in ipairs(load_pack(pack)) do
            local rule = entry.rule
            local level = configured_level(options, pack, rule)
            if level ~= "off" then
               plan = plan or { by_kind = {}, by_operator = {}, by_call = {}, by_hot_call = {}, teal_only = true }
               local enabled: model.EnabledRule = {
                  id = rule.id, severity = level as model.Severity, check = rule.check,
                  teal_only = pack == "teal", in_loop = rule.in_loop,
               }
               plan.bindings = plan.bindings or rule.bindings or rule.calls ~= nil or rule.c_symbols
               plan.ffi_origins = plan.ffi_origins or rule.ffi_origins or rule.c_symbols
               plan.teal_only = plan.teal_only and enabled.teal_only
               plan.track_loops = plan.track_loops or rule.in_loop
               for _, kind in ipairs(rule.kinds) do
                  if kind == "op" and (rule.calls or rule.c_symbols) then
                     if rule.calls then
                        local routes = rule.in_loop and plan.by_hot_call or plan.by_call
                        for _, call in ipairs(rule.calls) do register(routes, call, enabled) end
                     end
                     if rule.c_symbols then
                        if rule.in_loop then
                           plan.hot_c_symbols = plan.hot_c_symbols or {}
                           plan.hot_c_symbols[#plan.hot_c_symbols + 1] = enabled
                        else
                           plan.c_symbols = plan.c_symbols or {}
                           plan.c_symbols[#plan.c_symbols + 1] = enabled
                        end
                     end
                  elseif kind == "op" and rule.operators then
                     for _, op in ipairs(rule.operators) do register(plan.by_operator, op, enabled) end
                  else
                     register(plan.by_kind, kind, enabled)
                  end
               end
            end
         end
      end
   end
   return plan
end

return registry
