local macro (declare)!(name: Expression): Operator<prefix, unary>
   return ```local record $name value: integer end```
end

declare Item
local item: Item = {value = 42}
return item.value
