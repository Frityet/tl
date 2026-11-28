





local model = { Rule = {}, RuleInfo = {}, EnabledRule = {}, Plan = {}, State = {} }














































































function model.unwrap(n)
   while n and (n.kind == "paren" or (n.op and n.op.op == "as")) do
      n = n.e1
   end
   return n
end

function model.number(n)
   n = model.unwrap(n)
   if not n then return nil end
   if n.kind == "number" or n.kind == "integer" then
      return n.constnum
   end
   if n.op and n.op.op == "-" and n.op.arity == 1 then
      local value = model.number(n.e1)
      return value and -value
   end
end

function model.call_args(n)
   n = model.unwrap(n)
   if n and n.op and n.op.op == "@funcall" then
      return n.e2
   end
end

return model
