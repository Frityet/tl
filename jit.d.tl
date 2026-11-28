local record jit
   on: function(? function | boolean, ? boolean)
   off: function(? function | boolean, ? boolean)
   flush: function(? function | boolean | integer, ? boolean)
   status: function(): boolean, string...
   version: string
   version_num: integer
   os: string
   arch: string
end

return jit
