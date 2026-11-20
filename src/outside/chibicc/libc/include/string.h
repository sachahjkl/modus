// The thin libc of the system: bytes and texts that end with a byte 0
// (src/md/features/c_compiler.md, "The thin libc"). memcpy, memmove and
// memset are the procedures of src/runtime/memory.asm, which each module
// holds.
#ifndef THIN_LIBC_STRING_H
#define THIN_LIBC_STRING_H

#include <stddef.h>

void *memcpy(void *destination, const void *source, size_t size);
void *memmove(void *destination, const void *source, size_t size);
void *memset(void *destination, int value, size_t size);
int memcmp(const void *first, const void *second, size_t size);

size_t strlen(const char *text);
int strcmp(const char *first, const char *second);
int strncmp(const char *first, const char *second, size_t size);
char *strchr(const char *text, int character);
char *strrchr(const char *text, int character);
char *strstr(const char *text, const char *part);
char *strncpy(char *destination, const char *source, size_t size);
char *strdup(const char *text);
char *strndup(const char *text, size_t size);
// The words of an errno number, for a diagnostic.
char *strerror(int number);

#endif
