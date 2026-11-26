// Freestanding memory allocator and exit handling for doomgeneric on modus.
// Small allocations up to 64 KiB are recycled through power-of-two size bins
// backed by the Odin arena so repeated temporary strings never grow the arena.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <modus_doom_host.h>

// Alignment of every returned allocation (16 bytes for SSE2 and C max_align_t).
#define BLOCK_HEADER_SIZE 16
#define BLOCK_ALIGNMENT   16

// Format property: 12 power-of-two bins from 32 B (2^5) through 64 KiB (2^16).
#define BIN_MIN_SHIFT 5
#define BIN_MAX_SHIFT 16
#define BIN_COUNT     (BIN_MAX_SHIFT - BIN_MIN_SHIFT + 1)

typedef struct Free_Node {
  struct Free_Node *next;
} Free_Node;

typedef struct {
  size_t capacity; // Usable bytes after header; 0 for direct unbinned blocks is never stored.
  size_t bin_tag;  // Bin index 0..BIN_COUNT-1, or BIN_COUNT for direct large allocations.
} Block_Header;

_Static_assert(sizeof(Block_Header) == BLOCK_HEADER_SIZE, "Block_Header must be 16 bytes");

static Free_Node *free_bins[BIN_COUNT];

const Modus_Doom_Host *modus_doom_host = NULL;
void *modus_exit_jump_buffer[MODUS_JUMP_BUFFER_WORDS];
bool  modus_exit_jump_ready = false;
int   modus_exit_status = 0;
int   errno = 0;

void modus_libc_init(const Modus_Doom_Host *host) {
  modus_doom_host = host;
  for (int i = 0; i < BIN_COUNT; i++) {
    free_bins[i] = NULL;
  }
  errno = 0;
}

_Noreturn void exit(int status) {
  modus_libc_flush_log();
  if (!modus_exit_jump_ready) {
    __builtin_trap();
  }
  modus_exit_jump_ready = false;
  modus_exit_status = status;
  __builtin_longjmp(modus_exit_jump_buffer, 1);
}

_Noreturn void abort(void) {
  exit(1);
}

_Noreturn void modus_assertion_failed(const char *condition, const char *file, int line) {
  fprintf(stderr, "%s:%d: assertion failed: %s\n", file, line, condition);
  exit(1);
}

static size_t bin_for_size(size_t size, size_t *out_capacity) {
  size_t cap = (size_t)1 << BIN_MIN_SHIFT;
  for (size_t bin = 0; bin < BIN_COUNT; bin++) {
    if (size <= cap) {
      *out_capacity = cap;
      return bin;
    }
    cap <<= 1;
  }
  *out_capacity = size;
  return BIN_COUNT;
}

void *malloc(size_t size) {
  if (!modus_doom_host || !modus_doom_host->alloc) {
    return NULL;
  }
  if (size == 0) {
    size = 1;
  }
  if (size > SIZE_MAX - BLOCK_HEADER_SIZE) {
    return NULL;
  }
  size_t cap = 0;
  size_t bin = bin_for_size(size, &cap);
  if (bin < BIN_COUNT && free_bins[bin] != NULL) {
    Free_Node *node = free_bins[bin];
    free_bins[bin] = node->next;
    return (void *)node;
  }
  Block_Header *header = (Block_Header *)modus_doom_host->alloc(
      modus_doom_host->ctx, cap + BLOCK_HEADER_SIZE, BLOCK_ALIGNMENT);
  if (!header) {
    return NULL;
  }
  header->capacity = cap;
  header->bin_tag = bin;
  return (void *)((char *)header + BLOCK_HEADER_SIZE);
}

void *calloc(size_t count, size_t size) {
  if (size != 0 && count > SIZE_MAX / size) {
    return NULL;
  }
  size_t total = count * size;
  void *ptr = malloc(total);
  if (ptr && total > 0) {
    memset(ptr, 0, total);
  }
  return ptr;
}

void *realloc(void *ptr, size_t size) {
  if (!ptr) {
    return malloc(size);
  }
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  Block_Header *header = (Block_Header *)((char *)ptr - BLOCK_HEADER_SIZE);
  if (size <= header->capacity) {
    return ptr;
  }
  void *grown = malloc(size);
  if (!grown) {
    return NULL;
  }
  memcpy(grown, ptr, header->capacity);
  free(ptr);
  return grown;
}

void free(void *ptr) {
  if (!ptr) {
    return;
  }
  Block_Header *header = (Block_Header *)((char *)ptr - BLOCK_HEADER_SIZE);
  if (header->bin_tag < BIN_COUNT) {
    Free_Node *node = (Free_Node *)ptr;
    node->next = free_bins[header->bin_tag];
    free_bins[header->bin_tag] = node;
  }
}

char *getenv(const char *name) {
  (void)name;
  return NULL;
}

int system(const char *command) {
  (void)command;
  return -1;
}
