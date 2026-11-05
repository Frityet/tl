local function apply<A, B>(f: function(A): B, value: A): B
   return f(value)
end
local record Item value: integer end
local item: Item = {value = 3}
return apply(value -> value + 1, item.value)
