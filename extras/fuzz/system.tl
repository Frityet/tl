--#pragma strict_nil off
-- The only foreign/dynamic boundary: POSIX ABI objects are owned by this module.
-- Disable JIT before fork: children only configure descriptors/limits and exec.
local interface Handle end
local record Time
   tv_sec: number
   tv_nsec: number
end
local record Limit
   rlim_cur: number
   rlim_max: number
end
local record Entry
   name: any
   type: integer
end
local record Bindings
   fork: function(): integer
   getpid: function(): integer
   getpgrp: function(): integer
   execv: function(string, {string}): integer
   write: function(integer, string, integer): integer
   _exit: function(integer)
   setpgid: function(integer, integer): integer
   kill: function(integer, integer): integer
   waitpid: function(integer, {integer}, integer): integer
   chdir: function(string): integer
   getcwd: function(any, integer): any
   realpath: function(string, any): any
   access: function(string, integer): integer
   mkdir: function(string, integer): integer
   mkdtemp: function(any): any
   unlink: function(string): integer
   rmdir: function(string): integer
   open: function(string, integer, ...: any): integer
   close: function(integer): integer
   dup2: function(integer, integer): integer
   unsetenv: function(string): integer
   poll: function(any, integer, integer): integer
   clock_gettime: function(integer, {Time}): integer
   setrlimit: function(integer, {Limit}): integer
   opendir: function(string): Handle
   closedir: function(Handle): integer
   readdir: function(Handle): Entry
end
local record Foreign
   os: string
   C: Bindings
   cdef: function(string)
   new: function(string, ...: any): any
   string: function(any): string
   errno: function(): integer
end
local record Jit
   off: function()
end
local foreign_require = require as function(string): any
local ffi = foreign_require("ffi") as Foreign
local jit = foreign_require("jit") as Jit
jit.off()
assert(ffi.os == "OSX" or ffi.os == "Linux", "fuzzer supervisor requires macOS or Linux LuaJIT")
local darwin: boolean = ffi.os == "OSX"
ffi.cdef[[
long write(int, const void *, unsigned long);
int getpid(void); int getpgrp(void);
int fork(void); int execv(const char *, const char *const *); void _exit(int);
int setpgid(int, int); int kill(int, int); int waitpid(int, int *, int);
int chdir(const char *); char *getcwd(char *, unsigned long); char *realpath(const char *, char *);
int access(const char *, int); int mkdir(const char *, unsigned int);
char *mkdtemp(char *); int unlink(const char *); int rmdir(const char *);
int open(const char *, int, ...); int close(int); int dup2(int, int);
int unsetenv(const char *); int poll(void *, unsigned long, int);
struct fuzz_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int, struct fuzz_timespec *);
struct fuzz_rlimit { unsigned long long rlim_cur; unsigned long long rlim_max; };
int setrlimit(int, const struct fuzz_rlimit *);
void *opendir(const char *); int closedir(void *);
]]
if darwin then
   ffi.cdef[[struct fuzz_dirent { unsigned long long ino, off; unsigned short reclen, namlen; unsigned char type; char name[1024]; };]]
else
   ffi.cdef[[struct fuzz_dirent { unsigned long ino; long off; unsigned short reclen; unsigned char type; char name[256]; };]]
end
ffi.cdef[[struct fuzz_dirent *readdir(void *);]]
local C = ffi.C

local record system
   record Process
      pid: integer
      started: number
      timeout: number
      done: boolean
      timed_out: boolean
      status: integer
   end
   now: function(): number
   pause: function(integer)
   absolute: function(string): string
   executable: function(string): string
   mkdir: function(string)
   tempdir: function(): string
   read: function(string, ? integer): string
   tail: function(string, integer): string
   write: function(string, string)
   files: function(string): {string}
   cleanup: function(string)
   spawn: function({string}, string, string, string, number, integer): Process
   poll: function(Process): boolean
   kill: function(Process)
end

function system.now(): number
   local ts: {Time} = ffi.new("struct fuzz_timespec[1]") as {Time}
   assert(C.clock_gettime(darwin and 6 or 1, ts) == 0, "clock_gettime failed")
   return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) / 1e9
end
function system.pause(ms: integer)
   C.poll(nil, 0, ms)
end
function system.absolute(path: string): string
   local buf = ffi.new("char[4096]")
   if C.realpath(path, buf) ~= nil then return ffi.string(buf) as string end
   if path:sub(1, 1) == "/" then return path end
   assert(C.getcwd(buf, 4096) ~= nil, "getcwd failed")
   return (ffi.string(buf) as string) .. "/" .. path
end
function system.executable(name: string): string
   if name:find("/", 1, true) then
      if C.access(name, 1) == 0 then return system.absolute(name) end
      return nil
   end
   for path in ((os.getenv("PATH") or "") .. ":"):gmatch("(.-):") do
      local candidate = (path == "" and "." or path) .. "/" .. name
      if C.access(candidate, 1) == 0 then return system.absolute(candidate) end
   end
   return nil
end
function system.mkdir(path: string)
   local current = path:sub(1, 1) == "/" and "" or "."
   for component in path:gmatch("[^/]+") do
      current = current .. "/" .. component
      if C.mkdir(current, 448) ~= 0 then
         local d = C.opendir(current)
         assert(d ~= nil, "cannot create directory: " .. current)
         C.closedir(d)
      end
   end
end
function system.tempdir(): string
   local pattern = (os.getenv("TMPDIR") or "/tmp") .. "/teal-fuzz-XXXXXX"
   local buf = ffi.new("char[?]", #pattern + 1, pattern)
   assert(C.mkdtemp(buf) ~= nil, "mkdtemp failed")
   return ffi.string(buf) as string
end
function system.read(path: string, maximum?: integer): string
   local f = io.open(path, "rb")
   if not f then return nil end
   local data: string
   local read_error: string
   if maximum then data,read_error = f:read(maximum + 1) else data,read_error = f:read("*a") end
   f:close()
   if read_error then return nil end
   data = data or ""
   if maximum and #data > maximum then return nil end
   return data
end
function system.tail(path: string, count: integer): string
   local f = io.open(path, "rb")
   if not f then return "" end
   local size = f:seek("end") or 0
   f:seek("set", math.max(0, size - count))
   local data = f:read("*a"); f:close()
   return data
end
function system.write(path: string, text: string)
   local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
function system.files(path: string): {string}
   local result: {string} = {}
   local function walk(dir: string, depth: integer)
      assert(depth <= 64, "corpus directory nesting exceeds 64")
      local d = C.opendir(dir)
      if d == nil then
         if dir:match("%.tl$") and system.read(dir, 0) ~= nil then result[#result + 1] = dir end
         return
      end
      while true do
         local entry = C.readdir(d)
         if entry == nil then break end
         local name = ffi.string(entry.name) as string
         if name ~= "." and name ~= ".." then
            local child = dir .. "/" .. name
            if entry.type == 4 then walk(child, depth + 1)
            elseif entry.type == 0 then
               local nested = C.opendir(child)
               if nested ~= nil then C.closedir(nested); walk(child, depth + 1)
               elseif name:match("%.tl$") then result[#result + 1] = child end
            elseif entry.type ~= 10 and name:match("%.tl$") then result[#result + 1] = child end
         end
      end
      C.closedir(d)
   end
   -- A direct file seed need not be empty (read(path,0) tests size rather than existence).
   local f = io.open(path, "rb")
   local d = C.opendir(path)
   if d ~= nil then C.closedir(d); if f then f:close() end; walk(path, 0)
   elseif f then f:close(); result[1] = path end
   table.sort(result)
   return result
end
function system.cleanup(dir: string)
   -- Only remove files we created; do not recursively delete worker-created content.
   for _, name in ipairs({"input.tl", "stdout", "stderr"}) do C.unlink(dir .. "/" .. name) end
   C.rmdir(dir)
end
local function child_fail(message: string)
   local text = "fuzzer child setup: " .. message .. " (errno " .. ffi.errno() .. ")\n"
   C.write(2,text,#text)
   C._exit(125)
end
local function limit(kind: integer, soft: number, hard: number)
   local value: {Limit} = ffi.new("struct fuzz_rlimit[1]") as {Limit}
   value[0].rlim_cur = soft; value[0].rlim_max = hard
   if C.setrlimit(kind, value) ~= 0 then child_fail("setrlimit " .. kind) end
end
function system.spawn(args: {string}, cwd: string, stdout: string, stderr: string, timeout: number, memory_mb: integer): system.Process
   local argv: {string} = ffi.new("const char *[?]", #args + 1) as {string}
   for i, value in ipairs(args) do argv[i - 1] = value end
   io.stdout:flush(); io.stderr:flush()
   local pid = C.fork() as integer
   assert(pid >= 0, "fork failed")
   if pid == 0 then
      -- The parent may have established this group already (Darwin can return EPERM).
      if C.setpgid(0, 0) ~= 0 and C.getpgrp() ~= C.getpid() then child_fail("setpgid") end
      if C.chdir(cwd) ~= 0 then child_fail("chdir") end
      local flags = darwin and 1537 or 577 -- O_WRONLY | O_CREAT | O_TRUNC
      local out = C.open(stdout, flags, ffi.new("int", 384))
      local err = C.open(stderr, flags, ffi.new("int", 384))
      local input = C.open("/dev/null", 0)
      if out < 0 or err < 0 or input < 0 then child_fail("open stdio") end
      if C.dup2(input, 0) < 0 or C.dup2(out, 1) < 0 or C.dup2(err, 2) < 0 then child_fail("dup2") end
      if input > 2 then C.close(input) end
      if out > 2 then C.close(out) end
      if err > 2 then C.close(err) end
      C.unsetenv("LUA_INIT"); C.unsetenv("TL_PATH"); C.unsetenv("LUA_PATH"); C.unsetenv("LUA_CPATH")
      for version = 1, 5 do
         for _, key in ipairs({"LUA_INIT_5_", "LUA_PATH_5_", "LUA_CPATH_5_"}) do C.unsetenv(key .. version) end
      end
      limit(0, math.max(1, math.ceil(timeout)), math.max(2, math.ceil(timeout) + 1))
      limit(1, 4 * 1024 * 1024, 4 * 1024 * 1024); limit(4, 0, 0)
      if memory_mb > 0 then limit(darwin and 5 or 9, memory_mb * 1024 ^ 2, memory_mb * 1024 ^ 2) end
      C.execv(args[1], argv); C._exit(127)
   end
   -- Close the race where the timeout fires before the child establishes its group.
   C.setpgid(pid, pid)
   return {pid = pid, started = system.now(), timeout = timeout, done = false, timed_out = false, status = 0}
end
function system.kill(p: system.Process)
   if not p.done then
      C.kill(-p.pid, 9); C.kill(p.pid, 9)
      local status: {integer} = ffi.new("int[1]") as {integer}
      while C.waitpid(p.pid, status, 0) < 0 and ffi.errno() == 4 do end
      p.status = tonumber(status[0]) as integer; p.done = true
   end
end
function system.poll(p: system.Process): boolean
   if p.done then return true end
   local status: {integer} = ffi.new("int[1]") as {integer}
   local result = C.waitpid(p.pid, status, 1)
   if result == p.pid then
      p.status = tonumber(status[0]) as integer; p.done = true
   elseif result < 0 then
      if ffi.errno() == 4 then return false end
      system.kill(p); p.status = -1
   elseif system.now() - p.started >= p.timeout then
      p.timed_out = true; system.kill(p)
   end
   return p.done
end
return system
