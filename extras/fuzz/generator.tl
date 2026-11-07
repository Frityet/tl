--#pragma strict_nil off
local type model = require("extras.fuzz.model")
local record generator
   type Case = model.Case
   record RNG
      state: integer
      next: function(self, integer): integer
   end
   version: integer
   features: integer
   portable: {integer}
   rng: function(integer, integer): RNG
   expression: function(RNG, integer): string, number
   valid_program: function(RNG, ? integer): string, number
   tlng_program: function(RNG, ? integer, ? boolean): string, number
   mutate: function(RNG, string): string
   case_for: function(integer, integer, {string}, ? integer, ? string, ? boolean): Case
end
generator.version = 5
generator.features = 27
generator.portable = {0,1,6,7,8,9,10,11,13,16,17,18,19,20,21,22,23,24,25,26}
function generator.rng(seed: integer, index: integer): generator.RNG
   local rng: generator.RNG = {state = ((seed % 2147483646) * 65537 + (index % 2147483646) * 104729) % 2147483646 + 1}
   rng.next = function(self: generator.RNG, n: integer): integer
      assert(n > 0)
      self.state = (self.state * 48271) % 2147483647
      return self.state % n
   end
   return rng
end
local function pick<T>(rng: generator.RNG, values: {T}): T
   return values[rng:next(#values) + 1]
end
function generator.expression(rng: generator.RNG, depth: integer): string, number
   if depth <= 0 or rng:next(4) == 0 then
      local n = rng:next(41) - 20
      return "(" .. n .. ")", n
   end
   local lhs, a = generator.expression(rng, depth - 1)
   local rhs, b = generator.expression(rng, depth - 1)
   local op = pick(rng, {"+", "-", "*"})
   local value: number
   if op == "+" then value = a + b elseif op == "-" then value = a - b else value = a * b end
   return "(" .. lhs .. " " .. op .. " " .. rhs .. ")", value
end
function generator.valid_program(rng: generator.RNG, size?: integer): string, number
   local lines: {string} = {"local total: number = 0"}
   local expected: number = 0
   for i = 0, rng:next(size or 8) do
      local expr, value = generator.expression(rng, rng:next(3) + 1)
      local kind = rng:next(10)
      local snippet: string
      if kind == 0 then
         snippet = string.format("local v%d: number = %s\ntotal = total + v%d",i,expr,i)
      elseif kind == 1 then
         local n = rng:next(6) + 1
         snippet = string.format("for j%d = 1, %d do\n total = total + %s\nend",i,n,expr)
         value = value * n
      elseif kind == 2 then
         snippet = string.format("local function f%d(x: number): number\n return x * 2 + 1\nend\ntotal = total + f%d(%s)",i,i,expr)
         value = value * 2 + 1
      elseif kind == 3 then
         snippet = string.format("local record R%d\n value: number\nend\nlocal r%d: R%d = {value = %s}\ntotal = total + r%d.value",i,i,i,expr,i)
      elseif kind == 4 then
         snippet = string.format("local a%d: {number} = {%s, 2, 3}\nfor j%d = 1, #a%d do\n total = total + a%d[j%d]\nend",i,expr,i,i,i,i)
         value = value + 5
      elseif kind == 5 then
         snippet = string.format("local function identity%d<T>(x: T): T\n return x\nend\ntotal = total + identity%d(%s)",i,i,expr)
      elseif kind == 6 then
         snippet = string.format("local function union%d(u: number | string): number\n if u is number then\n return u\n else\n return 0\n end\nend\ntotal = total + union%d(%s)",i,i,expr)
      elseif kind == 7 then
         snippet = string.format('local enum E%d\n "yes"\n "no"\nend\nlocal e%d: E%d = "yes"\nif e%d == "yes" then\n total = total + %s\nend',i,i,i,i,expr)
      elseif kind == 8 then
         snippet = string.format("local x%d: number = 0\nrepeat\n x%d = x%d + 1\nuntil x%d == 3\ntotal = total + %s * x%d",i,i,i,i,expr,i)
         value = value * 3
      else
         snippet = string.format("local function pair%d(x: number): number, number\n return x, 2\nend\nlocal a%d, b%d = pair%d(%s)\ntotal = total + a%d + b%d",i,i,i,i,expr,i,i)
         value = value + 2
      end
      lines[#lines + 1] = snippet
      expected = expected + value
   end
   lines[#lines + 1] = "return total\n"
   return table.concat(lines, "\n"), expected
end
function generator.tlng_program(rng: generator.RNG, feature?: integer, native?: boolean): string, number
   local expr, value = generator.expression(rng, 3)
   if feature == nil then feature = native and rng:next(generator.features) or pick(rng, generator.portable) end
   if feature == 0 then
      return string.format("const f: function(number): number = x -> x + 2\nreturn f(%s)",expr), value+2
   elseif feature == 1 then
      return string.format("const f = |x: number| -> do return x * 2 end\nreturn f(%s)",expr), value*2
   elseif feature == 2 then
      return string.format("return %s < 0 ? -%s : %s",expr,expr,expr), math.abs(value)
   elseif feature == 3 then
      return string.format("local function f(x: number | nil): number\n return x ?? %s\nend\nreturn f(nil)",expr), value
   elseif feature == 4 then
      return string.format("local record R\n value: number\nend\nlocal function f(x: R | nil): number\n return x?.value ?? %s\nend\nreturn f(nil)",expr), value
   elseif feature == 5 then
      return string.format("local total: number = 0\nfor i = 1, 4 do\n if i == 2 then continue end\n total += %s\nend\nreturn total",expr), value*3
   elseif feature == 6 then
      return string.format("local macro identity!(v: Expression): Expression\n return `$v`\nend\nreturn identity!(%s)",expr), value
   elseif feature == 7 then
      local symbol = pick(rng, {"@", "⊗", "<=>", "\\"})
      return string.format("local macro (%s)!(lhs: Expression, rhs: Expression): Operator<infix, multiplicative>\n return `($lhs) * ($rhs)`\nend\nreturn %s %s 2 + 1",symbol,expr,symbol), value*2+1
   elseif feature == 8 then
      return string.format("local macro (combine)!(lhs: Expression, rhs: Expression): Operator<infix, additive>\n return `($lhs) + ($rhs)`\nend\nreturn %s combine 2 * 3",expr), value+6
   elseif feature == 9 then
      return string.format("local macro (@@)!(x: Expression): Operator<prefix, unary>\n return `-($x)`\nend\nreturn @@ %s",expr), -value
   elseif feature == 10 then
      return string.format("local macro (@@)!(x: Expression): Operator<postfix, postfix>\n return `($x) * 2`\nend\nreturn %s @@ + 1",expr), value*2+1
   elseif feature == 11 then
      return string.format("local macro (**)!(lhs: Expression, rhs: Expression): Operator<infix, exponentiation, right>\n return `($lhs) - ($rhs)`\nend\nreturn %s ** 2 ** 3",expr), value+1
   elseif feature == 12 then
      return string.format("const choose = || -> (true ? false : true)\nreturn choose() ? 1 : %s",expr), value
   elseif feature == 13 then
      return string.format("local macro (@)!(lhs: Expression, rhs: Expression): Operator<infix, additive>\n return `($lhs) + ($rhs)`\nend\nlocal before = %s @ 2\ndo\n local macro (@)!(lhs: Expression, rhs: Expression): Operator<infix, additive>\n return `($lhs) * ($rhs)`\n end\n return before + (%s @ 3)\nend",expr,expr), value*4+2
   elseif feature == 14 then
      return string.format("return (!false && %s != 0 || false) ? %s : 1",expr,expr), value ~= 0 and value or 1
   elseif feature == 15 then
      return string.format("local t: {number} = {%s}\nlocal calls: number = 0\nlocal function index(): integer calls += 1; return 1 end\nt[index()] += 2\nreturn t[1] + 100 * calls",expr), value+102
   elseif feature == 16 then
      return string.format("const thousand = 1_000\nreturn thousand + %s",expr), value+1000
   elseif feature == 17 then
      return string.format("local function apply<A, B>(x: A, f: function(A): B): B\n return f(x)\nend\nreturn apply(%s, n -> n + 1)",expr), value+1
   elseif feature == 18 then
      return string.format("local macro (@)!(a: Expression, b: Expression): Operator<infix, additive>\n return `$a + $b`\nend\nlocal macro (@@)! = (@)!\nreturn %s @@ 2",expr), value+2
   elseif feature == 19 then
      return string.format("local record Export end\nmacro Export.(@)!(a: Expression, b: Expression): Operator<infix, additive>\n return `$a + $b`\nend\nlocal macro (@)! = Export.(@)!\nreturn %s @ 2",expr), value+2
   elseif feature == 20 then
      return string.format("local function apply<A, B>(x: A, f: function(A): B): B return f(x) end\nreturn apply(%s, function(n) return n + 1 end)",expr), value+1
   elseif feature == 21 then
      return string.format("local record Item value: number end\nlocal item: Item = {value = %s}\nlocal function apply<A, B>(f: function(A): B, x: A): B return f(x) end\nreturn apply(n -> n + 2, item.value)",expr), value+2
   elseif feature == 22 then
      return string.format("local function use(f: (function(number, number, number): number) | nil): number\n if f then return f(%s, 2, 3) end\n return 0\nend\nreturn use(|value, _, _| -> value + 3)",expr), value+3
   elseif feature == 23 then
      return string.format("local add: function(number): (function(number): number) = outer -> inner -> outer + inner\nreturn add(%s)(2)",expr), value+2
   elseif feature == 24 then
      return string.format("local macro (declare)!(name: Expression): Operator<prefix, unary>\n return ```local $name = %s```\nend\ndeclare result\nreturn result",expr), value
   elseif feature == 25 then
      return string.format("local macro (initialized)!(name: Expression, value: Expression): Operator<infix, additive>\n return ```local $name = $value```\nend\nresult initialized (%s)\nreturn result",expr), value
   elseif feature == 26 then
      return string.format("local macro (initialized)!(name: Expression): Operator<postfix, postfix>\n return ```local $name = %s```\nend\nresult initialized\nreturn result",expr), value
   end
   error("unknown tl-ng feature: " .. tostring(feature))
end
local tokens: {string} = {
   "local","global","record","interface","enum","type","function","end","return","if","then","else","elseif","for","in","do","while","repeat","until","break","goto","::","as","is","where","and","or","not","nil","true","false","number","integer","string","boolean","any","unknown","userdata","metamethod","macroexp","require","(",")","{","}","[","]","<",">",":",";",",",".","=","...","?","|","&","//","<<",">>","~","^","+","-","*","/","%",'"x"',"'x'","[=[x]=]","--[[","]]","0","0xFF","1e-2","v","T","$","`","```","--#pragma arity on\n",
}
function generator.mutate(rng: generator.RNG, source: string): string
   for _ = 1, rng:next(5)+1 do
      local pos = rng:next(#source+1)
      local ending = math.min(#source, pos+rng:next(24)+1)
      local op = rng:next(6)
      local before, after = source:sub(1,pos), source:sub(pos+1)
      if op == 0 then source = before .. source:sub(ending+1)
      elseif op == 1 then source = before .. pick(rng,tokens) .. after
      elseif op == 2 then source = before
      elseif op == 3 then source = before .. source:sub(pos+1,ending):rep(rng:next(3)+2) .. after
      elseif op == 4 then source = before .. string.char(rng:next(256)) .. source:sub(ending+1)
      else source = before .. "\n--[=[" .. after .. "]=]\n" end
   end
   return source
end
function generator.case_for(seed: integer, index: integer, corpus: {string}, max_depth?: integer, selected?: string, native?: boolean): model.Case
   local rng = generator.rng(seed,index)
   local source, expected = generator.valid_program(rng)
   local dialect = selected == "tl-ng" and index % 16 < 8
   if dialect then source,expected = generator.tlng_program(rng,nil,native) end
   local profile = index % 8
   local case: model.Case = {source = source, expected = expected, profile = "grammar", seed = seed, index = index}
   if profile == 0 then case.profile = dialect and "tl-ng-grammar" or "grammar"
   elseif profile == 1 then
      case.source = "-- metamorphic\n" .. (source:gsub("%f[%w_]total%f[^%w_]","renamed_total"):gsub("\n","\n-- trivia\n"))
      case.profile = dialect and "tl-ng-metamorphic" or "metamorphic"
   elseif profile == 2 then case.source = generator.mutate(rng,source); case.expected = nil; case.profile = "editor"
   elseif profile == 3 then
      local parts: {string} = {}
      for _ = 1, rng:next(149)+1 do parts[#parts+1] = pick(rng,tokens) end
      case.source = table.concat(parts," "); case.expected = nil; case.profile = "tokens"
   elseif profile == 4 then
      local limit = max_depth or 128
      local depth = pick(rng,{math.min(8,limit),math.min(16,limit),math.min(32,limit),limit})
      local style = rng:next(4)
      if style == 0 then source = "return " .. ("("):rep(depth) .. "1" .. (")"):rep(depth)
      elseif style == 1 then source = ("do\n"):rep(depth) .. "local n: number = 1\n" .. ("end\n"):rep(depth)
      elseif style == 2 then source = "local type T = " .. ("{"):rep(depth) .. "number" .. ("}"):rep(depth)
      else
         local parts: {string} = {}
         for i = 0, depth-1 do parts[#parts+1] = "local type T" .. i .. " = " .. (i == 0 and "number" or "T" .. (i-1)) end
         source = table.concat(parts,"\n")
      end
      case.source = source; case.expected = nil; case.profile = "deep"
   elseif profile == 5 then case.source = generator.mutate(rng,#corpus > 0 and pick(rng,corpus) or source); case.expected = nil; case.profile = "corpus-mutation"
   elseif profile == 6 then
      if not dialect then case.source,case.expected = generator.valid_program(rng,40) end
      case.profile = dialect and "tl-ng-grammar" or "wide"
   else
      case.source = #corpus > 0 and corpus[math.floor(index/8)%#corpus+1] or source
      case.expected = nil; case.profile = "corpus"
      if selected == "tl-ng" and index%16 == 15 then
         case.source = case.source:sub(1,rng:next(#case.source+1)); case.profile = "extension-prefix"
      end
   end
   return case
end
return generator
