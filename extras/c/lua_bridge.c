#include "tl_runtime.h"

#include <lauxlib.h>
#include <lualib.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* These values never serve as storage for native compiler data. */
typedef struct Script {
   lua_State *main;
   lua_State *active;
   int builtins;
   int root_count;
   int external_only;
   bool closing;
} Script;

typedef struct NativeRef {
   tl_State *native;
   int index;
} NativeRef;

typedef struct ScriptRef {
   int ref;
   bool globals;
} ScriptRef;

typedef struct Imported {
   const void *pointer;
   tl_Value value;
} Imported;

typedef struct ImportMap {
   Imported *entries;
   size_t size;
   size_t capacity;
   const char *error;
} ImportMap;

static int call_script(tl_State *L);
static int native_callback(lua_State *lua);
static int resolve_module(lua_State *lua);

static int absolute_index(lua_State *lua, int i) {
   return i < 0 && i > LUA_REGISTRYINDEX ? lua_gettop(lua) + i + 1 : i;
}

static void drop_reference(tl_State *L, void *data) {
   ScriptRef *ref = data;
   if (ref) {
      Script *script = L->script;
      if (script) luaL_unref(script->main, LUA_REGISTRYINDEX, ref->ref);
      free(ref);
   }
}

static int release_native(lua_State *lua) {
   NativeRef *ref = lua_touserdata(lua, 1);
   tl_State *L = ref->native;
   Script *script = L->script;
   if (!script->closing)
      tl_rawput(L, L->script_roots, tl_numeric(-ref->index), tl_nil);
   return 0;
}

static void export_function(tl_State *L, lua_State *lua, tl_Value value) {
   tl_Function *fn = (tl_Function *)value.as.object;
   if (fn->code == call_script) {
      ScriptRef *ref = fn->data;
      lua_rawgeti(lua, LUA_REGISTRYINDEX, ref->ref);
      return;
   }
   Script *script = L->script;
   if (script->root_count == INT_MAX) luaL_error(lua, "too many native callback references");
   NativeRef *ref = lua_newuserdata(lua, sizeof *ref);
   *ref = (NativeRef){ L, ++script->root_count };
   tl_rawput(L, L->script_roots, tl_numeric(-ref->index), value);
   luaL_getmetatable(lua, "teal.native.callback");
   lua_setmetatable(lua, -2);
   lua_pushcclosure(lua, native_callback, 1);
}

static bool export_builtin(tl_State *L, lua_State *lua, tl_Value value) {
   Script *script = L->script;
   lua_rawgeti(lua, LUA_REGISTRYINDEX, script->builtins);
   lua_pushlightuserdata(lua, value.as.object);
   lua_rawget(lua, -2);
   lua_remove(lua, -2);
   if (!lua_isnil(lua, -1)) return true;
   lua_pop(lua, 1);
   return false;
}

static void push_lua(tl_State *L, lua_State *lua, tl_Value value, int copied, int depth) {
   luaL_checkstack(lua, 12, "marshalling native values");
   switch (value.type) {
      case TL_NIL: lua_pushnil(lua); break;
      case TL_BOOLEAN: lua_pushboolean(lua, value.as.boolean); break;
      case TL_NUMBER: lua_pushnumber(lua, value.as.number); break;
      case TL_STRING:
         lua_pushlstring(lua, value.as.string->bytes, value.as.string->length);
         break;
      case TL_FUNCTION:
      case TL_TABLE: {
         if (export_builtin(L, lua, value)) break;
         lua_pushlightuserdata(lua, value.as.object);
         lua_rawget(lua, copied);
         if (!lua_isnil(lua, -1)) return;
         lua_pop(lua, 1);
         if (depth >= 200) luaL_error(lua, "native value nesting is too deep for Lua");
         if (value.type == TL_FUNCTION) {
            export_function(L, lua, value);
         } else {
            lua_newtable(lua);
         }
         int created = lua_gettop(lua);
         lua_pushlightuserdata(lua, value.as.object);
         lua_pushvalue(lua, created);
         lua_rawset(lua, copied);
         if (value.type == TL_TABLE) {
            tl_Value previous = tl_nil, key, item;
            while (tl_next(L, value, previous, &key, &item)) {
               push_lua(L, lua, key, copied, depth + 1);
               push_lua(L, lua, item, copied, depth + 1);
               lua_rawset(lua, created);
               previous = key;
            }
            if (value.as.table->meta) {
               push_lua(L, lua, tl_object(&value.as.table->meta->header), copied, depth + 1);
               lua_setmetatable(lua, created);
            }
         }
         break;
      }
      case TL_FOREIGN: {
         ScriptRef *ref = ((tl_Foreign *)value.as.object)->data;
         lua_rawgeti(lua, LUA_REGISTRYINDEX, ref->ref);
         break;
      }
      case TL_FILE: {
         FILE *file = ((tl_File *)value.as.object)->file;
         if (file == stdin || file == stdout || file == stderr) {
            lua_getglobal(lua, "io");
            lua_getfield(lua, -1, file == stdin ? "stdin" : file == stdout ? "stdout" : "stderr");
            lua_remove(lua, -2);
         } else {
            lua_pushnil(lua);
         }
         break;
      }
      default: lua_pushnil(lua); break;
   }
}

static tl_Value import_ref(tl_State *L, lua_State *lua, int index, bool func, bool globals) {
   ScriptRef *ref = tl_resize(L, NULL, sizeof *ref);
   lua_pushvalue(lua, index);
   *ref = (ScriptRef){ luaL_ref(lua, LUA_REGISTRYINDEX), globals };
   if (func) {
      tl_pushcfunction(L, call_script);
      tl_Value result = tl_at(L, -1);
      tl_pop(L, 1);
      tl_Function *fn = (tl_Function *)result.as.object;
      fn->data = ref;
      fn->destroy = drop_reference;
      return result;
   }
   tl_Foreign *object = tl_allocate(L, sizeof *object, TL_FOREIGN);
   object->data = ref;
   object->destroy = drop_reference;
   return tl_object(&object->header);
}

static void remember(tl_State *L, ImportMap *map, const void *pointer, tl_Value value) {
   if (map->size == map->capacity) {
      map->capacity = map->capacity ? map->capacity * 2 : 16;
      map->entries = tl_resize(L, map->entries, map->capacity * sizeof *map->entries);
   }
   map->entries[map->size++] = (Imported){ pointer, value };
}

static tl_Value from_lua(tl_State *L, lua_State *lua, int index, ImportMap *map, int depth) {
   int kind = lua_type(lua, index);
   switch (kind) {
      case LUA_TNONE:
      case LUA_TNIL: return tl_nil;
      case LUA_TBOOLEAN: return tl_boolean(lua_toboolean(lua, index));
      case LUA_TNUMBER: return tl_numeric(lua_tonumber(lua, index));
      case LUA_TSTRING: {
         size_t length;
         const char *bytes = lua_tolstring(lua, index, &length);
         return tl_string(L, bytes, length);
      }
      case LUA_TFUNCTION: {
         if (lua_tocfunction(lua, index) == native_callback && lua_getupvalue(lua, index, 1)) {
            NativeRef *ref = lua_touserdata(lua, -1);
            lua_pop(lua, 1);
            return tl_rawget(L->script_roots, tl_numeric(-ref->index));
         }
         /* fall through to keep Lua closures and foreign values by reference */
         break;
      }
      default: break;
   }

   const void *pointer = lua_topointer(lua, index);
   for (size_t i = 0; pointer && i < map->size; ++i) {
      if (map->entries[i].pointer == pointer) return map->entries[i].value;
   }
   if (kind != LUA_TTABLE) {
      tl_Value value = import_ref(L, lua, index, kind == LUA_TFUNCTION, false);
      if (pointer) remember(L, map, pointer, value);
      return value;
   }

   if (depth >= 200 || !lua_checkstack(lua, 8)) {
      map->error = "Lua value nesting is too deep for native C";
      return tl_nil;
   }
   index = absolute_index(lua, index);
   tl_Value table = tl_table(L, lua_objlen(lua, index), 0);
   remember(L, map, pointer, table);
   lua_pushnil(lua);
   while (lua_next(lua, index)) {
      tl_Value key = from_lua(L, lua, -2, map, depth + 1);
      tl_Value value = from_lua(L, lua, -1, map, depth + 1);
      if (map->error) {
         lua_pop(lua, 2);
         return tl_nil;
      }
      tl_rawput(L, table, key, value);
      lua_pop(lua, 1);
   }
   if (lua_getmetatable(lua, index)) {
      tl_Value meta = from_lua(L, lua, -1, map, depth + 1);
      lua_pop(lua, 1);
      if (meta.type == TL_TABLE) table.as.table->meta = meta.as.table;
   }
   return table;
}

typedef struct Export {
   tl_State *native;
   int first;
   int last;
} Export;

static int export_values(lua_State *lua) {
   const Export *request = lua_touserdata(lua, 1);
   int count = request->last >= request->first ? request->last - request->first + 1 : 0;
   luaL_checkstack(lua, count + 12, "Lua arguments");
   lua_newtable(lua);
   for (int i = request->first; i <= request->last; ++i)
      push_lua(request->native, lua, tl_at(request->native, i), 2, 0);
   return count;
}

/* Keep errors raised by Lua's allocator on the Lua stack until native
   temporaries and the active-callback pointer have been restored. */
static int export_arguments(tl_State *L, lua_State *lua, int first, int last) {
   Export request = { L, first, last };
   lua_pushcfunction(lua, export_values);
   lua_pushlightuserdata(lua, &request);
   return lua_pcall(lua, 1, LUA_MULTRET, 0);
}

static const char *import_arguments(tl_State *L, lua_State *lua, int first, int last) {
   ImportMap map = {0};
   for (int i = first; i <= last; ++i) {
      tl_Value value = from_lua(L, lua, i, &map, 0);
      if (map.error) break;
      tl_push(L, value);
   }
   free(map.entries);
   return map.error;
}

static _Noreturn void script_error(tl_State *L, lua_State *lua, int restore) {
   size_t n;
   const char *message = lua_tolstring(lua, -1, &n);
   tl_Value error = message ? tl_string(L, message, n) : tl_cstring(L, "Lua runtime error");
   lua_settop(lua, restore);
   tl_raise(L, error);
}

static int native_callback(lua_State *lua) {
   NativeRef *ref = lua_touserdata(lua, lua_upvalueindex(1));
   tl_State *L = ref->native;
   Script *script = L->script;
   if (script->closing) return 0;
   int nargs = lua_gettop(lua);
   int mark = tl_gettop(L);
   lua_State *old = script->active;
   script->active = lua;
   tl_push(L, tl_rawget(L->script_roots, tl_numeric(-ref->index)));
   const char *error = import_arguments(L, lua, 1, nargs);
   if (error) {
      tl_settop(L, mark);
      script->active = old;
      return luaL_error(lua, "%s", error);
   }
   int failed = tl_pcall(L, nargs, TL_MULTRET);
   int count = tl_gettop(L) - mark;
   int export_failed = export_arguments(L, lua, mark + 1, mark + count);
   tl_settop(L, mark);
   script->active = old;
   if (failed || export_failed) return lua_error(lua);
   return count;
}

static void synchronize(tl_State *L, lua_State *lua) {
   tl_Value package = tl_field(L, L->globals, "package");
   lua_getglobal(lua, "package");
   lua_pushstring(lua, tl_field(L, package, "path").as.string->bytes);
   lua_setfield(lua, -2, "path");
   lua_pushstring(lua, tl_field(L, package, "cpath").as.string->bytes);
   lua_setfield(lua, -2, "cpath");
   lua_pop(lua, 1);

   lua_newtable(lua);
   push_lua(L, lua, tl_field(L, L->globals, "arg"), lua_gettop(lua), 0);
   lua_setglobal(lua, "arg");
   lua_pop(lua, 1);
}

static int call_script(tl_State *L) {
   Script *script = L->script;
   ScriptRef *ref = ((tl_Function *)L->current.as.object)->data;
   lua_State *lua = script->active ? script->active : script->main;
   const int top = lua_gettop(lua);
   if (ref->globals && !script->active) synchronize(L, lua);
   lua_rawgeti(lua, LUA_REGISTRYINDEX, ref->ref);
   int nargs = tl_gettop(L);
   if (export_arguments(L, lua, 1, nargs)) script_error(L, lua, top);
   int failed = lua_pcall(lua, nargs, LUA_MULTRET, 0);
   int count = lua_gettop(lua) - top;
   const char *error = import_arguments(L, lua, top + 1, top + count);
   lua_settop(lua, top);
   if (error) tl_fail(L, "%s", error);
   if (failed) tl_raise(L, tl_at(L, -1));
   return count;
}

static int call_required(lua_State *lua) {
   tl_State *L = lua_touserdata(lua, lua_upvalueindex(1));
   Script *script = L->script;
   int top = tl_gettop(L);
   lua_State *old = script->active;
   script->active = lua;
   tl_getglobal(L, "require");
   tl_pushstring(L, luaL_checkstring(lua, 1));
   int failed = tl_pcall(L, 1, 1);
   int export_failed = export_arguments(L, lua, top + 1, top + 1);
   tl_settop(L, top);
   script->active = old;
   if (failed || export_failed) return lua_error(lua);
   return 1;
}

static int resolve_module(lua_State *lua) {
   tl_State *L = lua_touserdata(lua, lua_upvalueindex(1));
   Script *script = L->script;
   const char *name = luaL_checkstring(lua, 1);
   if (script->external_only) return 0;
   tl_Value package = tl_field(L, L->globals, "package");
   tl_Value preload = tl_field(L, package, "preload");
   if (tl_field(L, preload, name).type == TL_FUNCTION) {
      lua_pushlightuserdata(lua, L);
      lua_pushcclosure(lua, call_required, 1);
      return 1;
   }

   tl_Value loaders = tl_field(L, package, "loaders");
   size_t count = tl_length(L, loaders);
   int top = tl_gettop(L);
   lua_State *old = script->active;
   script->active = lua;
   for (size_t i = 2; i <= count; ++i) {
      tl_push(L, tl_getkey(L, loaders, tl_numeric((double)i)));
      tl_pushstring(L, name);
      int failed = tl_pcall(L, 1, 2);
      if (failed || tl_at(L, -2).type == TL_FUNCTION) {
         int export_failed = export_arguments(L, lua, top + 1, tl_gettop(L));
         tl_settop(L, top);
         script->active = old;
         if (failed || export_failed) return lua_error(lua);
         return 2;
      }
      tl_settop(L, top);
   }
   script->active = old;
   return 0;
}

static int script_rawlen(lua_State *lua) {
   lua_pushnumber(lua, (lua_Number)lua_objlen(lua, 1));
   return 1;
}

static int script_pack(lua_State *lua) {
   int count = lua_gettop(lua);
   lua_createtable(lua, count, 1);
   for (int i = 1; i <= count; ++i) {
      lua_pushvalue(lua, i);
      lua_rawseti(lua, -2, i);
   }
   lua_pushinteger(lua, count);
   lua_setfield(lua, -2, "n");
   return 1;
}

static void remember_builtins(tl_State *L, lua_State *lua) {
   static const char *const names[] = {
      "math", "string", "table", "bit", "utf8", "coroutine",
      "assert", "error", "tostring", "tonumber", "type", "print", "pcall", "xpcall",
      "unpack", "select", "rawget", "rawset", "rawequal", "rawlen", "getmetatable",
      "setmetatable", "next", "pairs", "ipairs", NULL
   };
   lua_newtable(lua);
   for (const char *const *name = names; *name; ++name) {
      tl_Value value = tl_field(L, L->globals, *name);
      if (value.type != TL_FUNCTION && value.type != TL_TABLE) continue;
      lua_pushlightuserdata(lua, value.as.object);
      lua_getglobal(lua, *name);
      lua_rawset(lua, -3);
   }
   ((Script *)L->script)->builtins = luaL_ref(lua, LUA_REGISTRYINDEX);
}

static Script *engine(tl_State *L) {
   if (L->script) return L->script;
   Script *script = tl_resize(L, NULL, sizeof *script);
   *script = (Script){ .main = luaL_newstate() };
   if (!script->main) {
      free(script);
      tl_fail(L, "could not allocate LuaJIT script state");
   }
   L->script = script;
   L->script_roots = tl_table(L, 0, 0);
   lua_State *lua = script->main;
   luaL_openlibs(lua);
   luaL_newmetatable(lua, "teal.native.callback");
   lua_pushcfunction(lua, release_native);
   lua_setfield(lua, -2, "__gc");
   lua_pop(lua, 1);

   lua_getglobal(lua, "package");
   lua_getfield(lua, -1, "loaders");
   int count = (int)lua_objlen(lua, -1);
   for (int i = count; i >= 2; --i) {
      lua_rawgeti(lua, -1, i);
      lua_rawseti(lua, -2, i + 1);
   }
   lua_pushlightuserdata(lua, L);
   lua_pushcclosure(lua, resolve_module, 1);
   lua_rawseti(lua, -2, 2);
   lua_pop(lua, 2);

   lua_pushcfunction(lua, script_rawlen);
   lua_setglobal(lua, "rawlen");
   lua_getglobal(lua, "table");
   lua_getglobal(lua, "unpack");
   lua_setfield(lua, -2, "unpack");
   lua_pushcfunction(lua, script_pack);
   lua_setfield(lua, -2, "pack");
   lua_pop(lua, 1);
   remember_builtins(L, lua);
   return script;
}

int tl_loadscript(tl_State *L) {
   tl_String *source = tl_checkstring(L, 1);
   const char *name = tl_isnil(L, 2) ? "=(load)" : tl_bytes(L, 2);
   const char *mode = tl_isnil(L, 3) ? NULL : tl_bytes(L, 3);
   Script *script = engine(L);
   lua_State *lua = script->active ? script->active : script->main;
   int top = lua_gettop(lua);
   if (luaL_loadbufferx(lua, source->bytes, source->length, name, mode)) {
      size_t n;
      const char *message = lua_tolstring(lua, -1, &n);
      tl_pushnil(L);
      if (message) tl_pushlstring(L, message, n);
      else tl_pushstring(L, "LuaJIT could not load the script");
      lua_settop(lua, top);
      return 2;
   }
   bool globals = tl_isnil(L, 4);
   if (!globals) {
      if (tl_at(L, 4).type != TL_TABLE) {
         lua_settop(lua, top);
         tl_fail(L, "script environment must be a table");
      }
      if (export_arguments(L, lua, 4, 4)) script_error(L, lua, top);
      lua_setfenv(lua, -2);
   }
   tl_push(L, import_ref(L, lua, -1, true, globals));
   lua_settop(lua, top);
   return 1;
}

int tl_load_lua_module(tl_State *L) {
   const char *name = tl_bytes(L, 1);
   Script *script = engine(L);
   lua_State *lua = script->active ? script->active : script->main;
   int top = lua_gettop(lua);
   if (!script->active) synchronize(L, lua);
   lua_getglobal(lua, "require");
   lua_pushstring(lua, name);
   ++script->external_only;
   int failed = lua_pcall(lua, 1, 1, 0);
   --script->external_only;
   const char *error = import_arguments(L, lua, top + 1, top + 1);
   lua_settop(lua, top);
   if (error) tl_fail(L, "%s", error);
   if (failed) tl_raise(L, tl_at(L, -1));
   return 1;
}

void tl_closescript(tl_State *L) {
   Script *script = L->script;
   if (script) {
      script->closing = true;
      lua_close(script->main);
      free(script);
      L->script = NULL;
   }
}
