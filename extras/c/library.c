#include "tl_runtime.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static tl_Value named_function(tl_State *L, tl_CFunction code) {
   tl_pushcfunction(L, code);
   tl_Value function = tl_at(L, -1);
   tl_pop(L, 1);
   return function;
}

void tl_library(tl_State *L, tl_Value target, const tl_Library *library) {
   for (; library->name; ++library) {
      tl_Value function = named_function(L, library->code);
      tl_putfield(L, target, library->name, function);
   }
}

static int base_assert(tl_State *L) {
   if (!tl_toboolean(L, 1))
      tl_raise(L, tl_isnil(L, 2) ? tl_cstring(L, "assertion failed!") : tl_at(L, 2));
   return tl_gettop(L);
}

static int base_error(tl_State *L) { tl_raise(L, tl_at(L, 1)); }

static int base_type(tl_State *L) {
   tl_pushstring(L, tl_typename(tl_at(L, 1)));
   return 1;
}

static int base_tostring(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   tl_String *s = tl_asstring(L, value);
   if (s) tl_push(L, tl_object(&s->header));
   else if (value.type == TL_NIL) tl_pushstring(L, "nil");
   else if (value.type == TL_BOOLEAN) tl_pushstring(L, value.as.boolean ? "true" : "false");
   else {
      if (value.type == TL_TABLE && value.as.table->meta) {
         tl_Value method = tl_field(L, tl_object(&value.as.table->meta->header), "__tostring");
         if (method.type != TL_NIL) {
            tl_push(L, method);
            tl_push(L, value);
            tl_call(L, 1, 1);
            return 1;
         }
      }
      char text[72];
      snprintf(text, sizeof text, "%s: %p", tl_typename(value), (void *)value.as.object);
      tl_pushstring(L, text);
   }
   return 1;
}

static int base_tonumber(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   double n;
   if (tl_isnil(L, 2) || tl_checkinteger(L, 2) == 10) {
      if (tl_number(value, &n)) tl_pushnumber(L, n);
      else tl_pushnil(L);
   } else {
      int64_t radix = tl_checkinteger(L, 2);
      if (radix < 2 || radix > 36) tl_fail(L, "base out of range");
      tl_String *s = tl_asstring(L, value);
      if (!s) {
         tl_pushnil(L);
         return 1;
      }
      char *end;
      long long parsed = strtoll(s->bytes, &end, (int)radix);
      if (end != s->bytes && (size_t)(end - s->bytes) == s->length)
         tl_pushnumber(L, (double)parsed);
      else tl_pushnil(L);
   }
   return 1;
}

static int base_print(tl_State *L) {
   int args = tl_gettop(L);
   for (int i = 1; i <= args; ++i) {
      tl_getglobal(L, "tostring");
      tl_pushvalue(L, i);
      tl_call(L, 1, 1);
      tl_String *str = tl_checkstring(L, -1);
      if (i > 1) fputc('\t', stdout);
      fwrite(str->bytes, 1, str->length, stdout);
      tl_pop(L, 1);
   }
   fputc('\n', stdout);
   return 0;
}

static int base_pcall(tl_State *L) {
   bool ok = tl_pcall(L, tl_gettop(L) - 1, TL_MULTRET) == 0;
   tl_pushboolean(L, ok);
   tl_insert(L, 1);
   return tl_gettop(L);
}

static int base_xpcall(tl_State *L) {
   int args = tl_gettop(L);
   tl_pushvalue(L, 1);
   for (int i = 3; i <= args; ++i) tl_pushvalue(L, i);
   bool ok = tl_pcall(L, args - 2, TL_MULTRET) == 0;
   if (!ok) {
      tl_pushvalue(L, 2);
      tl_insert(L, -2);
      if (tl_pcall(L, 1, 1)) {
         tl_pop(L, 1);
         tl_pushstring(L, "error in error handling");
      }
   }
   tl_pushboolean(L, ok);
   tl_insert(L, args + 1);
   return tl_gettop(L) - args;
}

static int base_select(tl_State *L) {
   int count = tl_gettop(L) - 1;
   tl_Value selector = tl_at(L, 1);
   if (selector.type == TL_STRING && !strcmp(selector.as.string->bytes, "#")) {
      tl_pushinteger(L, count);
      return 1;
   }
   int64_t first = tl_checkinteger(L, 1);
   if (first < 0) first += count + 1;
   if (first < 1) tl_fail(L, "index out of range in select");
   return first > count ? 0 : count - (int)first + 1;
}

static tl_Value check_table(tl_State *L, int index) {
   tl_Value value = tl_at(L, index);
   if (value.type != TL_TABLE) tl_fail(L, "table expected (got %s)", tl_typename(value));
   return value;
}

static int base_rawget(tl_State *L) {
   tl_push(L, tl_rawget(check_table(L, 1), tl_at(L, 2)));
   return 1;
}

static int base_rawset(tl_State *L) {
   tl_rawput(L, check_table(L, 1), tl_at(L, 2), tl_at(L, 3));
   tl_pushvalue(L, 1);
   return 1;
}

static int base_rawequal(tl_State *L) {
   tl_pushboolean(L, tl_equal(tl_at(L, 1), tl_at(L, 2)));
   return 1;
}

static int base_rawlen(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   if (value.type == TL_TABLE) tl_pushnumber(L, (double)value.as.table->length);
   else if (value.type == TL_STRING) tl_pushnumber(L, (double)value.as.string->length);
   else tl_fail(L, "table or string expected");
   return 1;
}

static int base_getmetatable(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   tl_Table *table = value.type == TL_TABLE ? value.as.table->meta : NULL;
   tl_Value meta = table ? tl_object(&table->header) : tl_nil;
   tl_Value locked = table ? tl_rawget(meta, tl_cstring(L, "__metatable")) : tl_nil;
   tl_push(L, locked.type != TL_NIL ? locked : meta);
   return 1;
}

static int base_setmetatable(tl_State *L) {
   tl_Value value = check_table(L, 1);
   tl_Value meta = tl_at(L, 2);
   if (meta.type != TL_TABLE && meta.type != TL_NIL) tl_fail(L, "nil or table expected for metatable");
   tl_Table *old = value.as.table->meta;
   if (old && tl_rawget(tl_object(&old->header), tl_cstring(L, "__metatable")).type != TL_NIL)
      tl_fail(L, "cannot change a protected metatable");
   value.as.table->meta = meta.type == TL_TABLE ? meta.as.table : NULL;
   tl_push(L, value);
   return 1;
}

static int base_next(tl_State *L) {
   tl_Value key, value;
   if (!tl_next(L, tl_at(L, 1), tl_at(L, 2), &key, &value)) {
      tl_pushnil(L);
      return 1;
   }
   tl_push(L, key);
   tl_push(L, value);
   return 2;
}

static int base_pairs(tl_State *L) {
   tl_Value value = check_table(L, 1);
   if (value.as.table->meta) {
      tl_Value meta = tl_object(&value.as.table->meta->header);
      tl_Value method = tl_rawget(meta, tl_cstring(L, "__pairs"));
      if (method.type != TL_NIL) {
         tl_push(L, method);
         tl_pushvalue(L, 1);
         tl_call(L, 1, 3);
         return 3;
      }
   }
   tl_getglobal(L, "next");
   tl_pushvalue(L, 1);
   tl_pushnil(L);
   return 3;
}

static int inext(tl_State *L) {
   double next = tl_checknumber(L, 2) + 1;
   tl_Value value = tl_getkey(L, tl_at(L, 1), tl_numeric(next));
   if (value.type == TL_NIL) return 0;
   tl_pushnumber(L, next);
   tl_push(L, value);
   return 2;
}

static int base_ipairs(tl_State *L) {
   check_table(L, 1);
   tl_pushcfunction(L, inext);
   tl_pushvalue(L, 1);
   tl_pushinteger(L, 0);
   return 3;
}

static int table_pack(tl_State *L) {
   int count = tl_gettop(L);
   tl_Value table = tl_table(L, (size_t)count, 1);
   for (int i = 1; i <= count; ++i) tl_rawput(L, table, tl_numeric(i), tl_at(L, i));
   tl_putfield(L, table, "n", tl_numeric(count));
   tl_push(L, table);
   return 1;
}

static int table_unpack(tl_State *L) {
   tl_Value table = check_table(L, 1);
   int64_t start = tl_isnil(L, 2) ? 1 : tl_checkinteger(L, 2);
   int64_t end = tl_isnil(L, 3) ? (int64_t)tl_length(L, table) : tl_checkinteger(L, 3);
   if (end < start) return 0;
   if ((uint64_t)end - (uint64_t)start >= INT_MAX) tl_fail(L, "too many results to unpack");
   int count = (int)(end - start + 1);
   tl_reserve(L, count);
   for (int i = 0; i < count; ++i) tl_push(L, tl_getkey(L, table, tl_numeric((double)(start + i))));
   return count;
}

static int table_insert(tl_State *L) {
   tl_Value table = check_table(L, 1);
   int64_t end = (int64_t)tl_length(L, table) + 1;
   bool append = tl_gettop(L) == 2;
   int64_t index = append ? end : tl_checkinteger(L, 2);
   if (index < 1 || index > end) tl_fail(L, "position out of bounds in insert");
   for (int64_t i = end; i > index; --i) {
      tl_Value value = tl_getkey(L, table, tl_numeric((double)(i - 1)));
      tl_putkey(L, table, tl_numeric((double)i), value);
   }
   tl_putkey(L, table, tl_numeric((double)index), tl_at(L, append ? 2 : 3));
   return 0;
}

static int table_remove(tl_State *L) {
   tl_Value table = check_table(L, 1);
   int64_t end = (int64_t)tl_length(L, table);
   int64_t index = tl_isnil(L, 2) ? end : tl_checkinteger(L, 2);
   if (index < 1 || index > end) return 0;
   tl_push(L, tl_getkey(L, table, tl_numeric((double)index)));
   for (int64_t i = index; i < end; ++i) {
      tl_Value value = tl_getkey(L, table, tl_numeric((double)(i + 1)));
      tl_putkey(L, table, tl_numeric((double)i), value);
   }
   tl_putkey(L, table, tl_numeric((double)end), tl_nil);
   return 1;
}

static int table_concat(tl_State *L) {
   tl_Value table = check_table(L, 1);
   tl_String *separator = tl_isnil(L, 2) ? NULL : tl_checkstring(L, 2);
   int64_t start = tl_isnil(L, 3) ? 1 : tl_checkinteger(L, 3);
   int64_t end = tl_isnil(L, 4) ? (int64_t)tl_length(L, table) : tl_checkinteger(L, 4);
   {
      if (separator) tl_push(L, tl_object(&separator->header));
      tl_Buffer out = {0};
      for (int64_t i = start; i <= end; ++i) {
         tl_Value value = tl_getkey(L, table, tl_numeric((double)i));
         tl_String *str = tl_asstring(L, value);
         if (!str) {
            free(out.data);
            tl_fail(L, "invalid value (%s) at index %lld in concat", tl_typename(value), (long long)i);
         }
         if (separator && i != start) tl_buffer_add(L, &out, separator->bytes, separator->length);
         tl_buffer_add(L, &out, str->bytes, str->length);
         if (i == end) break;
      }
      tl_buffer_push(L, &out);
   }
   return 1;
}

static bool sort_less(tl_State *L, tl_Value cmp, tl_Value a, tl_Value b) {
   if (cmp.type == TL_NIL) return tl_less(L, a, b);
   tl_push(L, cmp);
   tl_push(L, a);
   tl_push(L, b);
   tl_call(L, 2, 1);
   return tl_test(L);
}

static void sort_part(tl_State *L, tl_Value table, tl_Value cmp, int left, int right) {
   while (left < right) {
      tl_Value pivot = tl_rawget(table, tl_numeric(left + (right - left) / 2));
      tl_push(L, pivot);
      int i = left;
      int j = right;
      while (i <= j) {
         while (i <= right && sort_less(L, cmp, tl_rawget(table, tl_numeric(i)), pivot)) ++i;
         while (j >= left && sort_less(L, cmp, pivot, tl_rawget(table, tl_numeric(j)))) --j;
         if (i > right || j < left) tl_fail(L, "invalid order function for sorting");
         if (i <= j) {
            tl_Value a = tl_rawget(table, tl_numeric(i));
            tl_Value b = tl_rawget(table, tl_numeric(j));
            tl_rawput(L, table, tl_numeric(i++), b);
            tl_rawput(L, table, tl_numeric(j--), a);
         }
      }
      tl_pop(L, 1);
      if (j - left < right - i) {
         sort_part(L, table, cmp, left, j);
         left = i;
      } else {
         sort_part(L, table, cmp, i, right);
         right = j;
      }
   }
}

static int table_sort(tl_State *L) {
   tl_Value table = check_table(L, 1);
   sort_part(L, table, tl_at(L, 2), 1, (int)tl_length(L, table));
   return 0;
}

static int table_new(tl_State *L) {
   int64_t array = tl_checkinteger(L, 1);
   int64_t hash = tl_checkinteger(L, 2);
   if (array < 0 || hash < 0 || array > INT_MAX || hash > INT_MAX)
      tl_fail(L, "invalid capacity for table.new");
   tl_createtable(L, (int)array, (int)hash);
   return 1;
}

#define MATH_UNARY(name, expression) \
   static int math_##name(tl_State *L) { \
      double x = tl_checknumber(L, 1); \
      tl_pushnumber(L, expression); \
      return 1; \
   }

MATH_UNARY(abs, fabs(x))
MATH_UNARY(floor, floor(x))
MATH_UNARY(ceil, ceil(x))
MATH_UNARY(sqrt, sqrt(x))
MATH_UNARY(sin, sin(x))
MATH_UNARY(cos, cos(x))
MATH_UNARY(tan, tan(x))
MATH_UNARY(log, log(x))
MATH_UNARY(exp, exp(x))
MATH_UNARY(rad, x * (3.14159265358979323846 / 180.0))
MATH_UNARY(deg, x * (180.0 / 3.14159265358979323846))

static int math_fmod(tl_State *L) {
   tl_pushnumber(L, fmod(tl_checknumber(L, 1), tl_checknumber(L, 2)));
   return 1;
}

static int math_pow(tl_State *L) {
   tl_pushnumber(L, pow(tl_checknumber(L, 1), tl_checknumber(L, 2)));
   return 1;
}

static int math_minmax(tl_State *L, bool max) {
   double value = tl_checknumber(L, 1);
   int count = tl_gettop(L);
   for (int i = 2; i <= count; ++i) {
      double next = tl_checknumber(L, i);
      if (max ? next > value : next < value) value = next;
   }
   tl_pushnumber(L, value);
   return 1;
}

static int math_min(tl_State *L) { return math_minmax(L, false); }
static int math_max(tl_State *L) { return math_minmax(L, true); }

static bool exact_integer(double n) { return n >= -0x1p53 && n <= 0x1p53 && trunc(n) == n; }

static int math_tointeger(tl_State *L) {
   double n;
   if (tl_number(tl_at(L, 1), &n) && exact_integer(n)) tl_pushnumber(L, n);
   else tl_pushnil(L);
   return 1;
}

static int math_type(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   if (value.type == TL_NUMBER) tl_pushstring(L, exact_integer(value.as.number) ? "integer" : "float");
   else tl_pushnil(L);
   return 1;
}

static int package_no_loader(tl_State *L) { (void)L; return 0; }

static int library_global(tl_State *L) {
   tl_pushvalue(L, TL_GLOBALS);
   return 1;
}

static int table_new_module(tl_State *L) {
   tl_pushcfunction(L, table_new);
   return 1;
}

void tl_preload(tl_State *L, const char *name, tl_CFunction code) {
   tl_Value package = tl_field(L, L->globals, "package");
   tl_putfield(L, tl_field(L, package, "preload"), name, named_function(L, code));
}

static int base_require(tl_State *L) {
   tl_Value key = tl_at(L, 1);
   const char *name = tl_bytes(L, 1);
   if (key.type != TL_STRING) key = tl_cstring(L, name);
   tl_Value package = tl_field(L, L->globals, "package");
   tl_Value loaded = tl_field(L, package, "loaded");
   tl_Value value = tl_rawget(loaded, key);
   if (tl_truth(value)) {
      tl_push(L, value);
      return 1;
   }
   tl_Value preload = tl_field(L, package, "preload");
   tl_Value loader = tl_rawget(preload, key);
   const int argc = tl_gettop(L);
   tl_Value data = tl_nil;
   if (loader.type == TL_NIL) {
      tl_Value loaders = tl_field(L, package, "loaders");
      size_t n = tl_length(L, loaders);
      for (size_t i = 2; i <= n; ++i) {
         tl_push(L, tl_getkey(L, loaders, tl_numeric((double)i)));
         tl_push(L, key);
         tl_call(L, 1, 2);
         loader = tl_at(L, -2);
         data = tl_at(L, -1);
         if (loader.type == TL_FUNCTION) break;
         tl_pop(L, 2);
         loader = tl_nil;
      }
   }
   if (loader.type == TL_NIL) return tl_load_lua_module(L);
   tl_push(L, loader);
   tl_push(L, key);
   tl_push(L, data);
   if (tl_pcall(L, 2, 1)) tl_raise(L, tl_at(L, -1));
   value = tl_at(L, -1);
   if (value.type == TL_NIL) value = tl_rawget(loaded, key);
   if (value.type == TL_NIL) value = tl_boolean(true);
   tl_rawput(L, loaded, key, value);
   tl_settop(L, argc);
   tl_push(L, value);
   return 1;
}

static int debug_info(tl_State *L) {
   tl_Value info = tl_table(L, 0, 4);
   tl_putfield(L, info, "what", tl_cstring(L, "C"));
   tl_putfield(L, info, "currentline", tl_numeric(-1));
   tl_push(L, info);
   return 1;
}

static int debug_traceback(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   if (value.type != TL_NIL && value.type != TL_STRING) {
      tl_push(L, value);
      return 1;
   }
   tl_pushstring(L, value.type == TL_STRING ? value.as.string->bytes : "stack traceback:");
   return 1;
}

static int debug_hook(tl_State *L) {
   if (!tl_isnil(L, 1)) tl_fail(L, "instruction hooks are available in LuaJIT builds");
   return 0;
}

static const tl_Library base[] = {
   { "assert", base_assert }, { "error", base_error }, { "type", base_type },
   { "tostring", base_tostring }, { "tonumber", base_tonumber }, { "print", base_print },
   { "pcall", base_pcall }, { "xpcall", base_xpcall }, { "select", base_select },
   { "rawget", base_rawget }, { "rawset", base_rawset }, { "rawequal", base_rawequal },
   { "rawlen", base_rawlen }, { "getmetatable", base_getmetatable }, { "setmetatable", base_setmetatable },
   { "next", base_next }, { "pairs", base_pairs }, { "ipairs", base_ipairs },
   { "unpack", table_unpack }, { "load", tl_loadscript }, { "loadstring", tl_loadscript },
   { "require", base_require }, { NULL, NULL }
};

static const tl_Library math_functions[] = {
   { "abs", math_abs }, { "floor", math_floor }, { "ceil", math_ceil },
   { "sin", math_sin }, { "cos", math_cos }, { "tan", math_tan }, { "exp", math_exp },
   { "log", math_log }, { "sqrt", math_sqrt }, { "rad", math_rad }, { "deg", math_deg },
   { "fmod", math_fmod }, { "pow", math_pow }, { "min", math_min }, { "max", math_max },
   { "type", math_type }, { "tointeger", math_tointeger }, { NULL, NULL }
};

static const tl_Library table_functions[] = {
   { "pack", table_pack }, { "unpack", table_unpack }, { "insert", table_insert },
   { "remove", table_remove }, { "sort", table_sort }, { "concat", table_concat },
   { "new", table_new }, { NULL, NULL }
};

static const tl_Library debug_functions[] = {
   { "getinfo", debug_info }, { "sethook", debug_hook }, { "traceback", debug_traceback },
   { "getmetatable", base_getmetatable }, { NULL, NULL }
};

static tl_Value package_path(tl_State *L, const char *path, const char *defaults) {
   if (!path) return tl_cstring(L, defaults);
   const char *gap = strstr(path, ";;");
   if (!gap) return tl_cstring(L, path);
   tl_Buffer expanded = {0};
   do {
      tl_buffer_add(L, &expanded, path, (size_t)(gap - path));
      tl_buffer_byte(L, &expanded, ';');
      tl_buffer_add(L, &expanded, defaults, strlen(defaults));
      tl_buffer_byte(L, &expanded, ';');
      path = gap + 2;
      gap = strstr(path, ";;");
   } while (gap);
   tl_buffer_add(L, &expanded, path, strlen(path));
   tl_buffer_push(L, &expanded);
   tl_Value result = tl_at(L, -1);
   tl_pop(L, 1);
   return result;
}

void tl_openlibs(tl_State *L) {
   L->globals = tl_table(L, 0, 48);
   L->mode_key = tl_cstring(L, "__mode");
   tl_library(L, L->globals, base);
   tl_putfield(L, L->globals, "_G", L->globals);
   tl_putfield(L, L->globals, "_VERSION", tl_cstring(L, "Lua 5.1"));
   tl_putfield(L, L->globals, "_TEAL_NATIVE", tl_boolean(true));

   tl_Value math = tl_table(L, 0, 24);
   tl_library(L, math, math_functions);
   tl_putfield(L, L->globals, "math", math);
   tl_putfield(L, math, "huge", tl_numeric(HUGE_VAL));
   tl_putfield(L, math, "pi", tl_numeric(3.14159265358979323846));
   tl_putfield(L, math, "maxinteger", tl_numeric(0x1p53));
   tl_putfield(L, math, "mininteger", tl_numeric(-0x1p53));

   tl_Value tables = tl_table(L, 0, 8);
   tl_library(L, tables, table_functions);
   tl_putfield(L, L->globals, "table", tables);

   tl_Value debug = tl_table(L, 0, 5);
   tl_library(L, debug, debug_functions);
   tl_putfield(L, L->globals, "debug", debug);

   tl_Value package = tl_table(L, 0, 6);
   tl_putfield(L, L->globals, "package", package);
   const char *path = getenv("LUA_PATH");
   const char *cpath = getenv("LUA_CPATH");
   tl_putfield(L, package, "path", package_path(L, path, "./?.lua;./?/init.lua;./extras/?.lua;./extras/?/init.lua"));
   tl_putfield(L, package, "cpath", package_path(L, cpath, "./?.so"));
   tl_putfield(L, package, "config", tl_cstring(L, "/\n;\n?\n!\n-\n"));
   tl_putfield(L, package, "loaded", tl_table(L, 0, 0));
   tl_putfield(L, package, "preload", tl_table(L, 0, 0));
   tl_Value loaders = tl_table(L, 1, 0);
   tl_rawput(L, loaders, tl_numeric(1), named_function(L, package_no_loader));
   tl_putfield(L, package, "loaders", loaders);
   tl_preload(L, "compat53.module", library_global);
   tl_preload(L, "compat53", library_global);
   tl_preload(L, "table.new", table_new_module);

   tl_putfield(L, L->globals, "coroutine", tl_table(L, 0, 0));
   tl_putfield(L, L->globals, "bit", tl_table(L, 0, 0));
   tl_openstrings(L);
   tl_opensystem(L);
   static const char *const standard[] = {
      "package", "math", "table", "string", "io", "os", "debug", "utf8", "coroutine", "bit", NULL,
   };
   tl_Value loaded = tl_field(L, package, "loaded");
   for (const char *const *name = standard; *name; ++name)
      tl_putfield(L, loaded, *name, tl_field(L, L->globals, *name));
}
