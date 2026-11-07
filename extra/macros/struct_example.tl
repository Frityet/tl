local structs = require("extra.macros.struct")
local macro (struct)! = structs.(struct)!

local interface Identifiable
   id: integer
end

local interface Labelled is Identifiable
   label: function(self: Labelled): string
end

struct Employee {
   implements(Labelled),
   constructor(auto);

   id: integer = required {invariant = x -> x > 0, readonly = true};
   name: string = required {
      invariant = x -> #x > 0;
      set = new -> do field = new:lower() end;
   };
   score: number = property {default = 2, get = x -> x * 10};
   tags: {string} = {};
   access_token: string | nil = nil;
   created_at: number = os.time();
}

function Employee:print_id()
   print(self.id)
end

function Employee:label(): string
   return "employee:" .. tostring(self.id)
end

local employee = Employee:create(42, "ADA")
employee.name = "GRACE"
employee.score = 3
employee.tags[1] = "engineering"

assert(employee.tags[1] == "engineering")
assert(employee.name == "grace" and employee.score == 30)

employee:print_id()
print(employee:label())
