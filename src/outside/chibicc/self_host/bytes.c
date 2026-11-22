// memcpy, memmove and memset for a program that chibicc builds. A module
// that clang builds takes them from src/runtime/memory.asm.
#include <stddef.h>
#include <string.h>

void *memcpy(void *destination, const void *source, size_t size) {
  char *to = destination;
  const char *from = source;
  for (size_t index = 0; index < size; index++)
    to[index] = from[index];
  return destination;
}

void *memmove(void *destination, const void *source, size_t size) {
  char *to = destination;
  const char *from = source;
  if (to < from) {
    for (size_t index = 0; index < size; index++)
      to[index] = from[index];
  } else {
    for (size_t index = size; index > 0; index--)
      to[index - 1] = from[index - 1];
  }
  return destination;
}

void *memset(void *destination, int value, size_t size) {
  char *to = destination;
  for (size_t index = 0; index < size; index++)
    to[index] = (char)value;
  return destination;
}
