--#pragma strict_nil off
--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------
local errors = require("teal.errors")
local type Error = errors.Error

local util = require("teal.util")
local binary_search = util.binary_search

local record lexer
   enum TokenKind
      "hashbang"
      "keyword"
      "op"
      "string"
      "[" "]" "(" ")" "{" "}" "," ":" "." ";" "?" "!" "$" "`"
      "::"
      "..."
      "identifier"
      "number"
      "integer"
      "pragma"
      "pragma_identifier"
      "$ERR$"
      "$EOF$"
   end

   record Comment
      x: integer
      y: integer
      text: string
   end

   record Token
      x: integer
      y: integer
      tk: string
      kind: TokenKind
      comments: {Comment}
   end

   record ConditionalOptions
      defines: {string:any}
      strict_nil: boolean
   end

   lex: function(input: string, filename: string, opts?: ConditionalOptions, is_lua?: boolean): {Token}, {Error}
   get_token_at: function(tks: {Token}, y: integer, x: integer): string
end

local type Token = lexer.Token
local type TokenKind = lexer.TokenKind
local type Comment = lexer.Comment
local type ConditionalOptions = lexer.ConditionalOptions

local condition_precedence: {string:integer} = {
   ["or"] = 1, ["and"] = 2, ["=="] = 3, ["~="] = 3, ["!="] = 3,
}

local function conditional_value(tokens: {Token}, defines: {string:any}, strict_nil: boolean): boolean, string
   local index = 1
   local err: string
   local expression: function(integer, integer): any
   expression = function(min_precedence: integer, depth: integer): any
      if depth > 100 then
         err = "condition is nested too deeply"
         return nil
      end
      local token = tokens[index]
      index = index + 1
      local value: any
      if token.tk == "(" then
         value = expression(1, depth + 1)
         if not err then
            if tokens[index].tk == ")" then
               index = index + 1
            else
               err = "expected ')' in condition"
            end
         end
      elseif token.tk == "not" then
         value = not expression(4, depth + 1)
      elseif token.tk == "TL_NG" or token.tk == "true" then
         value = true
      elseif token.tk == "STRICT_NIL" then
         value = strict_nil
      elseif token.tk == "false" then
         value = false
      elseif token.tk == "nil" then
         value = nil
      elseif token.kind == "identifier" then
         value = defines and rawget(defines, token.tk)
      elseif token.kind == "string" then
         -- The lexer has already verified that this is a single string literal.
         local literal = load("return " .. token.tk, "=(conditional literal)", "t", {})
         if literal then
            value = literal()
         else
            err = "invalid string literal in condition"
         end
      elseif token.kind == "integer" or token.kind == "number" then
         local text = token.tk:gsub("_", "")
         value = text:match("^0[bB]") and tonumber(text:sub(3), 2) or tonumber(text)
         if value == nil then err = "invalid number in condition" end
      else
         err = "expected a define, literal, 'not', or '(' in condition"
      end

      while not err do
         local op = tokens[index].tk
         local precedence = condition_precedence[op]
         if not precedence or precedence < min_precedence then break end
         index = index + 1
         local rhs = expression(precedence + 1, depth + 1)
         if op == "or" then
            value = value or rhs
         elseif op == "and" then
            value = value and rhs
         elseif op == "==" then
            value = rawequal(value, rhs)
         else
            value = not rawequal(value, rhs)
         end
      end
      return value
   end

   local value = expression(1, 0)
   if not err and tokens[index].kind ~= "$EOF$" then
      err = "unexpected token '" .. tokens[index].tk .. "' in condition"
   end
   return not not value, err
end

do
   local enum LexState
      "start"
      "any"
      "identifier"
      "got -"
      "got --"
      "got ."
      "got .."
      "got ="
      "got ~"
      "got ["
      "got 0"
      "got <"
      "got >"
      "got /"
      "got :"
      "got --["
      "string single"
      "string single got \\"
      "string double"
      "string double got \\"
      "string backtick"
      "string backtick got \\"
      "string backtick triple"
      "string long"
      "string long got ]"
      "comment short"
      "comment long"
      "comment long got ]"
      "number dec"
      "number decfloat"
      "number binary"
      "number suffix"
      "number hex"
      "number hexfloat"
      "number power"
      "number powersign"
      "pragma"
      "pragma word"
      "pragma any"
   end

   local last_token_kind <total>: {LexState:TokenKind} = {
      ["start"] = nil, -- never in a token
      ["any"] = nil, -- never in a token
      ["identifier"] = "identifier",
      ["got -"] = "op",
      ["got --"] = nil, -- drop comment
      ["got ."] = ".",
      ["got .."] = "op",
      ["got ="] = "op",
      ["got ~"] = "op",
      ["got ["] = "[",
      ["got 0"] = "number",
      ["got <"] = "op",
      ["got >"] = "op",
      ["got /"] = "op",
      ["got :"] = "op",
      ["got --["] = nil, -- drop comment
      ["string single"] = "$ERR$",
      ["string single got \\"] = "$ERR$",
      ["string double"] = "$ERR$",
      ["string double got \\"] = "$ERR$",
      ["string backtick"] = "$ERR$",
      ["string backtick got \\"] = "$ERR$",
      ["string backtick triple"] = "$ERR$",
      ["string long"] = "$ERR$",
      ["string long got ]"] = "$ERR$",
      ["comment short"] = nil, -- drop comment
      ["comment long"] = "$ERR$",
      ["comment long got ]"] = "$ERR$",
      ["number dec"] = "integer",
      ["number decfloat"] = "number",
      ["number binary"] = "integer",
      ["number suffix"] = "number",
      ["number hex"] = "integer",
      ["number hexfloat"] = "number",
      ["number power"] = "number",
      ["number powersign"] = "$ERR$",
      ["pragma"] = nil, -- drop comment
      ["pragma any"] = nil, -- never in a token
      ["pragma word"] = "pragma_identifier", -- never in a token
   }

   local keywords: {string:boolean} = {
      ["and"] = true,
      ["break"] = true,
      ["do"] = true,
      ["else"] = true,
      ["elseif"] = true,
      ["end"] = true,
      ["false"] = true,
      ["for"] = true,
      ["function"] = true,
      ["goto"] = true,
      ["if"] = true,
      ["in"] = true,
      ["local"] = true,
      ["nil"] = true,
      ["not"] = true,
      ["or"] = true,
      ["repeat"] = true,
      ["return"] = true,
      ["then"] = true,
      ["true"] = true,
      ["until"] = true,
      ["while"] = true,
   }

   local lex_any_char_states: {string:LexState} = {
      ["\""] = "string double",
      ["'"] = "string single",
      ["-"] = "got -",
      ["."] = "got .",
      ["0"] = "got 0",
      ["<"] = "got <",
      [">"] = "got >",
      ["/"] = "got /",
      [":"] = "got :",
      ["="] = "got =",
      ["~"] = "got ~",
      ["["] = "got [",
   }

   for c = string.byte("a"), string.byte("z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   lex_any_char_states["_"] = "identifier"

   for c = string.byte("1"), string.byte("9") do
      lex_any_char_states[string.char(c)] = "number dec"
   end

   local lex_word: {string:boolean} = {}
   for c = string.byte("a"), string.byte("z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("0"), string.byte("9") do
      lex_word[string.char(c)] = true
   end
   lex_word["_"] = true

   local lex_decimals: {string:boolean} = {}
   for c = string.byte("0"), string.byte("9") do
      lex_decimals[string.char(c)] = true
   end

   local lex_hexadecimals: {string:boolean} = {}
   for c = string.byte("0"), string.byte("9") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("a"), string.byte("f") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("F") do
      lex_hexadecimals[string.char(c)] = true
   end

   local lex_any_char_kinds: {string:TokenKind} = {}
   local single_char_kinds: {TokenKind} = {"[", "]", "(", ")", "{", "}", ",", ";", "?", "$"}
   for _, c in ipairs(single_char_kinds) do
      lex_any_char_kinds[c] = c
   end
   for _, c in ipairs({"#", "+", "*", "|", "&", "%", "^", "!"}) do
      lex_any_char_kinds[c] = "op"
   end

   local lex_space: {string:boolean} = {}
   for _, c in ipairs({" ", "\t", "\v", "\n", "\r"}) do
      lex_space[c] = true
   end

   local escapable_characters: {string:boolean} = {
      a = true,
      b = true,
      f = true,
      n = true,
      r = true,
      t = true,
      v = true,
      z = true,
      ["\\"] = true,
      ["\'"] = true,
      ["\""] = true,
      ["\r"] = true,
      ["\n"] = true,
   }

   local function lex_string_escape(input: string, i: integer, c: string): integer, boolean
      if escapable_characters[c] then
         return 0, true
      elseif c == "x" then
         return 2, (
            lex_hexadecimals[input:sub(i+1, i+1)] and
            lex_hexadecimals[input:sub(i+2, i+2)]
         )
      elseif c == "u" then
         if input:sub(i+1, i+1) == "{" then
            local p = i + 2
            if not lex_hexadecimals[input:sub(p, p)] then
               return 2, false
            end
            while true do
               p = p + 1
               c = input:sub(p, p)
               if not lex_hexadecimals[c] then
                  return p - i, c == "}"
               end
            end
         end
      elseif lex_decimals[c] then
         local len = lex_decimals[input:sub(i+1, i+1)]
                     and (lex_decimals[input:sub(i+2, i+2)] and 2 or 1)
                     or  0
         return len, tonumber(input:sub(i, i + len)) < 256
      else
         return 0, false
      end
   end

   local function lex(input: string, filename: string, opts?: ConditionalOptions, is_lua?: boolean): {Token}, {Error}
      local tokens: {Token} = {}

      local state: LexState = "any"
      local fwd = true
      local y = 1
      local x = 0
      local i = 0
      local lc_open_lvl = 0
      local lc_close_lvl = 0
      local ls_open_lvl = 0
      local ls_close_lvl = 0
      local errs: {Error} = {}
      local nt = 0

      local tx: integer
      local ty: integer
      local ti: integer
      local in_token = false

      local comments: {Comment}
      local strict_nil = not opts or opts.strict_nil ~= false
      local record ConditionalEnd
         first: integer
         last: integer
         parent: ConditionalEnd
      end
      local conditional_end: ConditionalEnd
      if is_lua == nil then
         is_lua = filename and filename:lower():match("%.lua$") ~= nil
      end

      local function begin_token()
         tx = x
         ty = y
         ti = i
         in_token = true
      end

      local function end_token(kind: TokenKind, tk: string)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_identifier()
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = keywords[tk] and "keyword" or "identifier",
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_prev(kind: TokenKind)
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_here(kind: TokenKind)
         local tk = input:sub(ti, i)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,

         }
         comments = nil
         in_token = false
      end

      local function drop_token()
         in_token = false
      end

      local function add_syntax_error(msg?: string)
         local t = tokens[nt]
         table.insert(errs, {
            filename = filename,
            y = t.y,
            x = t.x,
            msg = msg or "invalid token '" .. t.tk .. "'",
         })
      end

      local function add_comment(text: string)
         if not comments then
            comments = {}
         end
         comments[#comments + 1] = {
            x = tx,
            y = ty,
            text = text,
         }
      end

      local function skip_through(last: integer)
         local newline = input:find("\n", i, true)
         while newline and newline <= last do
            y = y + 1
            i = newline
            x = 0
            newline = input:find("\n", i + 1, true)
         end
         x = x + last - i
         i = last
      end

      local function open_conditional(level: integer): boolean
         local header = input:match("^%s*()#if%f[^%w_]", i + 1)
         if not header then return false end

         local function fail(msg: string)
            local line = ty
            local column = tx + header - ti
            for newline in input:sub(ti, header - 1):gmatch("\n()") do
               line = line + 1
               column = header - ti - newline + 2
            end
            table.insert(errs, { filename = filename, y = line, x = column, msg = msg })
         end

         local close, last = input:find("]" .. string.rep("=", level) .. "]", i + 1, true)
         if not close or (conditional_end and last >= conditional_end.first) then return false end
         local header_end = input:find("\n", header, true)
         local footer = header_end and header_end < close
            and input:sub(header_end, close - 1):match("\n()[ \t]*#end%s*$")
         local condition = header_end and header_end < close
            and input:sub(header + 3, header_end - 1):match("^[ \t]+(.-)[ \t]+then[ \t\r]*$")
         local enabled = false
         if not condition or condition == "" then
            fail("expected '#if <condition> then'")
         elseif not footer then
            fail("expected '#end' before the conditional comment closes")
         else
            local condition_tokens, condition_errors = lex(condition, filename, nil, true)
            local message: string
            if #condition_errors > 0 then
               message = condition_errors[1].msg
            else
               enabled, message = conditional_value(condition_tokens, opts and opts.defines, strict_nil)
            end
            if message then
               fail("invalid conditional compilation condition: " .. message)
               enabled = false
            end
         end

         if enabled then
            conditional_end = {
               first = header_end + footer - 1,
               last = last,
               parent = conditional_end,
            }
            skip_through(header_end - 1)
         else
            add_comment(input:sub(ti, last))
            skip_through(last)
         end
         drop_token()
         return true
      end

      local function update_strict_nil()
         if nt >= 3 and tokens[nt - 2].tk == "--#pragma" and tokens[nt - 1].tk == "strict_nil"
               and tokens[nt - 2].y == tokens[nt].y then
            if tokens[nt].tk == "on" then
               strict_nil = true
            elseif tokens[nt].tk == "off" then
               strict_nil = false
            end
         end
      end

      local bom <const> = "\239\187\191" -- "\xEF\xBB\xBF"
      local bom_len = bom:len()
      if input:sub(1, bom_len) == bom then
         input = input:sub(bom_len + 1)
      end

      local len = #input
      if input:sub(1,2) == "#!" then
         begin_token()
         i = input:find("\n")
         if not i then
            i = len + 1
         end
         end_token_prev("hashbang")
         y = 2
         x = 0
      end
      state = "any"

      local extension_operators: {string: {string}} = {
         ["~"] = { "~>>=", "~>>" }, ["<"] = { "<<=" }, [">"] = { ">>=" },
         ["."] = { "..=" }, ["!"] = { "!=" }, ["&"] = { "&&", "&=" },
         ["|"] = { "||", "|=" }, ["?"] = { "??", "?." },
         ["+"] = { "+=" }, ["-"] = { "-=", "->" }, ["*"] = { "*=" },
         ["/"] = { "/=" }, ["%"] = { "%=" },
      }

      while i <= len do
         if fwd then
            i = i + 1
            if i > len then
               break
            end
         end

         local c: string = input:sub(i, i)

         if fwd then
            if c == "\n" then
               y = y + 1
               x = 0
            else
               x = x + 1
            end
         else
            fwd = true
         end

         local extension_op: string
         if state == "any" and extension_operators[c] then
            for _, candidate in ipairs(extension_operators[c]) do
               if input:sub(i, i + #candidate - 1) == candidate then
                  extension_op = candidate
                  break
               end
            end
         end
         if conditional_end and i == conditional_end.first then
            if state ~= "any" then
               end_token_prev("$ERR$")
               add_syntax_error("unfinished token in conditional compilation block")
            end
            skip_through(conditional_end.last)
            conditional_end = conditional_end.parent
            lc_open_lvl = 0
            lc_close_lvl = 0
            state = "any"
         elseif extension_op then
            begin_token()
            end_token("op", extension_op)
            i = i + #extension_op - 1
            x = x + #extension_op - 1
         elseif c == "_" and (state == "got 0" or state:sub(1, 7) == "number ") then
            -- Separators do not change the numeric lexer state.
         elseif state ~= "number suffix" and (state == "got 0" or state:sub(1, 7) == "number ") and
            (c == "L" or c == "l" or c == "U" or c == "u" or c == "i" or c == "I") then
            state = "number suffix"
         elseif state == "number suffix" then
            if not lex_word[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number binary" then
            if c ~= "0" and c ~= "1" then
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "any" then
            if c == "`" then
               local c2 = input:sub(i + 1, i + 1)
               local c3 = input:sub(i + 2, i + 2)
               if c2 == "`" and c3 == "`" then
                  state = "string backtick triple"
               else
                  state = "string backtick"
               end
               begin_token()
            else
               local st = lex_any_char_states[c]
               if st then
                  state = st
                  begin_token()
               else
                  local k = lex_any_char_kinds[c]
                  if k then
                     begin_token()
                     end_token(k, c)
                  elseif c:match("%p") or c:byte() >= 128 then
                     begin_token()
                     end_token_here("op")
                  elseif not lex_space[c] then
                     begin_token()
                     end_token_here("$ERR$")
                     add_syntax_error()
                  end
               end
            end
         elseif state == "identifier" then
            if not lex_word[c] then
               end_token_identifier()
               fwd = false
               state = "any"
            end
         elseif state == "string double" then
            if c == "\\" then
               state = "string double got \\"
            elseif c == "\"" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "string backtick" then
            if c == "\\" then
               state = "string backtick got \\"
            elseif c == "`" then
               end_token_here("`")
               state = "any"
            end
         elseif state == "string backtick triple" then
            if input:sub(i, i + 2) == "```" then
               if i == ti then
                  i = i + 2
                  x = x + 2
               else
                  i = i + 2
                  x = x + 2
                  end_token_here("`")
                  state = "any"
               end
            end
         elseif state == "string backtick got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string backtick"
         elseif state == "comment short" then
            if c == "\n" then
               add_comment(input:sub(ti, i - 1))
               state = "any"
            end
         elseif state == "got =" then
            local t: string
            if c == "=" then
               t = "=="
            else
               t = "="
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got ." then
            if c == "." then
               state = "got .."
            elseif lex_decimals[c] then
               state = "number decfloat"
            else
               end_token(".", ".")
               fwd = false
               state = "any"
            end
         elseif state == "got :" then
            local t: TokenKind
            if c == ":" then
               t = "::"
            else
               t = ":"
               fwd = false
            end
            end_token(t, t)
            state = "any"
         elseif state == "got [" then
            if c == "[" then
               state = "string long"
            elseif c == "=" then
               ls_open_lvl = ls_open_lvl + 1
            else
               end_token("[", "[")
               fwd = false
               state = "any"
               ls_open_lvl = 0
            end
         elseif state == "number dec" then
            if lex_decimals[c] then
               -- proceed
            elseif c == "." then
               state = "number decfloat"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got -" then
            if c == "-" then
               state = "got --"
            else
               end_token("op", "-")
               fwd = false
               state = "any"
            end
         elseif state == "got .." then
            if c == "." then
               end_token("...", "...")
            else
               end_token("op", "..")
               fwd = false
            end
            state = "any"
         elseif state == "number hex" then
            if lex_hexadecimals[c] then
               -- proceed
            elseif c == "." then
               state = "number hexfloat"
            elseif c == "p" or c == "P" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --" then
            if c == "[" then
               state = "got --["
            elseif c == "#" then
               state = "pragma"
            else
               fwd = false
               state = "comment short"
               drop_token()
            end
         elseif state == "pragma" then
            if not lex_word[c] then
               end_token_prev("pragma")
               if tokens[nt].tk == "--#pragma" then
                  state = "pragma any"
               else
                  state = "comment short"
                  table.remove(tokens)
                  nt = nt - 1
                  drop_token()
               end
               fwd = false
            end
         elseif state == "pragma any" then
            if c == "\n" then
               state = "any"
            elseif lex_word[c] then
               state = "pragma word"
               begin_token()
            elseif not lex_space[c] then
               begin_token()
               end_token_here("$ERR$")
               add_syntax_error()
            end
         elseif state == "pragma word" then
            if not lex_word[c] then
               end_token_prev("pragma_identifier")
               update_strict_nil()
               fwd = false
               state = (c == "\n") and "any" or "pragma any"
            end
         elseif state == "got 0" then
            if c == "x" or c == "X" then
               state = "number hex"
            elseif c == "b" or c == "B" then
               state = "number binary"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            elseif lex_decimals[c] then
               state = "number dec"
            elseif c == "." then
               state = "number decfloat"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --[" then
            if c == "[" then
               if not is_lua and open_conditional(lc_open_lvl) then
                  state = "any"
                  lc_open_lvl = 0
               else
                  state = "comment long"
               end
            elseif c == "=" then
               lc_open_lvl = lc_open_lvl + 1
            else
               fwd = false
               state = "comment short"
               drop_token()
               lc_open_lvl = 0
            end
         elseif state == "comment long" then
            if c == "]" then
               state = "comment long got ]"
            end
         elseif state == "comment long got ]" then
            if c == "]" and lc_close_lvl == lc_open_lvl then
               add_comment(input:sub(ti, i))
               drop_token()
               state = "any"
               lc_open_lvl = 0
               lc_close_lvl = 0
            elseif c == "=" then
               lc_close_lvl = lc_close_lvl + 1
            else
               state = "comment long"
               lc_close_lvl = 0
            end
         elseif state == "string double got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string double"
         elseif state == "string single" then
            if c == "\\" then
               state = "string single got \\"
            elseif c == "'" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "string single got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string single"
         elseif state == "got ~" then
            local t: string
            if c == "=" then
               t = "~="
            else
               t = "~"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got <" then
            local t: string
            if c == "=" then
               t = "<="
            elseif c == "<" then
               t = "<<"
            else
               t = "<"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got >" then
            local t: string
            if c == "=" then
               t = ">="
            elseif c == ">" then
               t = ">>"
            else
               t = ">"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got /" then
            local t: string
            if c == "/" then
               t = "//"
            else
               t = "/"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "string long" then
            if c == "]" then
               state = "string long got ]"
            end
         elseif state == "string long got ]" then
            if c == "]" then
               if ls_close_lvl == ls_open_lvl then
                  end_token_here("string")
                  state = "any"
                  ls_open_lvl = 0
                  ls_close_lvl = 0
               end
            elseif c == "=" then
               ls_close_lvl = ls_close_lvl + 1
            else
               state = "string long"
               ls_close_lvl = 0
            end
         elseif state == "number hexfloat" then
            if c == "p" or c == "P" then
               state = "number powersign"
            elseif not lex_hexadecimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number decfloat" then
            if c == "e" or c == "E" then
               state = "number powersign"
            elseif not lex_decimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number powersign" then
            if c == "-" or c == "+" then
               state = "number power"
            elseif lex_decimals[c] then
               state = "number power"
            elseif lex_space[c] then
               end_token_prev("$ERR$")
               fwd = false
               add_syntax_error("malformed number")
               state = "any"
            else
               end_token_here("$ERR$")
               add_syntax_error("malformed number")
               state = "any"
            end
         elseif state == "number power" then
            if not lex_decimals[c] then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         end
      end

      if in_token then
         if last_token_kind[state] then
            end_token_prev(last_token_kind[state])
            if last_token_kind[state] == "$ERR$" then
               local state_type = state:sub(1, 6)
               if state_type == "string" then
                  add_syntax_error("malformed string")
               elseif state_type == "number" then
                  add_syntax_error("malformed number")
               elseif state_type == "commen" then
                  add_syntax_error("unfinished long comment")
               else
                  add_syntax_error()
               end
            elseif keywords[tokens[nt].tk] then
               tokens[nt].kind = "keyword"
            end
         else
            drop_token()
         end
      end

      if state == "comment short" or state == "got --" or state == "got --[" then
         add_comment(input:sub(ti, #input))
      end

      for _, token in ipairs(tokens) do
         if token.kind == "number" or token.kind == "integer" then
            local text = token.tk:gsub("_", ""):lower()
            local integer_suffix = text:sub(-2) == "ll"
            if text:sub(-3) == "ull" then text = text:sub(1, -4)
            elseif integer_suffix then text = text:sub(1, -3)
            elseif text:sub(-1) == "i" then text = text:sub(1, -2) end
            local value = text:match("^0b[01]+$") and tonumber(text:sub(3), 2) or tonumber(text)
            if not value then
               token.kind = "$ERR$"
               table.insert(errs, { filename = filename, y = token.y, x = token.x, msg = "malformed number" })
            elseif integer_suffix then
               token.kind = "integer"
            end
         end
      end
      table.insert(tokens, { x = x + 1, y = y, tk = "$EOF$", kind = "$EOF$", comments = comments })

      return tokens, errs
   end

   lexer.lex = lex
end

lexer.get_token_at = function(tks: {Token}, y: integer, x: integer): string
   local _, found <const> = binary_search(
      tks, nil,
      function(tk: Token): boolean
         return tk.y < y
            or (tk.y == y and tk.x <= x)
      end
   )

   if found
      and found.y == y
      and found.x <= x and x < found.x + #found.tk
   then
      return found.tk
   end
end

return lexer
