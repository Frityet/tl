local macro inner!(value: Expression): Expression
   return `$value`
end

local macro outer!(): Expression
   return `inner!(1)`
end

return outer!()
