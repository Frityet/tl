local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table





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

local function end_of_c_quote(source, start, quote)
   local offset = start + 1
   while offset <= #source do
      local byte = source:byte(offset)
      if byte == quote then return offset end
      offset = offset + (byte == 92 and 2 or 1)
   end
   return #source
end



function model.c_declaration(state, node)
   node = model.unwrap(node)
   if not node or node.kind ~= "string" then return nil end
   local source = node.conststr
   if not source then return nil end
   if source == state.last_c_source then return state.last_c_text end
   local chunks
   local copy_from, cursor = 1, 1
   while true do
      local start = source:find("[/'\"]", cursor)
      if not start then break end
      local byte = source:byte(start)
      local finish
      if byte == 47 then
         local next_byte = source:byte(start + 1)
         if next_byte == 42 then
            local close = source:find("*/", start + 2, true)
            finish = close and close + 1 or #source
         elseif next_byte == 47 then
            local newline = source:find("\n", start + 2, true)
            finish = newline and newline - 1 or #source
         end
      else
         finish = end_of_c_quote(source, start, byte)
      end
      cursor = (finish or start) + 1
      if finish then
         chunks = chunks or {}
         chunks[#chunks + 1] = source:sub(copy_from, start - 1)
         local newlines = source:sub(start, finish):gsub("[^\n]+", "")
         chunks[#chunks + 1] = " " .. newlines
         copy_from = cursor
      end
   end
   local text = source
   if chunks then
      chunks[#chunks + 1] = source:sub(copy_from)
      text = table.concat(chunks)
   end
   state.last_c_source, state.last_c_text = source, text
   return text
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
