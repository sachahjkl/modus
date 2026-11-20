// The thin libc of the system: memory over an arena, and the end of a
// work (src/md/features/c_compiler.md, "The thin libc").
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <thin_libc.h>

// Each block starts with its size, so realloc copies only the bytes that
// the block has. 16 bytes keep each block on the alignment of the largest
// scalar of the processor.
#define BLOCK_HEADER_SIZE 16
#define BLOCK_ALIGNMENT 16

static Memory_Provider *memory_provider;
static void *memory_provider_context;

void *thin_libc_exit_buffer[5];
bool thin_libc_exit_ready;
int thin_libc_exit_status;

void thin_libc_memory_set(Memory_Provider *provider, void *provider_context) {
  memory_provider = provider;
  memory_provider_context = provider_context;
}

_Noreturn void exit(int status) {
  if (!thin_libc_exit_ready)
    __builtin_trap();
  thin_libc_exit_ready = false;
  thin_libc_exit_status = status;
  __builtin_longjmp(thin_libc_exit_buffer, 1);
}

_Noreturn void assertion_failed(const char *condition, const char *file, int line) {
  fprintf(stderr, "%s:%d: the check %s failed\n", file, line, condition);
  exit(1);
}

// A work of C does not check each result of malloc: a request that the
// budget refuses ends the work, and the module reads the refusal.
static _Noreturn void memory_refused(size_t size) {
  fprintf(stderr, "out of memory: the budget cannot pay %lu bytes\n", (unsigned long)size);
  exit(1);
}

void *malloc(size_t size) {
  if (!memory_provider || size > SIZE_MAX - BLOCK_HEADER_SIZE)
    memory_refused(size);
  char *block = memory_provider(memory_provider_context, size + BLOCK_HEADER_SIZE, BLOCK_ALIGNMENT);
  if (!block)
    memory_refused(size);
  *(size_t *)block = size;
  return block + BLOCK_HEADER_SIZE;
}

void *calloc(size_t count, size_t size) {
  if (size != 0 && count > SIZE_MAX / size)
    memory_refused(SIZE_MAX);
  size_t total = count * size;
  void *bytes = malloc(total);
  // An arena gives zero pages at their first commit, and never the same
  // bytes twice; the fill keeps calloc right if that changes.
  memset(bytes, 0, total);
  return bytes;
}

void *realloc(void *bytes, size_t size) {
  if (!bytes)
    return malloc(size);
  size_t old_size = *(size_t *)((char *)bytes - BLOCK_HEADER_SIZE);
  if (size <= old_size)
    return bytes;
  void *grown = malloc(size);
  memcpy(grown, bytes, old_size);
  return grown;
}

void free(void *bytes) {
  (void)bytes;
}
