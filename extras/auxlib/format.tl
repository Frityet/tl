--#pragma strict_nil on
local record Format end

--- Interpolate a literal string, with optional printf-style format specifiers.
---
--- ```teal
--- local format = require("auxlib.format")
--- local macro f! = format.f!
--- local name = "Ada"
--- local price = 12.345
--- local message = f!"Hello {name}, price {price:.2f}" -- Hello Ada, price 12.35
--- local code = f!"{42:04d} {255:08x}" -- 0042 000000ff
--- ```
---
--- Fields contain ordinary Teal expressions, including member access, indexing and calls.
--- Each field is evaluated once, from left to right, and is checked in the caller's
--- lexical scope. Plain fields use tostring, including boolean and nil values.
--- Escape literal braces with {{ and }}. Normal Lua string escapes and long-bracket
--- strings are supported. Parenthesize expressions with an otherwise ambiguous colon.
---
--- A field `{value:spec}` uses string.format with one conversion. A leading % is
--- optional. Examples: `.2f` (decimal places), `04d` (zero-padded integer), `08x`
--- (hexadecimal), `+8.2f` (signed number), `10s` (right alignment), `-10s` (left
--- alignment), `.3s` (string truncation), `e`/`g` (scientific/general notation),
--- `o` (octal), `c` (character) and `q` (quoted string). Width and precision are
--- limited to 99, matching Lua's format syntax. Dynamic widths are not supported.
--- Plain templates compile to concatenation; a template with format specs uses
--- one string.format call. No runtime parts table or formatter module is needed.
--- @param template Literal string whose fields are expanded at compile time.
--- @return An expression producing one string, with no runtime auxlib dependency.
macro Format.f!(template: Expression): Expression
   assert(template.kind == "string", "f!: expected a literal string")
   local B = BLOCK_INDEXES

   local function utf8_character(code)
      assert(code <= 0x10ffff and not (code >= 0xd800 and code <= 0xdfff), "f!: invalid Unicode escape")
      if code < 0x80 then return string.char(code) end
      if code < 0x800 then return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64) end
      if code < 0x10000 then
         return string.char(0xe0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
      end
      return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
         0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
   end

   local function decode_literal(raw)
      local opening = raw:match("^%[=*%[")
      if opening then
         local text = raw:sub(#opening + 1, -#opening - 1):gsub("\r\n", "\n"):gsub("\r", "\n")
         return text:sub(1, 1) == "\n" and text:sub(2) or text
      end
      local text = raw:sub(2, -2)
      local escapes = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
         ["\\"] = "\\", ['"'] = '"', ["'"] = "'"}
      local result, index = {}, 1
      while index <= #text do
         local char = text:sub(index, index)
         if char ~= "\\" then
            table.insert(result, char)
            index = index + 1
         else
            index = index + 1
            local escape = text:sub(index, index)
            if escapes[escape] then
               table.insert(result, escapes[escape]); index = index + 1
            elseif escape == "z" then
               index = index + 1
               while text:sub(index, index):match("%s") do index = index + 1 end
            elseif escape == "x" then
               table.insert(result, string.char(assert(tonumber(text:sub(index + 1, index + 2), 16))))
               index = index + 3
            elseif escape == "u" then
               local digits = assert(text:sub(index):match("^u{(%x+)}"), "f!: invalid Unicode escape")
               table.insert(result, utf8_character(assert(tonumber(digits, 16))))
               index = index + #digits + 3
            elseif escape:match("%d") then
               local digits = text:sub(index):match("^%d%d?%d?")
               table.insert(result, string.char(assert(tonumber(digits))))
               index = index + #digits
            elseif escape == "\n" or escape == "\r" then
               table.insert(result, "\n")
               index = index + (text:sub(index, index + 1) == "\r\n" and 2 or 1)
            else
               error("f!: invalid string escape", 0)
            end
         end
      end
      return table.concat(result)
   end

   local function literal(text)
      local node = block("string")
      node.tk = string.format("%q", text)
      return node
   end

   local text = decode_literal(template.tk)
   local pieces, pending, format_parts, format_arguments = {}, {}, {}, {}
   local uses_format = false
   local function flush()
      if #pending > 0 then
         local part = table.concat(pending)
         table.insert(pieces, literal(part))
         table.insert(format_parts, (part:gsub("%%", "%%%%")))
         pending = {}
      end
   end

   local function skip_quote(index)
      local quote = text:sub(index, index)
      index = index + 1
      while index <= #text do
         local char = text:sub(index, index)
         if char == "\\" then index = index + 2
         elseif char == quote then return index + 1
         else index = index + 1 end
      end
      error("f!: unterminated string in interpolation field", 0)
   end
   local function skip_long(index)
      local equals = text:sub(index):match("^%[(=*)%[")
      if equals == nil then return nil end
      local closing = "]" .. equals .. "]"
      local finish = text:find(closing, index + #equals + 2, true)
      assert(finish, "f!: unterminated long string or comment in interpolation field")
      return finish + #closing
   end
   local function field(index)
      local start, stack = index, {}
      while index <= #text do
         local char = text:sub(index, index)
         local long_end = char == "[" and skip_long(index)
         if char == '"' or char == "'" then
            index = skip_quote(index)
         elseif long_end then
            index = long_end
         elseif text:sub(index, index + 1) == "--" then
            local comment_end = skip_long(index + 2)
            index = comment_end or (text:find("\n", index + 2, true) or (#text + 1))
         elseif char == "(" or char == "[" or char == "{" then
            table.insert(stack, char == "(" and ")" or (char == "[" and "]" or "}"))
            index = index + 1
         elseif char == "}" and #stack == 0 then
            return text:sub(start, index - 1), nil, index + 1
         elseif char == ")" or char == "]" or char == "}" then
            assert(stack[#stack] == char, "f!: mismatched delimiter in interpolation field")
            table.remove(stack); index = index + 1
         elseif char == ":" and #stack == 0 then
            local tail = text:sub(index + 1)
            local after_name = tail:match("^%s*[%a_][%w_]*%s*()")
            local call_start = after_name and tail:sub(after_name, after_name)
            if call_start == "(" or call_start == "{" or call_start == '"' or call_start == "'" or
               (call_start == "[" and tail:sub(after_name):match("^%[=*%[")) then
               index = index + 1 -- a method call, not a format separator
            else
               local finish = text:find("}", index + 1, true)
               assert(finish, "f!: unmatched '{'")
               return text:sub(start, index - 1), text:sub(index + 1, finish - 1), finish + 1
            end
         else
            index = index + 1
         end
      end
      error("f!: unmatched '{'", 0)
   end

   local function format_specifier(spec)
      if not spec or spec == "" then return nil end
      if spec:sub(1, 1) == "%" then spec = spec:sub(2) end
      local flags, width, precision, conversion = spec:match("^([%-%+ #0]*)(%d*)(%.?%d*)([cdiouxXeEfgGaAqs])$")
      assert(flags, "f!: invalid format specifier '" .. spec .. "'")
      assert(#width <= 2 and (#precision == 0 or (precision:match("^%.%d+$") and #precision <= 3)),
         "f!: format width and precision must be between 0 and 99")
      local format = "%" .. spec
      local sample = (conversion == "s" or conversion == "q") and "" or 0
      local valid, err = pcall(string.format, format, sample)
      assert(valid, "f!: invalid format specifier: " .. tostring(err))
      return format
   end

   local index = 1
   while index <= #text do
      local char, pair = text:sub(index, index), text:sub(index, index + 1)
      if pair == "{{" or pair == "}}" then
         table.insert(pending, char); index = index + 2
      elseif char == "{" then
         flush()
         local source, spec, finish = field(index + 1)
         source = source:match("^%s*(.-)%s*$")
         assert(source ~= "", "f!: empty interpolation field")
         local expression = parse_expression(source)
         local format = format_specifier(spec)
         local plain = `tostring(($expression))`
         local value = plain
         local argument = plain
         if format then
            uses_format = true
            local format_node = literal(format)
            value = `string.format($format_node, ($expression))`
            argument = `($expression)`
         end
         table.insert(pieces, value)
         table.insert(format_parts, format or "%s")
         table.insert(format_arguments, argument)
         index = finish
      elseif char == "}" then
         error("f!: unmatched '}' (use '}}' for a literal brace)", 0)
      else
         table.insert(pending, char); index = index + 1
      end
   end
   flush()
   if #format_arguments == 0 then return pieces[1] or literal("") end
   local result
   if uses_format then
      -- Numeric/width formatting wins with one format call for the whole template.
      local pattern = literal(table.concat(format_parts))
      result = `string.format($pattern)`
      for _, argument in ipairs(format_arguments) do table.insert(result[B.OP.E2], argument) end
   else
      -- A right-associated chain becomes a single CONCAT instruction.
      result = pieces[#pieces]
      for i = #pieces - 1, 1, -1 do
         local piece = pieces[i]
         result = `$piece .. $result`
      end
   end
   return result
end

return Format
