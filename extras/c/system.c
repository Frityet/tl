#define _POSIX_C_SOURCE 200809L

#include "tl_runtime.h"

#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int system_error(tl_State *L, int error) {
   tl_pushnil(L);
   tl_pushstring(L, strerror(error));
   tl_pushinteger(L, error);
   return 3;
}

static tl_Value file_value(tl_State *L, FILE *file, int (*close)(FILE *)) {
   tl_File *handle = tl_allocate(L, sizeof *handle, TL_FILE);
   handle->file = file;
   handle->close = close;
   return tl_object(&handle->header);
}

static tl_File *get_file(tl_State *L, int index) {
   tl_Value value = tl_at(L, index);
   if (value.type != TL_FILE) tl_fail(L, "expected a file handle");
   tl_File *file = (tl_File *)value.as.object;
   if (!file->file) tl_fail(L, "attempt to use a closed file");
   return file;
}

static int io_open(tl_State *L) {
   const char *name = tl_bytes(L, 1);
   const char *mode = tl_isnil(L, 2) ? "r" : tl_bytes(L, 2);
   FILE *file = fopen(name, mode);
   if (!file) return system_error(L, errno);
   tl_push(L, file_value(L, file, fclose));
   return 1;
}

static int io_popen(tl_State *L) {
   const char *command = tl_bytes(L, 1);
   const char *mode = tl_isnil(L, 2) ? "r" : tl_bytes(L, 2);
   FILE *file = popen(command, mode);
   if (!file) return system_error(L, errno);
   tl_push(L, file_value(L, file, pclose));
   return 1;
}

static int io_tmpfile(tl_State *L) {
   FILE *file = tmpfile();
   if (!file) return system_error(L, errno);
   tl_push(L, file_value(L, file, fclose));
   return 1;
}

static int io_type(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   if (value.type != TL_FILE) tl_pushnil(L);
   else tl_pushstring(L, ((tl_File *)value.as.object)->file ? "file" : "closed file");
   return 1;
}

static int file_close(tl_State *L) {
   tl_File *handle = get_file(L, 1);
   if (!handle->close) {
      tl_pushnil(L);
      tl_pushstring(L, "cannot close standard file");
      return 2;
   }
   FILE *file = handle->file;
   handle->file = NULL;
   if (handle->close(file) == -1) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int file_flush(tl_State *L) {
   if (fflush(get_file(L, 1)->file) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static bool read_line(tl_State *L, FILE *file, bool newline) {
   tl_Buffer out = {0};
   int ch;
   while ((ch = getc(file)) != EOF) {
      if (ch == '\n') {
         if (newline) tl_buffer_byte(L, &out, (char)ch);
         break;
      }
      tl_buffer_byte(L, &out, (char)ch);
   }
   bool result = ch != EOF || out.length;
   if (result) tl_buffer_push(L, &out);
   else tl_pushnil(L);
   return result;
}

static bool read_bytes(tl_State *L, FILE *file, size_t count, bool all) {
   if (!count && !all) {
      int ch = getc(file);
      if (ch == EOF) {
         tl_pushnil(L);
         return false;
      }
      ungetc(ch, file);
      tl_pushlstring(L, "", 0);
      return true;
   }
   tl_Buffer out = {0};
   char piece[8192];
   while (all || count) {
      size_t request = all || count > sizeof piece ? sizeof piece : count;
      size_t got = fread(piece, 1, request, file);
      tl_buffer_add(L, &out, piece, got);
      if (got < request) break;
      if (!all) count -= got;
   }
   bool result = all || out.length;
   if (result) tl_buffer_push(L, &out);
   else tl_pushnil(L);
   return result;
}

static bool read_item(tl_State *L, FILE *file, tl_Value format) {
   if (format.type == TL_NIL) return read_line(L, file, false);
   if (format.type == TL_NUMBER) {
      if (!(format.as.number >= 0 && format.as.number <= INT32_MAX)) tl_fail(L, "invalid read count");
      return read_bytes(L, file, (size_t)format.as.number, false);
   }
   if (format.type != TL_STRING) tl_fail(L, "invalid format for read");
   const char *mode = format.as.string->bytes;
   if (*mode == '*') ++mode;
   if (!strcmp(mode, "a")) return read_bytes(L, file, 0, true);
   if (!strcmp(mode, "l")) return read_line(L, file, false);
   if (!strcmp(mode, "L")) return read_line(L, file, true);
   if (!strcmp(mode, "n")) {
      double number;
      if (fscanf(file, "%lf", &number) == 1) {
         tl_pushnumber(L, number);
         return true;
      }
      tl_pushnil(L);
      return false;
   }
   tl_fail(L, "invalid format for read");
}

static int file_read(tl_State *L) {
   FILE *file = get_file(L, 1)->file;
   int args = tl_gettop(L);
   int count = 0;
   do {
      bool result = read_item(L, file, tl_at(L, 2 + count));
      ++count;
      if (!result) break;
   } while (2 + count <= args);
   if (ferror(file)) return system_error(L, errno);
   return count;
}

static int file_write(tl_State *L) {
   FILE *file = get_file(L, 1)->file;
   int args = tl_gettop(L);
   for (int i = 2; i <= args; ++i) {
      tl_String *text = tl_checkstring(L, i);
      if (fwrite(text->bytes, 1, text->length, file) != text->length)
         return system_error(L, errno);
   }
   tl_pushvalue(L, 1);
   return 1;
}

static int file_seek(tl_State *L) {
   FILE *file = get_file(L, 1)->file;
   const char *origin = tl_isnil(L, 2) ? "cur" : tl_bytes(L, 2);
   off_t offset = tl_isnil(L, 3) ? 0 : (off_t)tl_checkinteger(L, 3);
   int whence;
   if (!strcmp(origin, "set")) whence = SEEK_SET;
   else if (!strcmp(origin, "cur")) whence = SEEK_CUR;
   else if (!strcmp(origin, "end")) whence = SEEK_END;
   else tl_fail(L, "invalid seek mode");
   if (fseeko(file, offset, whence) != 0) return system_error(L, errno);
   off_t result = ftello(file);
   if (result == (off_t)-1) return system_error(L, errno);
   tl_pushnumber(L, (double)result);
   return 1;
}

static int file_setvbuf(tl_State *L) {
   FILE *file = get_file(L, 1)->file;
   const char *mode = tl_bytes(L, 2);
   int buffer_mode;
   if (!strcmp(mode, "no")) buffer_mode = _IONBF;
   else if (!strcmp(mode, "line")) buffer_mode = _IOLBF;
   else if (!strcmp(mode, "full")) buffer_mode = _IOFBF;
   else tl_fail(L, "invalid buffering mode");
   int64_t size = tl_isnil(L, 3) ? BUFSIZ : tl_checkinteger(L, 3);
   if (size < 0) tl_fail(L, "invalid buffer size");
   if (setvbuf(file, NULL, buffer_mode, (size_t)size) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int io_read(tl_State *L) {
   tl_push(L, L->default_in);
   tl_insert(L, 1);
   return file_read(L);
}

static int io_write(tl_State *L) {
   tl_push(L, L->default_out);
   tl_insert(L, 1);
   return file_write(L);
}

static int io_close(tl_State *L) {
   if (tl_isnil(L, 1)) {
      tl_settop(L, 0);
      tl_push(L, L->default_out);
   }
   return file_close(L);
}

static int io_flush(tl_State *L) {
   tl_push(L, L->default_out);
   tl_insert(L, 1);
   return file_flush(L);
}

static int io_default(tl_State *L, bool input) {
   tl_Value *current = input ? &L->default_in : &L->default_out;
   tl_Value value = tl_at(L, 1);
   if (value.type == TL_STRING) {
      FILE *file = fopen(value.as.string->bytes, input ? "r" : "w");
      if (!file) tl_fail(L, "could not open %s: %s", value.as.string->bytes, strerror(errno));
      *current = file_value(L, file, fclose);
   } else if (value.type == TL_FILE) {
      get_file(L, 1);
      *current = value;
   } else if (value.type != TL_NIL) {
      tl_fail(L, "expected a file or path");
   }
   tl_push(L, *current);
   return 1;
}

static int io_input(tl_State *L) { return io_default(L, true); }
static int io_output(tl_State *L) { return io_default(L, false); }

static int os_getenv(tl_State *L) {
   tl_pushstring(L, getenv(tl_bytes(L, 1)));
   return 1;
}

static int os_time(tl_State *L) {
   if (!tl_isnil(L, 1)) tl_fail(L, "date table is unsupported in the native build");
   tl_pushnumber(L, (double)time(NULL));
   return 1;
}

static int os_clock(tl_State *L) {
   tl_pushnumber(L, (double)clock() / CLOCKS_PER_SEC);
   return 1;
}

static int os_difftime(tl_State *L) {
   tl_pushnumber(L, difftime((time_t)tl_checknumber(L, 1), (time_t)tl_checknumber(L, 2)));
   return 1;
}

static int os_date(tl_State *L) {
   const char *format = tl_isnil(L, 1) ? "%c" : tl_bytes(L, 1);
   time_t t = tl_isnil(L, 2) ? time(NULL) : (time_t)tl_checknumber(L, 2);
   struct tm time;
   struct tm *ok = *format == '!' ? gmtime_r(&t, &time) : localtime_r(&t, &time);
   if (*format == '!') ++format;
   if (!ok) tl_fail(L, "date out of range");
   if (!strcmp(format, "*t")) {
      tl_Value value = tl_table(L, 0, 10);
      tl_putfield(L, value, "year", tl_numeric(time.tm_year + 1900));
      tl_putfield(L, value, "month", tl_numeric(time.tm_mon + 1));
      tl_putfield(L, value, "day", tl_numeric(time.tm_mday));
      tl_putfield(L, value, "hour", tl_numeric(time.tm_hour));
      tl_putfield(L, value, "min", tl_numeric(time.tm_min));
      tl_putfield(L, value, "sec", tl_numeric(time.tm_sec));
      tl_putfield(L, value, "wday", tl_numeric(time.tm_wday + 1));
      tl_putfield(L, value, "yday", tl_numeric(time.tm_yday + 1));
      tl_putfield(L, value, "isdst", tl_boolean(time.tm_isdst > 0));
      tl_push(L, value);
   } else {
      char text[4096];
      size_t count = strftime(text, sizeof text, format, &time);
      tl_pushlstring(L, text, count);
   }
   return 1;
}

static int os_execute(tl_State *L) {
   const char *command = tl_isnil(L, 1) ? NULL : tl_bytes(L, 1);
   int status = system(command);
   tl_pushinteger(L, status);
   return 1;
}

static int os_remove(tl_State *L) {
   if (remove(tl_bytes(L, 1)) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int os_rename(tl_State *L) {
   if (rename(tl_bytes(L, 1), tl_bytes(L, 2)) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int os_tmpname(tl_State *L) {
   char name[] = "/tmp/teal_XXXXXX";
   int fd = mkstemp(name);
   if (fd < 0) tl_fail(L, "cannot make temporary file: %s", strerror(errno));
   close(fd);
   tl_pushstring(L, name);
   return 1;
}

static int os_exit(tl_State *L) {
   tl_Value value = tl_at(L, 1);
   int status = EXIT_SUCCESS;
   if (value.type == TL_BOOLEAN) status = value.as.boolean ? EXIT_SUCCESS : EXIT_FAILURE;
   else if (value.type != TL_NIL) status = (int)tl_checkinteger(L, 1);
   tl_close(L);
   exit(status);
}

static int lfs_currentdir(tl_State *L) {
   char *path = getcwd(NULL, 0);
   if (!path) return system_error(L, errno);
   tl_pushstring(L, path);
   free(path);
   return 1;
}

static int lfs_chdir(tl_State *L) {
   if (chdir(tl_bytes(L, 1)) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int lfs_mkdir(tl_State *L) {
   if (mkdir(tl_bytes(L, 1), 0777) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static int lfs_rmdir(tl_State *L) {
   if (rmdir(tl_bytes(L, 1)) != 0) return system_error(L, errno);
   tl_pushboolean(L, true);
   return 1;
}

static tl_Value stat_field(tl_State *L, const struct stat *state, const char *field) {
   if (!strcmp(field, "dev")) return tl_numeric((double)state->st_dev);
   if (!strcmp(field, "ino")) return tl_numeric((double)state->st_ino);
   if (!strcmp(field, "size")) return tl_numeric((double)state->st_size);
   if (!strcmp(field, "modification")) return tl_numeric((double)state->st_mtime);
   if (!strcmp(field, "access")) return tl_numeric((double)state->st_atime);
   if (!strcmp(field, "change")) return tl_numeric((double)state->st_ctime);
   if (!strcmp(field, "mode")) {
      const mode_t mode = state->st_mode;
      const char *type = S_ISREG(mode) ? "file" : S_ISDIR(mode) ? "directory"
         : S_ISLNK(mode) ? "link" : S_ISFIFO(mode) ? "named pipe" : "other";
      return tl_cstring(L, type);
   }
   return tl_nil;
}

static int lfs_stat(tl_State *L, bool follow) {
   const char *path = tl_bytes(L, 1);
   struct stat state;
   if ((follow ? stat(path, &state) : lstat(path, &state)) != 0)
      return system_error(L, errno);
   if (tl_isnil(L, 2)) {
      static const char *const names[] = { "mode", "modification", "access", "change", "size", "dev", "ino" };
      tl_Value result = tl_table(L, 0, sizeof names / sizeof names[0]);
      for (size_t i = 0; i < sizeof names / sizeof names[0]; ++i)
         tl_putfield(L, result, names[i], stat_field(L, &state, names[i]));
      tl_push(L, result);
   } else {
      tl_push(L, stat_field(L, &state, tl_bytes(L, 2)));
   }
   return 1;
}

static int lfs_attributes(tl_State *L) { return lfs_stat(L, true); }
static int lfs_symlinkattributes(tl_State *L) { return lfs_stat(L, false); }

static void dispose_directory(tl_State *L, void *data) {
   (void)L;
   if (data) closedir(data);
}

static int next_directory(tl_State *L) {
   tl_Function *iterator = (tl_Function *)L->current.as.object;
   DIR *dir = iterator->data;
   if (!dir) return 0;
   errno = 0;
   struct dirent *entry = readdir(dir);
   if (!entry) {
      int error = errno;
      closedir(dir);
      iterator->data = NULL;
      if (error) tl_fail(L, "cannot read directory: %s", strerror(error));
      return 0;
   }
   tl_pushstring(L, entry->d_name);
   return 1;
}

static int lfs_dir(tl_State *L) {
   const char *path = tl_bytes(L, 1);
   DIR *dir = opendir(path);
   if (!dir) tl_fail(L, "cannot open %s: %s", path, strerror(errno));
   tl_pushcfunction(L, next_directory);
   tl_Function *function = (tl_Function *)tl_at(L, -1).as.object;
   function->data = dir;
   function->destroy = dispose_directory;
   return 1;
}

static int lfs_module(tl_State *L) {
   static const tl_Library filesystem[] = {
      { "currentdir", lfs_currentdir }, { "chdir", lfs_chdir }, { "dir", lfs_dir },
      { "mkdir", lfs_mkdir }, { "rmdir", lfs_rmdir }, { "attributes", lfs_attributes },
      { "symlinkattributes", lfs_symlinkattributes }, { NULL, NULL }
   };
   tl_Value library = tl_table(L, 0, 8);
   tl_library(L, library, filesystem);
   tl_push(L, library);
   return 1;
}

static int stdin_ready(tl_State *L) {
   int64_t wait = tl_checkinteger(L, 1);
   if (wait < 0 || wait > INT32_MAX) tl_fail(L, "poll timeout out of range");
   struct pollfd input = { .fd = fileno(stdin), .events = POLLIN };
   tl_pushboolean(L, poll(&input, 1, (int)wait) > 0);
   return 1;
}

static int monotonic_ms(tl_State *L) {
   struct timespec time;
   if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return 0;
   tl_pushnumber(L, (double)time.tv_sec * 1000.0 + (double)time.tv_nsec / 1000000.0);
   return 1;
}

void tl_opensystem(tl_State *L) {
   static const tl_Library io_functions[] = {
      { "open", io_open }, { "popen", io_popen }, { "tmpfile", io_tmpfile },
      { "type", io_type }, { "read", io_read }, { "write", io_write },
      { "input", io_input }, { "output", io_output }, { "close", io_close },
      { "flush", io_flush }, { NULL, NULL }
   };
   static const tl_Library file_functions[] = {
      { "close", file_close }, { "flush", file_flush }, { "read", file_read },
      { "write", file_write }, { "seek", file_seek }, { "setvbuf", file_setvbuf }, { NULL, NULL }
   };
   static const tl_Library os_functions[] = {
      { "getenv", os_getenv }, { "time", os_time }, { "clock", os_clock },
      { "difftime", os_difftime }, { "date", os_date }, { "execute", os_execute },
      { "exit", os_exit }, { "remove", os_remove }, { "rename", os_rename },
      { "tmpname", os_tmpname }, { NULL, NULL }
   };

   tl_Value io = tl_table(L, 0, 16);
   tl_library(L, io, io_functions);
   L->default_in = file_value(L, stdin, NULL);
   L->default_out = file_value(L, stdout, NULL);
   tl_putfield(L, io, "stdin", L->default_in);
   tl_putfield(L, io, "stdout", L->default_out);
   tl_putfield(L, io, "stderr", file_value(L, stderr, NULL));
   tl_putfield(L, L->globals, "io", io);
   L->file_lib = tl_table(L, 0, 8);
   tl_library(L, L->file_lib, file_functions);

   tl_Value os = tl_table(L, 0, 12);
   tl_library(L, os, os_functions);
   tl_putfield(L, L->globals, "os", os);
   tl_preload(L, "lfs", lfs_module);

   static const tl_Library clock[] = {
      { "stdin_ready", stdin_ready }, { "monotonic_ms", monotonic_ms }, { NULL, NULL },
   };
   tl_Value native_clock = tl_table(L, 0, 2);
   tl_library(L, native_clock, clock);
   tl_putfield(L, L->globals, "_TEAL_NATIVE_CLOCK", native_clock);
}
