// memcpy, memmove, memset and memcmp of the thin libc. A module of the system
// links src/runtime/memory.asm, which has them; a module of C alone links
// this file in its place. The string instructions keep the compiler from
// turning a loop here into a call to the procedure itself.
#include "modus_thin_libc.h"

void *memcpy(void *restrict destination, const void *restrict source, size_t count) {
  void *at = destination;
  __asm__ volatile("rep movsb" : "+D"(at), "+S"(source), "+c"(count) : : "memory");
  return destination;
}

void *memmove(void *destination, const void *source, size_t count) {
  unsigned char *to = destination;
  const unsigned char *from = source;
  if (to == from || count == 0)
    return destination;
  if (to < from || to >= from + count)
    return memcpy(destination, source, count);
  // The ranges overlap with the destination above: copy from the end.
  to += count - 1;
  from += count - 1;
  __asm__ volatile("std\n\trep movsb\n\tcld" : "+D"(to), "+S"(from), "+c"(count) : : "memory");
  return destination;
}

void *memset(void *destination, int value, size_t count) {
  void *at = destination;
  __asm__ volatile("rep stosb" : "+D"(at), "+c"(count) : "a"(value) : "memory");
  return destination;
}

int memcmp(const void *left, const void *right, size_t count) {
  const unsigned char *a = left;
  const unsigned char *b = right;
  for (size_t index = 0; index < count; index++)
    if (a[index] != b[index])
      return a[index] - b[index];
  return 0;
}
