local util = require("spec.util")

describe("fornum", function()
   it("5.3: doesn't generate control variable that is local to the iteration", util.gen([[
      local t: {string} = { "a", "b", "c" }

      for i = 1, #t do
         i = i + 1
         print(t[i])
      end
   ]], [[
      local t = { "a", "b", "c" }

      for i = 1, #t do
         i = i + 1
         print(t[i])
      end
   ]], "5.3"))

   it("5.4: generates control variable that is local to the iteration", util.gen([[
      local t: {string} = { "a", "b", "c" }

      for i = 1, #t do
         i = i + 1
         print(t[i])
      end
   ]], [[
      local t = { "a", "b", "c" }

      for i = 1, #t do local i = i
         i = i + 1
         print(t[i])
      end
   ]], "5.4"))

   it("5.4: does not generate control variable if not assigned to", util.gen([[
      local t: {string} = { "a", "b", "c" }

      for i = 1, #t do
         local j = i + 1
         print(t[j])
      end
   ]], [[
      local t = { "a", "b", "c" }

      for i = 1, #t do
         local j = i + 1
         print(t[j])
      end
   ]], "5.4"))

   it("5.4: generates control variable for a loop with a step", util.gen([[
      for i = 10, 1, -2 do
         i = i // 2
         print(i)
      end
   ]], [[
      for i = 10, 1, -2 do local i = i
         i = i // 2
         print(i)
      end
   ]], "5.4"))

   it("5.4: detects an assignment made from a nested function", util.gen([[
      for i = 1, 3 do
         local function bump()
            i = i + 1
         end
         bump()
         print(i)
      end
   ]], [[
      for i = 1, 3 do local i = i
         local function bump()
            i = i + 1
         end
         bump()
         print(i)
      end
   ]], "5.4"))

   it("5.4: only shadows the loops that are assigned to", util.gen([[
      for i = 1, 3 do
         for j = 1, 3 do
            j = j + 1
            print(i, j)
         end
      end
   ]], [[
      for i = 1, 3 do
         for j = 1, 3 do local j = j
            j = j + 1
            print(i, j)
         end
      end
   ]], "5.4"))
end)
