--#pragma strict_nil on
local record FFI end

--- Declare C prototypes, extern objects and typedefs from a string literal.
--- The compiler checks the declared symbols in the C namespace.
macro FFI.cdef!(declarations: Expression)
   if declarations.kind ~= "string" then
      error("ffi.cdef! expects one string literal", 0)
   end
   local declaration = block("ffi_cdef")
   declaration.tk = declarations.tk
   return declaration
end

return FFI
