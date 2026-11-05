







local JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })
local JSON_ARRAYS = {}

local function array()
   local result = {}
   JSON_ARRAYS[result] = true
   return result
end

local function mark_array(values)
   JSON_ARRAYS[values] = true
   return values
end

local function is_array(value)
   return JSON_ARRAYS[value] == true
end

local function json_escape(value)
   return (value:gsub('[%z\1-\31\\"]', function(ch)
      local byte = ch:byte()
      if ch == "\\" then return "\\\\" end
      if ch == '"' then return '\\"' end
      if ch == "\b" then return "\\b" end
      if ch == "\f" then return "\\f" end
      if ch == "\n" then return "\\n" end
      if ch == "\r" then return "\\r" end
      if ch == "\t" then return "\\t" end
      return string.format("\\u%04x", byte)
   end))
end

local function json_encode(value)
   if value == JSON_NULL or value == nil then
      return "null"
   elseif type(value) == "boolean" then
      return value and "true" or "false"
   elseif type(value) == "number" then
      if value ~= value or value == math.huge or value == -math.huge then
         return "null"
      end
      return tostring(value)
   elseif type(value) == "string" then
      return '"' .. json_escape(value) .. '"'
   elseif not (type(value) == "table") then
      return '"' .. json_escape(tostring(value)) .. '"'
   elseif is_array(value) then
      local list = value
      local out = {}
      for i = 1, #list do
         out[i] = json_encode(list[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
   end

   local object = value
   local keys = {}
   for key, _ in pairs(object) do
      if type(key) == "string" then
         table.insert(keys, key)
      end
   end
   table.sort(keys)
   local out = {}
   for i, key in ipairs(keys) do
      out[i] = json_encode(key) .. ":" .. json_encode(object[key])
   end
   return "{" .. table.concat(out, ",") .. "}"
end

local function utf8_char(codepoint)
   if codepoint < 0x80 then
      return string.char(codepoint)
   elseif codepoint < 0x800 then
      return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
   elseif codepoint < 0x10000 then
      return string.char(0xe0 + math.floor(codepoint / 0x1000), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
   end
   return string.char(0xf0 + math.floor(codepoint / 0x40000), 0x80 + (math.floor(codepoint / 0x1000) % 0x40), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
end

local function json_decode(input)
   local index = 1
   local size = #input

   local function whitespace()
      while index <= size and input:sub(index, index):match("%s") do
         index = index + 1
      end
   end

   local parse_value

   local function parse_string()
      index = index + 1
      local out = {}
      local out_n = 0
      while index <= size do
         local ch = input:sub(index, index)
         if ch == '"' then
            index = index + 1
            return table.concat(out)
         elseif ch ~= "\\" then
            out_n = out_n + 1
            out[out_n] = ch
            index = index + 1
         else
            local escaped = input:sub(index + 1, index + 1)
            if escaped == '"' or escaped == "\\" or escaped == "/" then
               out_n = out_n + 1
               out[out_n] = escaped
               index = index + 2
            elseif escaped == "b" then
               out_n = out_n + 1; out[out_n] = "\b"; index = index + 2
            elseif escaped == "f" then
               out_n = out_n + 1; out[out_n] = "\f"; index = index + 2
            elseif escaped == "n" then
               out_n = out_n + 1; out[out_n] = "\n"; index = index + 2
            elseif escaped == "r" then
               out_n = out_n + 1; out[out_n] = "\r"; index = index + 2
            elseif escaped == "t" then
               out_n = out_n + 1; out[out_n] = "\t"; index = index + 2
            elseif escaped == "u" then
               local digits = input:sub(index + 2, index + 5)
               local codepoint = tonumber(digits, 16)
               if not codepoint then
                  return nil, "invalid unicode escape"
               end
               index = index + 6
               if codepoint >= 0xd800 and codepoint <= 0xdbff and input:sub(index, index + 1) == "\\u" then
                  local low = tonumber(input:sub(index + 2, index + 5), 16)
                  if low and low >= 0xdc00 and low <= 0xdfff then
                     codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
                     index = index + 6
                  end
               end
               out_n = out_n + 1
               out[out_n] = utf8_char(codepoint)
            else
               return nil, "invalid string escape"
            end
         end
      end
      return nil, "unterminated string"
   end

   local function parse_array()
      local result = array()
      index = index + 1
      whitespace()
      if input:sub(index, index) == "]" then
         index = index + 1
         return result
      end
      while true do
         local value, err = parse_value()
         if err then return nil, err end
         table.insert(result, value)
         whitespace()
         local separator = input:sub(index, index)
         if separator == "]" then
            index = index + 1
            return result
         elseif separator ~= "," then
            return nil, "expected ',' or ']'"
         end
         index = index + 1
         whitespace()
      end
   end

   local function parse_object()
      local result = {}
      index = index + 1
      whitespace()
      if input:sub(index, index) == "}" then
         index = index + 1
         return result
      end
      while true do
         if input:sub(index, index) ~= '"' then
            return nil, "expected object key"
         end
         local key, key_err = parse_string()
         if key_err then return nil, key_err end
         whitespace()
         if input:sub(index, index) ~= ":" then
            return nil, "expected ':'"
         end
         index = index + 1
         whitespace()
         local value, value_err = parse_value()
         if value_err then return nil, value_err end
         result[key] = value
         whitespace()
         local separator = input:sub(index, index)
         if separator == "}" then
            index = index + 1
            return result
         elseif separator ~= "," then
            return nil, "expected ',' or '}'"
         end
         index = index + 1
         whitespace()
      end
   end

   parse_value = function()
      whitespace()
      local ch = input:sub(index, index)
      if ch == '"' then
         return parse_string()
      elseif ch == "{" then
         return parse_object()
      elseif ch == "[" then
         return parse_array()
      elseif input:sub(index, index + 3) == "true" then
         index = index + 4
         return true
      elseif input:sub(index, index + 4) == "false" then
         index = index + 5
         return false
      elseif input:sub(index, index + 3) == "null" then
         index = index + 4
         return JSON_NULL
      end
      local number = input:match("^-?%d+%.?%d*[eE]?[+-]?%d*", index)
      if number and #number > 0 then
         local value = tonumber(number)
         if value then
            index = index + #number
            return value
         end
      end
      return nil, "unexpected token at byte " .. tostring(index)
   end

   local value, err = parse_value()
   if err then return nil, err end
   whitespace()
   if index <= size then
      return nil, "trailing data at byte " .. tostring(index)
   end
   return value
end









return { null = JSON_NULL, encode = json_encode, decode = json_decode, array = mark_array }
