#include "tl_runtime.h"

#include <stdlib.h>
#include <string.h>

void tl_register_modules(tl_State *L);
int tl_entry(tl_State *L);
int tl_module_extras_c_generate(tl_State *L);

int main(int argc, char **argv) {
   tl_State *L = tl_newstate();
   if (!L) {
      fputs("tl: could not allocate compiler state\n", stderr);
      return EXIT_FAILURE;
   }
   tl_openlibs(L);
   tl_register_modules(L);
   bool bootstrap = argc > 1 && !strcmp(argv[1], "--emit-bootstrap-c");
   int first = bootstrap ? 2 : 1;
   tl_Value args = tl_table(L, (size_t)(argc - first), 1);
   tl_rawput(L, args, tl_numeric(0), tl_cstring(L, argv[0]));
   for (int i = first; i < argc; ++i)
      tl_rawput(L, args, tl_numeric(i - first + 1), tl_cstring(L, argv[i]));
   tl_putfield(L, L->globals, "arg", args);

   tl_pushcfunction(L, bootstrap ? tl_module_extras_c_generate : tl_entry);
   for (int i = first; i < argc; ++i) tl_pushstring(L, argv[i]);
   int status;
   if (tl_pcall(L, argc - first, 1) == 0) {
      tl_Value value = tl_at(L, -1);
      status = value.type == TL_NUMBER ? (int)value.as.number : EXIT_SUCCESS;
   } else {
      tl_Value problem = tl_at(L, -1);
      const char *message = problem.type == TL_STRING ? problem.as.string->bytes : tl_typename(problem);
      fprintf(stderr, "tl: %s\n", message);
      status = EXIT_FAILURE;
   }
   tl_close(L);
   return status;
}
