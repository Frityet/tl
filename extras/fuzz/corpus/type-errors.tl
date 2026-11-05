local record R
   x: number
end
local r: R = {x = "wrong"}
local n: number = true
local function f(x: string): number
   return x
end
return f(r)
