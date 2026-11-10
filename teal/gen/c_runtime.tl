--#pragma strict_nil off
local record c_runtime
   namespaces: {string:boolean}
   builtins: {string:boolean}
   array_type: string
end

c_runtime.namespaces = { math = true, string = true, table = true }
c_runtime.builtins = {
   math = true, string = true, table = true, ipairs = true,
   print = true, tostring = true, tonumber = true, type = true, assert = true, error = true,
}

local panic = [[
static _Noreturn void tl_native_panic(const char *message) {
   fputs(message, stderr);
   fputc('\n', stderr);
   exit(EXIT_FAILURE);
}
]]

local sizes = [[
static size_t tl_native_size_add(size_t a, size_t b) {
   size_t result;
   if (__builtin_add_overflow(a, b, &result)) tl_native_panic("native size overflow");
   return result;
}

static __attribute__((unused)) size_t tl_native_size_mul(size_t a, size_t b) {
   size_t result;
   if (__builtin_mul_overflow(a, b, &result)) tl_native_panic("native size overflow");
   return result;
}
]]

local allocation = [[
typedef struct tl_native_allocation {
   struct tl_native_allocation *next;
   max_align_t alignment;
} tl_native_allocation;

static tl_native_allocation *tl_native_allocations;

static void tl_native_cleanup(void) {
   while (tl_native_allocations) {
      tl_native_allocation *allocation = tl_native_allocations;
      tl_native_allocations = allocation->next;
      free(allocation);
   }
}

static void *tl_native_alloc(size_t size) {
   tl_native_allocation *allocation = calloc(1, tl_native_size_add(sizeof(*allocation), size));
   if (!allocation) tl_native_panic("native allocation failed");
   if (!tl_native_allocations && atexit(tl_native_cleanup)) tl_native_panic("native cleanup registration failed");
   allocation->next = tl_native_allocations;
   tl_native_allocations = allocation;
   return allocation + 1;
}
]]

c_runtime.array_type = [[
typedef struct {
   size_t length;
   size_t capacity;
   size_t width;
   void *data;
} tl_native_array;
]]

local arrays = [[
static void tl_native_array_reserve(tl_native_array *array, size_t length) {
   if ((uintmax_t)length > (uintmax_t)INT64_MAX) tl_native_panic("array length overflow");
   if (length <= array->capacity) return;
   size_t doubled;
   size_t capacity = length;
   if (!__builtin_mul_overflow(array->capacity, (size_t)2, &doubled) &&
       (uintmax_t)doubled <= (uintmax_t)INT64_MAX && doubled > capacity) capacity = doubled;
   void *data = tl_native_alloc(tl_native_size_mul(capacity, array->width));
   if (array->length) memcpy(data, array->data, array->length * array->width);
   array->capacity = capacity;
   array->data = data;
}

static __attribute__((unused)) tl_native_array *tl_native_array_new(size_t width, size_t length) {
   tl_native_array *array = tl_native_alloc(sizeof(*array));
   array->width = width;
   tl_native_array_reserve(array, length);
   array->length = length;
   return array;
}

static __attribute__((unused)) void *tl_native_array_slot(tl_native_array *array, int64_t index, _Bool append) {
   if (index < 1 || (uint64_t)index > (uint64_t)array->length + (uint64_t)append)
      tl_native_panic("array index out of bounds");
   if ((uint64_t)index > array->length) {
      size_t length = tl_native_size_add(array->length, 1);
      tl_native_array_reserve(array, length);
      array->length = length;
   }
   return (unsigned char *)array->data + (size_t)(index - 1) * array->width;
}

static __attribute__((unused)) int64_t tl_native_array_append_index(tl_native_array *array) {
   if ((uintmax_t)array->length >= (uintmax_t)INT64_MAX) tl_native_panic("array length overflow");
   return (int64_t)array->length + 1;
}

static __attribute__((unused)) void tl_native_array_insert(tl_native_array *array, int64_t index, const void *value) {
   if (index < 1 || (uint64_t)index > (uint64_t)array->length + 1)
      tl_native_panic("table.insert position out of bounds");
   tl_native_array_reserve(array, tl_native_size_add(array->length, 1));
   size_t offset = (size_t)(index - 1);
   unsigned char *slot = (unsigned char *)array->data + offset * array->width;
   memmove(slot + array->width, slot, (array->length - offset) * array->width);
   memcpy(slot, value, array->width);
   ++array->length;
}

static __attribute__((unused)) _Bool tl_native_array_remove(tl_native_array *array, int64_t index, void *value) {
   if ((index == 0 && !array->length) || (index > 0 && (uint64_t)index == (uint64_t)array->length + 1))
      return 0;
   if (index < 1 || (uint64_t)index > array->length) tl_native_panic("table.remove position out of bounds");
   unsigned char *slot = (unsigned char *)array->data + (size_t)(index - 1) * array->width;
   memcpy(value, slot, array->width);
   memmove(slot, slot + array->width, (array->length - (size_t)index) * array->width);
   --array->length;
   return 1;
}
]]

local strings = [[
static char *tl_native_string_alloc(size_t length) {
   return tl_native_alloc(tl_native_size_add(length, 1));
}

static __attribute__((unused)) const char *tl_native_concat(const char *a, const char *b) {
   size_t a_len = strlen(a), b_len = strlen(b);
   char *result = tl_native_string_alloc(tl_native_size_add(a_len, b_len));
   memcpy(result, a, a_len);
   memcpy(result + a_len, b, b_len);
   return result;
}

static __attribute__((unused)) const char *tl_native_sub(const char *text, int64_t first, int64_t last) {
   int64_t length = (int64_t)strlen(text);
   if (first < 0) first = length + first + 1;
   if (last < 0) last = length + last + 1;
   if (first < 1) first = 1;
   if (last > length) last = length;
   if (first > last) return "";
   size_t count = (size_t)(last - first + 1);
   char *result = tl_native_string_alloc(count);
   memcpy(result, text + first - 1, count);
   return result;
}

static __attribute__((unused)) const char *tl_native_rep(const char *text, int64_t count, const char *separator) {
   if (count <= 0) return "";
   if (!separator) separator = "";
   size_t length = strlen(text), sep_len = strlen(separator);
   if (!length && !sep_len) return "";
   if ((int64_t)(size_t)count != count) tl_native_panic("string repetition overflow");
   size_t bytes = tl_native_size_add(tl_native_size_mul(length, (size_t)count),
                                     tl_native_size_mul(sep_len, (size_t)count - 1));
   char *result = tl_native_string_alloc(bytes), *out = result;
   for (int64_t i = 0; i < count; ++i) {
      if (i) {
         memcpy(out, separator, sep_len);
         out += sep_len;
      }
      memcpy(out, text, length);
      out += length;
   }
   return result;
}

static __attribute__((unused)) const char *tl_native_string_transform(const char *text, int mode) {
   size_t length = strlen(text);
   char *result = tl_native_string_alloc(length);
   for (size_t i = 0; i < length; ++i) {
      unsigned char byte = (unsigned char)text[i];
      if (mode == 0) result[i] = (char)tolower(byte);
      else if (mode == 1) result[i] = (char)toupper(byte);
      else result[length - i - 1] = (char)byte;
   }
   return result;
}

static __attribute__((unused)) const char *tl_native_integer_string(int64_t value) {
   char buffer[32];
   int length = snprintf(buffer, sizeof(buffer), "%lld", (long long)value);
   char *result = tl_native_string_alloc((size_t)length);
   memcpy(result, buffer, (size_t)length);
   return result;
}

static __attribute__((unused)) const char *tl_native_number_string(double value) {
   char buffer[64];
   int length = snprintf(buffer, sizeof(buffer), "%.14g", value);
   if (__builtin_isfinite(value) && !strpbrk(buffer, ".eE")) {
      buffer[length++] = '.';
      buffer[length++] = '0';
   }
   char *result = tl_native_string_alloc((size_t)length);
   memcpy(result, buffer, (size_t)length);
   return result;
}
]]

local parsing = [[
static _Bool tl_native_parse_number(const char *text, double *value) {
   if (!text) return 0;
   while (isspace((unsigned char)*text)) ++text;
   const char *start = text;
   if (*start == '+' || *start == '-') ++start;
   if (!isdigit((unsigned char)*start) && *start != '.') return 0;
   char *end;
   *value = strtod(text, &end);
   if (end == text) return 0;
   while (isspace((unsigned char)*end)) ++end;
   return !*end;
}
]]

local math_integer = [[
static int64_t tl_native_math_integer(double value) {
   if (!(value >= -0x1p63 && value < 0x1p63)) tl_native_panic("math result does not fit in integer");
   return (int64_t)value;
}
]]

local print_number = [[
static void tl_native_print_number(double value) {
   char buffer[64];
   snprintf(buffer, sizeof(buffer), "%.14g", value);
   fputs(buffer, stdout);
   if (__builtin_isfinite(value) && !strpbrk(buffer, ".eE")) fputs(".0", stdout);
}
]]

local table_concat = [[
static const char *tl_native_table_concat(tl_native_array *array, const char *separator, int64_t first, int64_t last) {
   if (first > last) return "";
   if (first < 1 || (uint64_t)last > array->length) tl_native_panic("table.concat range out of bounds");
   if (!separator) separator = "";
   const char *const *items = array->data;
   size_t sep_len = strlen(separator);
   size_t length = tl_native_size_mul(sep_len, (size_t)(last - first));
   for (int64_t i = first - 1; i < last; ++i) length = tl_native_size_add(length, strlen(items[i]));
   char *result = tl_native_string_alloc(length), *out = result;
   for (int64_t i = first - 1; i < last; ++i) {
      if (i >= first) {
         memcpy(out, separator, sep_len);
         out += sep_len;
      }
      size_t bytes = strlen(items[i]);
      memcpy(out, items[i], bytes);
      out += bytes;
   }
   return result;
}
]]

function c_runtime.uses_allocation(used: {string:boolean}): boolean
   return used.alloc or used.array or used.strings or used.table_concat or false
end

function c_runtime.emit(used: {string:boolean}, shared?: boolean, provides_allocator?: boolean): {string}
   local result: {string} = {}
   local uses_strings = used.strings or used.table_concat
   local defines_allocator = provides_allocator or (not shared and c_runtime.uses_allocation(used))
   local uses_sizes = defines_allocator or used.array or uses_strings
   local uses_panic = used.panic or uses_sizes or used.math_integer
   if used.print or uses_panic then table.insert(result, "#include <stdio.h>") end
   if uses_panic or used.parse_number then table.insert(result, "#include <stdlib.h>") end
   if uses_strings or used.array or used.print_number then table.insert(result, "#include <string.h>") end
   if uses_strings or used.parse_number then table.insert(result, "#include <ctype.h>") end
   if #result > 0 then table.insert(result, "") end
   if uses_panic then table.insert(result, panic) end
   if uses_sizes then table.insert(result, sizes) end
   if defines_allocator then
      local implementation = allocation
      if shared then implementation = implementation:gsub("static void %*tl_native_alloc", "void *tl_native_alloc", 1) end
      table.insert(result, implementation)
   end
   if used.array then
      if not shared then table.insert(result, c_runtime.array_type) end
      table.insert(result, arrays)
   end
   if uses_strings then table.insert(result, strings) end
   if used.parse_number then table.insert(result, parsing) end
   if used.math_integer then table.insert(result, math_integer) end
   if used.table_concat then table.insert(result, table_concat) end
   if used.print_number then table.insert(result, print_number) end
   return result
end

return c_runtime
