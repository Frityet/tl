#include "tl_runtime.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

tl_State *tl_newstate(void) {
   tl_State *L = calloc(1, sizeof *L);
   if (L) L->collect_at = 8 * 1024 * 1024;
   return L;
}

static void destroy(tl_State *L, tl_Object *object) {
   if (object->type == TL_TABLE) {
      tl_Table *table = (tl_Table *)object;
      free(table->array);
      free(table->entries);
   } else if (object->type == TL_FUNCTION) {
      tl_Function *function = (tl_Function *)object;
      if (function->destroy) function->destroy(L, function->data);
   } else if (object->type == TL_FOREIGN) {
      tl_Foreign *reference = (tl_Foreign *)object;
      if (reference->destroy) reference->destroy(L, reference->data);
   } else if (object->type == TL_FILE) {
      tl_File *file = (tl_File *)object;
      if (file->file && file->close) file->close(file->file);
   }
   free(object);
}

void tl_close(tl_State *L) {
   tl_closescript(L);
   while (L->objects) {
      tl_Object *object = L->objects;
      L->objects = object->next;
      destroy(L, object);
   }
   free(L->strings);
   free(L->stack);
   free(L);
}

void *tl_resize(tl_State *L, void *old, size_t size) {
   void *p = realloc(old, size);
   if (!p) {
      fputs("tl: out of memory\n", stderr);
      exit(EXIT_FAILURE);
   }
   L->allocated += size;
   return p;
}

void *tl_allocate(tl_State *L, size_t size, tl_Type type) {
   tl_Object *p = tl_resize(L, NULL, size);
   memset(p, 0, size);
   p->type = type;
   p->next = L->objects;
   L->objects = p;
   return p;
}

static size_t string_slot(tl_State *L, uint32_t hash, const char *bytes, size_t len) {
   size_t mask = L->string_capacity - 1;
   size_t i = hash & mask;
   while (L->strings[i]) {
      tl_String *s = L->strings[i];
      if (s->hash == hash && s->length == len && !memcmp(s->bytes, bytes, len)) break;
      i = (i + 1) & mask;
   }
   return i;
}

static void rebuild_strings(tl_State *L, size_t capacity) {
   tl_String **old = L->strings;
   L->strings = tl_resize(L, NULL, capacity * sizeof *L->strings);
   memset(L->strings, 0, capacity * sizeof *L->strings);
   L->string_capacity = capacity;
   L->string_count = 0;
   for (tl_Object *v = L->objects; v; v = v->next) {
      if (v->type != TL_STRING) continue;
      tl_String *s = (tl_String *)v;
      L->strings[string_slot(L, s->hash, s->bytes, s->length)] = s;
      ++L->string_count;
   }
   free(old);
}

tl_Value tl_string(tl_State *L, const char *bytes, size_t len) {
   uint32_t hash = UINT32_C(2166136261);
   for (size_t i = 0; i < len; ++i) hash = (hash ^ (unsigned char)bytes[i]) * UINT32_C(16777619);
   if (!L->string_capacity || (L->string_count + 1) * 4 > L->string_capacity * 3)
      rebuild_strings(L, L->string_capacity ? L->string_capacity * 2 : 256);
   size_t slot = string_slot(L, hash, bytes, len);
   if (L->strings[slot]) return tl_object(&L->strings[slot]->header);
   tl_String *s = tl_allocate(L, sizeof *s + len + 1, TL_STRING);
   memcpy(s->bytes, bytes, len);
   s->hash = hash;
   s->length = len;
   L->strings[slot] = s;
   ++L->string_count;
   return tl_object(&s->header);
}

tl_Value tl_cstring(tl_State *L, const char *str) {
   return tl_string(L, str, strlen(str));
}

void tl_pushstring(tl_State *L, const char *str) {
   tl_push(L, str ? tl_cstring(L, str) : tl_nil);
}

void tl_pushlstring(tl_State *L, const char *str, size_t len) {
   tl_push(L, tl_string(L, str, len));
}

static tl_Value literal(tl_State *L, const char *str, size_t len) {
   uintptr_t address = (uintptr_t)str;
   size_t index = ((address >> 2) ^ (address >> 14)) & 4095;
   tl_Literal *cached = &L->literals[index];
   if (cached->data == str && cached->string->length == len)
      return tl_object(&cached->string->header);
   tl_Value value = tl_string(L, str, len);
   *cached = (tl_Literal){ str, value.as.string };
   return value;
}

void tl_pushliteral(tl_State *L, const char *str, size_t len) {
   tl_push(L, literal(L, str, len));
}

typedef struct Marker {
   tl_Value mode_key;
   size_t marked;
} Marker;

enum { WEAK_KEYS = 1, WEAK_VALUES = 2 };

static unsigned weak_mode(Marker *marker, tl_Table *table) {
   if (!table->meta) return 0;
   tl_Value mode = tl_rawget(tl_object(&table->meta->header), marker->mode_key);
   if (mode.type != TL_STRING) return 0;
   const char *text = mode.as.string->bytes;
   return (strchr(text, 'k') ? WEAK_KEYS : 0) | (strchr(text, 'v') ? WEAK_VALUES : 0);
}

static bool alive(tl_Value value) {
   return value.type < TL_STRING || value.as.object->marked;
}

static void mark(Marker *marker, tl_Value value) {
   if (alive(value)) return;
   tl_Object *object = value.as.object;
   object->marked = true;
   ++marker->marked;
   switch (object->type) {
      case TL_TABLE: {
         tl_Table *table = (tl_Table *)object;
         if (table->meta) mark(marker, tl_object(&table->meta->header));
         unsigned weak = weak_mode(marker, table);
         for (size_t i = 0; i < table->array_size; ++i) {
            tl_Value item = table->array[i];
            if (!(weak & WEAK_VALUES) || item.type == TL_STRING) mark(marker, item);
         }
         for (size_t i = 0; i < table->capacity; ++i) {
            tl_Entry entry = table->entries[i];
            if (!(weak & WEAK_KEYS) || entry.key.type == TL_STRING) mark(marker, entry.key);
            if (!(weak & WEAK_VALUES) ? alive(entry.key) : entry.value.type == TL_STRING)
               mark(marker, entry.value);
         }
         break;
      }
      case TL_FUNCTION: mark(marker, ((tl_Function *)object)->closure); break;
      case TL_CELL: mark(marker, ((tl_Cell *)object)->value); break;
      default: break;
   }
}

static void resize_hash(tl_State *, tl_Table *, size_t);

static void sweep_weak(tl_State *L, Marker *marker) {
   /* A value in a weak-key map stays alive while its key is reachable. */
   size_t old;
   do {
      old = marker->marked;
      for (tl_Object *object = L->objects; object; object = object->next) {
         if (object->type != TL_TABLE || !object->marked) continue;
         tl_Table *table = (tl_Table *)object;
         if (weak_mode(marker, table) != WEAK_KEYS) continue;
         for (size_t i = 0; i < table->capacity; ++i)
            if (alive(table->entries[i].key)) mark(marker, table->entries[i].value);
      }
   } while (old != marker->marked);

   for (tl_Object *object = L->objects; object; object = object->next) {
      if (object->type != TL_TABLE || !object->marked) continue;
      tl_Table *table = (tl_Table *)object;
      unsigned weak = weak_mode(marker, table);
      if (!weak) continue;
      if (weak & WEAK_VALUES) {
         for (size_t i = 0; i < table->array_size; ++i)
            if (!alive(table->array[i])) table->array[i] = tl_nil;
         while (table->length && table->array[table->length - 1].type == TL_NIL) --table->length;
      }
      bool removed = false;
      for (size_t i = 0; i < table->capacity; ++i) {
         tl_Entry *entry = &table->entries[i];
         if (!alive(entry->key) || !alive(entry->value)) {
            entry->value = tl_nil;
            removed = true;
         }
      }
      if (removed) resize_hash(L, table, table->capacity);
   }
}

void tl_collect(tl_State *L) {
   Marker marker = { .mode_key = L->mode_key };
   for (int i = 0; i < L->top; ++i) mark(&marker, L->stack[i]);
   mark(&marker, L->globals);
   mark(&marker, L->current);
   mark(&marker, L->string_lib);
   mark(&marker, L->file_lib);
   mark(&marker, L->default_in);
   mark(&marker, L->default_out);
   mark(&marker, L->script_roots);
   mark(&marker, L->error);
   mark(&marker, L->mode_key);
   for (size_t i = 0; i < sizeof L->literals / sizeof L->literals[0]; ++i)
      if (L->literals[i].string) mark(&marker, tl_object(&L->literals[i].string->header));
   sweep_weak(L, &marker);
   size_t live = 0;
   tl_Object **link = &L->objects;
   while (*link) {
      tl_Object *object = *link;
      if (!object->marked) {
         *link = object->next;
         destroy(L, object);
      } else {
         object->marked = false;
         live += sizeof(tl_Function);
         if (object->type == TL_TABLE) {
            tl_Table *table = (tl_Table *)object;
            live += table->capacity * sizeof(tl_Entry) + table->array_size * sizeof(tl_Value);
         } else if (object->type == TL_STRING) {
            live += ((tl_String *)object)->length;
         }
         link = &object->next;
      }
   }
   if (L->string_capacity) rebuild_strings(L, L->string_capacity);
   L->allocated = 0;
   L->collect_at = live / 2 + 8 * 1024 * 1024;
}

void tl_reserve(tl_State *L, int n) {
   if (n < 0 || n > INT32_MAX / 2 - L->top) tl_fail(L, "value stack overflow");
   if (n <= L->capacity - L->top) return;
   int size = L->capacity ? L->capacity : 256;
   while (size < L->top + n) size *= 2;
   L->stack = tl_resize(L, L->stack, (size_t)size * sizeof *L->stack);
   L->capacity = size;
}

void tl_settop(tl_State *L, int index) {
   int count = index < 0 ? tl_gettop(L) + index + 1 : index;
   if (count < 0) tl_fail(L, "invalid stack index");
   int n = L->base + count - L->top;
   if (n > 0) {
      tl_reserve(L, n);
      while (n--) L->stack[L->top++] = tl_nil;
   } else {
      L->top = L->base + count;
   }
}

static int stack_position(const tl_State *L, int i) {
   return L->base + tl_absolute(L, i) - 1;
}

void tl_insert(tl_State *L, int i) {
   int p = stack_position(L, i);
   tl_Value value = L->stack[L->top - 1];
   memmove(L->stack + p + 1, L->stack + p, (size_t)(L->top - p - 1) * sizeof value);
   L->stack[p] = value;
}

void tl_remove(tl_State *L, int i) {
   int p = stack_position(L, i);
   memmove(L->stack + p, L->stack + p + 1, (size_t)(L->top - p - 1) * sizeof(tl_Value));
   --L->top;
}

void tl_replace(tl_State *L, int i) {
   int p = stack_position(L, i);
   L->stack[p] = L->stack[--L->top];
}

void tl_pushcclosure(tl_State *L, tl_CFunction code, int captures) {
   tl_Function *fn = tl_allocate(L, sizeof *fn, TL_FUNCTION);
   fn->code = code;
   if (captures) {
      fn->closure = tl_at(L, -1);
      tl_pop(L, captures);
   }
   tl_push(L, tl_object(&fn->header));
}

void tl_pushcfunction(tl_State *L, tl_CFunction code) {
   tl_pushcclosure(L, code, 0);
}

_Noreturn void tl_raise(tl_State *L, tl_Value problem) {
   L->error = problem;
   if (L->protected_call) longjmp(L->protected_call->jump, 1);
   const char *message = problem.type == TL_STRING ? problem.as.string->bytes : tl_typename(problem);
   fprintf(stderr, "tl: %s\n", message);
   exit(EXIT_FAILURE);
}

_Noreturn void tl_fail(tl_State *L, const char *format, ...) {
   char message[1024];
   va_list args;
   va_start(args, format);
   vsnprintf(message, sizeof message, format, args);
   va_end(args);
   tl_raise(L, tl_cstring(L, message));
}

const char *tl_typename(tl_Value value) {
   static const char *const names[] = {
      "nil", "boolean", "number", "string", "table", "function", "userdata", "cell", "cdata"
   };
   return names[value.type];
}

static tl_Value metamethod(tl_State *L, tl_Value value, const char *name) {
   tl_Table *table = value.type == TL_TABLE ? value.as.table : NULL;
   if (!table || !table->meta) return tl_nil;
   return tl_rawget(tl_object(&table->meta->header), tl_cstring(L, name));
}

void tl_call(tl_State *L, int nargs, int results) {
   int slot = L->top - nargs - 1;
   tl_Value function = L->stack[slot];
   if (function.type != TL_FUNCTION) {
      tl_Value method = metamethod(L, function, "__call");
      if (method.type != TL_FUNCTION) tl_fail(L, "attempt to call a %s value", tl_typename(function));
      tl_push(L, method);
      tl_insert(L, slot - L->base + 1);
      function = method;
   }

   if (L->depth >= 1200) tl_fail(L, "C call stack overflow");
   int old_base = L->base;
   tl_Value old_function = L->current;
   L->base = slot + 1;
   L->current = function;
   ++L->depth;
   if (L->allocated >= L->collect_at) tl_collect(L);
   int returned = ((tl_Function *)function.as.object)->code(L);
   L->base = old_base;
   L->current = old_function;
   --L->depth;

   int requested = results == TL_MULTRET ? returned : results;
   int copied = returned < requested ? returned : requested;
   memmove(L->stack + slot, L->stack + L->top - returned, (size_t)copied * sizeof(tl_Value));
   L->top = slot + copied;
   tl_reserve(L, requested - copied);
   while (copied++ < requested) tl_pushnil(L);
}

int tl_pcall(tl_State *L, int nargs, int results) {
   tl_Protected call = { .previous = L->protected_call };
   int saved_top = L->top - nargs - 1;
   int saved_base = L->base;
   int saved_depth = L->depth;
   tl_Value saved_function = L->current;
   L->protected_call = &call;
   if (setjmp(call.jump) == 0) {
      tl_call(L, nargs, results);
      L->protected_call = call.previous;
      return 0;
   }
   L->protected_call = call.previous;
   L->top = saved_top;
   L->base = saved_base;
   L->depth = saved_depth;
   L->current = saved_function;
   tl_push(L, L->error);
   L->error = tl_nil;
   return 1;
}

bool tl_number(tl_Value value, double *out) {
   if (value.type == TL_NUMBER) {
      *out = value.as.number;
      return true;
   }
   if (value.type != TL_STRING) return false;
   const char *start = value.as.string->bytes;
   char *end;
   double result = strtod(start, &end);
   if (end == start) return false;
   while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r' || *end == '\v' || *end == '\f') ++end;
   if ((size_t)(end - start) != value.as.string->length) return false;
   *out = result;
   return true;
}

double tl_checknumber(tl_State *L, int i) {
   double number;
   if (!tl_number(tl_at(L, i), &number)) tl_fail(L, "number expected (argument %d, got %s)", i, tl_typename(tl_at(L, i)));
   return number;
}

int64_t tl_checkinteger(tl_State *L, int i) {
   double number = tl_checknumber(L, i);
   if (!(number >= -0x1p63 && number < 0x1p63)) tl_fail(L, "integer out of range");
   return (int64_t)number;
}

tl_String *tl_asstring(tl_State *L, tl_Value value) {
   if (value.type == TL_STRING) return value.as.string;
   if (value.type == TL_NUMBER) {
      char text[64];
      int size = snprintf(text, sizeof text, "%.14g", value.as.number);
      return tl_string(L, text, (size_t)size).as.string;
   }
   return NULL;
}

tl_String *tl_checkstring(tl_State *L, int i) {
   tl_String *value = tl_asstring(L, tl_at(L, i));
   if (!value) tl_fail(L, "string expected (argument %d, got %s)", i, tl_typename(tl_at(L, i)));
   return value;
}

const char *tl_bytes(tl_State *L, int i) { return tl_checkstring(L, i)->bytes; }

bool tl_equal(tl_Value a, tl_Value b) {
   if (a.type != b.type) return false;
   switch (a.type) {
      case TL_NIL: return true;
      case TL_BOOLEAN: return a.as.boolean == b.as.boolean;
      case TL_NUMBER: return a.as.number == b.as.number;
      default: return a.as.object == b.as.object;
   }
}

static uint64_t hash_key(tl_Value key) {
   uint64_t hash;
   if (key.type == TL_STRING) return key.as.string->hash;
   if (key.type == TL_NUMBER) {
      double number = key.as.number == 0 ? 0 : key.as.number;
      memcpy(&hash, &number, sizeof hash);
   } else if (key.type == TL_BOOLEAN) {
      hash = key.as.boolean ? 1 : 2;
   } else {
      hash = (uintptr_t)key.as.object;
   }
   hash ^= hash >> 33;
   hash *= UINT64_C(0xff51afd7ed558ccd);
   return hash ^ (hash >> 33);
}

static size_t array_index(tl_Value key) {
   if (key.type != TL_NUMBER || !(key.as.number >= 1 && key.as.number <= INT32_MAX)) return 0;
   size_t index = (size_t)key.as.number;
   return (double)index == key.as.number ? index : 0;
}

static tl_Entry *find_entry(tl_Table *table, tl_Value key) {
   size_t mask = table->capacity - 1;
   size_t i = hash_key(key) & mask;
   for (;;) {
      tl_Entry *entry = &table->entries[i];
      if (entry->key.type == TL_NIL || tl_equal(key, entry->key)) return entry;
      i = (i + 1) & mask;
   }
}

static void resize_hash(tl_State *L, tl_Table *table, size_t capacity) {
   tl_Entry *old = table->entries;
   size_t old_capacity = table->capacity;
   table->entries = tl_resize(L, NULL, capacity * sizeof *table->entries);
   memset(table->entries, 0, capacity * sizeof *table->entries);
   table->capacity = capacity;
   table->occupied = 0;
   table->entries_used = 0;
   for (size_t i = 0; i < old_capacity; ++i) {
      if (old[i].value.type == TL_NIL) continue;
      *find_entry(table, old[i].key) = old[i];
      ++table->occupied;
      ++table->entries_used;
   }
   free(old);
}

static void resize_array(tl_State *L, tl_Table *table, size_t size) {
   size_t previous = table->array_size;
   table->array = tl_resize(L, table->array, size * sizeof *table->array);
   memset(table->array + previous, 0, (size - previous) * sizeof *table->array);
   table->array_size = size;
   for (size_t i = 0; i < table->capacity; ++i) {
      tl_Entry *entry = &table->entries[i];
      if (entry->value.type == TL_NIL) continue;
      size_t index = array_index(entry->key);
      if (index && index <= size) {
         table->array[index - 1] = entry->value;
         entry->value = tl_nil;
         --table->entries_used;
      }
   }
}

tl_Value tl_table(tl_State *L, size_t array, size_t entries) {
   tl_Table *table = tl_allocate(L, sizeof *table, TL_TABLE);
   if (array) resize_array(L, table, array);
   if (entries) {
      size_t capacity = 8;
      while (entries > capacity / 2) capacity *= 2;
      resize_hash(L, table, capacity);
   }
   return tl_object(&table->header);
}

tl_Value tl_rawget(tl_Value object, tl_Value key) {
   if (object.type != TL_TABLE || key.type == TL_NIL) return tl_nil;
   tl_Table *table = object.as.table;
   size_t index = array_index(key);
   if (index && index <= table->array_size) return table->array[index - 1];
   if (!table->capacity) return tl_nil;
   return find_entry(table, key)->value;
}

void tl_rawput(tl_State *L, tl_Value object, tl_Value key, tl_Value value) {
   if (object.type != TL_TABLE) tl_fail(L, "attempt to index a %s value", tl_typename(object));
   if (key.type == TL_NIL || (key.type == TL_NUMBER && isnan(key.as.number))) tl_fail(L, "invalid table key");
   tl_Table *table = object.as.table;
   size_t index = array_index(key);
   if (index && (index <= table->array_size || (index <= 8 + 2 * table->array_size && value.type != TL_NIL))) {
      if (index > table->array_size) {
         size_t size = table->array_size ? table->array_size * 2 : 8;
         if (size < index) size = index;
         resize_array(L, table, size);
      }
      table->array[index - 1] = value;
      if (index == table->length + 1 && value.type != TL_NIL) {
         size_t next = index;
         while (next < table->array_size && table->array[next].type != TL_NIL) ++next;
         table->length = next;
      } else if (index == table->length && value.type == TL_NIL) {
         while (table->length && table->array[table->length - 1].type == TL_NIL) --table->length;
      }
      return;
   }

   if (!table->capacity) {
      if (value.type == TL_NIL) return;
      resize_hash(L, table, 8);
   }
   tl_Entry *entry = find_entry(table, key);
   if (entry->key.type == TL_NIL) {
      if (value.type == TL_NIL) return;
      if ((table->occupied + 1) * 4 > table->capacity * 3) {
         size_t size = table->entries_used > table->capacity / 2 ? table->capacity * 2 : table->capacity;
         resize_hash(L, table, size);
         entry = find_entry(table, key);
      }
      entry->key = key;
      ++table->occupied;
   }
   if (entry->value.type == TL_NIL && value.type != TL_NIL) ++table->entries_used;
   if (entry->value.type != TL_NIL && value.type == TL_NIL) --table->entries_used;
   entry->value = value;
}

bool tl_next(tl_State *L, tl_Value object, tl_Value previous, tl_Value *key, tl_Value *value) {
   if (object.type != TL_TABLE) tl_fail(L, "table expected for next");
   tl_Table *table = object.as.table;
   size_t hash = 0;
   size_t index = array_index(previous);
   if (previous.type != TL_NIL && (!index || index > table->array_size)) {
      if (!table->capacity) tl_fail(L, "invalid key to next");
      tl_Entry *entry = find_entry(table, previous);
      if (entry->key.type == TL_NIL) tl_fail(L, "invalid key to next");
      hash = (size_t)(entry - table->entries) + 1;
      index = table->array_size;
   }
   for (; index < table->array_size; ++index) {
      if (table->array[index].type != TL_NIL) {
         *key = tl_numeric((double)index + 1);
         *value = table->array[index];
         return true;
      }
   }
   for (; hash < table->capacity; ++hash) {
      if (table->entries[hash].value.type != TL_NIL) {
         *key = table->entries[hash].key;
         *value = table->entries[hash].value;
         return true;
      }
   }
   return false;
}

tl_Value tl_getkey(tl_State *L, tl_Value object, tl_Value key) {
   for (int chain = 0; chain < 100; ++chain) {
      tl_Value index;
      if (object.type == TL_TABLE) {
         tl_Value direct = tl_rawget(object, key);
         if (direct.type != TL_NIL) return direct;
         index = metamethod(L, object, "__index");
         if (index.type == TL_NIL) return tl_nil;
      } else if (object.type == TL_STRING) {
         return tl_rawget(L->string_lib, key);
      } else if (object.type == TL_FILE) {
         return tl_rawget(L->file_lib, key);
      } else {
         tl_fail(L, "attempt to index a %s value", tl_typename(object));
      }
      if (index.type == TL_FUNCTION) {
         tl_push(L, index);
         tl_push(L, object);
         tl_push(L, key);
         tl_call(L, 2, 1);
         tl_Value result = tl_at(L, -1);
         tl_pop(L, 1);
         return result;
      }
      object = index;
   }
   tl_fail(L, "__index chain too long");
}

void tl_putkey(tl_State *L, tl_Value object, tl_Value key, tl_Value value) {
   for (int chain = 0; chain < 100; ++chain) {
      if (object.type != TL_TABLE) tl_fail(L, "attempt to index a %s value", tl_typename(object));
      tl_Value newindex = metamethod(L, object, "__newindex");
      if (newindex.type == TL_NIL || tl_rawget(object, key).type != TL_NIL) {
         tl_rawput(L, object, key, value);
         return;
      }
      if (newindex.type == TL_FUNCTION) {
         tl_push(L, newindex);
         tl_push(L, object);
         tl_push(L, key);
         tl_push(L, value);
         tl_call(L, 3, 0);
         return;
      }
      object = newindex;
   }
   tl_fail(L, "__newindex chain too long");
}

tl_Value tl_field(tl_State *L, tl_Value object, const char *name) {
   return tl_getkey(L, object, tl_cstring(L, name));
}

void tl_putfield(tl_State *L, tl_Value object, const char *name, tl_Value value) {
   tl_rawput(L, object, tl_cstring(L, name), value);
}

void tl_getfield(tl_State *L, int i, const char *name) {
   tl_push(L, tl_field(L, tl_at(L, i), name));
}

void tl_setfield(tl_State *L, int i, const char *name) {
   tl_putkey(L, tl_at(L, i), tl_cstring(L, name), tl_at(L, -1));
   tl_pop(L, 1);
}

void tl_getliteral(tl_State *L, int i, const char *name, size_t len) {
   tl_push(L, tl_getkey(L, tl_at(L, i), literal(L, name, len)));
}

void tl_setliteral(tl_State *L, int i, const char *name, size_t len) {
   tl_putkey(L, tl_at(L, i), literal(L, name, len), tl_at(L, -1));
   tl_pop(L, 1);
}

void tl_getglobal(tl_State *L, const char *name) { tl_getfield(L, TL_GLOBALS, name); }
void tl_setglobal(tl_State *L, const char *name) { tl_setfield(L, TL_GLOBALS, name); }

void tl_gettable(tl_State *L, int i) {
   tl_Value result = tl_getkey(L, tl_at(L, i), tl_at(L, -1));
   L->stack[L->top - 1] = result;
}

void tl_settable(tl_State *L, int i) {
   tl_putkey(L, tl_at(L, i), tl_at(L, -2), tl_at(L, -1));
   tl_pop(L, 2);
}

void tl_rawset(tl_State *L, int i) {
   tl_rawput(L, tl_at(L, i), tl_at(L, -2), tl_at(L, -1));
   tl_pop(L, 2);
}

void tl_rawgeti(tl_State *L, int i, int key) { tl_push(L, tl_rawget(tl_at(L, i), tl_numeric(key))); }

void tl_rawseti(tl_State *L, int i, int key) {
   tl_rawput(L, tl_at(L, i), tl_numeric(key), tl_at(L, -1));
   tl_pop(L, 1);
}

void tl_createtable(tl_State *L, int array, int entries) {
   tl_push(L, tl_table(L, (size_t)array, (size_t)entries));
}

void tl_newtable(tl_State *L) { tl_createtable(L, 0, 0); }

void tl_frame(tl_State *L, int slots) {
   if (!slots) return;
   tl_reserve(L, slots);
   memset(L->stack + L->top, 0, (size_t)slots * sizeof(tl_Value));
   L->top += slots;
}

void tl_capture(tl_State *L, int frame, int slot) {
   tl_Value *target = tl_slot(L, frame, slot);
   if (target->type != TL_CELL) {
      tl_Cell *cell = tl_allocate(L, sizeof *cell, TL_CELL);
      cell->value = *target;
      *target = tl_object(&cell->header);
   }
   tl_push(L, *target);
}

void tl_vararg(tl_State *L, int argc, int fixed, int wanted) {
   int have = argc > fixed ? argc - fixed : 0;
   int count = wanted == TL_MULTRET ? have : wanted;
   for (int i = 1; i <= count; ++i) tl_push(L, i <= have ? tl_at(L, fixed + i) : tl_nil);
}

void tl_array_tail(tl_State *L, int table, int next) {
   tl_Value array = tl_at(L, table);
   int last = tl_gettop(L);
   for (int i = table + 1; i <= last; ++i) tl_rawput(L, array, tl_numeric(next++), tl_at(L, i));
   tl_settop(L, table);
}

static tl_Value invoke_method(tl_State *L, tl_Value method, tl_Value a, tl_Value b, int operands) {
   tl_push(L, method);
   tl_push(L, a);
   if (operands == 2) tl_push(L, b);
   tl_call(L, operands, 1);
   tl_Value result = tl_at(L, -1);
   tl_pop(L, 1);
   return result;
}

static tl_Value binary_method(tl_State *L, tl_Value a, tl_Value b, const char *name) {
   tl_Value method = metamethod(L, a, name);
   return method.type != TL_NIL ? method : metamethod(L, b, name);
}

size_t tl_length(tl_State *L, tl_Value value) {
   if (value.type == TL_STRING) return value.as.string->length;
   if (value.type == TL_TABLE) {
      tl_Value method = metamethod(L, value, "__len");
      if (method.type == TL_NIL) return value.as.table->length;
      tl_Value result = invoke_method(L, method, value, tl_nil, 1);
      if (result.type == TL_NUMBER && result.as.number >= 0 && result.as.number <= INT32_MAX)
         return (size_t)result.as.number;
   }
   tl_fail(L, "cannot get length of %s", tl_typename(value));
}

static int compare_strings(tl_String *a, tl_String *b) {
   size_t n = a->length < b->length ? a->length : b->length;
   int cmp = memcmp(a->bytes, b->bytes, n);
   if (cmp) return cmp;
   return a->length > b->length ? 1 : a->length < b->length ? -1 : 0;
}

static bool compare(tl_State *L, tl_Value a, tl_Value b, bool or_equal) {
   if (a.type == TL_NUMBER && b.type == TL_NUMBER)
      return or_equal ? a.as.number <= b.as.number : a.as.number < b.as.number;
   if (a.type == TL_STRING && b.type == TL_STRING)
      return or_equal ? compare_strings(a.as.string, b.as.string) <= 0 : compare_strings(a.as.string, b.as.string) < 0;
   tl_Value method = binary_method(L, a, b, or_equal ? "__le" : "__lt");
   if (method.type != TL_NIL) return tl_truth(invoke_method(L, method, a, b, 2));
   if (or_equal) {
      method = binary_method(L, b, a, "__lt");
      if (method.type != TL_NIL) return !tl_truth(invoke_method(L, method, b, a, 2));
   }
   tl_fail(L, "attempt to compare %s and %s", tl_typename(a), tl_typename(b));
}

bool tl_less(tl_State *L, tl_Value a, tl_Value b) { return compare(L, a, b, false); }

static tl_Value operation(tl_State *L, enum tl_Operation op, tl_Value a, tl_Value b, int operands) {
   if (op == TL_LEN) return tl_numeric((double)tl_length(L, a));
   if (op == TL_EQ || op == TL_NE) {
      bool equal = tl_equal(a, b);
      if (!equal && a.type == TL_TABLE && b.type == TL_TABLE) {
         tl_Value method = metamethod(L, a, "__eq");
         if (method.type != TL_NIL && tl_equal(method, metamethod(L, b, "__eq")))
            equal = tl_truth(invoke_method(L, method, a, b, 2));
      }
      return tl_boolean(op == TL_EQ ? equal : !equal);
   }
   if (op >= TL_LT) {
      if (op == TL_GT || op == TL_GE) return tl_boolean(compare(L, b, a, op == TL_GE));
      return tl_boolean(compare(L, a, b, op == TL_LE));
   }

   double left, right = 0;
   if (tl_number(a, &left) && (operands == 1 || tl_number(b, &right))) {
      switch (op) {
         case TL_ADD: return tl_numeric(left + right);
         case TL_SUB: return tl_numeric(left - right);
         case TL_MUL: return tl_numeric(left * right);
         case TL_DIV: return tl_numeric(left / right);
         case TL_MOD: {
            double res = fmod(left, right);
            if (res != 0 && ((res < 0) != (right < 0))) res += right;
            return tl_numeric(res);
         }
         case TL_POW: return tl_numeric(pow(left, right));
         case TL_NEG: return tl_numeric(-left);
         default: break;
      }
   }
   static const char *const methods[] = { "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm" };
   tl_Value method = binary_method(L, a, b, methods[op]);
   if (method.type == TL_NIL) tl_fail(L, "attempt to do arithmetic on %s and %s", tl_typename(a), tl_typename(b));
   return invoke_method(L, method, a, b, operands);
}

void tl_op(tl_State *L, enum tl_Operation op, int operands) {
   tl_Value result = operation(L, op, tl_at(L, -operands), operands == 2 ? tl_at(L, -1) : tl_nil, operands);
   tl_pop(L, operands);
   tl_push(L, result);
}

void tl_buffer_add(tl_State *L, tl_Buffer *buffer, const char *bytes, size_t len) {
   if (!len) return;
   if (len > SIZE_MAX - buffer->length) tl_fail(L, "string too large");
   size_t need = buffer->length + len;
   if (need > buffer->capacity) {
      size_t capacity = buffer->capacity ? buffer->capacity : 64;
      while (capacity < need) {
         if (capacity > SIZE_MAX / 2) tl_fail(L, "string too large");
         capacity *= 2;
      }
      buffer->data = tl_resize(L, buffer->data, capacity);
      buffer->capacity = capacity;
   }
   memcpy(buffer->data + buffer->length, bytes, len);
   buffer->length = need;
}

void tl_buffer_byte(tl_State *L, tl_Buffer *buffer, char byte) {
   tl_buffer_add(L, buffer, &byte, 1);
}

void tl_buffer_push(tl_State *L, tl_Buffer *buffer) {
   tl_pushlstring(L, buffer->data ? buffer->data : "", buffer->length);
   free(buffer->data);
   *buffer = (tl_Buffer){0};
}

void tl_concat(tl_State *L, int values) {
   if (values == 0) {
      tl_pushlstring(L, "", 0);
      return;
   }
   if (values != 2) tl_fail(L, "invalid concatenate count");
   tl_Value a = tl_at(L, -2);
   tl_Value b = tl_at(L, -1);
   tl_String *sa = tl_asstring(L, a);
   tl_String *sb = tl_asstring(L, b);
   tl_Value result;
   if (sa && sb) {
      tl_Buffer buffer = {0};
      tl_buffer_add(L, &buffer, sa->bytes, sa->length);
      tl_buffer_add(L, &buffer, sb->bytes, sb->length);
      tl_buffer_push(L, &buffer);
      result = tl_at(L, -1);
      tl_pop(L, 1);
   } else {
      tl_Value method = binary_method(L, a, b, "__concat");
      if (method.type == TL_NIL) tl_fail(L, "attempt to concatenate %s and %s", tl_typename(a), tl_typename(b));
      result = invoke_method(L, method, a, b, 2);
   }
   tl_pop(L, 2);
   tl_push(L, result);
}
