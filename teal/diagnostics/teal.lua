local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs
local model = require("teal.diagnostics.model")
local types = require("teal.types")







local primitive = {
   ["boolean"] = true, ["integer"] = true, ["number"] = true, ["string"] = true,
   ["nil"] = true, ["thread"] = true, ["userdata"] = true,
}

local known_non_nil = {
   ["boolean"] = true, ["integer"] = true, ["number"] = true, ["string"] = true,
   ["thread"] = true, ["userdata"] = true, ["enum"] = true, ["function"] = true,
   ["array"] = true, ["map"] = true, ["record"] = true, ["tupletable"] = true, ["emptytable"] = true,
}

local function single(t)
   return t and types.untuple(t)
end

local function cannot_be_nil(t)
   if not t then return false end
   if t.typename == "union" then
      for _, member in ipairs(t.types) do
         if not cannot_be_nil(member) then return false end
      end
      return #t.types > 0
   end
   return known_non_nil[t.typename] or false
end

local function can_be_nil(t)
   if not t then return false end
   if t.typename == "union" then
      for _, member in ipairs(t.types) do
         if can_be_nil(member) then return true end
      end
   end
   return t.typename == "nil"
end

local function boolean_or_nil(t)
   if not t then return false, false end
   if t.typename == "nil" then return true, false end
   if t.typename == "boolean" then return true, t.literal ~= true end
   if t.typename == "union" then
      local can_be_false = false
      for _, member in ipairs(t.types) do
         local valid, admits_false = boolean_or_nil(member)
         if not valid then return false, false end
         can_be_false = can_be_false or admits_false
      end
      return true, can_be_false
   end
   return false, false
end

local function op(id, severity, description, operators, check)
   return {
      id = "teal/" .. id, severity = severity, description = description,
      kinds = { "op" }, operators = operators, check = check,
   }
end

local rules = {
   op("cast-to-any", "info", "Find casts that remove type information.", { "as" },
   function(s, n, _t, children)
      local original, cast = single(children[1]), children[3]
      if original and cast and original.typename ~= "any" and original.typename ~= "invalid" and cast.typename == "any" then
         s:emit(n.e2, "A cast to any removes static type checks for this value. Keep the specific type if possible.")
      end
   end),
   op("cast-from-any", "warning", "Find casts from any to a specific type.", { "as" },
   function(s, n, _t, children)
      local original, cast = single(children[1]), children[3]
      if original and cast and original.typename == "any" and cast.typename ~= "any" and cast.typename ~= "invalid" then
         s:emit(n.e2, "This cast sets a type without a runtime check. Check untyped input before use.")
      end
   end),
   op("cast-can-hide-nil", "warning", "Find casts from a nullable value to a non-nil type.", { "as" },
   function(s, n, _t, children)
      if can_be_nil(single(children[1])) and cannot_be_nil(children[3]) then
         s:emit(n.e2, "This cast can hide a nil value from the checker. Add a nil check before the cast. You can also use a fallback value.")
      end
   end),
   op("redundant-primitive-cast", "hint", "Find variable casts to their existing primitive type.", { "as" },
   function(s, n, _t, children)
      local original, cast = single(children[1]), children[3]
      if n.e1.kind == "variable" and original and cast and primitive[cast.typename] and original.typename == cast.typename then
         s:emit(n.e2, "The variable already has this primitive type.")
      end
   end),
   op("redundant-type-test", "hint", "Find primitive type tests that the static type already satisfies.", { "is" },
   function(s, n, _t, children)
      local original, test = single(children[1]), children[3]
      if s.strict_nil and n.e1.kind == "variable" and original and test and primitive[test.typename] and
         (original.typename == test.typename or (original.typename == "integer" and test.typename == "number")) then
         s:emit(n.e2, "The static type of this variable already satisfies this test.")
      end
   end),
   op("nil-coalescing-always-falls-back", "info", "Find nil-coalescing expressions whose left side is always nil.", { "??" },
   function(s, n, _t, children)
      local left = single(children[1])
      if left and left.typename == "nil" then
         s:emit(n.e1, "The left operand has type nil. This expression always uses its fallback.")
      end
   end),
   op("nil-coalescing-unreachable-fallback", "hint", "Find fallback expressions for values with non-nil types.", { "??" },
   function(s, n, _t, children)
      if s.strict_nil and cannot_be_nil(single(children[1])) then
         s:emit(n.e2, "The left operand has a non-nil type. The declared types make this fallback unreachable.")
      end
   end),
   op("optional-chain-always-nil", "warning", "Find optional accesses that always stop at a nil receiver.", { ".", ":", "@index", "@funcall" },
   function(s, n, _t, _children)
      if n.safe_navigation and n.chain_always_nil and not n.e1.chain_always_nil then
         s:emit(n, "This optional access stops at a nil receiver. It skips the rest of the chain.")
      end
   end),
   op("optional-chain-non-nil-receiver", "hint", "Find optional accesses on non-nil receiver types.", { ".", ":", "@index", "@funcall" },
   function(s, n, _t, children)
      if s.strict_nil and n.safe_navigation and not n.e1.optional_chain and cannot_be_nil(single(children[1])) then
         s:emit(n, "This receiver has a non-nil type. The declared types make optional access unnecessary.")
      end
   end),
   op("boolean-default-masks-false", "warning", "Find boolean defaults that replace false with true.", { "or" },
   function(s, n, _t, children)
      local right = model.unwrap(n.e2)
      if right and right.kind == "boolean" and right.tk == "true" then
         local valid, can_be_false = boolean_or_nil(single(children[1]))
         if valid and can_be_false then
            s:emit(n, "This default replaces false with true. Use ?? true to default only when the value is nil.")
         end
      end
   end),
   {
      id = "teal/strict-nil-disabled", severity = "info",
      description = "Find pragmas that disable strict nil checking.", kinds = { "pragma" },
      check = function(s, n, _t, _children)
         if n.pkey == "strict_nil" and n.pvalue == "off" then
            s:emit(n, "This pragma disables strict nil checking. Use explicit optional types where the affected code permits it.")
         end
      end,
   },
   {
      id = "teal/arity-disabled", severity = "info",
      description = "Find pragmas that disable minimum argument counts.", kinds = { "pragma" },
      check = function(s, n, _t, _children)
         if n.pkey == "arity" and n.pvalue == "off" then
            s:emit(n, "This pragma disables minimum argument checks. Mark optional parameters explicitly where possible.")
         end
      end,
   },
   {
      id = "teal/any-parameter", severity = "info",
      description = "Find parameters explicitly annotated as any.", kinds = { "argument" },
      check = function(s, n, _t, _children)
         if n.argtype and n.argtype.typename == "any" then
            s:emit(n, "This parameter accepts any value. A type parameter or a more specific type can keep checks for callers.")
         end
      end,
   },
   {
      id = "teal/any-return", severity = "info",
      description = "Find return annotations that expose any to callers.",
      kinds = { "local_function", "global_function", "record_function", "function" },
      check = function(s, n, _t, _children)
         if n.has_return_annotation then
            for i, ret in ipairs(n.rets.tuple) do
               if ret.typename == "any" then
                  s:emit(n.name or n, "Return value " .. i .. " has type any. Use a more specific type for this value.")
               end
            end
         end
      end,
   },
   {
      id = "teal/any-variable", severity = "info",
      description = "Find variables explicitly annotated as any.", kinds = { "local_declaration", "global_declaration" },
      check = function(s, n, _t, _children)
         if n.decltuple then
            for i, var in ipairs(n.vars) do
               local annotation = n.decltuple.tuple[i]
               if annotation and annotation.typename == "any" then
                  s:emit(var, "This variable has type any. This type disables many checks on its uses.")
               end
            end
         end
      end,
   },
}

return rules
