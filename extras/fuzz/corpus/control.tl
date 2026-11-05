local sum: number = 0
local function count(...: number): number
   local args = {...}
   local n: number = 0
   for _, x in ipairs(args) do n = n + x end
   return n
end
for i = 1, 5 do
   local n = i
   while n > 0 do
      n = n - 1
      if n == 1 then break end
      sum = sum + n
   end
end
return count(sum, 2, 3)
