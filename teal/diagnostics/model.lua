local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local string = _tl_compat and _tl_compat.string or string





local model = { Rule = {}, RuleInfo = {}, EnabledRule = {}, Plan = {}, State = {} }

























































































function model.unwrap(n)
   while n and (n.kind == "paren" or (n.op and n.op.op == "as")) do
      n = n.e1
   end
   return n
end

function model.number(n)
   n = model.unwrap(n)
   if not n then return nil end
   if n.kind == "number" or n.kind == "integer" then
      return n.constnum
   end
   if n.op and n.op.op == "-" and n.op.arity == 1 then
      local value = model.number(n.e1)
      return value and -value
   end
end

function model.call_args(n)
   n = model.unwrap(n)
   if n and n.op and n.op.op == "@funcall" then
      return n.e2
   end
end

function model.ffi_namespace(path)
   return path == "ffi.C" or path == "ffi.load()"
end

function model.ffi_temporary_symbol(path)
   return path ~= nil and path:sub(1, 16) == "ffi.temporary()."
end

function model.ffi_symbol(path)
   if not path then return false end
   local prefix
   if path:sub(1, 6) == "ffi.C." then
      prefix = "ffi.C."
   elseif path:sub(1, 11) == "ffi.load()." then
      prefix = "ffi.load()."
   elseif model.ffi_temporary_symbol(path) then
      prefix = "ffi.temporary()."
   end
   return prefix ~= nil and #path > #prefix and not path:find(".", #prefix + 1, true)
end

return model
