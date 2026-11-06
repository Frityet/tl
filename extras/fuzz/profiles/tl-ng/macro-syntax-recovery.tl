local macro (emit)!(expr: Expression): Operator<prefix, unary>
   return `print($expr)`
end

local invalid = emit []
