-- These are definitions that are core to the language.
--
-- In Lua terms, these are definitions that fundamental to the
-- Lua language behavior itself, that is, which are valid
-- even before one does luaL_openlibs to load the standard
-- library.

global interface any
end

global interface thread
end

global interface userdata
   is userdata
end

global record metatable<T>
   enum Mode
      "k" "v" "kv"
   end

   __call: function(T, any...): any...
   __mode: Mode
   __name: string
   __tostring: function(T): string
   __pairs: function<K, V>(T): function(): (K, V)

   __index: any --[[FIXME: function | table | anything with an __index metamethod]]
   __newindex: any --[[FIXME: function | table | anything with an __index metamethod]]

   __gc: function(T)
   __close: function(T)

   __add: function<A, B, C>(A, B): C
   __sub: function<A, B, C>(A, B): C
   __mul: function<A, B, C>(A, B): C
   __div: function<A, B, C>(A, B): C
   __idiv: function<A, B, C>(A, B): C
   __mod: function<A, B, C>(A, B): C
   __pow: function<A, B, C>(A, B): C
   __band: function<A, B, C>(A, B): C
   __bor: function<A, B, C>(A, B): C
   __bxor: function<A, B, C>(A, B): C
   __shl: function<A, B, C>(A, B): C
   __shr: function<A, B, C>(A, B): C
   __concat: function<A, B, C>(A, B): C

   __len: function<A>(T): A
   __unm: function<A>(T): A
   __bnot: function<A>(T): A

   __eq: function<A, B>(A, B): boolean
   __lt: function<A, B>(A, B): boolean
   __le: function<A, B>(A, B): boolean
end

--- Types returned by the builtin typeof! macro.
global record reflection
   enum Kind
      "any" "unknown" "nil" "boolean" "integer" "number" "string" "thread" "userdata"
      "table" "array" "map" "tuple" "record" "interface" "enum" "function"
      "overload" "union" "type_parameter" "reference"
   end

   interface Type where self.kind
      kind: Kind
      text: string
      type_arguments: {Type}?
      type_parameters: {TypeParameter}?

      metamethod __eq: function(Type, Type): boolean
      metamethod __tostring: function(Type): string
   end

   record AnyType is Type where self.kind == "any"
      kind: "any"
   end

   record UnknownType is Type where self.kind == "unknown"
      kind: "unknown"
   end

   record NilType is Type where self.kind == "nil"
      kind: "nil"
   end

   record BooleanType is Type where self.kind == "boolean"
      kind: "boolean"
      literal: boolean?
   end

   record IntegerType is Type where self.kind == "integer"
      kind: "integer"
      literal: integer?
   end

   record NumberType is Type where self.kind == "number"
      kind: "number"
      literal: number?
   end

   record StringType is Type where self.kind == "string"
      kind: "string"
      literal: string?
   end

   record ThreadType is Type where self.kind == "thread"
      kind: "thread"
   end

   record UserdataType is Type where self.kind == "userdata"
      kind: "userdata"
   end

   record TableType is Type where self.kind == "table"
      kind: "table"
   end

   record ArrayType is Type where self.kind == "array"
      kind: "array"
      element: Type
   end

   record MapType is Type where self.kind == "map"
      kind: "map"
      key: Type
      value: Type
   end

   record TupleType is Type where self.kind == "tuple"
      kind: "tuple"
      items: {Type}
   end

   interface RecordLikeType is Type where self.fields
      name: string?
      fields: {string: Type}
      metamethods: {string: Type}?
      interfaces: {Type}?
      userdata: boolean?
      element: Type?
      items: {Type}?
   end

   record RecordType is RecordLikeType where self.kind == "record"
      kind: "record"
   end

   record InterfaceType is RecordLikeType where self.kind == "interface"
      kind: "interface"
   end

   record EnumType is Type where self.kind == "enum"
      kind: "enum"
      name: string?
      values: {string}
   end

   record FunctionType is Type where self.kind == "function"
      kind: "function"
      parameters: {Type}
      returns: {Type}
      required_parameters: integer
      variadic_parameters: boolean
      variadic_returns: boolean
      method: boolean?
   end

   record OverloadType is Type where self.kind == "overload"
      kind: "overload"
      alternatives: {FunctionType}
   end

   record UnionType is Type where self.kind == "union"
      kind: "union"
      alternatives: {Type}
   end

   record TypeParameter is Type where self.kind == "type_parameter"
      kind: "type_parameter"
      name: string
      constraint: Type?
   end

   record ReferenceType is Type where self.kind == "reference"
      kind: "reference"
      name: string?
   end
end
