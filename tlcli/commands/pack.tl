--#pragma strict_nil off
local lfs = require("lfs")
local teal = require("teal.init")
local lexer = require("teal.lexer")
local common = require("tlcli.common")
local driver = require("tlcli.driver")
local report = require("tlcli.report")
local native = require("tlcli.pack_native")
local type Args = require("tlcli.args")
local type TlConfig = require("tlcli.tlconfig")

local record Chunk
   name: string
   filename: string
   code: string
end

local record Link
   cc: string
   include: string
   libraries: {string}
   compress: boolean
end

local function fail(message: string)
   error("tl pack: " .. message, 0)
end

local function file_exists(path: string): boolean
   return lfs.attributes(path, "mode") == "file"
end

local function directory(path: string): string
   local dir = path:match("^(.*)/")
   return dir == "" and "/" or dir or "."
end

local function absolute(path: string): string
   return path:sub(1, 1) == "/" and path or assert(lfs.currentdir()) .. "/" .. path
end

local function protect_input(output: string, input: string)
   local from = lfs.attributes(input)
   local to = lfs.attributes(output)
   if from and to and from.dev == to.dev and from.ino == to.ino then
      fail("output would replace an input file: " .. input)
   end
end

local function read(path: string): string
   local file = assert(io.open(path, "rb"))
   local data, err = file:read("*a")
   file:close()
   return assert(data, err)
end

local function write(path: string, data: string)
   local file = assert(io.open(path, "wb"))
   local ok, err = file:write(data)
   local closed, close_err = file:close()
   assert(ok, err)
   assert(closed, close_err)
end

local function command(argv: {string}): string
   local quoted: {string} = {}
   for i, value in ipairs(argv) do
      assert(not value:find("%z"), "NUL byte in command argument")
      quoted[i] = "'" .. value:gsub("'", "'\\''") .. "'"
   end
   return table.concat(quoted, " ")
end

-- Lua 5.1 returns a numeric status. Later versions return true on success.
local function succeeded(status: any): boolean
   return status == true or status == 0
end

local function exec(argv: {string}, action: string, output?: string)
   local cmd = command(argv)
   if output then cmd = cmd .. " > " .. command({output}) end
   if not succeeded((os.execute(cmd))) then
      fail(action .. " failed")
   end
end

local function capture(argv: {string}): string
   local pipe = io.popen(command(argv) .. " 2>/dev/null", "r")
   if not pipe then return end
   local data = pipe:read("*a")
   pipe:close()
   return data and data:match("^%s*(.-)%s*$")
end

local function cc_library(cc: string, name: string): string
   local path = capture({cc, "-print-file-name=" .. name})
   if path and file_exists(path) then return path end
end

local function pkg_config(version: string): string, string, string
   local packages: {string} = {}
   local versions = version and {version} or {"5.4", "5.5", "5.3", "luajit", "5.2", "5.1"}
   for _, v in ipairs(versions) do
      if v == "luajit" then
         table.insert(packages, "luajit")
      else
         table.insert(packages, "lua" .. v)
         table.insert(packages, "lua-" .. v)
         table.insert(packages, ("lua" .. v:gsub("%.", "")))
      end
   end
   table.insert(packages, "lua")
   for _, pkg in ipairs(packages) do
      local includes = capture({"pkg-config", "--variable=includedir", pkg})
      if includes and not file_exists(includes .. "/lua.h") then
         local cflags = capture({"pkg-config", "--cflags-only-I", pkg}) or ""
         for dir in cflags:gmatch("%-I([^%s]+)") do
            if file_exists(dir .. "/lua.h") then
               includes = dir
               break
            end
         end
      end
      if includes and file_exists(includes .. "/lua.h") then
         local flags = capture({"pkg-config", "--libs-only-l", pkg})
         local library = flags and flags:match("%-l(lua[%w.%-]*)")
         if library then
            return includes, capture({"pkg-config", "--variable=libdir", pkg}), library
         end
      end
   end
end

local function find_lua(args: Args, cc: string): string, string
   local library, include = args.pack_liblua, args.pack_lua_include
   local version = args.pack_lua_version
   local static = not args.pack_no_static
   if library then
      if not file_exists(library) then fail("Lua library not found: " .. library) end
      if static ~= (library:match("%.a$") ~= nil) then
         fail(static and "--static needs a Lua archive (.a)" or "--no-static needs a shared Lua library")
      end
      local beside = directory(library)
      if not include and file_exists(beside .. "/lua.h") then include = beside end
      if not version then
         version = library:match("luajit") or library:match("lua%-?(5%.%d)")
      end
   end
   if not library or not include then
      local headers, libdir, libname = pkg_config(version)
      include = include or headers
      if not library and libname then
         for _, ext in ipairs(static and {".a"} or {".so", ".dylib"}) do
            local name = "lib" .. libname .. ext
            local path = libdir and libdir .. "/" .. name
            library = path and file_exists(path) and path or cc_library(cc, name)
            if library then break end
         end
      end
   end
   if not library then fail("Lua library not found. Install Lua development files or use --liblua.") end
   if not include or not file_exists(include .. "/lua.h") then
      fail("Lua headers not found. Use --lua-include with headers that match --liblua.")
   end
   return absolute(include), absolute(library)
end

local function link_settings(args: Args, output: string): Link
   local cc = args.pack_cc or os.getenv("CC") or "cc"
   local include, lua = find_lua(args, cc)
   protect_input(output, lua)
   local libraries = {lua}
   if args.pack_no_static then
      local dir = directory(lua)
      for _, flag in ipairs({"-Xlinker", "-rpath", "-Xlinker", dir}) do
         table.insert(libraries, flag)
      end
   end
   if args.pack_compress then
      local zlib = cc_library(cc, "libz.a")
      if not zlib then fail("--compress-source needs zlib headers and the static libz.a archive") end
      protect_input(output, zlib)
      table.insert(libraries, absolute(zlib))
   end
   table.insert(libraries, "-lm")
   table.insert(libraries, "-ldl")
   for _, flag in ipairs(args.pack_link_args) do table.insert(libraries, flag) end
   return {cc = cc, include = include, libraries = libraries, compress = args.pack_compress}
end

local function compile(link: Link, source: string, output: string, archives?: {string})
   local argv = {link.cc, "-std=c99", "-Os", "-I", link.include, "-o", output, source}
   if link.compress then table.insert(argv, "-DTL_PACK_COMPRESSED") end
   for _, archive in ipairs(archives or {}) do table.insert(argv, archive) end
   for _, flag in ipairs(link.libraries) do table.insert(argv, flag) end
   exec(argv, "C compilation or linking")
end

local function literal_requires(chunk: Chunk): {string}
   local tokens = lexer.lex(chunk.code, chunk.filename)
   local names: {string} = {}
   for i, token in ipairs(tokens) do
      local previous = tokens[i - 1]
      if token.kind == "identifier" and token.tk == "require" and
            (not previous or (previous.tk ~= "." and previous.tk ~= ":")) then
         local argument = tokens[i + 1]
         if argument and argument.tk == "(" and tokens[i + 3] and tokens[i + 3].tk == ")" then
            argument = tokens[i + 2]
         end
         if argument and argument.kind == "string" then
            -- Evaluate a single lexer-validated literal to decode Lua escapes.
            local decode = load("return " .. argument.tk, "=(module name)")
            if decode then table.insert(names, decode() as string) end
         end
      end
   end
   return names
end

local function collect(tlconfig: TlConfig, entry: string, modules: {string}, available: {string:boolean}): {Chunk}
   package.path = directory(entry) .. "/?.lua;" .. directory(entry) .. "/?/init.lua;" .. package.path
   local compiler = driver.setup_compiler(tlconfig)
   local chunks: {Chunk} = {}

   local function add(filename: string, name?: string)
      local code: string
      if filename:match("%.tl$") then
         local checked = compiler:recall(filename)
         if not checked then
            local input, err = compiler:open(filename)
            if not input then fail(err) end
            checked = input:check(name)
         end
         code = checked:gen()
         if not code then
            report.report_all_errors(tlconfig, compiler)
            fail("could not generate " .. filename)
         end
      else
         code = read(filename)
         if code:byte(1) == 27 then fail("expected Lua source in " .. filename) end
      end
      table.insert(chunks, {name = name, filename = filename, code = code:gsub("^#![^\n]*", "")})
   end

   local function add_module(name: string)
      if available[name] then return end
      if name:find("%z") then fail("NUL byte in module name") end
      local filename = teal.search_module(name, {[".tl"] = true, [".lua"] = true})
      if not filename then
         fail("cannot find source for module " .. string.format("%q", name) .. " (use --native for C modules)")
      end
      available[name] = true
      add(filename, name)
   end

   add(entry)
   for _, name in ipairs(modules) do add_module(name) end
   local i = 1
   while chunks[i] do
      for _, name in ipairs(literal_requires(chunks[i])) do add_module(name) end
      i = i + 1
   end
   local ok = report.report_all_errors(tlconfig, compiler)
   if not ok then fail("type check failed") end
   return chunks
end

local function c_string(value: string): string
   return '"' .. value:gsub(".", function(byte: string): string
      return string.format("\\%03o", byte:byte())
   end) .. '"'
end

local function encode(dir: string, chunks: {Chunk}, precompile: boolean, natives: {string:string})
   local file = assert(io.open(dir .. "/main.c", "wb"))
   local ok, err = pcall(function()
      assert(file:write(native.headers, native.launcher))
      local registrations: {string} = {}
      for _, name in ipairs(common.keys(natives)) do
         local symbol = "luaopen_" .. name:gsub("%.", "_")
         assert(file:write("extern int " .. symbol .. "(lua_State *L);\n"))
         table.insert(registrations, "lua_pushcfunction(L, " .. symbol .. "); lua_setfield(L, -2, " .. c_string(name) .. ");\n")
      end
      for i, chunk in ipairs(chunks) do
         local input, output = dir .. "/chunk.lua", dir .. "/chunk.bin"
         local label = "@" .. chunk.filename
         write(input, chunk.code)
         exec({dir .. "/encode", input, output, label, precompile and "1" or "0"}, "encoding " .. chunk.filename)
         local payload = read(output)
         local length, start = payload:match("^(%d+)\n()")
         local bytes = payload:sub(start)
         local data = bytes:gsub(".", function(byte: string): string
            return string.format("%3d,", byte:byte())
         end):gsub(("."):rep(76), "%0\n")
         assert(file:write("static const unsigned char data_", tostring(i), "[] = {\n", data, "0};\n"))
         assert(file:write(string.format("static const struct chunk chunk_%d = {data_%d, %d, %s, %s};\n",
            i, i, #bytes, length, c_string(label))))
         if chunk.name then
            table.insert(registrations, string.format("preload(L, %s, &chunk_%d);\n", c_string(chunk.name), i))
         end
      end
      assert(file:write("static void register_modules(lua_State *L) {\n", table.concat(registrations), "}\n", native.main))
   end)
   local closed, close_err = file:close()
   if not ok then error(err, 0) end
   assert(closed, close_err)
end

local function default_entry(tlconfig: TlConfig): string
   local dir = tlconfig.source_dir or "."
   for _, name in ipairs({"main.tl", "main.lua"}) do
      local path = dir .. "/" .. name
      if file_exists(path) then return path end
   end
   fail("no main.tl or main.lua found. Specify the entry script.")
end

local function set_target(tlconfig: TlConfig, version: string)
   tlconfig.gen_target = tlconfig.gen_target or ((version == "luajit" or version == "5.2") and "5.1" or version)
   tlconfig.gen_compat = tlconfig.gen_compat or "off"
end

--- Build an executable from a Teal or Lua entry script. Include the modules
--- that literal `require` calls load. Use `--module` for a name that the
--- program calculates. The executable starts with empty Lua search paths.
---
--- Build on a POSIX host with Lua development files. Use a C compiler that
--- builds executables the host can run. The command uses `pkg-config` to
--- find Lua by default. Use `--liblua` and `--lua-include` to set the paths.
--- You can omit `--lua-include` if `lua.h` is next to the library.
---
--- The command links Lua statically by default. It uses the selected Lua
--- library to compile the code to bytecode. Use `--no-static` for shared
--- Lua or `--no-precompile` for Lua source. `--compress-source` uses zlib
--- to compress the embedded source or bytecode.
---
--- ```sh
--- tl pack app/main.tl --liblua=/path/to/liblua.a --compress-source -o my-program
--- ```
---
--- If the entry is absent, look for `main.tl` and then `main.lua`. Look in
--- `source_dir` or the current directory. The command adds the entry
--- directory to the module search paths. Use `-I` or `include_dir` to add
--- other directories.
---
--- Use `--native MODULE=ARCHIVE` for a C module built for the same Lua ABI.
--- For example, `--native lfs=/path/to/lfs.a` registers `luaopen_lfs`. A dot
--- in the module name becomes an underscore in the loader name. Repeat
--- `--link-arg` for link dependencies. Supply data files separately.
--- @param tlconfig Compiler configuration.
--- @param args Build options from the command line.
local function pack(tlconfig: TlConfig, args: Args)
   if common.sep ~= "/" then common.die("tl pack needs a POSIX build host") end
   if (args.pack_static and args.pack_no_static) or (args.pack_precompile and args.pack_no_precompile) then
      common.die("tl pack: conflicting build options")
   end
   local dir: string
   local ok, err = pcall(function()
      local entry = args.entry or default_entry(tlconfig)
      if not entry:match("%.lua$") and (not entry:match("%.tl$") or entry:match("%.d%.tl$")) then
         fail("entry script must be a .tl or .lua file")
      end
      local output = args.output or (entry:match("[^/]+$"):gsub("%.[^.]+$", ""))
      protect_input(output, entry)
      local available: {string:boolean} = {}
      local natives: {string:string} = {}
      for _, spec in ipairs(args.pack_native) do
         local name, archive = spec:match("^([%a_][%w_.]*)=(.+%.a)$")
         if not name or not file_exists(archive) then
            fail("--native expects MODULE=ARCHIVE with an existing .a file: " .. spec)
         end
         if natives[name] then fail("duplicate native module " .. name) end
         protect_input(output, archive)
         natives[name], available[name] = absolute(archive), true
      end
      if tlconfig.pretend then
         set_target(tlconfig, args.pack_lua_version or "5.4")
         for _, name in ipairs({"_G", "package", "coroutine", "table", "io", "os", "string", "math", "debug", "utf8", "bit", "bit32", "ffi", "jit"}) do
            available[name] = true
         end
         collect(tlconfig, entry, args.pack_modules, available)
         print("Would write: " .. output)
         return
      end
      local link = link_settings(args, output)
      local tmp = os.tmpname()
      os.remove(tmp)
      local work = directory(absolute(output)) .. "/.tl-pack-" .. assert(tmp:match("[^/]+$"))
      exec({"mkdir", "-m", "700", work}, "creating a temporary build directory")
      dir = work
      write(dir .. "/encode.c", native.headers .. native.encoder)
      compile(link, dir .. "/encode.c", dir .. "/encode")
      local probe = dir .. "/runtime.txt"
      exec({dir .. "/encode"}, "checking selected Lua runtime", probe)
      local version: string
      for line in read(probe):gmatch("[^\n]+") do
         if not version then version = line else available[line] = true end
      end
      assert(version, "could not detect linked Lua version")
      if args.pack_lua_version and args.pack_lua_version ~= version then
         fail("linked Lua is " .. version .. ", expected " .. args.pack_lua_version)
      end
      set_target(tlconfig, version)
      local chunks = collect(tlconfig, entry, args.pack_modules, available)
      for _, chunk in ipairs(chunks) do protect_input(output, chunk.filename) end
      encode(dir, chunks, not args.pack_no_precompile, natives)
      local archives: {string} = {}
      for _, name in ipairs(common.keys(natives)) do table.insert(archives, natives[name]) end
      compile(link, dir .. "/main.c", dir .. "/program", archives)
      assert(os.rename(dir .. "/program", output))
      if not tlconfig.quiet then print("Wrote: " .. output) end
   end)
   if dir then
      for name in lfs.dir(dir) do
         if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
      end
      lfs.rmdir(dir)
   end
   if not ok then common.die(tostring(err)) end
end

return pack
