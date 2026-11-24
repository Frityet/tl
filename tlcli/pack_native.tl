-- C sources for the build-time encoder and the standalone launcher.

local record Native
   headers: string
   encoder: string
   launcher: string
   main: string
end

Native.headers = [[
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#ifdef TL_PACK_COMPRESSED
#include <zlib.h>
#endif
]]

Native.encoder = [[
static int fail(const char *message) {
   fprintf(stderr, "tl pack: %s\n", message ? message : "Lua error");
   return 1;
}

static int dump_bytes(lua_State *L, const void *data, size_t size, void *out) {
   (void)L;
   return fwrite(data, 1, size, out) != size;
}

static unsigned char *read_file(FILE *file, size_t *size) {
   long length;
   if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0 ||
       fseek(file, 0, SEEK_SET) != 0) return NULL;
   *size = (size_t)length;
   unsigned char *data = malloc(*size ? *size : 1);
   if (data && fread(data, 1, *size, file) != *size) {
      free(data);
      return NULL;
   }
   return data;
}

static void print_modules(lua_State *L, const char *field) {
   lua_getfield(L, -1, field);
   lua_pushnil(L);
   while (lua_next(L, -2)) {
      if (lua_type(L, -2) == LUA_TSTRING) puts(lua_tostring(L, -2));
      lua_pop(L, 1);
   }
   lua_pop(L, 1);
}

int main(int argc, char **argv) {
   lua_State *L = luaL_newstate();
   if (!L) return fail("cannot create Lua state");
   luaL_openlibs(L);
   lua_getglobal(L, "_VERSION");
   const char *version = lua_tostring(L, -1);
   if (!version || strcmp(version, LUA_VERSION))
      return fail("Lua headers and library are from different versions");
   if (argc == 1) {
      lua_getglobal(L, "jit");
      puts(lua_istable(L, -1) ? "luajit" : version + 4);
      lua_getglobal(L, "package");
      print_modules(L, "loaded");
      print_modules(L, "preload");
      lua_close(L);
      return 0;
   }
   if (argc != 5) return fail("invalid encoder arguments");

   FILE *file = fopen(argv[1], "rb");
   if (!file) return fail("cannot open input chunk");
   size_t size;
   unsigned char *data = read_file(file, &size);
   fclose(file);
   if (!data) return fail("cannot read input chunk");
   if (luaL_loadbuffer(L, (const char *)data, size, argv[3]) != 0)
      return fail(lua_tostring(L, -1));
   if (argv[4][0] == '1') {
      file = tmpfile();
      if (!file) return fail("cannot open bytecode temporary file");
#if LUA_VERSION_NUM >= 503
      int status = lua_dump(L, dump_bytes, file, 0);
#else
      int status = lua_dump(L, dump_bytes, file);
#endif
      if (status || fflush(file)) return fail("cannot write bytecode");
      free(data);
      data = read_file(file, &size);
      fclose(file);
      if (!data) return fail("cannot read bytecode");
   }
   size_t raw_size = size;
#ifdef TL_PACK_COMPRESSED
   if (size > ULONG_MAX) return fail("chunk is too large to compress");
   uLongf capacity = compressBound((uLong)size);
   unsigned char *compressed = malloc(capacity);
   if (!compressed || compress2(compressed, &capacity, data, (uLong)size, Z_BEST_COMPRESSION) != Z_OK)
      return fail("cannot compress chunk");
   free(data);
   data = compressed;
   size = capacity;
#endif
   file = fopen(argv[2], "wb");
   if (!file) return fail("cannot open encoded chunk");
   if (fprintf(file, "%zu\n", raw_size) < 0 ||
       fwrite(data, 1, size, file) != size || fclose(file))
      return fail("cannot write encoded chunk");
   free(data);
   lua_close(L);
   return 0;
}
]]

Native.launcher = [[
struct chunk {
   const unsigned char *data;
   size_t size;
   size_t raw_size;
   const char *filename;
};

static void load_chunk(lua_State *L, const struct chunk *chunk) {
#ifdef TL_PACK_COMPRESSED
   uLongf size = chunk->raw_size ? chunk->raw_size : 1;
   unsigned char *data = malloc(size);
   if (!data) luaL_error(L, "out of memory loading %s", chunk->filename);
   if (uncompress(data, &size, chunk->data, chunk->size) != Z_OK || size != chunk->raw_size) {
      free(data);
      luaL_error(L, "invalid compressed chunk %s", chunk->filename);
   }
   int status = luaL_loadbuffer(L, (const char *)data, size, chunk->filename);
   free(data);
#else
   int status = luaL_loadbuffer(L, (const char *)chunk->data, chunk->size, chunk->filename);
#endif
   if (status) lua_error(L);
}

static int load_module(lua_State *L) {
   const struct chunk *chunk = lua_touserdata(L, lua_upvalueindex(1));
   int argc = lua_gettop(L);
   load_chunk(L, chunk);
   lua_insert(L, 1);
   lua_call(L, argc, LUA_MULTRET);
   return lua_gettop(L);
}

static void preload(lua_State *L, const char *name, const struct chunk *chunk) {
   lua_pushlightuserdata(L, (void *)chunk);
   lua_pushcclosure(L, load_module, 1);
   lua_setfield(L, -2, name);
}

/* Generated chunks and module registrations follow this code. */
]]

Native.main = [[
static int run(lua_State *L) {
   int argc = (int)lua_tointeger(L, 1);
   char **argv = lua_touserdata(L, 2);
   luaL_openlibs(L);
   lua_getglobal(L, "package");
   lua_pushliteral(L, "");
   lua_setfield(L, -2, "path");
   lua_pushliteral(L, "");
   lua_setfield(L, -2, "cpath");
   lua_getfield(L, -1, "preload");
   register_modules(L);
   lua_pop(L, 2);
   lua_createtable(L, argc - 1, 1);
   for (int i = 0; i < argc; i++) {
      lua_pushstring(L, argv[i]);
      lua_rawseti(L, -2, i);
   }
   lua_setglobal(L, "arg");
   luaL_checkstack(L, argc, "too many program arguments");
   load_chunk(L, &chunk_1);
   for (int i = 1; i < argc; i++) lua_pushstring(L, argv[i]);
   lua_call(L, argc - 1, 0);
   return 0;
}

static int traceback(lua_State *L) {
#if LUA_VERSION_NUM >= 502
   const char *message = lua_tostring(L, 1);
   luaL_traceback(L, L, message ? message : "Lua error", 1);
   return 1;
#else
   lua_getglobal(L, "debug");
   if (!lua_istable(L, -1)) return 1;
   lua_getfield(L, -1, "traceback");
   if (!lua_isfunction(L, -1)) {
      lua_settop(L, 1);
      return 1;
   }
   lua_pushvalue(L, 1);
   lua_pushinteger(L, 2);
   lua_call(L, 2, 1);
   return 1;
#endif
}

int main(int argc, char **argv) {
   lua_State *L = luaL_newstate();
   if (!L) {
      fputs("cannot create Lua state\n", stderr);
      return 1;
   }
   lua_pushcfunction(L, traceback);
   lua_pushcfunction(L, run);
   lua_pushinteger(L, argc);
   lua_pushlightuserdata(L, argv);
   int status = lua_pcall(L, 2, 0, 1);
   if (status) {
      const char *message = lua_tostring(L, -1);
      fprintf(stderr, "%s\n", message ? message : "Lua error");
   }
   lua_close(L);
   return status ? 1 : 0;
}
]]

return Native
