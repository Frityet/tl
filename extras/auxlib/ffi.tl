--#pragma strict_nil on
local record FFI end

--- Declare C prototypes, extern objects and typedefs from a string literal.
--- The native checker makes the declared symbols available in the C namespace.
macro FFI.cdef!(declarations: Expression)
   return `require("ffi").cdef($declarations)`
end

return FFI
