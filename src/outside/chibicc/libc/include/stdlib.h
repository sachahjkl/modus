// The thin libc of the system: memory, numbers and the end of a work
// (src/md/features/c_compiler.md, "The thin libc").
#ifndef THIN_LIBC_STDLIB_H
#define THIN_LIBC_STDLIB_H

#include <stddef.h>

// The memory is an arena of the budget of the process, which the module
// gives to the work. A request that the budget cannot pay ends the work
// through `exit`: a work of C does not check each result of malloc.
void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *bytes, size_t size);
// Ends nothing: the arena ends whole at the end of the call of the module.
void free(void *bytes);

// Returns to the entry of the work, which gives the failure to the
// module: a module never stops on a call of exit.
_Noreturn void exit(int status);

unsigned long strtoul(const char *text, char **end, int base);
// Reads no number: `*end` is `text`. The assembler has no instruction of
// floating point, so a work that needs one is refused at its constant.
long double strtold(const char *text, char **end);

#endif
