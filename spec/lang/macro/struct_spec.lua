local tl = require('teal.api.v2')

describe('extras struct macro', function()
   local imports = [[local structs = require('extras.struct')
local macro (struct)! = structs.(struct)!
]]
   local function compile(source)
      local ast, errors = tl.parse(imports .. source, 'struct-fixture.tl')
      assert.same({}, errors)
      return tl.check(ast, 'struct-fixture.tl', {gen_target = '5.1', gen_compat = 'off'})
   end
   local function run(source)
      local checked = compile(source)
      assert.same({}, checked.type_errors)
      local output, err = tl.generate(checked.ast, '5.1')
      assert.is_nil(err)
      return assert(loadstring(output), output)()
   end
   local function rejects(source, message)
      local _, errors = tl.parse(imports .. source, 'struct-fixture.tl')
      assert.is_true(#errors > 0)
      assert.matches(message, errors[1].msg, 1, true)
   end
   local function type_error(source, message)
      local checked = compile(source)
      assert.is_true(#checked.type_errors > 0)
      for _, err in ipairs(checked.type_errors) do
         if err.msg:find(message, 1, true) then return end
      end
      error('missing type error: ' .. message)
   end

   it('uses explicit value parameters and an implicit setter field binding', function()
      assert.same({1, 'bob', 30}, {run([[
         struct Sample {
            constructor(auto);
            id: integer = required {invariant = x -> x > 0};
            name: string = required {set = new -> do field = new:lower() end};
            score: number = property {default = 2, get = x -> x * 10};
         }
         local value = Sample:create(1, "ADA")
         value.name = "BOB"
         value.score = 3
         return value.id, value.name, value.score
      ]])})
   end)

   it('keeps public keys absent so every write invokes the setter', function()
      local value = run([[
         struct Sample {
            constructor(auto);
            value: integer = property {default = 0, set = new -> do field = field + new end};
         }
         return Sample:create()
      ]])
      value.value = 2
      value.value = 3
      assert.equals(5, value.value)
      assert.equals(5, rawget(value, '_value'))
      assert.is_nil(rawget(value, 'value'))
   end)

   it('preserves false and nil getter results', function()
      assert.same({false, nil}, {run([[
         struct Sample {
            constructor(auto);
            enabled: boolean = property {default = true, get = x -> not x};
            optional: string | nil = property {default = "stored", get = x -> nil};
         }
         local value = Sample:create()
         return value.enabled, value.optional
      ]])})
   end)

   it('supports nullable properties with strict nil enabled', function()
      assert.equals(0, run([[--#pragma strict_nil on
         struct Sample {
            value: string | nil = property {default = "hello", get = x -> x};
            tags: {string} = {};
         }
         local value = Sample:from {}
         value.value = nil
         assert(value.value == nil)
         return #value.tags
      ]]))
   end)

   it('preserves names captured by defaults and setters', function()
      assert.equals(8, run([[
         local __struct_runtime = 5
         local __struct_current = 3
         struct Sample {
            constructor(auto);
            value: integer = property {
               default = __struct_runtime;
               set = new -> do field = new + __struct_current end;
            };
         }
         return Sample:create().value
      ]]))
   end)

   it('leaves a field unchanged when validation fails', function()
      local value = run([[
         struct Sample {
            constructor(auto);
            value: integer = required {invariant = x -> x > 0, message = "must be positive"};
         }
         return Sample:create(3)
      ]])
      assert.has_error(function() value.value = 0 end, 'Sample.value: must be positive')
      assert.equals(3, value.value)
   end)

   it('validates after setter normalization', function()
      assert.equals(4, run([[
         struct Sample {
            constructor(auto);
            value: integer = required {
               set = new -> do field = math.abs(new) end;
               invariant = x -> x > 0;
            };
         }
         return Sample:create(-4).value
      ]]))
   end)

   it('runs each field invariant once per construction and assignment', function()
      assert.equals(2, run([[
         local checks = 0
         struct Sample {
            constructor(auto);
            value: integer = required {
               invariant = x -> do checks = checks + 1; return x > 0 end;
            };
         }
         local value = Sample:create(1)
         value.value = 2
         return checks
      ]]))
   end)

   it('evaluates defaults for each instance, only when omitted', function()
      assert.same({1, 2, 2, 0, 7}, {run([[
         local calls = 0
         local function next_value(): integer calls = calls + 1; return calls end
         struct Sample {
            constructor(auto);
            serial: integer = next_value();
            tags: {integer} = {};
         }
         local a, b, c = Sample:create(), Sample:create(), Sample:create(7)
         a.tags[1] = 9
         return a.serial, b.serial, calls, #b.tags, c.serial
      ]])})
   end)

   it('supports named construction and ordinary record methods', function()
      assert.equals(5, run([[
         struct Sample { id: integer = required; extra: integer = 2; }
         function Sample:sum(): integer return self.id + self.extra end
         local value = Sample:from {id = 3}
         return value:sum()
      ]]))
   end)

   it('allows a handwritten create without a constructor mode', function()
      assert.equals(42, run([[
         struct Sample { id: integer = required; }
         function Sample:create(id: integer): Sample return self:from {id = id} end
         return Sample:create(42).id
      ]]))
   end)

   it('rejects missing required and unknown constructor fields at runtime', function()
      local Sample = run('struct Sample {constructor(auto); id: integer = required;}\nreturn Sample')
      assert.has_error(function() Sample:create() end, 'Sample.id: a value is required')
      assert.has_error(function() Sample:from {id = 1, missing = 2} end, "Sample: unknown constructor field 'missing'")
      assert.has_error(function() Sample:create(1, 2) end, 'Sample: too many constructor arguments')
   end)

   it('supports whole-record invariants and rejects invalid writes before committing', function()
      local value = run([[
         struct Range {
            constructor(auto), invariant (x -> x.low <= x.high);
            low: integer = 1; high: integer = 5;
         }
         return Range:create()
      ]])
      assert.has_error(function() value.low = 6 end, 'Range: struct invariant failed')
      assert.equals(1, value.low)
      value.low = 4
      assert.equals(4, value.low)
      assert.equals(value, value:validate())
   end)

   it('supports readonly properties after construction', function()
      local value = run([[
         struct Sample {
            constructor(auto);
            id: integer = required {readonly = true};
         }
         return Sample:create(7)
      ]])
      assert.equals(7, value.id)
      assert.has_error(function() value.id = 8 end, 'Sample.id: property is readonly')
      assert.equals(7, value.id)
   end)

   it('rejects unknown property writes', function()
      local value = run('struct Sample {constructor(auto); value: integer = 0;}\nreturn Sample:create()')
      assert.has_error(function() value.unknown = 1 end, "Sample: unknown property 'unknown'")
   end)

   it('derives equality, selective deep copy, redacted display and JSON', function()
      local a, b, shown, encoded = run([[
         struct Sample {
            constructor(auto), deriving {
               Equal {ignore = {"stamp"}}, Copy {deep = {"tags"}},
               Show {redact = {"secret"}}, Json {omit = {"secret"}, rename = {id = "identifier"}},
            };
            id: integer = required;
            tags: {string} = {};
            secret: string = "hidden";
            stamp: integer = 1;
         }
         local a = Sample:create(7)
         a.tags[1] = "first"
         local b = a:copy()
         b.stamp = 2
         assert(a:equal(b))
         return a, b, a:show(), a:to_json()
      ]])
      assert.is_true(a == b)
      assert.equals(shown, tostring(a))
      b.tags[1] = 'changed'
      assert.equals('first', a.tags[1])
      assert.is_false(a == b)
      assert.not_matches('hidden', shown, 1, true)
      assert.matches('<redacted>', shown, 1, true)
      assert.equals('{"identifier":7,"tags":["first"],"stamp":1}', encoded)
   end)

   it('encodes empty arrays and optional nil values correctly', function()
      assert.equals('{"tags":[],"value":null}', run([[
         struct Sample {
            constructor(auto), deriving {Json};
            tags: {string} = {}; value: string | nil = nil;
         }
         return Sample:create():to_json()
      ]]))
   end)

   it('supports cyclic deep copies and diagnoses cyclic JSON', function()
      local value = run([[
         struct Sample {
            constructor(auto), deriving {Copy {deep = true}, Json};
            links: {string:any} = {};
         }
         return Sample:create()
      ]])
      value.links.self = value.links
      local copy = value:copy()
      assert.not_equals(value.links, copy.links)
      assert.equals(copy.links, copy.links.self)
      assert.has_error(function() value:to_json() end, 'Json: cyclic value')
   end)

   it('checks and installs custom trait providers through native interfaces', function()
      assert.equals('item:7', run([[
         local interface Labelled
            id: integer
            label: function(Labelled): string
         end
         local record Labels end
         function Labels.label(value: Labelled): string return "item:" .. tostring(value.id) end
         struct Sample {
            constructor(auto), deriving {Labels {implements = {Labelled}, methods = {label}}};
            id: integer = required;
         }
         return Sample:create(7):label()
      ]]))
   end)

   it('type-checks interface field conformance', function()
      type_error([[
         local interface HasId id: integer end
         struct Sample {implements(HasId); id: string = required;}
      ]], 'does not match definition in interface')
   end)

   it('type-checks custom trait method assignments against their interface', function()
      type_error([[
         local interface Labelled label: function(Labelled): string end
         local record Labels end
         function Labels.label(_value: Labelled): integer return 42 end
         struct Sample {deriving {Labels {implements = {Labelled}, methods = {label}}};}
      ]], 'string')
   end)

   it('type-checks getter, invariant and setter contracts', function()
      type_error('struct Sample {value: integer = property {default = 0, get = x -> "bad"};}', 'integer')
      type_error('struct Sample {value: integer = required {invariant = x -> x + 1};}', 'boolean')
      type_error('struct Sample {value: string = required {set = new -> do field = 4 end};}', 'string')
   end)

   it('type-checks constructor calls, public writes and named inputs', function()
      type_error('struct Sample {constructor(auto); id: integer = required;}\nlocal x = Sample:create("bad")', 'integer')
      type_error('struct Sample {constructor(auto); id: integer = required;}\nlocal x = Sample:create(1); x.id = "bad"', 'integer')
      type_error('struct Sample {id: integer = required;}\nlocal x = Sample:from {}', 'missing')
   end)

   it('does not expose backing fields in the public Teal type', function()
      type_error('struct Sample {constructor(auto); id: integer = required;}\nlocal x = Sample:create(1); print(x._id)', '_id')
   end)

   it('diagnoses malformed metadata and naming conflicts', function()
      rejects('struct Sample(T) {value: T = required;}', 'generic parameters are deferred')
      rejects('struct Sample {constructor(manual); value: integer = 0;}', 'constructor only accepts auto')
      rejects('struct Sample {value: integer = 0; _value: integer = 1;}', 'backing field collision')
      rejects('struct Sample {value: integer = 0; value: integer = 1;}', 'duplicate field')
      rejects('struct Sample {deriving {Equal {ignore = {"missing"}}}; value: integer = 0;}', 'unknown field')
      rejects('struct Sample {deriving {Json {rename = {x = "y"}}}; x: integer = 0; y: integer = 1;}', 'duplicate Json output name')
      rejects('struct Sample {value: integer = required {set = |field, new| -> do field = new end};}', 'exactly one value parameter')
      rejects('struct Sample {value: integer = required {set = field -> field};}', 'cannot shadow')
      rejects('struct Sample {value: integer = required {typo = true};}', 'unknown property option')
   end)
end)
