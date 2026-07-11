local record ffi
   interface CData end
   interface Array<T> is {T}, CData end
   type CNamespace = {string:any}
   cdef: function(string)
   new: function<T>(string, ...: any): T
   istype: function(any, any): boolean
   C: CNamespace
   os: string
end

return ffi
