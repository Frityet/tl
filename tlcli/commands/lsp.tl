--#pragma strict_nil off










local teal = require("teal.init")
local driver = require("tlcli.driver")
local configuration = require("tlcli.configuration")
local lfs = require("lfs")
local jit_opt = require("jit.opt")
local ffi = require("ffi")
local type TlConfig = require("tlcli.tlconfig")
local type Args = require("tlcli.args")
local type Token = teal.Token
local type TypeReport = teal.TypeReport
local type CheckError = teal.CheckError
local type TealError = teal.Error
local type Module = teal.Module
local type Compiler = teal.Compiler
local type type_reporter = require("teal.type_reporter")
local type TypeInfo = type_reporter.TypeInfo

-- The checker consists of large, repeatedly visited dispatch loops. Compile
-- them sooner and retain substantially more machine code than LuaJIT's CLI
-- defaults; this is a long-lived interactive process, not a short command.
jit_opt.start("hotloop=12", "hotexit=2", "maxtrace=10000", "maxrecord=20000", "maxmcode=4096")
io.stdin:setvbuf("no")

local POSIX_POLL = ffi.os ~= "Windows"
if POSIX_POLL then
   ffi.cdef [[
      struct pollfd { int fd; short events; short revents; };
      int poll(struct pollfd *fds, unsigned long nfds, int timeout);
   ]]
end

local record Pollfd is ffi.CData where ffi.istype(self, "struct pollfd")
   fd: integer
   events: integer
   revents: integer
end

local stdin_pollfd: ffi.Array<Pollfd> = POSIX_POLL and ffi.new("struct pollfd[1]")
if stdin_pollfd then stdin_pollfd[0].fd = 0; stdin_pollfd[0].events = 1 end

local function stdin_ready(timeout_ms: integer): boolean
   if not stdin_pollfd then return true end
   stdin_pollfd[0].revents = 0
   return (ffi.C.poll as function(ffi.Array<Pollfd>, integer, integer): integer)(stdin_pollfd, 1, timeout_ms) > 0
end

local type AnyArray = {any}
local type AnyObject = {string: any}

local record NullValue
end

local JSON_NULL: NullValue = setmetatable({}, { __tostring = function(): string return "null" end })
local JSON_ARRAYS: {AnyArray: boolean} = {}

local function array(): AnyArray
   local result: AnyArray = {}
   JSON_ARRAYS[result] = true
   return result
end

local function mark_array(values: AnyArray): AnyArray
   JSON_ARRAYS[values] = true
   return values
end

local function is_array(value: AnyArray): boolean
   return JSON_ARRAYS[value] == true
end

local function json_escape(value: string): string
   return (value:gsub('[%z\1-\31\\"]', function(ch: string): string
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

local function json_encode(value: any): string
   if value == JSON_NULL or value == nil then
      return "null"
   elseif value is boolean then
      return value and "true" or "false"
   elseif value is number then
      if value ~= value or value == math.huge or value == -math.huge then
         return "null"
      end
      return tostring(value)
   elseif value is string then
      return '"' .. json_escape(value) .. '"'
   elseif not value is table then
      return '"' .. json_escape(tostring(value)) .. '"'
   elseif is_array(value as AnyArray) then
      local list = value as AnyArray
      local out: {string} = {}
      for i = 1, #list do
         out[i] = json_encode(list[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
   end

   local object = value as AnyObject
   local keys: {string} = {}
   for key, _ in pairs(object) do
      if type(key) == "string" then
         table.insert(keys, key)
      end
   end
   table.sort(keys)
   local out: {string} = {}
   for i, key in ipairs(keys) do
      out[i] = json_encode(key) .. ":" .. json_encode(object[key])
   end
   return "{" .. table.concat(out, ",") .. "}"
end

local function utf8_char(codepoint: integer): string
   if codepoint < 0x80 then
      return string.char(codepoint)
   elseif codepoint < 0x800 then
      return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
   elseif codepoint < 0x10000 then
      return string.char(0xe0 + math.floor(codepoint / 0x1000), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
   end
   return string.char(0xf0 + math.floor(codepoint / 0x40000), 0x80 + (math.floor(codepoint / 0x1000) % 0x40), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
end

local function json_decode(input: string): AnyObject, string
   local index = 1
   local size = #input

   local function whitespace()
      while index <= size and input:sub(index, index):match("%s") do
         index = index + 1
      end
   end

   local parse_value: function(): any, string

   local function parse_string(): string, string
      index = index + 1
      local out: {string} = {}
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

   local function parse_array(): AnyArray, string
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

   local function parse_object(): AnyObject, string
      local result: AnyObject = {}
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

   parse_value = function(): any, string
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
   return value as AnyObject
end

local function read_message(): AnyObject, string
   local content_length: integer
   while true do
      local line = io.stdin:read("*l")
      if line == nil then
         return nil, "eof"
      end
      if line == "" or line == "\r" then
         break
      end
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name and name:lower() == "content-length" then
         content_length = math.floor(tonumber(value) or 0)
      end
   end
   if not content_length then
      return nil, "missing Content-Length"
   end
   local body = io.stdin:read(content_length)
   if not body or #body ~= content_length then
      return nil, "unexpected eof in request body"
   end
   return json_decode(body)
end

local function write_message(payload: AnyObject)
   local body = json_encode(payload)
   io.stdout:write("Content-Length: ", tostring(#body), "\r\n\r\n", body)
   io.stdout:flush()
end

local function notification(method: string, params: any)
   write_message({ jsonrpc = "2.0", method = method, params = params } as AnyObject)
end

local function response(id: any, result: any, err: any)
   local payload: AnyObject = { jsonrpc = "2.0", id = id or JSON_NULL }
   if err then
      payload.error = err
   else
      payload.result = result == nil and JSON_NULL or result
   end
   write_message(payload)
end

local function uri_decode(value: string): string
   return (value:gsub("%%(%x%x)", function(hex: string): string
      return string.char(tonumber(hex, 16) or 0)
   end))
end

local function uri_encode(value: string): string
   return (value:gsub("[^%w%-%._~/:]", function(ch: string): string
      return string.format("%%%02X", ch:byte())
   end))
end

local function uri_to_path(uri: string): string
   local path = uri:gsub("^file://", "")
   if package.config:sub(1, 1) == "\\" and path:sub(1, 1) == "/" then
      path = path:sub(2)
   end
   return uri_decode(path)
end

local function path_to_uri(path: string): string
   local normalized = path:gsub("\\", "/")
   if normalized:sub(1, 1) ~= "/" then
      normalized = "/" .. normalized
   end
   return "file://" .. uri_encode(normalized)
end

local function split_lines(text: string): {string}
   local lines: {string} = {}
   local start = 1
   while true do
      local finish = text:find("\n", start, true)
      if not finish then
         table.insert(lines, text:sub(start))
         break
      end
      local line = text:sub(start, finish - 1)
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      table.insert(lines, line)
      start = finish + 1
   end
   return lines
end

local function utf8_step(text: string, index: integer): integer, integer
   local byte = text:byte(index) or 0
   if byte < 0x80 then return 1, 1 end
   if byte < 0xe0 then return 2, 1 end
   if byte < 0xf0 then return 3, 1 end
   return 4, 2
end

local function utf16_length(text: string): integer
   local index, units = 1, 0
   while index <= #text do
      local width, utf16 = utf8_step(text, index)
      index = index + width
      units = units + utf16
   end
   return units
end

local function utf16_to_byte(text: string, units: integer): integer
   local index, used = 1, 0
   while index <= #text and used < units do
      local width, utf16 = utf8_step(text, index)
      if used + utf16 > units then break end
      index = index + width
      used = used + utf16
   end
   return index - 1
end

local function byte_to_utf16(text: string, byte_count: integer): integer
   local index, units = 1, 0
   while index <= #text and index <= byte_count do
      local width, utf16 = utf8_step(text, index)
      if index + width - 1 > byte_count then break end
      index = index + width
      units = units + utf16
   end
   return units
end

local record Position
   line: integer
   character: integer
end

local record Range
   start: Position
   ["end"]: Position
end

local function make_range(lines: {string}, y: integer, x: integer, length: integer): Range
   local line = lines[y] or ""
   local prefix = line:sub(1, math.max(0, x - 1))
   local token = line:sub(x, x + math.max(0, length) - 1)
   local start = byte_to_utf16(prefix, #prefix)
   local finish = start + utf16_length(token)
   return { start = { line = y - 1, character = start }, ["end"] = { line = y - 1, character = finish } }
end

local function full_range(lines: {string}): Range
   local last = lines[#lines] or ""
   return { start = { line = 0, character = 0 }, ["end"] = { line = math.max(0, #lines - 1), character = utf16_length(last) } }
end

local function lsp_position_to_offset(_text: string, lines: {string}, position: Position): integer
   local wanted_line = (position.line or 0) + 1
   local wanted_units = position.character or 0
   local offset = 1
   for line = 1, wanted_line - 1 do
      offset = offset + #(lines[line] or "") + 1
   end
   local content = lines[wanted_line] or ""
   return offset + utf16_to_byte(content, wanted_units)
end

local function module_name_from_path(path: string, root: string): string
   local relative = path
   if root and path:sub(1, #root) == root then
      relative = path:sub(#root + 1):gsub("^[\\/]", "")
   end
   return (relative:gsub("\\", "/"):gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", "."))
end























local KEYWORDS: {string: boolean} = {
   ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
   ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
   ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
   ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
   ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
   ["until"] = true, ["while"] = true,
   ["global"] = true, ["record"] = true, ["interface"] = true, ["enum"] = true,
   ["type"] = true, ["macro"] = true, ["is"] = true, ["where"] = true,
   ["metamethod"] = true, ["userdata"] = true, ["as"] = true,
}

local COMPLETION_KEYWORDS = {
   "and", "as", "break", "do", "else", "elseif", "end", "enum", "false",
   "for", "function", "global", "if", "in", "interface", "is", "local", "macro",
   "metamethod", "nil", "not", "or", "record", "repeat", "return", "then", "true",
   "type", "until", "userdata", "where", "while",
}

local record MacroInfo
   name: string
   y: integer
   x: integer
   detail: string
end

local record SyntaxField
   token: Token
   detail: string
end

local record Document
   uri: string
   path: string
   text: string
   version: integer
   lines: {string}
   analysis_version: integer
   tokens: {Token}
   tokens_by_line: {integer: {Token}}
   token_indices: {Token: integer}
   tokens_by_name: {string: {Token}}
   type_info_cache: {Token: TypeInfo}
   type_id_cache: {Token: integer}
   type_info_resolved: {Token: boolean}
   type_declarations: {string: Token}
   fields_by_name: {string: {SyntaxField}}
   fields_by_type: {string: {string: {SyntaxField}}}
   diagnostics: AnyArray
   macros: {MacroInfo}
   macros_by_name: {string: MacroInfo}
   macro_expansions: {integer: {integer: string}}
   generated: string
   semantic_full: AnyObject
   document_symbols_cache: AnyArray
   folding_ranges_cache: AnyArray
   symbols: {TypeReport.Symbol}
   module: Module
   type_report: TypeReport
end

local record Server
   tlconfig: TlConfig
   args: Args
   root: string
   documents: {string: Document}
   type_documents: {string: {Document:boolean}}
   field_documents: {string: {Document:boolean}}
   shutdown: boolean
   workspace_indexed: boolean
   compiler: Compiler
   pending_diagnostics: {Document:boolean}
end

local ensure_workspace_index: function(Server)

local function index_text_hints(server: Server, document: Document)
   for _, line in ipairs(document.lines) do
      local type_name = line:match("%f[%a]record%s+([%a_][%w_]*)") or
         line:match("%f[%a]interface%s+([%a_][%w_]*)") or line:match("%f[%a]enum%s+([%a_][%w_]*)")
      if type_name then
         local documents = server.type_documents[type_name]
         if not documents then documents = {}; server.type_documents[type_name] = documents end
         documents[document] = true
      end
      local field_name = line:match("^%s*([%a_][%w_]*)%s*:")
      if field_name then
         local documents = server.field_documents[field_name]
         if not documents then documents = {}; server.field_documents[field_name] = documents end
         documents[document] = true
      end
   end
end

local function load_workspace_config(server: Server)
   local previous = lfs.currentdir()
   if not previous or not lfs.chdir(server.root) then return end
   local config = configuration.get()
   for index, include in ipairs(config.include_dir or {}) do
      if include:sub(1, 1) ~= "/" and not include:match("^%a:[/\\]") then
         config.include_dir[index] = server.root .. "/" .. include
      end
   end
   if config.global_env_def and config.global_env_def:sub(1, 1) ~= "/" and not config.global_env_def:match("^%a:[/\\]") then
      config.global_env_def = server.root .. "/" .. config.global_env_def
   end
   configuration.merge_config_and_args(config, server.args)
   lfs.chdir(previous)
   config.quiet = true
   server.tlconfig = config
   server.compiler = nil
end

local function lsp_enabled(server: Server, feature: string): boolean
   return not server.tlconfig.lsp or server.tlconfig.lsp[feature] ~= false
end

local function document_new(uri: string, text: string, version: integer): Document
   return {
      uri = uri,
      path = uri_to_path(uri),
      text = text,
      version = version or 0,
      lines = split_lines(text),
      analysis_version = -1,
      tokens = {},
      tokens_by_line = {},
      token_indices = {},
      tokens_by_name = {},
      type_info_cache = {},
      type_id_cache = {},
      type_info_resolved = {},
      type_declarations = {},
      fields_by_name = {},
      fields_by_type = {},
      diagnostics = {},
      macros = {},
      macros_by_name = {},
      macro_expansions = {},
      symbols = {},
   }
end

local function token_contains(token: Token, line: integer, character: integer, lines: {string}): boolean
   if token.y ~= line + 1 then return false end
   local start = byte_to_utf16((lines[token.y] or ""):sub(1, math.max(0, token.x - 1)), token.x - 1)
   return character >= start and character < start + utf16_length(token.tk)
end

local function token_at(document: Document, position: Position): Token, integer
   local line = position.line or 0
   local character = position.character or 0
   for _, token in ipairs(document.tokens_by_line[line + 1] or {}) do
      if token.kind ~= "$EOF$" and token_contains(token, line, character, document.lines) then
         return token, document.token_indices[token]
      end
   end
end

local function token_at_or_before(document: Document, position: Position): Token, integer
   local token, index = token_at(document, position)
   if token then return token, index end
   local line_number = (position.line or 0) + 1
   local character = position.character or 0
   local winner: Token
   for _, candidate in ipairs(document.tokens_by_line[line_number] or {}) do
      local line = document.lines[line_number] or ""
      local start = byte_to_utf16(line:sub(1, math.max(0, candidate.x - 1)), candidate.x - 1)
      if start <= character then winner = candidate else break end
   end
   local previous_line = line_number - 1
   while not winner and previous_line >= 1 do
      local candidates = document.tokens_by_line[previous_line]
      if candidates and #candidates > 0 then winner = candidates[#candidates] end
      previous_line = previous_line - 1
   end
   return winner, winner and document.token_indices[winner]
end

local function previous_token(document: Document, token_index?: integer): Token, integer
   local index = (token_index or (#document.tokens + 1)) - 1
   while index >= 1 do
      local token = document.tokens[index]
      if token.kind ~= "$EOF$" then return token, index end
      index = index - 1
   end
end

local function next_token(document: Document, token_index?: integer): Token, integer
   local index = (token_index or 0) + 1
   while index <= #document.tokens do
      local token = document.tokens[index]
      if token.kind ~= "$EOF$" then return token, index end
      index = index + 1
   end
end

local function macro_name_at(tokens: {Token}, start: integer): string, integer
   local parts: {string} = {}
   local index = start
   while index <= #tokens do
      local token = tokens[index]
      if token.tk == "!" then
         return table.concat(parts, "") .. "!", index
      end
      if token.kind ~= "identifier" and token.tk ~= "." then
         return nil, index
      end
      table.insert(parts, token.tk)
      index = index + 1
   end
end

local function collect_macros(tokens: {Token}): {MacroInfo}
   local macros: {MacroInfo} = {}
   for i, token in ipairs(tokens) do
      if token.tk == "macro" then
         local name = macro_name_at(tokens, i + 1)
         if name then
            local name_token = tokens[i + 1]
            table.insert(macros, { name = name, y = name_token.y, x = name_token.x, detail = "Teal macro" })
         end
      end
   end
   return macros
end

local function is_declaration(document: Document, index: integer): boolean
   local previous, previous_index = previous_token(document, index)
   if not previous then return false end
   if previous.tk == "function" or previous.tk == "record" or previous.tk == "interface" or
      previous.tk == "enum" or previous.tk == "type" or previous.tk == "macro" then
      return true
   end
   if previous.tk == "local" or previous.tk == "global" then return true end
   if previous.kind == "identifier" then
      local before = previous_token(document, previous_index)
      return before and before.tk == "function"
   end
   return false
end

local function macro_invocation(document: Document, index: integer): string
   local following = next_token(document, index)
   if not following or following.tk ~= "!" then return nil end
   local first = index
   while first > 2 and document.tokens[first - 1].tk == "." and document.tokens[first - 2].kind == "identifier" do
      first = first - 2
   end
   local parts: {string} = {}
   for i = first, index do table.insert(parts, document.tokens[i].tk) end
   return table.concat(parts, "") .. "!"
end

local function render_tealdoc(lines: {string}): string
   local rendered: {string} = {}
   for _, line in ipairs(lines) do
      local tag, parameter, description = line:match("^@([%w_]+)%s+([^%s]+)%s*(.*)$")
      if tag == "param" then
         table.insert(rendered, "**Parameter `" .. parameter .. "`:** " .. description)
      elseif tag == "typearg" then
         table.insert(rendered, "**Type parameter `" .. parameter .. "`:** " .. description)
      elseif tag == "return" then
         table.insert(rendered, "**Returns:** " .. (description ~= "" and (parameter .. " " .. description) or parameter))
      elseif tag then
         table.insert(rendered, "**@" .. tag .. " `" .. parameter .. "`:** " .. description)
      else
         local bare_tag, bare_description = line:match("^@([%w_]+)%s*(.*)$")
         if bare_tag then
            table.insert(rendered, "**@" .. bare_tag .. ":** " .. bare_description)
         else
            table.insert(rendered, line)
         end
      end
   end
   return table.concat(rendered, "\n\n")
end

local function tealdoc_for_token(token: Token): string
   if not token or not token.comments or #token.comments == 0 then return nil end
   local lines: {string} = {}
   local documenting = false
   for _, comment in ipairs(token.comments) do
      local text = comment.text
      if text:match("^%-%-%-") or text:match("^%-%-%[%[%-%-") then
         documenting = true
      elseif not documenting then
         break
      end
      if documenting then
         text = text:gsub("^%-%-%[%[%-%-?%s*", ""):gsub("%s*%]%]%-%-$", "")
         text = text:gsub("^%-%-%-?%s?", "")
         for line in (text .. "\n"):gmatch("(.-)\r?\n") do
            local cleaned = line:gsub("^%s+", "")
            cleaned = cleaned:gsub("%s+$", "")
            table.insert(lines, cleaned)
         end
      end
   end
   while lines[1] == "" do table.remove(lines, 1) end
   while lines[#lines] == "" do table.remove(lines) end
   if #lines == 0 then return nil end
   return render_tealdoc(lines)
end

local function documentation_in_tokens(tokens: {Token}, y: integer, x: integer, name?: string): string
   local closest: Token
   for _, token in ipairs(tokens) do
      if token.y == y and (not name or token.tk == name) and token.x >= x and tealdoc_for_token(token) and (not closest or token.x < closest.x) then closest = token end
   end
   if closest then return tealdoc_for_token(closest) end
   for _, token in ipairs(tokens) do
      if token.y == y and token.x <= x and tealdoc_for_token(token) and (not closest or token.x > closest.x) then closest = token end
   end
   return closest and tealdoc_for_token(closest)
end


local function documentation_from_file(path: string, y: integer, x: integer, name?: string): string
   local file = io.open(path, "rb")
   if not file then return nil end
   local text = file:read("*a") or ""
   file:close()
   local compiler = teal.compiler({})
   local input = compiler:input(text, path)
   if not input then return nil end
   return documentation_in_tokens(input:lex().tokens, y, x, name)
end

local function error_diagnostic(document: Document, err: TealError, severity: integer, category: string): AnyObject
   local y = err.y or 1
   local x = err.x or 1
   local line = document.lines[y] or ""
   local length = 1
   if x <= #line then
      local word = line:sub(x):match("^[%a_][%w_]*")
      length = word and #word or 1
   end
   return {
      range = make_range(document.lines, y, x, length),
      severity = severity,
      code = err.tag or category,
      source = "tl",
      message = err.msg or category,
   }
end

local function append_diagnostics(document: Document, out: AnyArray, errors: {TealError}, severity: integer, category: string, server: Server)
   for _, err in ipairs(errors or {}) do
      if category ~= "warning" or not server.tlconfig._disabled_warnings_set[err.tag] then
         local actual_severity = severity
         if category == "warning" and server.tlconfig._warning_errors_set[err.tag] then
            actual_severity = 1
         end
         table.insert(out, error_diagnostic(document, err, actual_severity, category))
      end
   end
end

local function analyze_document(server: Server, document: Document): Document
   if document.analysis_version == document.version then
      return document
   end
   document.generated = nil
   document.semantic_full = nil
   document.document_symbols_cache = nil
   document.folding_ranges_cache = nil

   local compiler = server.compiler
   if not compiler then
      compiler = driver.setup_compiler(server.tlconfig)
      compiler:enable_type_reporting(true)
      server.compiler = compiler
   end
   local input, input_err = compiler:input(document.text, document.path)
   local diagnostics = array()
   local tokens: {Token} = {}
   local module: Module
   local check_error: CheckError

   if input == nil then
      table.insert(diagnostics, {
         range = make_range(document.lines, 1, 1, 1), severity = 1,
         source = "tl", message = input_err or "could not read document",
      })
   else
      local token_list = input:lex()
      tokens = token_list.tokens
      local parse_tree = token_list:parse()
      local ok, checked_module, checked_errors = pcall(function(): Module, CheckError
         return parse_tree:check(module_name_from_path(document.path, server.root))
      end)
      if ok then
         module = checked_module
         check_error = checked_errors
      else
         table.insert(diagnostics, {
            range = make_range(document.lines, 1, 1, 1), severity = 1,
            source = "tl", code = "compiler-crash",
            message = "compiler recovery: " .. tostring(checked_module),
         })
      end
   end

   if check_error then
      append_diagnostics(document, diagnostics, check_error.syntax_errors, 1, "syntax", server)
      append_diagnostics(document, diagnostics, check_error.type_errors, 1, "type", server)
      append_diagnostics(document, diagnostics, check_error.warnings, 2, "warning", server)
   end

   document.tokens = tokens
   document.tokens_by_line = {}
   document.token_indices = {}
   document.tokens_by_name = {}
   document.type_info_cache = {}
   document.type_id_cache = {}
   document.type_info_resolved = {}
   document.type_declarations = {}
   document.fields_by_name = {}
   document.fields_by_type = {}
   for index, token in ipairs(tokens) do
      document.token_indices[token] = index
      local line_tokens = document.tokens_by_line[token.y]
      if not line_tokens then line_tokens = {}; document.tokens_by_line[token.y] = line_tokens end
      table.insert(line_tokens, token)
      if token.kind == "identifier" then
         local named = document.tokens_by_name[token.tk]
         if not named then named = {}; document.tokens_by_name[token.tk] = named end
         table.insert(named, token)
      end
      if token.tk == "record" or token.tk == "interface" or token.tk == "enum" or token.tk == "type" then
         local declared = tokens[index + 1]
         if declared and declared.kind == "identifier" then document.type_declarations[declared.tk] = declared end
      end
   end
   local current_type: string
   for line_number = 1, #document.lines do
      local line_tokens = document.tokens_by_line[line_number] or {}
      local line_text = document.lines[line_number] or ""
      local declared_type = line_text:match("%f[%a]record%s+([%a_][%w_]*)") or line_text:match("%f[%a]interface%s+([%a_][%w_]*)")
      if declared_type then
         current_type = declared_type
         document.fields_by_type[current_type] = document.fields_by_type[current_type] or {}
      end
      local method_owner, method_name = line_text:match("^%s*function%s+([%a_][%w_]*)%s*:%s*([%a_][%w_]*)")
      if method_owner and method_name then
         local method_token: Token
         for _, candidate in ipairs(line_tokens) do
            if candidate.tk == method_name then method_token = candidate; break end
         end
         if method_token then
            local field: SyntaxField = { token = method_token, detail = line_text:match("^%s*(.-)%s*$") }
            local named = document.fields_by_name[method_name]
            if not named then named = {}; document.fields_by_name[method_name] = named end
            table.insert(named, field)
            local typed = document.fields_by_type[method_owner]
            if not typed then typed = {}; document.fields_by_type[method_owner] = typed end
            typed[method_name] = typed[method_name] or {}
            table.insert(typed[method_name], field)
         end
      end
      for index, token in ipairs(line_tokens) do
         local colon = line_tokens[index + 1]
         if index == 1 and token.kind == "identifier" and colon and colon.tk == ":" then
            local parts: {string} = {}
            for part_index = index + 2, #line_tokens do
               local part = line_tokens[part_index]
               if part.kind ~= "$EOF$" then table.insert(parts, part.tk) end
            end
            local fields = document.fields_by_name[token.tk]
            if not fields then fields = {}; document.fields_by_name[token.tk] = fields end
            local field: SyntaxField = { token = token, detail = table.concat(parts, " ") }
            table.insert(fields, field)
            if current_type then
               local typed = document.fields_by_type[current_type]
               typed[token.tk] = typed[token.tk] or {}
               table.insert(typed[token.tk], field)
            end
         end
      end
      if current_type and line_text:match("^%s*end%f[%A]") then current_type = nil end
   end
   document.diagnostics = diagnostics
   document.module = module
   document.type_report = compiler:get_type_report()
   document.symbols = document.type_report and document.type_report.symbols_by_file[document.path] or {}
   document.macros = collect_macros(tokens)
   document.macros_by_name = {}
   for _, macro in ipairs(document.macros) do document.macros_by_name[macro.name] = macro end
   document.macro_expansions = {}
   document.analysis_version = document.version
   return document
end

local function publish_diagnostics(server: Server, document: Document)
   analyze_document(server, document)
   notification("textDocument/publishDiagnostics", {
      uri = document.uri,
      version = document.version,
      diagnostics = document.diagnostics,
   })
end

local function flush_pending_diagnostics(server: Server)
   local pending = server.pending_diagnostics
   server.pending_diagnostics = {}
   for document in pairs(pending) do
      if server.documents[document.uri] == document then publish_diagnostics(server, document) end
   end
end

local function apply_change(document: Document, change: AnyObject)
   local new_text = change.text as string or ""
   if not change.range then
      document.text = new_text
   else
      local changed_range = change.range as Range
      local start = lsp_position_to_offset(document.text, document.lines, changed_range.start)
      local finish = lsp_position_to_offset(document.text, document.lines, changed_range["end"])
      document.text = document.text:sub(1, start - 1) .. new_text .. document.text:sub(finish)
   end
   document.lines = split_lines(document.text)
end

local function member_type_id(report: TypeReport, info: TypeInfo, name: string, seen?: {TypeInfo:boolean}): integer
   if not info then return nil end
   seen = seen or {}
   if seen[info] then return nil end
   seen[info] = true
   local type_id = (info.fields and info.fields[name]) or (info.meta_fields and info.meta_fields[name])
   if type_id then return type_id end
   if info.ref then
      type_id = member_type_id(report, report.types[info.ref], name, seen)
      if type_id then return type_id end
   end
   for _, nested_id in ipairs(info.types or {}) do
      type_id = member_type_id(report, report.types[nested_id], name, seen)
      if type_id then return type_id end
   end
end

local function member_location(report: TypeReport, info: TypeInfo, name: string, seen?: {TypeInfo:boolean}): AnyObject
   if not info then return nil end
   seen = seen or {}
   if seen[info] then return nil end
   seen[info] = true
   local location = (info.field_locations and info.field_locations[name]) or (info.meta_field_locations and info.meta_field_locations[name])
   if location then return location as AnyObject end
   if info.ref then
      local found = member_location(report, report.types[info.ref], name, seen)
      if found then return found end
   end
   for _, nested_id in ipairs(info.types or {}) do
      local found = member_location(report, report.types[nested_id], name, seen)
      if found then return found end
   end
end

local function type_info(document: Document, position: Position, token?: Token): TypeInfo, integer
   if token and document.type_info_resolved[token] then
      return document.type_info_cache[token], document.type_id_cache[token]
   end
   local report = document.type_report
   if not report then return nil end
   local y = (position.line or 0) + 1
   local line = document.lines[y] or ""
   local prefix_bytes = utf16_to_byte(line, position.character or 0)
   local x = prefix_bytes + 1
   local by_line = report.by_pos[document.path] and report.by_pos[document.path][y]
   local type_id: integer = by_line and (by_line[x] or (token and by_line[token.x]))
   if not type_id and token then
      local scope = report:symbols_in_scope(document.path, y, x)
      type_id = scope[token.tk]
   end
   if not type_id and token then
      local token_index = document.token_indices[token]
      local dot, dot_index = previous_token(document, token_index)
      if dot and (dot.tk == "." or dot.tk == ":") then
         local receiver = previous_token(document, dot_index)
         if receiver then
            local receiver_line = document.lines[receiver.y] or ""
            local receiver_position: Position = {
               line = receiver.y - 1,
               character = byte_to_utf16(receiver_line:sub(1, receiver.x - 1), receiver.x - 1),
            }
            local receiver_info: TypeInfo = type_info(document, receiver_position, receiver)
            type_id = member_type_id(report, receiver_info, token.tk)
         end
      end
   end
   local info: TypeInfo = type_id and report.types[type_id]
   if token then
      document.type_info_resolved[token] = true
      document.type_info_cache[token] = info
      document.type_id_cache[token] = type_id
   end
   return info, type_id
end

local function symbol_location(document: Document, name: string, position?: Position): AnyObject
   local before_y: integer = (position and position.line or 0x7ffffffe) + 1
   local before_x: integer = 0x7fffffff
   if position then
      local line = document.lines[before_y] or ""
      before_x = utf16_to_byte(line, position.character or 0) + 1
   end
   local winner: TypeReport.Symbol
   for _, symbol in ipairs(document.symbols or {}) do
      if symbol[3] == name and symbol[1] <= before_y and (symbol[1] < before_y or symbol[2] <= before_x) then
         if not winner or symbol[1] > winner[1] or (symbol[1] == winner[1] and symbol[2] > winner[2]) then
            winner = symbol
         end
      end
   end
   if winner then
      return { uri = document.uri, range = make_range(document.lines, winner[1], winner[2], #name) }
   end
   local macro = document.macros_by_name[name] or document.macros_by_name[name .. "!"]
   if macro then return { uri = document.uri, range = make_range(document.lines, macro.y, macro.x, #name) } end
end

local function field_location(server: Server, document: Document, token: Token): AnyObject
   local token_index = document.token_indices[token]
   local dot, dot_index = previous_token(document, token_index)
   if not dot or (dot.tk ~= "." and dot.tk ~= ":") then return nil end
   local receiver = previous_token(document, dot_index)
   if not receiver then return nil end
   local receiver_line = document.lines[receiver.y] or ""
   local receiver_position: Position = { line = receiver.y - 1, character = byte_to_utf16(receiver_line:sub(1, receiver.x - 1), receiver.x - 1) }
   local receiver_info: TypeInfo = type_info(document, receiver_position, receiver)
   if not receiver_info then return nil end
   local location = member_location(document.type_report, receiver_info, token.tk)
   if not location then return nil end
   local path = location.file as string
   if path:sub(1, 1) ~= "/" and not path:match("^%a:[/\\]") then path = server.root .. "/" .. path end
   local lines: {string} = { "" }
   local target = server.documents[path_to_uri(path)]
   if target then
      lines = target.lines
   else
      local file = io.open(path, "rb")
      if file then lines = split_lines(file:read("*a") or ""); file:close() end
   end
   return { uri = path_to_uri(path), range = make_range(lines, location.y as integer, location.x as integer, #token.tk) }
end

local function type_declaration_location(document: Document, name: string): AnyObject
   local declared = document.type_declarations[name]
   if declared then return { uri = document.uri, range = make_range(document.lines, declared.y, declared.x, #name) } end
end

local function first_syntax_field(document: Document, name: string): SyntaxField
   local fields = document.fields_by_name[name]
   return fields and fields[1]
end

local function syntax_member(server: Server, document: Document, token: Token): SyntaxField, Document
   local direct = first_syntax_field(document, token.tk)
   if direct then return direct, document end
   local index = document.token_indices[token]
   local separator, separator_index = previous_token(document, index)
   if not separator or (separator.tk ~= "." and separator.tk ~= ":") then return nil end
   local receiver = previous_token(document, separator_index)
   if not receiver then return nil end
   local receiver_field = first_syntax_field(document, receiver.tk)
   local receiver_type = receiver_field and receiver_field.detail:match("([%a_][%w_]*)%s*<") or
      (receiver_field and receiver_field.detail:match("([%a_][%w_]*)%s*$"))
   if not receiver_type then
      local line = document.lines[receiver.y] or ""
      local position: Position = { line = receiver.y - 1, character = byte_to_utf16(line:sub(1, receiver.x - 1), receiver.x - 1) }
      local receiver_info = type_info(document, position, receiver)
      receiver_type = receiver_info and receiver_info.str:match("^([%a_][%w_]*)")
   end
   ensure_workspace_index(server)
   local candidates = receiver_type and server.type_documents[receiver_type] or server.field_documents[token.tk]
   for candidate in pairs(candidates or {}) do
      analyze_document(server, candidate)
      if not receiver_type or candidate.type_declarations[receiver_type] then
         local typed_fields = receiver_type and candidate.fields_by_type[receiver_type]
         local matches = typed_fields and typed_fields[token.tk]
         local field = matches and matches[1] or first_syntax_field(candidate, token.tk)
         if field then return field, candidate end
      end
   end
end

local function find_definition(server: Server, document: Document, name: string, position?: Position): AnyObject
   if position then
      local token, token_index = token_at(document, position)
      if token and is_declaration(document, token_index) then
         return { uri = document.uri, range = make_range(document.lines, token.y, token.x, #token.tk) }
      end
      local macro_name = token and macro_invocation(document, token_index)
      if macro_name then
         local macro_info = document.macros_by_name[macro_name]
         if macro_info then return { uri = document.uri, range = make_range(document.lines, macro_info.y, macro_info.x, #token.tk) } end
         ensure_workspace_index(server)
         for _, candidate in pairs(server.documents) do
            analyze_document(server, candidate)
            macro_info = candidate.macros_by_name[macro_name]
            if macro_info then return { uri = candidate.uri, range = make_range(candidate.lines, macro_info.y, macro_info.x, #token.tk) } end
         end
         return nil
      end
      local field = token and field_location(server, document, token)
      if field then return field end
      if token then
         local syntax_field, syntax_document = syntax_member(server, document, token)
         if syntax_field then
            return { uri = syntax_document.uri, range = make_range(syntax_document.lines, syntax_field.token.y, syntax_field.token.x, #token.tk) }
         end
      end
      local previous = previous_token(document, token_index)
      local type_context = previous and (previous.tk == ":" or previous.tk == "<" or previous.tk == "|" or previous.tk == ",")
      if type_context then
         local type_location = type_declaration_location(document, token.tk)
         if type_location then return type_location end
         ensure_workspace_index(server)
         for candidate in pairs(server.type_documents[token.tk] or {}) do
            analyze_document(server, candidate)
            type_location = type_declaration_location(candidate, token.tk)
            if type_location then return type_location end
         end
      end
      local info: TypeInfo = token and type_info(document, position, token)
      if info and info.file and info.file ~= "" and info.y and info.x then
         local target_path = info.file
         if target_path:sub(1, 1) ~= "/" and not target_path:match("^%a:[/\\]") then
            target_path = server.root .. "/" .. target_path
         end
         local target_uri = path_to_uri(target_path)
         local target_lines: {string} = { "" }
         local file = io.open(target_path, "rb")
         if file then
            target_lines = split_lines(file:read("*a") or "")
            file:close()
         end
         return {
            uri = target_uri,
            range = make_range(target_lines, info.y, info.x, #name),
         }
      end
   end
   local local_location = symbol_location(document, name, position)
   if local_location then return local_location end
   ensure_workspace_index(server)
   for _, candidate in pairs(server.documents) do
      analyze_document(server, candidate)
      local location = symbol_location(candidate, name, nil)
      if location then return location end
   end
end

local function declaration_preview(server: Server, location: AnyObject): string
   if not location then return nil end
   local uri = location.uri as string
   local document = server.documents[uri]
   if not document then return nil end
   local start = (location.range as Range).start.line + 1
   local first = document.lines[start] or ""
   if not (first:match("%f[%a]record%f[%A]") or first:match("%f[%a]interface%f[%A]") or first:match("%f[%a]enum%f[%A]")) then
      return first:match("^%s*(.-)%s*$")
   end
   local out: {string} = {}
   local depth = 0
   for y = start, math.min(#document.lines, start + 100) do
      local line = document.lines[y]
      table.insert(out, line)
      if line:match("%f[%a]record%f[%A]") or line:match("%f[%a]interface%f[%A]") or line:match("%f[%a]enum%f[%A]") then depth = depth + 1 end
      if line:match("^%s*end%f[%A]") then
         depth = depth - 1
         if depth <= 0 then break end
      end
   end
   return table.concat(out, "\n")
end

local function symbol_at(server: Server, document: Document, position: Position): AnyObject
   analyze_document(server, document)
   local token = token_at(document, position)
   if not token or token.kind ~= "identifier" then return nil end
   return {
      name = token.tk,
      kind = 12,
      uri = document.uri,
      range = make_range(document.lines, token.y, token.x, #token.tk),
      selectionRange = make_range(document.lines, token.y, token.x, #token.tk),
      data = { uri = document.uri, name = token.tk },
   }
end

local function all_word_ranges(document: Document, name: string): AnyArray
   local result = array()
   for _, token in ipairs(document.tokens_by_name[name] or {}) do
      table.insert(result, make_range(document.lines, token.y, token.x, #token.tk))
   end
   return result
end

local function all_locations(server: Server, name: string): AnyArray
   ensure_workspace_index(server)
   local result = array()
   for _, document in pairs(server.documents) do
      if document.text:find(name, 1, true) then
         analyze_document(server, document)
         for _, range in ipairs(all_word_ranges(document, name)) do
            table.insert(result, { uri = document.uri, range = range })
         end
      end
   end
   return result
end

local function type_identity(info: TypeInfo): string
   if not info or not info.file or info.file == "" then return nil end
   return info.file .. ":" .. tostring(info.y) .. ":" .. tostring(info.x)
end

local function resolved_locations(server: Server, origin: Document, token: Token, position: Position): AnyArray
   ensure_workspace_index(server)
   local origin_info: TypeInfo = type_info(origin, position, token)
   local identity = type_identity(origin_info)
   if not identity then return all_locations(server, token.tk) end
   local result = array()
   for _, document in pairs(server.documents) do
      if document.text:find(token.tk, 1, true) then
         analyze_document(server, document)
         for _, candidate in ipairs(document.tokens_by_name[token.tk] or {}) do
            local line = document.lines[candidate.y] or ""
            local candidate_position: Position = {
               line = candidate.y - 1,
               character = byte_to_utf16(line:sub(1, candidate.x - 1), candidate.x - 1),
            }
            local info: TypeInfo = type_info(document, candidate_position, candidate)
               if type_identity(info) == identity then
                  table.insert(result, { uri = document.uri, range = make_range(document.lines, candidate.y, candidate.x, #candidate.tk) })
               end
         end
      end
   end
   return result
end

local function completion_kind_for_type(info: TypeInfo): integer
   if not info then return 6 end
   local kind = info.t
   if kind == 0x00000020 then return 3 end
   if kind == 0x00020008 or kind == 0x00100008 then return 7 end
   return 6
end

local function completion_items(server: Server, document: Document, position: Position): AnyArray
   analyze_document(server, document)
   local entries: {AnyObject} = {}
   local seen: {string: boolean} = {}
   local function add(label: string, kind: integer, detail: string, documentation?: string, method?: boolean)
      if label ~= "" and not seen[label] then
         seen[label] = true
         local entry: AnyObject = { label = label, kind = kind, detail = detail, sortText = method and ("0_" .. label) or ("1_" .. label) }
         if documentation then entry.documentation = { kind = "markdown", value = documentation } end
         if method then entry.insertText = label .. "(${1})"; entry.insertTextFormat = 2 end
         table.insert(entries, entry)
      end
   end

   local cursor_token, index = token_at_or_before(document, position)
   local previous, previous_index: Token, integer
   if cursor_token and (cursor_token.tk == "." or cursor_token.tk == ":") then
      previous, previous_index = cursor_token, index
   else
      previous, previous_index = previous_token(document, index)
   end
   if previous and (previous.tk == "." or previous.tk == ":") then
      local receiver = previous_token(document, previous_index)
      local receiver_position: Position
      if receiver then
         local receiver_line = document.lines[receiver.y] or ""
         receiver_position = {
            line = receiver.y - 1,
            character = byte_to_utf16(receiver_line:sub(1, math.max(0, receiver.x - 1)), receiver.x - 1),
         }
      end
      local info: TypeInfo
      if receiver then
         info = type_info(document, receiver_position, receiver)
      end
      if info and not info.fields and info.ref and document.type_report then
         info = document.type_report.types[info.ref] or info
      end
      if info and info.fields then
         for field, type_id in pairs(info.fields) do
            local field_type = document.type_report.types[type_id]
            local detail = field_type and field_type.str or "field"
            add(field, completion_kind_for_type(field_type), detail, nil, detail:match("^function") ~= nil)
         end
      end
      if not info or not info.fields then
         local receiver_field = receiver and first_syntax_field(document, receiver.tk)
         local receiver_type = receiver_field and (receiver_field.detail:match("([%a_][%w_]*)%s*<") or receiver_field.detail:match("([%a_][%w_]*)%s*$"))
         local candidates: {Document:boolean} = receiver_type and server.type_documents[receiver_type]
         if receiver_type and not candidates then ensure_workspace_index(server); candidates = server.type_documents[receiver_type] end
         if not candidates then candidates = { [document] = true } end
         for candidate in pairs(candidates) do
            analyze_document(server, candidate)
            local available = receiver_type and candidate.fields_by_type[receiver_type] or candidate.fields_by_name
            for name, fields in pairs(available or {}) do
               local field = fields[1]
               local method = field.detail:match("^function%f[%A]") ~= nil
               local docs = documentation_in_tokens(candidate.tokens, field.token.y, field.token.x, field.token.tk)
               add(name, method and 2 or 5, field.detail, docs, method)
            end
         end
      end
   else
      local report = document.type_report
      if report then
         local line = (position.line or 0) + 1
         local content = document.lines[line] or ""
         local x = utf16_to_byte(content, position.character or 0) + 1
         local scoped = report:symbols_in_scope(document.path, line, x)
         for name, type_id in pairs(scoped) do
            local info = report.types[type_id]
            add(name, completion_kind_for_type(info), info and info.str or "value")
         end
         for name, type_id in pairs(report.globals or {}) do
            local info = report.types[type_id]
            add(name, completion_kind_for_type(info), info and info.str or "global")
         end
      end
      for _, keyword in ipairs(COMPLETION_KEYWORDS) do
         add(keyword, 14, "keyword")
      end
      for _, candidate in pairs(server.documents) do
         if candidate.analysis_version >= 0 then
            for _, macro in ipairs(candidate.macros or {}) do add(macro.name, 3, "Teal macro") end
         end
      end
   end
   table.sort(entries, function(a: AnyObject, b: AnyObject): boolean return (a.label as string) < (b.label as string) end)
   local result = array()
   for _, entry in ipairs(entries) do table.insert(result, entry) end
   return result
end

local function prettify_macro_expansion(code: string): string
   local out: {string} = {}
   local quote: string
   local escaped = false
   local table_depth = 0
   local function_parens = -1
   local function newline()
      if out[#out] ~= "\n" then table.insert(out, "\n") end
   end
   local index = 1
   while index <= #code do
      local char = code:sub(index, index)
      if quote then
         table.insert(out, char)
         if escaped then
            escaped = false
         elseif char == "\\" then
            escaped = true
         elseif char == quote then
            quote = nil
         end
      elseif char == '"' or char == "'" then
         quote = char
         table.insert(out, char)
      elseif char:match("[%a_]") then
         local word = code:sub(index):match("^[%a_][%w_]*")
         if word == "else" or word == "elseif" or word == "end" or word == "until" then newline() end
         table.insert(out, word)
         index = index + #word - 1
         if word == "function" then function_parens = 0 end
         if word == "then" or word == "do" or word == "repeat" or word == "else" then newline() end
      elseif char == ";" then
         newline()
         while code:sub(index + 1, index + 1):match("[ \t]") do index = index + 1 end
      elseif char == "{" then
         table.insert(out, char)
         local rest = code:sub(index + 1)
         if not rest:match("^%s*}") then table_depth = table_depth + 1; newline() end
      elseif char == "}" then
         if table_depth > 0 then newline(); table_depth = table_depth - 1 end
         table.insert(out, char)
      elseif char == "," and table_depth > 0 then
         table.insert(out, char)
         newline()
         while code:sub(index + 1, index + 1):match("[ \t]") do index = index + 1 end
      elseif char == "(" and function_parens >= 0 then
         function_parens = function_parens + 1
         table.insert(out, char)
      elseif char == ")" and function_parens > 0 then
         function_parens = function_parens - 1
         table.insert(out, char)
         if function_parens == 0 then function_parens = -1; newline() end
      else
         table.insert(out, char)
      end
      index = index + 1
   end

   local formatted: {string} = {}
   local indent = 0
   for raw in (table.concat(out) .. "\n"):gmatch("(.-)\r?\n") do
      local line = raw:match("^%s*(.-)%s*$")
      if line ~= "" then
         if line:match("^(end%f[%A])") or line:match("^until%f[%A]") or line:match("^else%f[%A]") or line:match("^elseif%f[%A]") or line:match("^}") then
            indent = math.max(0, indent - 1)
         end
         table.insert(formatted, string.rep("   ", indent) .. line)
         local opens = 0
         for _ in line:gmatch("%f[%a]function%f[%A]") do opens = opens + 1 end
         if line:match("then%s*$") then opens = opens + 1 end
         if line:match("do%s*$") then opens = opens + 1 end
         if line:match("repeat%s*$") then opens = opens + 1 end
         if line:match("{%s*$") then opens = opens + 1 end
         indent = indent + opens
         if line:match("^else%f[%A]") or line:match("^elseif%f[%A]") then indent = indent + 1 end
      end
   end
   return table.concat(formatted, "\n")
end

local function hover(server: Server, document: Document, position: Position): AnyObject
   analyze_document(server, document)
   local token = token_at(document, position)
   if not token then return nil end
   local info: TypeInfo = type_info(document, position, token)
   local macro_detail: string
   local _, token_index = token_at(document, position)
   local following = next_token(document, token_index)
   if following and following.tk == "!" then
      macro_detail = "Teal macro invocation"
   end
   local syntax_field: SyntaxField
   local syntax_document: Document
   if not info and not macro_detail then syntax_field, syntax_document = syntax_member(server, document, token) end
   if not info and not macro_detail and not syntax_field then return nil end
   local text = "`" .. token.tk .. "`"
   if info then text = text .. "\n\n```teal\n" .. info.str .. "\n```" end
   if syntax_field then
      local detail = syntax_field.detail:match("^function%f[%A]") and syntax_field.detail or (token.tk .. ": " .. syntax_field.detail)
      text = text .. "\n\n```teal\n" .. detail .. "\n```"
   end
   if macro_detail then
      local expansion: string
      local by_line = document.macro_expansions[token.y]
      if by_line then
         expansion = by_line[token.x]
         if not expansion then
            local closest = -1
            for x, value in pairs(by_line) do
               if x <= token.x and x > closest then closest, expansion = x, value end
            end
         end
      end
      if not expansion and document.module then
         document.generated = document.generated or document.module:gen()
         local generated_line = split_lines(document.generated)[token.y]
         expansion = generated_line and generated_line:match("^%s*(.-)%s*$")
      end
      text = text .. "\n\n**Macro expansion**"
      if expansion then text = text .. "\n\n```lua\n" .. prettify_macro_expansion(expansion) .. "\n```" end
   end
   local documentation = documentation_in_tokens(document.tokens, token.y, token.x, token.tk)
   if not documentation and info and info.file and info.file ~= "" then
      local target_path = info.file
      if target_path:sub(1, 1) ~= "/" and not target_path:match("^%a:[/\\]") then target_path = server.root .. "/" .. target_path end
      for _, candidate in pairs(server.documents) do
         if candidate.path == target_path then
            documentation = documentation_in_tokens(candidate.tokens, info.y, info.x, token.tk)
            break
         end
      end
      if not documentation then documentation = documentation_from_file(target_path, info.y, info.x, token.tk) end
   end
   if not documentation then
      local location = find_definition(server, document, token.tk, position)
      if location then
         local target_uri = location.uri as string
         local target_range = location.range as Range
         local target = server.documents[target_uri]
         if target then
            local y = target_range.start.line + 1
            local line = target.lines[y] or ""
            local x = utf16_to_byte(line, target_range.start.character) + 1
            documentation = documentation_in_tokens(target.tokens, y, x, token.tk)
         end
      end
   end
   if documentation then text = text .. "\n\n---\n\n" .. documentation end
   if syntax_field and syntax_document then
      local syntax_doc = documentation_in_tokens(syntax_document.tokens, syntax_field.token.y, syntax_field.token.x, syntax_field.token.tk)
      if syntax_doc and syntax_doc ~= documentation then text = text .. "\n\n---\n\n" .. syntax_doc end
   end
   local record_info = info
   if record_info and not record_info.fields and record_info.ref and document.type_report then
      record_info = document.type_report.types[record_info.ref] or record_info
   end
   if not macro_detail and not syntax_field and not (record_info and record_info.fields) then
      local location = find_definition(server, document, token.tk, position)
      local preview = declaration_preview(server, location)
      if preview and preview ~= "" then text = text .. "\n\n**Definition**\n\n```teal\n" .. preview .. "\n```" end
   end
   if info and info.file and info.file ~= "" and not macro_detail then
      text = text .. "\n\nDefined in `" .. info.file .. ":" .. tostring(info.y) .. ":" .. tostring(info.x) .. "`."
   end
   if record_info and record_info.fields then
      local type_name = info.str and info.str:match("([%a_][%w_]*)%s*$")
      local type_location = type_name and type_declaration_location(document, type_name)
      if not type_location and type_name then
         for _, candidate in pairs(server.documents) do
            type_location = type_declaration_location(candidate, type_name)
            if type_location then break end
         end
      end
      if not type_location and type_name then
         ensure_workspace_index(server)
         for _, candidate in pairs(server.documents) do
            analyze_document(server, candidate)
            type_location = type_declaration_location(candidate, type_name)
            if type_location then break end
         end
      end
      local record_definition = declaration_preview(server, type_location)
      if record_definition and record_definition ~= "" then
         text = text .. "\n\n**Type definition**\n\n```teal\n" .. record_definition .. "\n```"
      end
   end
   if macro_detail then text = text .. "\n\n" .. macro_detail .. ". Expanded by the compiler before type checking." end
   return {
      contents = { kind = "markdown", value = text },
      range = make_range(document.lines, token.y, token.x, #token.tk),
   }
end

local function signature_help(server: Server, document: Document, position: Position): AnyObject
   analyze_document(server, document)
   local token, index = token_at(document, position)
   local before = previous_token(document, index)
   if token and token.tk == "(" then before = previous_token(document, index) end
   if not before then return nil end
   local info: TypeInfo = type_info(document, position, before)
   if not info then return nil end
   local documentation = documentation_in_tokens(document.tokens, before.y, before.x, before.tk) or "Inferred by the Teal type checker."
   return {
      signatures = mark_array({ { label = before.tk .. ": " .. info.str, documentation = { kind = "markdown", value = documentation } } } as AnyArray),
      activeSignature = 0,
      activeParameter = 0,
   }
end

local function document_symbols(server: Server, document: Document): AnyArray
   analyze_document(server, document)
   if document.document_symbols_cache then return document.document_symbols_cache end
   local result = array()
   local declaration_kinds: {string: integer} = {
      ["record"] = 23, ["interface"] = 11, ["enum"] = 10, ["type"] = 26, ["function"] = 12, ["macro"] = 12,
   }
   for i, token in ipairs(document.tokens) do
      local kind = declaration_kinds[token.tk]
      if kind then
         local following, _ = next_token(document, i)
         if following and following.kind == "identifier" then
            local selection = make_range(document.lines, following.y, following.x, #following.tk)
            table.insert(result, {
               name = following.tk,
               detail = token.tk == "macro" and "Teal macro" or token.tk,
               kind = kind,
               range = selection,
               selectionRange = selection,
            })
         end
      end
   end
   document.document_symbols_cache = result
   return result
end

local function workspace_symbols(server: Server, query: string): AnyArray
   ensure_workspace_index(server)
   local result = array()
   local needle = (query or ""):lower()
   for _, document in pairs(server.documents) do
      for _, raw_symbol in ipairs(document_symbols(server, document)) do
         local symbol = raw_symbol as AnyObject
         local symbol_name = symbol.name as string
         if needle == "" or symbol_name:lower():find(needle, 1, true) then
            table.insert(result, {
               name = symbol_name,
               kind = symbol.kind,
               containerName = "Teal",
               location = { uri = document.uri, range = symbol.selectionRange },
            })
         end
      end
   end
   return result
end

local function semantic_token_kind(document: Document, token: Token, index: integer): integer, integer
   if token.kind == "string" then return 16, 0 end
   if token.kind == "number" or token.kind == "integer" then return 17, 0 end
   if KEYWORDS[token.tk] then return 14, 0 end
   if token.kind ~= "identifier" then
      if token.kind == "op" or token.tk:match("^[+*/%%<>=~#%^&|%-]+$") then return 18, 0 end
      return nil
   end
   local following = next_token(document, index)
   local previous = previous_token(document, index)
   local declaration = previous and (previous.tk == "local" or previous.tk == "global" or previous.tk == "function" or previous.tk == "record" or previous.tk == "interface" or previous.tk == "enum" or previous.tk == "type" or previous.tk == "macro")
   local modifiers = declaration and 1 or 0
   if following and following.tk == "!" then return 13, modifiers end
   if previous and previous.tk == "record" then return 4, modifiers end
   if previous and previous.tk == "interface" then return 3, modifiers end
   if previous and previous.tk == "enum" then return 2, modifiers end
   if previous and previous.tk == "type" then return 1, modifiers end
   if previous and previous.tk == "macro" then return 13, modifiers end
   if previous and previous.tk == ":" then
      if following and following.tk == "(" then return 12, modifiers end
      return 1, modifiers
   end
   if previous and previous.tk == "." then return 9, modifiers end
   if previous and (previous.tk == "<" or previous.tk == "|" or previous.tk == "is") then return 1, modifiers end
   if previous and previous.tk == "function" then return 11, modifiers end
   if following and following.tk == ":" then
      local after_colon = next_token(document, document.token_indices[following])
      if after_colon and after_colon.tk == "function" then return 12, 1 end
      return 7, 1
   end
   local line = document.lines[token.y] or ""
   local position: Position = { line = token.y - 1, character = byte_to_utf16(line:sub(1, token.x - 1), token.x - 1) }
   local info: TypeInfo = type_info(document, position, token)
   if info and info.t == 0x00000020 then return 11, modifiers end
   if info and info.enums then return 2, modifiers end
   if info and info.fields then return 4, modifiers end
   return 8, modifiers
end

local function semantic_tokens(server: Server, document: Document, wanted?: Range): AnyObject
   analyze_document(server, document)
   if not wanted and document.semantic_full then return document.semantic_full end
   local data = array()
   local previous_line, previous_start = 0, 0
   for index, token in ipairs(document.tokens) do
      if token.kind ~= "$EOF$" and (not wanted or (token.y - 1 >= wanted.start.line and token.y - 1 <= wanted["end"].line)) then
         local token_type, modifiers = semantic_token_kind(document, token, index)
         if token_type then
            local line = token.y - 1
            local start = byte_to_utf16((document.lines[token.y] or ""):sub(1, math.max(0, token.x - 1)), token.x - 1)
            local delta_line = line - previous_line
            local delta_start = delta_line == 0 and start - previous_start or start
            table.insert(data, delta_line)
            table.insert(data, delta_start)
            table.insert(data, utf16_length(token.tk))
            table.insert(data, token_type)
            table.insert(data, modifiers or 0)
            previous_line, previous_start = line, start
         end
      end
   end
   local result: AnyObject = { data = data }
   if not wanted then document.semantic_full = result end
   return result
end

local function folding_ranges(server: Server, document: Document): AnyArray
   analyze_document(server, document)
   if document.folding_ranges_cache then return document.folding_ranges_cache end
   local result = array()
   local stack: {Token} = {}
   local opens: {string: boolean} = { ["do"] = true, ["function"] = true, ["if"] = true, ["for"] = true, ["while"] = true, ["repeat"] = true, ["record"] = true, ["interface"] = true, ["enum"] = true }
   for _, token in ipairs(document.tokens) do
      if opens[token.tk] then
         table.insert(stack, token)
      elseif token.tk == "end" or token.tk == "until" then
         local opening = table.remove(stack)
         if opening and token.y > opening.y then
            table.insert(result, { startLine = opening.y - 1, endLine = token.y - 1, kind = "region" })
         end
      end
   end
   document.folding_ranges_cache = result
   return result
end

local function formatting(document: Document): AnyArray
   local lines = split_lines(document.text)
   local changed = false
   for index, line in ipairs(lines) do
      local trimmed = line:gsub("[ \t]+$", "")
      if trimmed ~= line then changed = true; lines[index] = trimmed end
   end
   if not changed then return array() end
   return mark_array({ { range = full_range(document.lines), newText = table.concat(lines, "\n") } } as AnyArray)
end

local function code_actions(document: Document): AnyArray
   local actions = array()
   if #(document.diagnostics or {}) > 0 then
      table.insert(actions, {
         title = "Recheck with Teal",
         kind = "source.organizeImports",
         command = { title = "Recheck with Teal", command = "tl.check", arguments = mark_array({ document.uri } as AnyArray) },
      })
      table.insert(actions, {
         title = "Generate Lua with Teal",
         kind = "source",
         command = { title = "Generate Lua with Teal", command = "tl.generate", arguments = mark_array({ document.uri } as AnyArray) },
      })
   end
   return actions
end

local function selection_ranges(document: Document, positions: AnyArray): AnyArray
   local result = array()
   for _, raw_position in ipairs(positions) do
      local position = raw_position as Position
      local token = token_at(document, position)
      local line = (position.line or 0) + 1
      local token_range = token and make_range(document.lines, token.y, token.x, #token.tk) or make_range(document.lines, line, 1, #(document.lines[line] or ""))
      table.insert(result, {
         range = token_range,
         parent = { range = make_range(document.lines, line, 1, #(document.lines[line] or "")) },
      })
   end
   return result
end

local function inlay_hints(server: Server, document: Document, wanted: Range): AnyArray
   analyze_document(server, document)
   local result = array()
   if not document.type_report then return result end
   for _, symbol in ipairs(document.symbols) do
      local y, x, name, type_id = symbol[1], symbol[2], symbol[3], symbol[4]
      if y - 1 >= wanted.start.line and y - 1 <= wanted["end"].line then
         local info = document.type_report.types[type_id]
         if info and info.str and info.str ~= "unknown" then
            table.insert(result, {
               position = { line = y - 1, character = byte_to_utf16((document.lines[y] or ""):sub(1, x + #name - 1), x + #name - 1) },
               label = ": " .. info.str,
               kind = 1,
               paddingLeft = true,
            })
         end
      end
   end
   return result
end

local function inline_values(server: Server, document: Document, wanted: Range): AnyArray
   analyze_document(server, document)
   local result = array()
   for _, symbol in ipairs(document.symbols) do
      local y, x, name = symbol[1], symbol[2], symbol[3]
      if y - 1 >= wanted.start.line and y - 1 <= wanted["end"].line then
         table.insert(result, {
            range = make_range(document.lines, y, x, #name),
            variableName = name,
            caseSensitiveLookup = true,
         })
      end
   end
   return result
end

local function document_links(server: Server, document: Document): AnyArray
   local result = array()
   for index, token in ipairs(document.tokens) do
      if token.tk == "require" then
         local open, open_index = next_token(document, index)
         local value = open and next_token(document, open_index)
         if open and open.tk == "(" and value and value.kind == "string" then
            local module_name = value.tk:match('^[' .. "\"'" .. '](.-)[' .. "\"'" .. ']$')
            if module_name then
               local relative = module_name:gsub("%.", "/") .. ".tl"
               local path = server.root .. "/" .. relative
               local candidates: {string} = { path, server.root .. "/" .. module_name:gsub("%.", "/") .. "/init.tl" }
               for _, include in ipairs(server.tlconfig.include_dir or {}) do
                  local base = include
                  if base:sub(1, 1) ~= "/" and not base:match("^%a:[/\\]") then base = server.root .. "/" .. base end
                  table.insert(candidates, base .. "/" .. relative)
                  table.insert(candidates, base .. "/" .. module_name:gsub("%.", "/") .. "/init.tl")
               end
               for _, candidate in ipairs(candidates) do
                  local file = io.open(candidate, "rb")
                  if file then file:close(); path = candidate; break end
               end
               table.insert(result, {
                  range = make_range(document.lines, value.y, value.x, #value.tk),
                  target = path_to_uri(path),
                  tooltip = "Open module " .. module_name,
               })
            end
         end
      end
   end
   return result
end

local function linked_editing(document: Document, position: Position): AnyObject
   local token = token_at(document, position)
   if not token or token.kind ~= "identifier" then return nil end
   return { ranges = all_word_ranges(document, token.tk), wordPattern = "[A-Za-z_][A-Za-z0-9_]*" }
end

local function code_lenses(server: Server, document: Document): AnyArray
   local result = array()
   for _, raw_symbol in ipairs(document_symbols(server, document)) do
      local symbol = raw_symbol as AnyObject
      if symbol.kind == 12 then
         local selection = symbol.selectionRange as Range
         table.insert(result, {
            range = selection,
            data = { uri = document.uri, name = symbol.name, position = selection.start },
         })
      end
   end
   return result
end

local function document_colors(document: Document): AnyArray
   local result = array()
   for _, token in ipairs(document.tokens) do
      if token.kind == "string" then
         local hex = token.tk:match("#(%x%x)(%x%x)(%x%x)(%x?%x?)")
         if hex then
            local red, green, blue, alpha = token.tk:match("#(%x%x)(%x%x)(%x%x)(%x?%x?)")
            table.insert(result, {
               range = make_range(document.lines, token.y, token.x, #token.tk),
               color = {
                  red = (tonumber(red, 16) or 0) / 255,
                  green = (tonumber(green, 16) or 0) / 255,
                  blue = (tonumber(blue, 16) or 0) / 255,
                  alpha = alpha and #alpha == 2 and (tonumber(alpha, 16) or 255) / 255 or 1,
               },
            })
         end
      end
   end
   return result
end

local function type_hierarchy_item(server: Server, document: Document, position: Position): AnyObject
   local item = symbol_at(server, document, position)
   if not item then return nil end
   item.kind = 23
   return item
end

local function server_capabilities(server: Server): AnyObject
   local token_types = array()
   for _, token_type in ipairs({
      "namespace", "type", "enum", "interface", "struct", "typeParameter", "enumMember",
      "parameter", "variable", "property", "event", "function", "method", "macro",
      "keyword", "comment", "string", "number", "operator"
   }) do
      table.insert(token_types, token_type)
   end
   local capabilities: AnyObject = {
      positionEncoding = "utf-16",
      textDocumentSync = { openClose = true, change = 2, willSave = true, willSaveWaitUntil = true, save = { includeText = true } },
      workspace = { workspaceFolders = { supported = true, changeNotifications = true } },
      executeCommandProvider = { commands = mark_array({ "tl.check", "tl.generate", "tl.restart" } as AnyArray) },
   }
   if lsp_enabled(server, "hover") then capabilities.hoverProvider = true end
   if lsp_enabled(server, "definitions") then
      capabilities.definitionProvider = true; capabilities.declarationProvider = true
      capabilities.typeDefinitionProvider = true; capabilities.implementationProvider = true
   end
   if lsp_enabled(server, "references") then capabilities.referencesProvider = true; capabilities.documentHighlightProvider = true end
   if lsp_enabled(server, "symbols") then capabilities.documentSymbolProvider = true; capabilities.workspaceSymbolProvider = true end
   if lsp_enabled(server, "rename") then capabilities.renameProvider = { prepareProvider = true } end
   if lsp_enabled(server, "completion") then
      capabilities.completionProvider = { triggerCharacters = mark_array({ ".", ":", "<", "!", "\n" } as AnyArray), resolveProvider = true }
      capabilities.signatureHelpProvider = { triggerCharacters = mark_array({ "(", "," } as AnyArray) }
   end
   if lsp_enabled(server, "formatting") then
      capabilities.documentFormattingProvider = true; capabilities.documentRangeFormattingProvider = true
      capabilities.documentOnTypeFormattingProvider = { firstTriggerCharacter = "\n", moreTriggerCharacter = mark_array({ "end" } as AnyArray) }
   end
   if lsp_enabled(server, "folding_ranges") then capabilities.foldingRangeProvider = true end
   if lsp_enabled(server, "selection_ranges") then capabilities.selectionRangeProvider = true end
   if lsp_enabled(server, "inlay_hints") then capabilities.inlayHintProvider = true end
   if lsp_enabled(server, "inline_values") then capabilities.inlineValueProvider = true end
   if lsp_enabled(server, "document_links") then capabilities.documentLinkProvider = { resolveProvider = false } end
   if lsp_enabled(server, "linked_editing") then capabilities.linkedEditingRangeProvider = true end
   if lsp_enabled(server, "code_lens") then capabilities.codeLensProvider = { resolveProvider = true } end
   if lsp_enabled(server, "call_hierarchy") then capabilities.callHierarchyProvider = true end
   if lsp_enabled(server, "type_hierarchy") then capabilities.typeHierarchyProvider = true end
   if lsp_enabled(server, "document_colors") then capabilities.colorProvider = true end
   if lsp_enabled(server, "monikers") then capabilities.monikerProvider = true end
   if lsp_enabled(server, "diagnostics") then capabilities.diagnosticProvider = { identifier = "teal", interFileDependencies = true, workspaceDiagnostics = true } end
   if lsp_enabled(server, "code_actions") then capabilities.codeActionProvider = { codeActionKinds = mark_array({ "quickfix", "source" } as AnyArray) } end
   if lsp_enabled(server, "semantic_highlighting") then
      capabilities.semanticTokensProvider = {
         legend = { tokenTypes = token_types, tokenModifiers = mark_array({ "declaration", "readonly" } as AnyArray) },
         full = { delta = true }, range = true,
      }
   end
   return capabilities
end

local function document_for(server: Server, uri: string): Document
   local document = server.documents[uri]
   if document then return document end
   local path = uri_to_path(uri)
   local file = io.open(path, "rb")
   local text = file and file:read("*a") or ""
   if file then file:close() end
   document = document_new(uri, text, 0)
   server.documents[uri] = document
   index_text_hints(server, document)
   return document
end

local function index_directory(directory: string, files: {string})
   local mode = lfs.attributes(directory, "mode")
   if mode ~= "directory" then return end
   for entry in lfs.dir(directory) do
      if entry ~= "." and entry ~= ".." and entry ~= ".git" and entry ~= "build" and entry ~= "lua_modules" then
         local path = directory .. "/" .. entry
         local entry_mode = lfs.attributes(path, "mode")
         if entry_mode == "directory" then
            index_directory(path, files)
         elseif entry_mode == "file" and path:match("%.tl$") then
            table.insert(files, path)
         end
      end
   end
end

ensure_workspace_index = function(server: Server)
   if not lsp_enabled(server, "workspace_index") then return end
   if server.workspace_indexed then return end
   server.workspace_indexed = true
   local roots: {string:boolean} = {}
   local root_list: {string} = {}
   for _, include in ipairs(server.tlconfig.include_dir or {}) do
      local root = include
      if root:sub(1, 1) ~= "/" and not root:match("^%a:[/\\]") then root = server.root .. "/" .. root end
      if not roots[root] then roots[root] = true; table.insert(root_list, root) end
   end
   table.sort(root_list)

   local cache_dir = server.root .. "/.cache"
   local cache_subdir = cache_dir .. "/tl-lsp"
   local cache_path = cache_subdir .. "/workspace-index.json"
   local files: {string} = {}
   local use_cache = lsp_enabled(server, "cache")
   local cache = use_cache and io.open(cache_path, "rb")
   if cache then
      local decoded = json_decode(cache:read("*a") or "")
      cache:close()
      if decoded and decoded.version == teal.version() and os.time() - (decoded.generated as integer or 0) <= 60 then
         local cached_roots = decoded.roots as AnyArray
         local cached_files = decoded.files as AnyArray
         local valid = #cached_roots == #root_list
         for index, root in ipairs(root_list) do
            local cached = cached_roots[index] as AnyObject
            local modified = lfs.attributes(root, "modification") as integer or 0
            if not cached or cached.path ~= root or cached.modified ~= modified then valid = false; break end
         end
         if valid then
            for _, path in ipairs(cached_files) do table.insert(files, path as string) end
         end
      end
   end
   if #files == 0 then
      local encoded_roots = array()
      for _, root in ipairs(root_list) do
         index_directory(root, files)
         table.insert(encoded_roots, { path = root, modified = lfs.attributes(root, "modification") as integer or 0 })
      end
      table.sort(files)
      if use_cache then lfs.mkdir(cache_dir); lfs.mkdir(cache_subdir) end
      local output = use_cache and io.open(cache_path, "wb")
      if output then
         local encoded_files = array()
         for _, path in ipairs(files) do table.insert(encoded_files, path) end
         output:write(json_encode({ version = teal.version(), generated = os.time(), roots = encoded_roots, files = encoded_files } as AnyObject))
         output:close()
      end
   end
   for _, path in ipairs(files) do
      local uri = path_to_uri(path)
      if not server.documents[uri] then document_for(server, uri) end
   end
end

local function request_uri(params: AnyObject): string
   local text_document = params.textDocument as AnyObject
   return text_document and text_document.uri as string
end

local function handle_notification(server: Server, method: string, params: AnyObject): boolean
   if method == "initialized" or method == "$/cancelRequest" then
      return true
   elseif method == "workspace/didChangeConfiguration" or method == "workspace/didChangeWorkspaceFolders" or method == "workspace/didChangeWatchedFiles" then
      server.workspace_indexed = false
      server.compiler = nil
      for _, document in pairs(server.documents) do
         document.analysis_version = -1
         publish_diagnostics(server, document)
      end
      return true
   elseif method == "exit" then
      return false
   elseif method == "textDocument/didOpen" then
      local item = params.textDocument as AnyObject
      local uri = item.uri as string
      local document = document_new(uri, item.text as string or "", item.version as integer or 0)
      server.documents[uri] = document
      index_text_hints(server, document)
      server.pending_diagnostics[document] = true
   elseif method == "textDocument/didChange" then
      local text_document = params.textDocument as AnyObject
      local uri = text_document.uri as string
      local document = document_for(server, uri)
      for _, change in ipairs(params.contentChanges as AnyArray or {}) do
         apply_change(document, change as AnyObject)
      end
      document.version = text_document.version as integer or document.version + 1
      document.analysis_version = -1
      index_text_hints(server, document)
      server.pending_diagnostics[document] = true
   elseif method == "textDocument/didSave" then
      local text_document = params.textDocument as AnyObject
      local uri = text_document.uri as string
      local document = document_for(server, uri)
      if params.text then
         document.text = params.text as string
         document.lines = split_lines(document.text)
         document.analysis_version = -1
         index_text_hints(server, document)
      end
      publish_diagnostics(server, document)
   elseif method == "textDocument/didClose" then
      local text_document = params.textDocument as AnyObject
      local uri = text_document.uri as string
      server.documents[uri] = nil
      notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = array() })
   end
   return true
end

local function handle_request(server: Server, method: string, params: AnyObject): any, AnyObject
   if method == "initialize" then
      local root_uri = params.rootUri
      local folders = params.workspaceFolders as AnyArray
      if not root_uri and folders and folders[1] then
         root_uri = (folders[1] as AnyObject).uri
      end
      if root_uri and root_uri ~= JSON_NULL then
         server.root = uri_to_path(root_uri as string)
         load_workspace_config(server)
      end
      return {
         capabilities = server_capabilities(server),
         serverInfo = { name = "Teal", version = teal.version() },
      }
   elseif method == "shutdown" then
      server.shutdown = true
      return JSON_NULL
   elseif method == "textDocument/hover" then
      local uri = request_uri(params)
      return hover(server, document_for(server, uri), params.position as Position)
   elseif method == "textDocument/completion" then
      local uri = request_uri(params)
      return { isIncomplete = false, items = completion_items(server, document_for(server, uri), params.position as Position) }
   elseif method == "completionItem/resolve" then
      local item = params
      local label = item.label as string
      local documentation: string
      for _, document in pairs(server.documents) do
         analyze_document(server, document)
         for _, token in ipairs(document.tokens) do
            if token.tk == label then
               documentation = documentation_in_tokens(document.tokens, token.y, token.x, label)
               if documentation then break end
            end
         end
         if documentation then break end
      end
      item.documentation = { kind = "markdown", value = documentation or "Resolved by the Teal compiler-backed language server." }
      return item
   elseif method == "textDocument/signatureHelp" then
      local uri = request_uri(params)
      return signature_help(server, document_for(server, uri), params.position as Position)
   elseif method == "textDocument/definition" or method == "textDocument/declaration" or method == "textDocument/typeDefinition" or method == "textDocument/implementation" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      local position = params.position as Position
      local token = token_at(document, position)
      if token then return find_definition(server, document, token.tk, position) end
      return JSON_NULL
   elseif method == "textDocument/references" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      local position = params.position as Position
      local token = token_at(document, position)
      if token then return resolved_locations(server, document, token, position) end
      return array()
   elseif method == "textDocument/documentHighlight" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      local position = params.position as Position
      local token = token_at(document, position)
      local result = array()
      if token then
         for _, raw_location in ipairs(resolved_locations(server, document, token, position)) do
            local location = raw_location as AnyObject
            if location.uri == uri then table.insert(result, { range = location.range, kind = 1 }) end
         end
      end
      return result
   elseif method == "textDocument/prepareRename" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      local token = token_at(document, params.position as Position)
      if token and token.kind == "identifier" and not KEYWORDS[token.tk] then
         return make_range(document.lines, token.y, token.x, #token.tk)
      end
      return JSON_NULL
   elseif method == "textDocument/rename" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      local position = params.position as Position
      local token = token_at(document, position)
      if not token then return { changes = {} } end
      local changes: {string: AnyArray} = {}
      for _, raw_location in ipairs(resolved_locations(server, document, token, position)) do
         local location = raw_location as AnyObject
         local other_uri = location.uri as string
         local edits = changes[other_uri]
         if not edits then edits = array(); changes[other_uri] = edits end
         table.insert(edits, { range = location.range, newText = params.newName })
      end
      return { changes = changes }
   elseif method == "textDocument/documentSymbol" then
      local uri = request_uri(params)
      return document_symbols(server, document_for(server, uri))
   elseif method == "workspace/symbol" then
      return workspace_symbols(server, params.query as string)
   elseif method == "textDocument/semanticTokens/full" then
      local uri = request_uri(params)
      return semantic_tokens(server, document_for(server, uri))
   elseif method == "textDocument/semanticTokens/range" then
      local uri = request_uri(params)
      return semantic_tokens(server, document_for(server, uri), params.range as Range)
   elseif method == "textDocument/semanticTokens/full/delta" then
      local uri = request_uri(params)
      return semantic_tokens(server, document_for(server, uri))
   elseif method == "textDocument/foldingRange" then
      local uri = request_uri(params)
      return folding_ranges(server, document_for(server, uri))
   elseif method == "textDocument/formatting" or method == "textDocument/rangeFormatting" or method == "textDocument/onTypeFormatting" or method == "textDocument/willSaveWaitUntil" then
      local uri = request_uri(params)
      return formatting(document_for(server, uri))
   elseif method == "textDocument/selectionRange" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return selection_ranges(document, params.positions as AnyArray or {})
   elseif method == "textDocument/inlayHint" then
      local uri = request_uri(params)
      return inlay_hints(server, document_for(server, uri), params.range as Range)
   elseif method == "textDocument/inlineValue" then
      local uri = request_uri(params)
      return inline_values(server, document_for(server, uri), params.range as Range)
   elseif method == "textDocument/documentLink" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return document_links(server, document)
   elseif method == "textDocument/linkedEditingRange" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return linked_editing(document, params.position as Position) or JSON_NULL
   elseif method == "textDocument/codeLens" then
      local uri = request_uri(params)
      return code_lenses(server, document_for(server, uri))
   elseif method == "codeLens/resolve" then
      local data = params.data as AnyObject
      local uri = data.uri as string
      local position = data.position as Position
      local document = document_for(server, uri)
      analyze_document(server, document)
      local token = token_at(document, position)
      local locations = token and resolved_locations(server, document, token, position) or array()
      params.command = {
         title = tostring(#locations) .. (#locations == 1 and " usage" or " usages"),
         command = "editor.action.showReferences",
         arguments = mark_array({ uri, position, locations } as AnyArray),
      }
      return params
   elseif method == "textDocument/documentColor" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return document_colors(document)
   elseif method == "textDocument/colorPresentation" then
      local color = params.color as AnyObject
      local red = math.floor((color.red as number or 0) * 255 + 0.5)
      local green = math.floor((color.green as number or 0) * 255 + 0.5)
      local blue = math.floor((color.blue as number or 0) * 255 + 0.5)
      local alpha = math.floor((color.alpha as number or 1) * 255 + 0.5)
      local label = alpha < 255 and string.format("#%02X%02X%02X%02X", red, green, blue, alpha) or string.format("#%02X%02X%02X", red, green, blue)
      return mark_array({ { label = label, textEdit = { range = params.range, newText = label } } } as AnyArray)
   elseif method == "textDocument/prepareCallHierarchy" then
      local uri = request_uri(params)
      local item = symbol_at(server, document_for(server, uri), params.position as Position)
      if item then return mark_array({ item } as AnyArray) end
      return array()
   elseif method == "callHierarchy/incomingCalls" then
      local item = params.item as AnyObject
      local data = item.data as AnyObject
      local result = array()
      for _, raw_location in ipairs(all_locations(server, data.name as string)) do
         local location = raw_location as AnyObject
         table.insert(result, {
            from = { name = data.name, kind = 12, uri = location.uri, range = location.range, selectionRange = location.range },
            fromRanges = mark_array({ location.range } as AnyArray),
         })
      end
      return result
   elseif method == "callHierarchy/outgoingCalls" then
      local item = params.item as AnyObject
      local data = item.data as AnyObject
      local document = document_for(server, data.uri as string)
      local result = array()
      local seen: {string: boolean} = {}
      for _, token in ipairs(document.tokens) do
         if token.kind == "identifier" and not seen[token.tk] then
            local line = document.lines[token.y] or ""
            local position: Position = { line = token.y - 1, character = byte_to_utf16(line:sub(1, token.x - 1), token.x - 1) }
            local target = find_definition(server, document, token.tk, position)
            if target then
               seen[token.tk] = true
               table.insert(result, {
                  to = { name = token.tk, kind = 12, uri = target.uri, range = target.range, selectionRange = target.range },
                  fromRanges = mark_array({ make_range(document.lines, token.y, token.x, #token.tk) } as AnyArray),
               })
            end
         end
      end
      return result
   elseif method == "textDocument/prepareTypeHierarchy" then
      local uri = request_uri(params)
      local item = type_hierarchy_item(server, document_for(server, uri), params.position as Position)
      if item then return mark_array({ item } as AnyArray) end
      return array()
   elseif method == "typeHierarchy/supertypes" or method == "typeHierarchy/subtypes" then
      return array()
   elseif method == "textDocument/moniker" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      local token = token_at(document, params.position as Position)
      if not token then return JSON_NULL end
      return { scheme = "teal", identifier = module_name_from_path(document.path, server.root) .. "." .. token.tk, unique = "document", kind = "local" }
   elseif method == "textDocument/diagnostic" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return { kind = "full", items = document.diagnostics }
   elseif method == "workspace/diagnostic" then
      local items = array()
      for uri, document in pairs(server.documents) do
         analyze_document(server, document)
         table.insert(items, { uri = uri, version = document.version, kind = "full", items = document.diagnostics })
      end
      return { items = items }
   elseif method == "textDocument/codeAction" then
      local uri = request_uri(params)
      local document = document_for(server, uri)
      analyze_document(server, document)
      return code_actions(document)
   elseif method == "workspace/executeCommand" then
      local command = params.command
      local arguments = params.arguments as AnyArray or {}
      if command == "tl.restart" then
         for _, document in pairs(server.documents) do
            document.analysis_version = -1
            publish_diagnostics(server, document)
         end
         return JSON_NULL
      end
      local uri = arguments[1] as string
      local document = uri and document_for(server, uri)
      if command == "tl.check" and document then
         publish_diagnostics(server, document)
         return document.diagnostics
      elseif command == "tl.generate" and document then
         analyze_document(server, document)
         local has_error = false
         for _, diagnostic in ipairs(document.diagnostics or {}) do
            if (diagnostic as AnyObject).severity == 1 then
               has_error = true
               break
            end
         end
         if document.module and not has_error then
            return { code = document.module:gen({}) }
         end
         return JSON_NULL, { code = -32001, message = "cannot generate Lua while the document has diagnostics" }
      end
      return JSON_NULL, { code = -32602, message = "unknown Teal command" }
   end
   return JSON_NULL, { code = -32601, message = "method not found: " .. method }
end

return function(tlconfig: TlConfig, args: Args)


   tlconfig.quiet = true

   local server: Server = {
      tlconfig = tlconfig,
      args = args,
      root = os.getenv("PWD") or ".",
      documents = {},
      type_documents = {},
      field_documents = {},
      shutdown = false,
      workspace_indexed = false,
      pending_diagnostics = {},
   }

   while true do
      local debounce = server.tlconfig.lsp and server.tlconfig.lsp.diagnostics_debounce_ms
      local debounce_ms = debounce is number and math.max(0, math.floor(debounce)) or 75
      if next(server.pending_diagnostics) and not stdin_ready(debounce_ms) then
         flush_pending_diagnostics(server)
      end
      local message, read_err = read_message()
      if message == nil then
         if read_err == "eof" then return end
         response(JSON_NULL, nil, { code = -32700, message = read_err or "invalid JSON-RPC message" })
      else
         local method = message.method as string
         if not method then
            if message.id then response(message.id, nil, { code = -32600, message = "missing method" }) end
         elseif message.id == nil or message.id == JSON_NULL then
            if not handle_notification(server, method, message.params as AnyObject or {}) then return end
         else
            local ok, result, err = pcall(handle_request, server, method, message.params as AnyObject or {})
            if ok then
               response(message.id, result, err)
            else
               response(message.id, nil, { code = -32603, message = "internal Teal LSP error: " .. tostring(result) })
            end
         end
      end
   end
end
