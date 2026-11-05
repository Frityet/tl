























































local foreign_require = require
local ffi = foreign_require("ffi")
local jit = foreign_require("jit")
jit.off()
assert(ffi.os == "OSX" or ffi.os == "Linux", "fuzzer supervisor requires macOS or Linux LuaJIT")
local darwin = ffi.os == "OSX"
ffi.cdef([[
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
]])
if darwin then
   ffi.cdef([[struct fuzz_dirent { unsigned long long ino, off; unsigned short reclen, namlen; unsigned char type; char name[1024]; };]])
else
   ffi.cdef([[struct fuzz_dirent { unsigned long ino; long off; unsigned short reclen; unsigned char type; char name[256]; };]])
end
ffi.cdef([[struct fuzz_dirent *readdir(void *);]])
local C = ffi.C

local system = { Process = {} }
























function system.now()
   local ts = ffi.new("struct fuzz_timespec[1]")
   assert(C.clock_gettime(darwin and 6 or 1, ts) == 0, "clock_gettime failed")
   return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) / 1e9
end
function system.pause(ms)
   C.poll(nil, 0, ms)
end
function system.absolute(path)
   local buf = ffi.new("char[4096]")
   if C.realpath(path, buf) ~= nil then return ffi.string(buf) end
   if path:sub(1, 1) == "/" then return path end
   assert(C.getcwd(buf, 4096) ~= nil, "getcwd failed")
   return (ffi.string(buf)) .. "/" .. path
end
function system.executable(name)
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
function system.mkdir(path)
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
function system.tempdir()
   local pattern = (os.getenv("TMPDIR") or "/tmp") .. "/teal-fuzz-XXXXXX"
   local buf = ffi.new("char[?]", #pattern + 1, pattern)
   assert(C.mkdtemp(buf) ~= nil, "mkdtemp failed")
   return ffi.string(buf)
end
function system.read(path, maximum)
   local f = io.open(path, "rb")
   if not f then return nil end
   local data
   local read_error
   if maximum then data, read_error = f:read(maximum + 1) else data, read_error = f:read("*a") end
   f:close()
   if read_error then return nil end
   data = data or ""
   if maximum and #data > maximum then return nil end
   return data
end
function system.tail(path, count)
   local f = io.open(path, "rb")
   if not f then return "" end
   local size = f:seek("end") or 0
   f:seek("set", math.max(0, size - count))
   local data = f:read("*a"); f:close()
   return data
end
function system.write(path, text)
   local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
function system.files(path)
   local result = {}
   local function walk(dir, depth)
      assert(depth <= 64, "corpus directory nesting exceeds 64")
      local d = C.opendir(dir)
      if d == nil then
         if dir:match("%.tl$") and system.read(dir, 0) ~= nil then result[#result + 1] = dir end
         return
      end
      while true do
         local entry = C.readdir(d)
         if entry == nil then break end
         local name = ffi.string(entry.name)
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

   local f = io.open(path, "rb")
   local d = C.opendir(path)
   if d ~= nil then C.closedir(d); if f then f:close() end; walk(path, 0)
   elseif f then f:close(); result[1] = path end
   table.sort(result)
   return result
end
function system.cleanup(dir)

   for _, name in ipairs({ "input.tl", "stdout", "stderr" }) do C.unlink(dir .. "/" .. name) end
   C.rmdir(dir)
end
local function child_fail(message)
   local text = "fuzzer child setup: " .. message .. " (errno " .. ffi.errno() .. ")\n"
   C.write(2, text, #text)
   C._exit(125)
end
local function limit(kind, soft, hard)
   local value = ffi.new("struct fuzz_rlimit[1]")
   value[0].rlim_cur = soft; value[0].rlim_max = hard
   if C.setrlimit(kind, value) ~= 0 then child_fail("setrlimit " .. kind) end
end
function system.spawn(args, cwd, stdout, stderr, timeout, memory_mb)
   local argv = ffi.new("const char *[?]", #args + 1)
   for i, value in ipairs(args) do argv[i - 1] = value end
   io.stdout:flush(); io.stderr:flush()
   local pid = C.fork()
   assert(pid >= 0, "fork failed")
   if pid == 0 then

      if C.setpgid(0, 0) ~= 0 and C.getpgrp() ~= C.getpid() then child_fail("setpgid") end
      if C.chdir(cwd) ~= 0 then child_fail("chdir") end
      local flags = darwin and 1537 or 577
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
         for _, key in ipairs({ "LUA_INIT_5_", "LUA_PATH_5_", "LUA_CPATH_5_" }) do C.unsetenv(key .. version) end
      end
      limit(0, math.max(1, math.ceil(timeout)), math.max(2, math.ceil(timeout) + 1))
      limit(1, 4 * 1024 * 1024, 4 * 1024 * 1024); limit(4, 0, 0)
      if memory_mb > 0 then limit(darwin and 5 or 9, memory_mb * 1024 ^ 2, memory_mb * 1024 ^ 2) end
      C.execv(args[1], argv); C._exit(127)
   end

   C.setpgid(pid, pid)
   return { pid = pid, started = system.now(), timeout = timeout, done = false, timed_out = false, status = 0 }
end
function system.kill(p)
   if not p.done then
      C.kill(-p.pid, 9); C.kill(p.pid, 9)
      local status = ffi.new("int[1]")
      while C.waitpid(p.pid, status, 0) < 0 and ffi.errno() == 4 do end
      p.status = tonumber(status[0]); p.done = true
   end
end
function system.poll(p)
   if p.done then return true end
   local status = ffi.new("int[1]")
   local result = C.waitpid(p.pid, status, 1)
   if result == p.pid then
      p.status = tonumber(status[0]); p.done = true
   elseif result < 0 then
      if ffi.errno() == 4 then return false end
      system.kill(p); p.status = -1
   elseif system.now() - p.started >= p.timeout then
      p.timed_out = true; system.kill(p)
   end
   return p.done
end
return system
