local record ffi
   interface CData end
   interface Array<T> is {T}, CData end
   interface CType is CData
      metamethod __call: function(CType, ...: any): any
   end
   type TypeSpec = string | CData
   type CNamespace = {string:any}
   load: function(string, ? boolean): CNamespace
   string: function(any, ? integer): string
   cdef: function(string)
   new: function<T>(TypeSpec, ...: any): T
   typeof: function(TypeSpec, ...: any): CType
   cast: function(TypeSpec, any): any
   metatype: function(TypeSpec, {string:any}): CType
   copy: function(any, any, ? integer)
   fill: function(any, integer, ? integer)
   gc: function<T>(T, function(T) | CData | nil): T
   sizeof: function(TypeSpec, ? integer): integer | nil
   alignof: function(TypeSpec): integer
   offsetof: function(TypeSpec, string): integer | nil, integer | nil, integer | nil
   abi: function(string): boolean
   istype: function(any, any): boolean
   C: CNamespace
   os: string
end

return ffi
