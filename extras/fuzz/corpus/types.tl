local interface Named
   name: string
end
local record Box<T>
   value: T
end
local record Person is Named
   name: string
   age: number
end
local p: Person = {name = "Teal", age = 1}
local b: Box<Person> = {value = p}
local function choose<T>(a: T, b: T, flag: boolean): T
   if flag then return a else return b end
end
return choose(b.value.age, 2, true)
