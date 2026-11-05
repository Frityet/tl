-- Lexer boundaries: comment/long-string delimiters, UTF-8 and numeric forms.
local s = [==[a ]=] boundary
雪 and café]==]
local escaped = "\x41\097\n\t\\\""
local numbers = {0, 0xFF, 1e-3, .25, 1., 0x1p2}
local comment = --[=[one ]==] two]=]
   "ok"
return s .. escaped .. comment, numbers
