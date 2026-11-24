#!/usr/bin/env bash
set -e

# Build the stand-alone Teal compiler with LuaJIT.
# Use the MinGW toolchain and --windows to build a Windows executable.

luajit_revision="96f7b297326e9fd454b7186c6858b2773f94a0dc"
compat53_version="0.15.1"
argparse_version="0.7.1"
luafilesystem_version="1.8.0"
export executable="tl"

export MAKE="${MAKE:-make}"
export CC="${CC:-gcc}"
export AR="${AR:-ar}"
export NM="${NM:-nm}"
export STRIP="${STRIP:-strip}"
LUA="${LUA:-luajit}"
target_sys="$(uname -s)"
host_cc="${HOST_CC:-${CC}}"
cross_prefix=""
MYCFLAGS=("-Os" "-rdynamic" "-ldl" "-lpthread" "-lm")

sourcedir="$(pwd)"
root="$(pwd)/_binary"
deps_name="deps"

# Let's parse any command line arguments

what_to_do="build"
while [ "$1" ]
do
   case "$1" in
   --windows)
      export CC=x86_64-w64-mingw32-gcc
      export NM=x86_64-w64-mingw32-nm
      export AR=x86_64-w64-mingw32-ar
      export STRIP=x86_64-w64-mingw32-strip
      target_sys="Windows"
      cross_prefix="x86_64-w64-mingw32-"
      MYCFLAGS=("-Os" "-lm")
      deps_name="deps-windows"
      executable="tl.exe"
      ;;
   --sourcedir=*)
      sourcedir="${1#--sourcedir=}"
      ;;
   --sourcedir)
      shift
      sourcedir="$1"
      ;;
   --targetdir=*)
      root="${1#--targetdir=}"
      ;;
   --targetdir)
      shift
      root="$1"
      ;;
   --clean)
      do_clean=1
      ;;
   --help)
      what_to_do="help"
      ;;
   esac
   shift
done

if [ "$what_to_do" = "help" ]
then
   echo ""
   echo "Usage: $0 [--windows] [--sourcedir=<DIR>] [--targetdir=<DIR>]"
   echo ""
   echo "   --windows          Cross-build for Windows (requires w64-mingw32 toolchain)"
   echo "   --sourcedir=<DIR>  Location of Teal sources root"
   echo "                      * root dir..........: $sourcedir"
   echo "   --targetdir=<DIR>  Target location root"
   echo "                      * root dir..........: $root"
   echo "                      * output binary.....: $root/build/$executable"
   echo ""
   exit 0
fi

# Let's check our build dependencies.

[ -e "${sourcedir}/tl.lua" ] || {
   echo "Could not find ${sourcedir}/tl.lua -- you might want to use the --sourcedir flag"
   exit 1
}
sourcedir="$(cd "$sourcedir" && pwd)"

curl -h &> /dev/null || {
   echo "You need curl installed."
   exit 1
}

${CC} --version &> /dev/null || {
   echo "You need ${CC} installed."
   exit 1
}

${MAKE} --version &> /dev/null || {
   echo "You need ${MAKE} installed."
   exit 1
}

${LUA} -v &> /dev/null || {
   echo "You need ${LUA} installed."
   exit 1
}

mkdir -p "$root"
root="$(cd "$root" && pwd)"
depsdir="${root}/${deps_name}"

if [ "$do_clean" = 1 ]
then
   rm -rf "${depsdir}"
fi

rm -rf "${root}/src"

# Let's prepare the environment

mkdir -p "${root}/downloads"
mkdir -p "${depsdir}"
mkdir -p "${root}/src"
mkdir -p "${root}/build"

# Let's download our dependencies

function download() {
   url="$1"
   output="${2:-$(basename "$url")}"
   [ -e "$output" ] && return
   echo "Downloading $url ..."
   curl --fail --progress-bar --output "$output" --location "$url"
}

(
   cd "${root}/downloads"
   download "https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/${luajit_revision}" "luajit-${luajit_revision}.tar.gz"
   download "https://codeload.github.com/lunarmodules/lua-compat-5.3/tar.gz/v${compat53_version}" "compat53-${compat53_version}.tar.gz"
   download "https://github.com/luarocks/argparse/archive/${argparse_version}.tar.gz" "argparse-${argparse_version}.tar.gz"
   download "https://github.com/keplerproject/luafilesystem/archive/v${luafilesystem_version//./_}.tar.gz" "luafilesystem-${luafilesystem_version}.tar.gz"
)

# Let's extract our dependencies

(
   cd "${depsdir}"
   tar zxpf "../downloads/luajit-${luajit_revision}.tar.gz"
   tar zxpf "../downloads/compat53-${compat53_version}.tar.gz"
   tar zxpf "../downloads/argparse-${argparse_version}.tar.gz"
   tar zxpf "../downloads/luafilesystem-${luafilesystem_version}.tar.gz"
   [ -e "luafilesystem-$luafilesystem_version" ] || mv "luafilesystem-${luafilesystem_version//./_}" "luafilesystem-$luafilesystem_version"
)

# Let's build our dependencies:

function check() {
   [ -e "$1" ] || {
      echo "Failed building $1. :("
      exit 1
   }
}

function build_dep() {
   at="$1"
   target="$2"
   builder="$3"

   cd "$at"
   [ -e "$target" ] && return

   set -x
   "$builder"
   set +x

   check "$target"
}

function lua_builder() (
   "${MAKE}" -C src BUILDMODE=static TARGET_SYS="$target_sys" \
      HOST_CC="$host_cc" STATIC_CC="$CC" TARGET_STRIP="$STRIP" \
      TARGET_AR="$AR rcs" CROSS="$cross_prefix" libluajit.a
)

LUAJIT_SRC="${depsdir}/LuaJIT-${luajit_revision}/src"
build_dep "${LUAJIT_SRC}/.." "src/libluajit.a" lua_builder

function lfs_builder() {
   "${CC}" -c -o "lfs.o" -I "$LUAJIT_SRC" "src/lfs.c"
   "${AR}" rcs "lfs.a" "lfs.o"
}

function compat53_builder() {
   local lib
   for lib in liolib lstrlib ltablib lutf8lib; do
      "$CC" -O2 -c -I "$LUAJIT_SRC" -o "$lib.o" "$lib.c"
   done
   "$AR" rcs compat53.a liolib.o lstrlib.o ltablib.o lutf8lib.o
}

build_dep "${depsdir}/luafilesystem-${luafilesystem_version}" "lfs.a" lfs_builder
build_dep "${depsdir}/lua-compat-5.3-${compat53_version}" "compat53.a" compat53_builder

build_dep "${depsdir}/argparse-${argparse_version}" "src/argparse.lua" true

LIBLUA_A="${LUAJIT_SRC}/libluajit.a"
LFS_A="${depsdir}/luafilesystem-${luafilesystem_version}/lfs.a"
ARGPARSE_LUA="${depsdir}/argparse-${argparse_version}/src/argparse.lua"
COMPAT53="${depsdir}/lua-compat-5.3-${compat53_version}"

# Let's prepare our sources

cat <<EOF > "${root}/src/gen.lua"

local NM = os.getenv("NM") or "nm"

local c_preamble = [[

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

/* portable alerts, from srlua */
#ifdef _WIN32
#include <windows.h>
#define alert(message)  MessageBox(NULL, message, progname, MB_ICONERROR | MB_OK)
#define getprogname()   char name[MAX_PATH]; argv[0]= GetModuleFileName(NULL,name,sizeof(name)) ? name : NULL;
#else
#define alert(message)  fprintf(stderr,"%s: %s\n", progname, message)
#define getprogname()
#endif

static int registry_key;

/* fatal error, from srlua */
static void fatal(const char* message) {
   alert(message);
   exit(EXIT_FAILURE);
}

]]

local c_main = [[

/* custom package loader */
static int pkg_loader(lua_State* L) {
   lua_pushlightuserdata(L, (void*) &registry_key); /* modname ? registry_key */
   lua_rawget(L, LUA_REGISTRYINDEX);                /* modname ? modules */
   lua_pushvalue(L, -1);                            /* modname ? modules modules */
   lua_pushvalue(L, 1);                             /* modname ? modules modules modname */
   lua_gettable(L, -2);                             /* modname ? modules mod */
   if (lua_type(L, -1) == LUA_TNIL) {
      lua_pop(L, 1);                                /* modname ? modules */
      lua_pushvalue(L, 1);                          /* modname ? modules modname */
      lua_pushliteral(L, ".init");                  /* modname ? modules modname ".init" */
      lua_concat(L, 2);                             /* modname ? modules modname..".init" */
      lua_gettable(L, -2);                          /* modname ? mod */
   }
   return 1;
}

static void install_pkg_loader(lua_State* L) {
   lua_settop(L, 0);                                /* */
   lua_getglobal(L, "table");                       /* table */
   lua_getfield(L, -1, "insert");                   /* table table.insert */
   lua_getglobal(L, "package");                     /* table table.insert package */
   lua_getfield(L, -1, "searchers");                /* table table.insert package package.searchers */
   if (lua_type(L, -1) == LUA_TNIL) {
      lua_pop(L, 1);
      lua_getfield(L, -1, "loaders");               /* table table.insert package package.loaders */
   }
   lua_copy(L, 4, 3);                               /* table table.insert package.searchers */
   lua_settop(L, 3);                                /* table table.insert package.searchers */
   lua_pushnumber(L, 1);                            /* table table.insert package.searchers 1 */
   lua_pushcfunction(L, pkg_loader);                /* table table.insert package.searchers 1 pkg_loader */
   lua_call(L, 3, 0);                               /* table */
   lua_settop(L, 0);                                /* */
}

/* main script launcher, from srlua */
static int pmain(lua_State *L) {
   int argc = lua_tointeger(L, 1);
   char** argv = lua_touserdata(L, 2);
   int i;
   load_main(L);
   lua_createtable(L, argc, 0);
   for (i = 0; i < argc; i++) {
      lua_pushstring(L, argv[i]);
      lua_rawseti(L, -2, i);
   }
   lua_setglobal(L, "arg");
   luaL_checkstack(L, argc - 1, "too many arguments to script");
   for (i = 1; i < argc; i++) {
      lua_pushstring(L, argv[i]);
   }
   lua_call(L, argc - 1, 0);
   return 0;
}

/* error handler, from luac */
static int msghandler (lua_State *L) {
   /* is error object not a string? */
   const char *msg = lua_tostring(L, 1);
   if (msg == NULL) {
      /* does it have a metamethod that produces a string */
      if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
         /* then that is the message */
         return 1;
      } else {
         msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
      }
   }
   /* append a standard traceback */
   luaL_traceback(L, L, msg, 1);
   return 1;
}

/* main function, from srlua */
int main(int argc, char** argv) {
   lua_State* L;
   getprogname();
   if (argv[0] == NULL) {
      fatal("cannot locate this executable");
   }
   L = luaL_newstate();
   if (L == NULL) {
      fatal("not enough memory for state");
   }
   luaL_openlibs(L);
   install_pkg_loader(L);
   declare_libraries(L);
   declare_modules(L);
   lua_pushcfunction(L, &msghandler);
   lua_pushcfunction(L, &pmain);
   lua_pushinteger(L, argc);
   lua_pushlightuserdata(L, argv);
   if (lua_pcall(L, 2, 0, -4) != 0) {
      fatal(lua_tostring(L, -1));
   }
   lua_close(L);
   return EXIT_SUCCESS;
}

]]

local function reindent_c(input)
   local out = {}
   local indent = 0
   local previous_is_blank = true
   for line in input:gmatch("([^\n]*)") do
      line = line:match("^[ \t]*(.-)[ \t]*$")

      local is_blank = (#line == 0)
      local do_print =
         (not is_blank) or
         (not previous_is_blank and indent == 0)

      if line:match("^[})]") then
         indent = indent - 1
         if indent < 0 then indent = 0 end
      end
      if do_print then
         table.insert(out, string.rep("   ", indent))
         table.insert(out, line)
         table.insert(out, "\n")
      end
      if line:match("[{(]$") then
         indent = indent + 1
      end

      previous_is_blank = is_blank
   end
   return table.concat(out)
end

local hexdump
do
   local numtab = {}
   for i = 0, 255 do
     numtab[string.char(i)] = ("%-3d,"):format(i)
   end
   function hexdump(str)
      return (str:gsub(".", numtab):gsub(("."):rep(80), "%0\n"))
   end
end

local function bin2c_file(out, filename)
   local fd = io.open(filename, "rb")
   local content = fd:read("*a"):gsub("^#![^\n]+\n", "")
   fd:close()
   table.insert(out, ("static const unsigned char code[] = {"))
   table.insert(out, hexdump(content))
   table.insert(out, ("};"))
end

local function load_main(out, main_program, program_name)
   table.insert(out, [[static void load_main(lua_State* L) {]])
   bin2c_file(out, main_program)
   table.insert(out, ("if(luaL_loadbuffer(L, code, sizeof(code), %q) != LUA_OK) {"):format(program_name))
   table.insert(out, ("   fatal(lua_tostring(L, -1));"))
   table.insert(out, ("}"))
   table.insert(out, [[}]])
   table.insert(out, [[]])
end

local function is_dir(filename)
   local ret, x, y = os.execute("test -d '" .. filename .. "'")
   return ret == true or ret == 0
end

local function find_all(dirname, pattern)
   local pd = io.popen("find '" .. dirname .. "' -name '" .. pattern .. "'")
   return pd:lines()
end

local function process_lua_file(out, basename, filename)
   local name = filename
   if filename:sub(1, #basename + 1) == basename .. "/" then
      name = filename:sub(#basename + 2)
   end
   local modname = name:gsub("%.lua$", ""):gsub("/", ".")
   table.insert(out, ("/* %s */"):format(modname))
   table.insert(out, ("{"))
   bin2c_file(out, filename)
   table.insert(out, ("luaL_loadbuffer(L, code, sizeof(code), %q);"):format(filename))
   table.insert(out, ("lua_setfield(L, 1, %q);"):format(modname))
   table.insert(out, ("}"))
end

local function declare_modules(out, basename, files)
   table.insert(out, [[
   static void declare_modules(lua_State* L) {
      lua_settop(L, 0);                                /* */
      lua_newtable(L);                                 /* modules */
      lua_pushlightuserdata(L, (void*) &registry_key); /* modules registry_key */
      lua_pushvalue(L, 1);                             /* modules registry_key modules */
      lua_rawset(L, LUA_REGISTRYINDEX);                /* modules */
   ]])
   for _, filename in ipairs(files) do
      if filename:match("%.lua$") then
         process_lua_file(out, basename, filename)
      elseif is_dir(filename) then
         for file in find_all(filename, "*.lua") do
            process_lua_file(out, basename, file)
         end
      end
   end
   table.insert(out, [[
      lua_settop(L, 0);                                /* */
   }
   ]])
end

local function nm(filename)
   local pd = io.popen(NM .. " " .. filename)
   local out = pd:read("*a")
   pd:close()
   return out
end

local function declare_libraries(out, files)
   local a_files = {}
   local externs = {}
   local fn = {}
   table.insert(fn, [[
   static void declare_libraries(lua_State* L) {
      lua_getglobal(L, "package");                     /* package */
      lua_getfield(L, -1, "preload");                  /* package package.preload */
   ]])
   for _, filename in ipairs(files) do
      if filename:match("%.a$") then
         table.insert(a_files, filename)
         local nmout = nm(filename)
         for luaopen in nmout:gmatch("[^dD] _?(luaopen_[%a%p%d]+)") do

            -- FIXME what about module names with underscores?
            local modname = luaopen:gsub("^_?luaopen_", ""):gsub("_", ".")

            table.insert(externs, "extern int " .. luaopen .. "(lua_State* L);")
            table.insert(fn, "lua_pushcfunction(L, " .. luaopen .. ");")
            table.insert(fn, "lua_setfield(L, -2, \"" .. modname .. "\");")
         end
      end
   end
   table.insert(fn, [[
      lua_settop(L, 0);                                /* */
   }
   ]])

   table.insert(out, "\n")
   for _, line in ipairs(externs) do
      table.insert(out, line)
   end
   table.insert(out, "\n")
   for _, line in ipairs(fn) do
      table.insert(out, line)
   end
   table.insert(out, "\n")

   return a_files
end

-- main:

local c_program = arg[1]
local lua_program = arg[2]
local basename = arg[3]
for i = 1, 3 do table.remove(arg, 1) end
local modules = arg

local program_name = lua_program:gsub(".*/", "")

local out = {}
table.insert(out, ([[static const char* progname = %q;]]):format(program_name))
table.insert(out, c_preamble)
load_main(out, lua_program, program_name)
declare_modules(out, basename, modules)
declare_libraries(out, modules)
table.insert(out, c_main)

local fd = io.open(c_program, "w")
fd:write(reindent_c(table.concat(out, "\n")))
fd:close()

EOF

# Copy our program sources to src/...

(
   find "${sourcedir}/teal" -name "*.lua"
   find "${sourcedir}/tlcli" -name "*.lua"
) | while read -r file
do
   fromroot="${file#"${sourcedir}"/}"
   newdir="${root}/src/$(dirname "${fromroot}")"
   [ -d "$newdir" ] || mkdir -p "${newdir}"
   cp "$file" "${newdir}"
done

# Copy our dependency Lua sources to src/ ...

cp "${ARGPARSE_LUA}" "${root}/src/"
cp -R "${COMPAT53}/compat53" "${root}/src/"

# Run the generator passing the output file, main Lua script, base Lua source dir, Lua source files and static libraries

${LUA} "${root}/src/gen.lua" \
   "${root}/src/tl.c" \
   "${sourcedir}/tl" \
   "${root}/src" \
   "${root}/src/teal" \
   "${root}/src/tlcli" \
   "${root}/src/argparse.lua" \
   "${root}/src/compat53" \
   "${COMPAT53}/compat53.a" \
   "${LFS_A}"

check "${root}/src/tl.c"

# Now let's compile!!!

exe_pathname="${root}/build/${executable}"

set -x
${CC} -o "$exe_pathname" -I"${LUAJIT_SRC}" "${root}/src/tl.c" "${LFS_A}" "${COMPAT53}/compat53.a" "${LIBLUA_A}" "${MYCFLAGS[@]}"
${STRIP} "$exe_pathname"
set +x

check "$exe_pathname"

echo
echo "$exe_pathname is now built!"
echo
