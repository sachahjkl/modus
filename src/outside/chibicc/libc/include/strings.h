// The thin libc of the system: the compare of texts with no case of ASCII
// (src/md/features/c_compiler.md, "The thin libc").
#ifndef THIN_LIBC_STRINGS_H
#define THIN_LIBC_STRINGS_H

#include <stddef.h>

int strcasecmp(const char *first, const char *second);
int strncasecmp(const char *first, const char *second, size_t size);

#endif
