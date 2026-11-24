#ifndef TL_RUNTIME_H
#define TL_RUNTIME_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <stdio.h>

typedef struct tl_State tl_State;
typedef struct tl_Object tl_Object;
typedef struct tl_Table tl_Table;
typedef struct tl_String tl_String;
typedef int (*tl_CFunction)(tl_State *);

typedef enum tl_Type {
   TL_NIL, TL_BOOLEAN, TL_NUMBER, TL_STRING, TL_TABLE, TL_FUNCTION, TL_FILE,
   TL_CELL, TL_FOREIGN
} tl_Type;

typedef struct tl_Value {
   union {
      double number;
      tl_Object *object;
      tl_Table *table;
      tl_String *string;
      bool boolean;
   } as;
   tl_Type type;
} tl_Value;

enum { TL_GLOBALS = -1000000000, TL_CAPTURES = -1000000001, TL_MULTRET = -1 };
enum tl_Operation {
   TL_ADD, TL_SUB, TL_MUL, TL_DIV, TL_MOD, TL_POW, TL_NEG, TL_LEN,
   TL_EQ, TL_NE, TL_LT, TL_LE, TL_GT, TL_GE
};

struct tl_Object {
   tl_Object *next;
   tl_Type type;
   bool marked;
};

struct tl_String {
   tl_Object header;
   size_t length;
   uint32_t hash;
   char bytes[];
};

typedef struct tl_Entry {
   tl_Value key;
   tl_Value value;
} tl_Entry;

struct tl_Table {
   tl_Object header;
   tl_Value *array;
   tl_Entry *entries;
   tl_Table *meta;
   size_t array_size;
   size_t capacity;
   size_t occupied;
   size_t entries_used;
   size_t length;
};

typedef struct tl_Function {
   tl_Object header;
   tl_CFunction code;
   tl_Value closure;
   void *data;
   void (*destroy)(tl_State *, void *);
} tl_Function;

typedef struct tl_Cell {
   tl_Object header;
   tl_Value value;
} tl_Cell;

typedef struct tl_Literal {
   const char *data;
   tl_String *string;
} tl_Literal;

typedef struct tl_File {
   tl_Object header;
   FILE *file;
   int (*close)(FILE *);
} tl_File;

typedef struct tl_Foreign {
   tl_Object header;
   void *data;
   void (*destroy)(tl_State *, void *);
} tl_Foreign;

typedef struct tl_Protected {
   jmp_buf jump;
   struct tl_Protected *previous;
} tl_Protected;

struct tl_State {
   tl_Value *stack;
   int top;
   int base;
   int capacity;
   tl_Value current;
   tl_Value globals;
   tl_Value string_lib;
   tl_Value file_lib;
   tl_Value error;
   tl_Value default_in;
   tl_Value default_out;
   tl_Value script_roots;
   tl_Value mode_key;
   tl_Object *objects;
   tl_Protected *protected_call;
   tl_String **strings;
   tl_Literal literals[4096];
   size_t allocated;
   size_t collect_at;
   size_t string_capacity;
   size_t string_count;
   int depth;
   void *script;
};

static const tl_Value tl_nil = { .type = TL_NIL };

static inline tl_Value tl_numeric(double n) {
   return (tl_Value){ .as.number = n, .type = TL_NUMBER };
}

static inline tl_Value tl_boolean(bool b) {
   return (tl_Value){ .as.boolean = b, .type = TL_BOOLEAN };
}

static inline tl_Value tl_object(tl_Object *o) {
   return (tl_Value){ .as.object = o, .type = o->type };
}

static inline int tl_gettop(const tl_State *L) { return L->top - L->base; }

static inline int tl_absolute(const tl_State *L, int i) {
   return i < 0 && i > TL_GLOBALS ? tl_gettop(L) + i + 1 : i;
}

static inline bool tl_truth(tl_Value v) {
   return v.type != TL_NIL && (v.type != TL_BOOLEAN || v.as.boolean);
}

static inline tl_Value tl_at(tl_State *L, int i) {
   if (i == TL_GLOBALS) return L->globals;
   if (i == TL_CAPTURES) return ((tl_Function *)L->current.as.object)->closure;
   int index = tl_absolute(L, i);
   return index > 0 && index <= tl_gettop(L) ? L->stack[L->base + index - 1] : tl_nil;
}
void *tl_allocate(tl_State *, size_t, tl_Type);
void *tl_resize(tl_State *, void *, size_t);
void tl_reserve(tl_State *, int);
void tl_settop(tl_State *, int);

static inline void tl_push(tl_State *L, tl_Value v) {
   if (L->top == L->capacity) tl_reserve(L, 1);
   L->stack[L->top++] = v;
}

static inline void tl_pop(tl_State *L, int n) { L->top -= n; }
static inline void tl_pushnil(tl_State *L) { tl_push(L, tl_nil); }
static inline void tl_pushnumber(tl_State *L, double n) { tl_push(L, tl_numeric(n)); }
static inline void tl_pushinteger(tl_State *L, int64_t i) { tl_pushnumber(L, (double)i); }
static inline void tl_pushboolean(tl_State *L, bool b) { tl_push(L, tl_boolean(b)); }
static inline void tl_pushvalue(tl_State *L, int i) { tl_push(L, tl_at(L, i)); }
static inline bool tl_isnil(tl_State *L, int i) { return tl_at(L, i).type == TL_NIL; }
static inline bool tl_toboolean(tl_State *L, int i) { return tl_truth(tl_at(L, i)); }

tl_State *tl_newstate(void);
void tl_close(tl_State *);
void tl_collect(tl_State *);
void tl_insert(tl_State *, int);
void tl_remove(tl_State *, int);
void tl_replace(tl_State *, int);
void tl_pushcclosure(tl_State *, tl_CFunction, int);
void tl_pushcfunction(tl_State *, tl_CFunction);
void tl_call(tl_State *, int args, int results);
int tl_pcall(tl_State *, int args, int results);
_Noreturn void tl_fail(tl_State *, const char *, ...);
_Noreturn void tl_raise(tl_State *, tl_Value);
const char *tl_typename(tl_Value);
double tl_checknumber(tl_State *, int);
int64_t tl_checkinteger(tl_State *, int);
bool tl_number(tl_Value, double *);
bool tl_equal(tl_Value, tl_Value);
bool tl_less(tl_State *, tl_Value, tl_Value);
size_t tl_length(tl_State *, tl_Value);

tl_Value tl_string(tl_State *, const char *, size_t);
tl_Value tl_cstring(tl_State *, const char *);
tl_String *tl_asstring(tl_State *, tl_Value);
tl_String *tl_checkstring(tl_State *, int);
const char *tl_bytes(tl_State *, int);
void tl_pushlstring(tl_State *, const char *, size_t);
void tl_pushstring(tl_State *, const char *);
void tl_pushliteral(tl_State *, const char *, size_t);
void tl_concat(tl_State *, int);

tl_Value tl_table(tl_State *, size_t, size_t);
tl_Value tl_rawget(tl_Value, tl_Value);
tl_Value tl_getkey(tl_State *, tl_Value, tl_Value);
void tl_rawput(tl_State *, tl_Value, tl_Value, tl_Value);
void tl_putkey(tl_State *, tl_Value, tl_Value, tl_Value);
bool tl_next(tl_State *, tl_Value, tl_Value, tl_Value *, tl_Value *);
void tl_createtable(tl_State *, int, int);
void tl_newtable(tl_State *);
void tl_getfield(tl_State *, int, const char *);
void tl_setfield(tl_State *, int, const char *);
void tl_getliteral(tl_State *, int, const char *, size_t);
void tl_setliteral(tl_State *, int, const char *, size_t);
void tl_gettable(tl_State *, int);
void tl_settable(tl_State *, int);
void tl_rawset(tl_State *, int);
void tl_rawgeti(tl_State *, int, int);
void tl_rawseti(tl_State *, int, int);
tl_Value tl_field(tl_State *, tl_Value, const char *);
void tl_putfield(tl_State *, tl_Value, const char *, tl_Value);
void tl_getglobal(tl_State *, const char *);
void tl_setglobal(tl_State *, const char *);

void tl_frame(tl_State *, int);
static inline tl_Value *tl_slot(tl_State *L, int frame, int slot) {
   if (frame == TL_CAPTURES) return &tl_at(L, frame).as.table->array[slot - 1];
   return &L->stack[L->base + frame + slot - 2];
}

static inline void tl_local(tl_State *L, int frame, int slot, int value) {
   *tl_slot(L, frame, slot) = tl_at(L, value);
}

static inline void tl_get(tl_State *L, int frame, int slot) {
   tl_Value value = *tl_slot(L, frame, slot);
   if (value.type == TL_CELL) value = ((tl_Cell *)value.as.object)->value;
   tl_push(L, value);
}

static inline void tl_set(tl_State *L, int frame, int slot, int value) {
   tl_Value *target = tl_slot(L, frame, slot);
   if (target->type == TL_CELL) target = &((tl_Cell *)target->as.object)->value;
   *target = tl_at(L, value);
}
void tl_capture(tl_State *, int frame, int slot);
void tl_vararg(tl_State *, int argc, int fixed, int wanted);
void tl_array_tail(tl_State *, int array, int start);
void tl_op(tl_State *, enum tl_Operation, int operands);

static inline bool tl_test(tl_State *L) {
   bool value = tl_toboolean(L, -1);
   tl_pop(L, 1);
   return value;
}

typedef struct tl_Library {
   const char *name;
   tl_CFunction code;
} tl_Library;

void tl_library(tl_State *, tl_Value, const tl_Library *);
void tl_preload(tl_State *, const char *, tl_CFunction);
void tl_openlibs(tl_State *);
void tl_openstrings(tl_State *);
void tl_opensystem(tl_State *);
int tl_loadscript(tl_State *);
void tl_closescript(tl_State *);
int tl_load_lua_module(tl_State *);

typedef struct tl_Buffer {
   char *data;
   size_t length;
   size_t capacity;
} tl_Buffer;

void tl_buffer_add(tl_State *, tl_Buffer *, const char *, size_t);
void tl_buffer_byte(tl_State *, tl_Buffer *, char);
void tl_buffer_push(tl_State *, tl_Buffer *);

#endif
