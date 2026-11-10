--#pragma strict_nil off
local types = require("teal.types")
local type Type = types.Type
local util = require("teal.util")
local sorted_keys = util.sorted_keys

local record c_types
   integer: Repr
   number: Repr
   boolean: Repr
   string: Repr
   nil_value: Repr
   void: Repr
   representation: function(Registry, Type): Repr

   enum Kind
      "integer"
      "number"
      "boolean"
      "string"
      "pointer"
      "nil"
      "void"
      "array"
      "record"
      "function"
   end

   record Repr
      kind: Kind
      ctype: string
      key: string
      nullable: boolean
      payload: Repr -- present only for tagged optional scalars
      element: Repr
      fields: {string:Field}
      params: {Repr}
      result: Repr
   end

   record Field
      name: string
      value: Repr
   end

   record Registry
      cache: {Type:Repr}
      active: {Type:boolean}
      shapes: {string:Repr}
      declarations: {string}
      tags: {string:boolean}
      next_id: integer
      uses_arrays: boolean
   end
end

local type Repr = c_types.Repr
local type Registry = c_types.Registry

c_types.integer = { kind = "integer", ctype = "int64_t", key = "integer" } as Repr
c_types.number = { kind = "number", ctype = "double", key = "number" } as Repr
c_types.boolean = { kind = "boolean", ctype = "_Bool", key = "boolean" } as Repr
c_types.string = { kind = "string", ctype = "const char *", key = "string" } as Repr
c_types.nil_value = { kind = "nil", ctype = "void *", key = "nil", nullable = true } as Repr
c_types.void = { kind = "void", ctype = "void", key = "void" } as Repr

function c_types.new(): Registry
   return { cache = {}, active = {}, shapes = {}, declarations = {}, tags = {}, next_id = 0 }
end

-- Each unit starts with the ABI shapes and can define its own private shapes.
function c_types.fork(public: Registry): Registry
   return {
      cache = util.shallow_copy_table(public.cache),
      shapes = util.shallow_copy_table(public.shapes),
      active = {}, declarations = {}, tags = {}, next_id = public.next_id,
   }
end

function c_types.resolve(t: Type): Type
   if not (t is types.NominalType or t is types.TypeDeclType) then return t end
   local seen: {Type:boolean} = {}
   while t is types.NominalType or t is types.TypeDeclType do
      if seen[t] then return nil end
      seen[t] = true
      if t is types.NominalType then
         t = t.resolved or (t.found and t.found.def)
      else
         t = t.def
      end
   end
   return t
end

function c_types.optional(r: Registry, value: Repr): Repr
   if value.nullable then return value end
   local id = "optional:" .. value.key
   if r.shapes[id] then return r.shapes[id] end

   local out = util.shallow_copy_table(value)
   out.nullable = true
   if value.kind == "integer" or value.kind == "number" or value.kind == "boolean" then
      out.ctype = "tl_native_optional_" .. value.kind
      out.key = id
      out.payload = value
      table.insert(r.declarations, ("typedef struct { _Bool present; %s value; } %s;"):format(value.ctype, out.ctype))
   end
   r.shapes[id] = out
   return out
end

local function layout_key(value: Repr): string
   return value.key .. (value.nullable and "?" or "!")
end

local function fresh(r: Registry, kind: string): string
   r.next_id = r.next_id + 1
   return "tl_native_" .. kind .. "_" .. tostring(r.next_id)
end

local representation: function(Registry, Type): Repr

local function record_repr(r: Registry, t: types.RecordType): Repr
   if t.native_pointer then
      local tag = t.native_pointer:match("(struct [%w_]+) %*$") or t.native_pointer:match("(union [%w_]+) %*$")
      if tag then r.tags[tag] = true end
      return { kind = "pointer", ctype = t.native_pointer, key = "pointer:" .. t.native_pointer }
   end
   if t.is_userdata or t.elements or t.types or (t.meta_field_order and #t.meta_field_order > 0) then return nil end
   local fields: {string:c_types.Field} = {}
   local layout: {string} = { "record" }
   local members: {string} = {}
   for _, name in ipairs(sorted_keys(t.fields)) do
      local typ = t.fields[name]
      if not typ is types.TypeDeclType then
         local value = representation(r, typ)
         if not value then return nil end
         local field = "field_" .. tostring(#members + 1)
         fields[name] = { name = field, value = value }
         table.insert(layout, ("%q:%s"):format(name, layout_key(value)))
         table.insert(members, value.ctype .. " " .. field .. ";")
      end
   end
   local key = table.concat(layout, "|")
   if r.shapes[key] then return r.shapes[key] end
   local tag = fresh(r, "record")
   local out: Repr = { kind = "record", ctype = tag .. " *", key = tag, fields = fields }
   local body = #members > 0 and table.concat(members, " ") or "unsigned char empty;"
   table.insert(r.declarations, ("typedef struct { %s } %s;"):format(body, tag))
   r.shapes[key] = out
   return out
end

local function function_repr(r: Registry, t: types.FunctionType): Repr
   if t.is_method or t.args.is_va or t.rets.is_va or #t.rets.tuple > 1 then return nil end
   local ret = #t.rets.tuple == 0 and c_types.void or representation(r, t.rets.tuple[1])
   if not ret then return nil end
   local params: {Repr} = {}
   local spellings: {string} = {}
   local layout = { "function", layout_key(ret) }
   for _, param in ipairs(t.args.tuple) do
      local value = representation(r, param)
      if not value then return nil end
      table.insert(params, value)
      table.insert(spellings, value.ctype)
      table.insert(layout, layout_key(value))
   end
   local key = table.concat(layout, "|")
   if r.shapes[key] then return r.shapes[key] end
   local name = fresh(r, "function")
   local signature = #spellings > 0 and table.concat(spellings, ", ") or "void"
   table.insert(r.declarations, ("typedef %s (*%s)(%s);"):format(ret.ctype, name, signature))
   local out: Repr = { kind = "function", ctype = name, key = name, params = params, result = ret }
   r.shapes[key] = out
   return out
end

local function make_repr(r: Registry, t: Type): Repr
   if t is types.TupleType then
      if t.is_va or #t.tuple > 1 then return nil end
      if #t.tuple == 0 then return c_types.nil_value end
      return representation(r, t.tuple[1])
   elseif t is types.UnionType then
      local value: Repr
      local nullable = false
      for _, member in ipairs(t.types) do
         local next_value = representation(r, member)
         if not next_value then return nil end
         if next_value.kind == "nil" then
            nullable = true
         elseif not value or value.key == next_value.key then
            value = next_value
            nullable = nullable or value.nullable
         else
            return nil
         end
      end
      if not value then return c_types.nil_value end
      return nullable and c_types.optional(r, value) or value
   elseif t is types.ArrayType then
      local element = representation(r, t.elements)
      if not element or element.nullable then return nil end
      r.uses_arrays = true
      return { kind = "array", ctype = "tl_native_array *", key = "array:" .. element.key, element = element }
   elseif t is types.RecordType then
      return record_repr(r, t)
   elseif t is types.FunctionType then
      return function_repr(r, t)
   end
   if t.typename == "integer" then return c_types.integer end
   if t.typename == "number" then return c_types.number end
   if t.typename == "boolean" then return c_types.boolean end
   if t.typename == "string" or t.typename == "enum" then return c_types.string end
   if t.typename == "nil" then return c_types.nil_value end
end

representation = function(r: Registry, t: Type): Repr
   t = c_types.resolve(t)
   if not t or r.active[t] then return nil end
   if r.cache[t] then return r.cache[t] end
   r.active[t] = true
   local value = make_repr(r, t)
   r.active[t] = nil
   r.cache[t] = value
   return value
end

c_types.representation = representation

return c_types
