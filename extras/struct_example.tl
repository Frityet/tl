local structs = require("extras.struct")
local macro (struct)! = structs.(struct)!

local interface Identifiable
   id: integer
end

local interface Serializable
   to_json: function(self: Serializable): string
end

local interface Labelled is Identifiable
   label: function(self: Labelled): string
end

local record Labels end

function Labels.label(self: Labelled): string
   return "employee:" .. tostring(self.id)
end

struct Employee {
   implements(Identifiable, Serializable),
   deriving {
      Equal {ignore = {"created_at"}},
      Copy {deep = {"tags"}},
      Show {redact = {"access_token"}},
      Json {omit = {"access_token"}, rename = {id = "employee_id"}},
      Labels {implements = {Labelled}, methods = {label}},
   },
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

local employee = Employee:create(42, "ADA")
employee.name = "GRACE"
employee.score = 3
employee.tags[1] = "engineering"

local copy = employee:copy()
assert(copy == employee)
copy.tags[1] = "research"
assert(employee.tags[1] == "engineering")
assert(employee.name == "grace" and employee.score == 30)

employee:print_id()
print(employee:label())
print(employee:show())
print(employee:to_json())
