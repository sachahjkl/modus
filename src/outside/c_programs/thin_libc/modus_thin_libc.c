// The thin libc of the C programs of modus (src/md/features/c_compiler.md,
// "The thin libc of the C programs"). It reaches no host: no system call, no
// path, no clock. memcpy and its kin are in modus_thin_libc_memory.c, because a module
// that links src/runtime/memory.asm already has them.
#include "modus_thin_libc.h"

// ---- The heap over a lent arena -------------------------------------------

#define HEAP_BLOCK_IN_USE 0x4d4f445553555345ULL // "MODUSUSE"
#define HEAP_BLOCK_FREE 0x4d4f445553465245ULL   // "MODUSFRE"

struct Modus_Heap_Block {
  size_t payload_size;
  unsigned long long state;
  // A free block keeps the next free block in its payload.
};

static Modus_Heap *current_heap;

static size_t align_up(size_t value) {
  return (value + (MODUS_HEAP_ALIGNMENT - 1)) & ~(size_t)(MODUS_HEAP_ALIGNMENT - 1);
}

static Modus_Heap_Block **next_free_place(Modus_Heap_Block *block) {
  return (Modus_Heap_Block **)((unsigned char *)block + MODUS_HEAP_HEADER_SIZE);
}

static unsigned char *block_end(Modus_Heap_Block *block) {
  return (unsigned char *)block + MODUS_HEAP_HEADER_SIZE + block->payload_size;
}

// The map of the starts of the blocks: one bit for each 16 bytes of the
// blocks, after them in the arena. A release names a block only where its bit
// is set: a header that an old block left in the bytes of a payload does not
// pass for a block.
static unsigned char *start_map(const Modus_Heap *heap) { return heap->start + heap->capacity; }

static size_t start_bit(const Modus_Heap *heap, const Modus_Heap_Block *block) {
  return (size_t)((const unsigned char *)block - heap->start) / MODUS_HEAP_ALIGNMENT;
}

static void start_mark(Modus_Heap *heap, Modus_Heap_Block *block) {
  size_t bit = start_bit(heap, block);
  start_map(heap)[bit / 8] |= (unsigned char)(1u << (bit % 8));
}

static void start_clear(Modus_Heap *heap, Modus_Heap_Block *block) {
  size_t bit = start_bit(heap, block);
  start_map(heap)[bit / 8] &= (unsigned char)~(1u << (bit % 8));
  block->state = 0;
}

static int start_marked(const Modus_Heap *heap, const Modus_Heap_Block *block) {
  size_t bit = start_bit(heap, block);
  return (start_map(heap)[bit / 8] >> (bit % 8)) & 1;
}

int modus_heap_init(Modus_Heap *heap, void *arena, size_t arena_size) {
  if (!heap)
    return -1;
  memset(heap, 0, sizeof *heap);
  if (!arena)
    return -1;
  uintptr_t address = (uintptr_t)arena;
  uintptr_t aligned = (address + (MODUS_HEAP_ALIGNMENT - 1)) & ~(uintptr_t)(MODUS_HEAP_ALIGNMENT - 1);
  size_t lost = (size_t)(aligned - address);
  if (arena_size < lost)
    return -1;
  size_t usable = (arena_size - lost) & ~(size_t)(MODUS_HEAP_ALIGNMENT - 1);
  // The map takes one bit for each 16 bytes of the usable bytes, rounded up
  // to 16 bytes: it covers the blocks, which are fewer bytes.
  size_t map_size = align_up((usable / MODUS_HEAP_ALIGNMENT + 7) / 8);
  if (usable < map_size + MODUS_HEAP_HEADER_SIZE + MODUS_HEAP_SMALLEST_PAYLOAD)
    return -1;
  heap->start = (unsigned char *)aligned;
  heap->capacity = usable - map_size;
  memset(start_map(heap), 0, map_size);
  return 0;
}

// Removes the free block that ends at top, so that top only covers blocks.
static void heap_lower_top(Modus_Heap *heap) {
  Modus_Heap_Block **place = &heap->free_blocks;
  while (*place) {
    Modus_Heap_Block *block = *place;
    if (block_end(block) == heap->start + heap->top) {
      *place = *next_free_place(block);
      heap->top = (size_t)((unsigned char *)block - heap->start);
      start_clear(heap, block);
      return;
    }
    place = next_free_place(block);
  }
}

void *modus_heap_allocate(Modus_Heap *heap, size_t size) {
  if (!heap || !heap->start)
    return 0;
  if (size > heap->capacity) {
    heap->refused_requests++;
    return 0;
  }
  size_t payload = size < MODUS_HEAP_SMALLEST_PAYLOAD ? MODUS_HEAP_SMALLEST_PAYLOAD : align_up(size);

  // First fit in the free blocks, by address: the oldest holes fill first.
  Modus_Heap_Block **place = &heap->free_blocks;
  while (*place) {
    Modus_Heap_Block *block = *place;
    if (block->payload_size >= payload) {
      size_t rest = block->payload_size - payload;
      if (rest >= MODUS_HEAP_HEADER_SIZE + MODUS_HEAP_SMALLEST_PAYLOAD) {
        Modus_Heap_Block *tail = (Modus_Heap_Block *)((unsigned char *)block + MODUS_HEAP_HEADER_SIZE + payload);
        tail->payload_size = rest - MODUS_HEAP_HEADER_SIZE;
        tail->state = HEAP_BLOCK_FREE;
        start_mark(heap, tail);
        *next_free_place(tail) = *next_free_place(block);
        *place = tail;
        block->payload_size = payload;
      } else {
        *place = *next_free_place(block);
      }
      block->state = HEAP_BLOCK_IN_USE;
      heap->live_bytes += block->payload_size;
      return (unsigned char *)block + MODUS_HEAP_HEADER_SIZE;
    }
    place = next_free_place(block);
  }

  if (heap->capacity - heap->top < MODUS_HEAP_HEADER_SIZE + payload) {
    heap->refused_requests++;
    return 0;
  }
  Modus_Heap_Block *block = (Modus_Heap_Block *)(heap->start + heap->top);
  block->payload_size = payload;
  block->state = HEAP_BLOCK_IN_USE;
  start_mark(heap, block);
  heap->top += MODUS_HEAP_HEADER_SIZE + payload;
  if (heap->top > heap->peak_bytes)
    heap->peak_bytes = heap->top;
  heap->live_bytes += payload;
  return (unsigned char *)block + MODUS_HEAP_HEADER_SIZE;
}

// Gives the block of a payload, or 0 when the pointer is no block in use.
static Modus_Heap_Block *heap_block_in_use(Modus_Heap *heap, void *payload) {
  if (!heap || !heap->start || !payload)
    return 0;
  unsigned char *bytes = payload;
  // Compare offsets, not addresses: a pointer far from the arena would wrap
  // a sum past the top of the address space.
  if ((uintptr_t)bytes < (uintptr_t)heap->start + MODUS_HEAP_HEADER_SIZE)
    return 0;
  size_t offset = (size_t)((uintptr_t)bytes - (uintptr_t)heap->start);
  if (offset + MODUS_HEAP_SMALLEST_PAYLOAD > heap->top || (offset & (MODUS_HEAP_ALIGNMENT - 1)) != 0)
    return 0;
  Modus_Heap_Block *block = (Modus_Heap_Block *)(bytes - MODUS_HEAP_HEADER_SIZE);
  if (!start_marked(heap, block) || block->state != HEAP_BLOCK_IN_USE)
    return 0;
  if (block->payload_size > (size_t)(heap->start + heap->top - bytes))
    return 0;
  return block;
}

int modus_heap_release(Modus_Heap *heap, void *payload) {
  if (!payload)
    return 0;
  Modus_Heap_Block *block = heap_block_in_use(heap, payload);
  if (!block) {
    if (heap)
      heap->refused_releases++;
    return -1;
  }
  heap->live_bytes -= block->payload_size;
  block->state = HEAP_BLOCK_FREE;

  // Insert by address, then join the neighbours that touch it.
  Modus_Heap_Block *previous = 0;
  Modus_Heap_Block *next = heap->free_blocks;
  while (next && next < block) {
    previous = next;
    next = *next_free_place(next);
  }
  *next_free_place(block) = next;
  if (previous)
    *next_free_place(previous) = block;
  else
    heap->free_blocks = block;
  if (next && block_end(block) == (unsigned char *)next) {
    block->payload_size += MODUS_HEAP_HEADER_SIZE + next->payload_size;
    *next_free_place(block) = *next_free_place(next);
    start_clear(heap, next);
  }
  if (previous && block_end(previous) == (unsigned char *)block) {
    previous->payload_size += MODUS_HEAP_HEADER_SIZE + block->payload_size;
    *next_free_place(previous) = *next_free_place(block);
    start_clear(heap, block);
  }
  heap_lower_top(heap);
  return 0;
}

void *modus_heap_resize(Modus_Heap *heap, void *payload, size_t size) {
  if (!payload)
    return modus_heap_allocate(heap, size);
  Modus_Heap_Block *block = heap_block_in_use(heap, payload);
  if (!block) {
    if (heap)
      heap->refused_releases++;
    return 0;
  }
  if (size <= block->payload_size)
    return payload;
  // The last block grows in place when the arena has the bytes.
  if (block_end(block) == heap->start + heap->top && size <= heap->capacity) {
    size_t payload_size = align_up(size);
    size_t grow = payload_size - block->payload_size;
    if (heap->capacity - heap->top >= grow) {
      heap->top += grow;
      if (heap->top > heap->peak_bytes)
        heap->peak_bytes = heap->top;
      heap->live_bytes += grow;
      block->payload_size = payload_size;
      return payload;
    }
  }
  void *moved = modus_heap_allocate(heap, size);
  if (!moved)
    return 0;
  memcpy(moved, payload, block->payload_size);
  modus_heap_release(heap, payload);
  return moved;
}

Modus_Heap_Fault modus_heap_check(const Modus_Heap *heap) {
  if (!heap || !heap->start)
    return MODUS_HEAP_FAULT_NOT_INITIALIZED;
  size_t live = 0;
  size_t offset = 0;
  Modus_Heap_Block *expected_free = heap->free_blocks;
  int previous_free = 0;
  while (offset < heap->top) {
    Modus_Heap_Block *block = (Modus_Heap_Block *)(heap->start + offset);
    if (!start_marked(heap, block) || (block->state != HEAP_BLOCK_IN_USE && block->state != HEAP_BLOCK_FREE))
      return MODUS_HEAP_FAULT_DAMAGED_HEADER;
    if ((block->payload_size & (MODUS_HEAP_ALIGNMENT - 1)) != 0 || block->payload_size < MODUS_HEAP_SMALLEST_PAYLOAD)
      return MODUS_HEAP_FAULT_DAMAGED_HEADER;
    if (block->payload_size > heap->top - offset - MODUS_HEAP_HEADER_SIZE)
      return MODUS_HEAP_FAULT_BLOCK_PAST_TOP;
    if (block->state == HEAP_BLOCK_FREE) {
      if (block != expected_free)
        return MODUS_HEAP_FAULT_FREE_LIST_DISORDER;
      if (previous_free)
        return MODUS_HEAP_FAULT_ADJACENT_FREE_BLOCKS;
      expected_free = *next_free_place(block);
      previous_free = 1;
    } else {
      live += block->payload_size;
      previous_free = 0;
    }
    offset += MODUS_HEAP_HEADER_SIZE + block->payload_size;
  }
  if (expected_free)
    return MODUS_HEAP_FAULT_FREE_LIST_DISORDER;
  if (previous_free)
    return MODUS_HEAP_FAULT_FREE_BLOCK_AT_TOP;
  if (live != heap->live_bytes)
    return MODUS_HEAP_FAULT_LIVE_COUNT_MISMATCH;
  return MODUS_HEAP_FAULT_NONE;
}

void modus_heap_use(Modus_Heap *heap) { current_heap = heap; }
Modus_Heap *modus_heap_current(void) { return current_heap; }

void *malloc(size_t size) {
  void *payload = modus_heap_allocate(current_heap, size);
  if (!payload)
    errno = ENOMEM;
  return payload;
}

void *calloc(size_t count, size_t size) {
  if (size != 0 && count > (size_t)-1 / size) {
    errno = ENOMEM;
    return 0;
  }
  void *payload = malloc(count * size);
  if (payload)
    memset(payload, 0, count * size);
  return payload;
}

void *realloc(void *payload, size_t size) {
  void *moved = modus_heap_resize(current_heap, payload, size);
  if (!moved)
    errno = ENOMEM;
  return moved;
}

void free(void *payload) { modus_heap_release(current_heap, payload); }

// ---- Text ------------------------------------------------------------------

void *memchr(const void *bytes, int value, size_t count) {
  const unsigned char *at = bytes;
  for (size_t index = 0; index < count; index++)
    if (at[index] == (unsigned char)value)
      return (void *)(at + index);
  return 0;
}

size_t strlen(const char *text) {
  size_t count = 0;
  while (text[count])
    count++;
  return count;
}

size_t strnlen(const char *text, size_t limit) {
  size_t count = 0;
  while (count < limit && text[count])
    count++;
  return count;
}

int strcmp(const char *left, const char *right) {
  while (*left && *left == *right) {
    left++;
    right++;
  }
  return (unsigned char)*left - (unsigned char)*right;
}

int strncmp(const char *left, const char *right, size_t count) {
  for (; count > 0; count--, left++, right++) {
    if (*left != *right)
      return (unsigned char)*left - (unsigned char)*right;
    if (!*left)
      return 0;
  }
  return 0;
}

// The one locale is "C": its order is the order of the bytes.
int strcoll(const char *left, const char *right) { return strcmp(left, right); }

char *strchr(const char *text, int character) {
  for (;; text++) {
    if (*text == (char)character)
      return (char *)text;
    if (!*text)
      return 0;
  }
}

char *strrchr(const char *text, int character) {
  const char *found = 0;
  for (;; text++) {
    if (*text == (char)character)
      found = text;
    if (!*text)
      return (char *)found;
  }
}

char *strstr(const char *text, const char *pattern) {
  size_t pattern_length = strlen(pattern);
  if (pattern_length == 0)
    return (char *)text;
  for (; *text; text++)
    if (*text == *pattern && strncmp(text, pattern, pattern_length) == 0)
      return (char *)text;
  return 0;
}

char *strpbrk(const char *text, const char *accepted) {
  for (; *text; text++)
    if (strchr(accepted, *text))
      return (char *)text;
  return 0;
}

size_t strspn(const char *text, const char *accepted) {
  size_t count = 0;
  while (text[count] && strchr(accepted, text[count]))
    count++;
  return count;
}

size_t strcspn(const char *text, const char *rejected) {
  size_t count = 0;
  while (text[count] && !strchr(rejected, text[count]))
    count++;
  return count;
}

char *strcpy(char *restrict destination, const char *restrict source) {
  char *at = destination;
  while ((*at++ = *source++))
    ;
  return destination;
}

char *strncpy(char *restrict destination, const char *restrict source, size_t count) {
  size_t index = 0;
  for (; index < count && source[index]; index++)
    destination[index] = source[index];
  for (; index < count; index++)
    destination[index] = 0;
  return destination;
}

char *strcat(char *restrict destination, const char *restrict source) {
  strcpy(destination + strlen(destination), source);
  return destination;
}

char *strdup(const char *text) {
  size_t size = strlen(text) + 1;
  char *copy = malloc(size);
  if (copy)
    memcpy(copy, text, size);
  return copy;
}

char *strerror(int error_number) {
  switch (error_number) {
  case 0:
    return "no error";
  case ERANGE:
    return "result out of range";
  case EINVAL:
    return "invalid argument";
  case ENOENT:
    return "no such name";
  case ENOMEM:
    return "out of memory";
  case EBADF:
    return "bad stream";
  case EDOM:
    return "argument out of domain";
  }
  return "unknown error";
}

int isdigit(int c) { return c >= '0' && c <= '9'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int isalpha(int c) { return islower(c) || isupper(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int iscntrl(int c) { return (c >= 0 && c < 32) || c == 127; }
int isprint(int c) { return c >= 32 && c < 127; }
int isgraph(int c) { return c > 32 && c < 127; }
int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int tolower(int c) { return isupper(c) ? c - 'A' + 'a' : c; }
int toupper(int c) { return islower(c) ? c - 'a' + 'A' : c; }

// ---- Integers --------------------------------------------------------------

static int error_number_value;
int *modus_errno_place(void) { return &error_number_value; }

static int digit_value(int c) {
  if (isdigit(c))
    return c - '0';
  if (islower(c))
    return c - 'a' + 10;
  if (isupper(c))
    return c - 'A' + 10;
  return 99;
}

// Reads an unsigned magnitude with its sign. The result saturates at the
// limit, with ERANGE; a text with no digit gives 0 and *end at the text.
static unsigned long long read_integer(const char *text, char **end, int base, unsigned long long positive_limit,
                                       unsigned long long negative_limit, int *negative_out) {
  *negative_out = 0;
  if (base < 0 || base == 1 || base > 36) {
    errno = EINVAL;
    if (end)
      *end = (char *)text;
    return 0;
  }
  const char *at = text;
  while (isspace((unsigned char)*at))
    at++;
  int negative = 0;
  if (*at == '+' || *at == '-')
    negative = *at++ == '-';
  if ((base == 0 || base == 16) && at[0] == '0' && (at[1] == 'x' || at[1] == 'X') && digit_value((unsigned char)at[2]) < 16) {
    at += 2;
    base = 16;
  } else if (base == 0) {
    base = at[0] == '0' ? 8 : 10;
  }
  unsigned long long limit = negative ? negative_limit : positive_limit;
  unsigned long long value = 0;
  int any = 0;
  int overflow = 0;
  for (;; at++) {
    int digit = digit_value((unsigned char)*at);
    if (digit >= base)
      break;
    any = 1;
    if (overflow)
      continue;
    if (value > (limit - (unsigned long long)digit) / (unsigned long long)base)
      overflow = 1;
    else
      value = value * (unsigned long long)base + (unsigned long long)digit;
  }
  if (end)
    *end = (char *)(any ? at : text);
  if (!any)
    return 0;
  *negative_out = negative;
  if (overflow) {
    errno = ERANGE;
    return limit;
  }
  return value;
}

long long strtoll(const char *restrict text, char **restrict end, int base) {
  int negative;
  unsigned long long magnitude =
      read_integer(text, end, base, (unsigned long long)LLONG_MAX, (unsigned long long)LLONG_MAX + 1ULL, &negative);
  return negative ? (long long)(0ULL - magnitude) : (long long)magnitude;
}

long strtol(const char *restrict text, char **restrict end, int base) { return (long)strtoll(text, end, base); }

unsigned long long strtoull(const char *restrict text, char **restrict end, int base) {
  int negative;
  unsigned long long magnitude = read_integer(text, end, base, ULLONG_MAX, ULLONG_MAX, &negative);
  // C gives the negation of the magnitude for a text with a minus sign, and
  // the largest value with no negation when the magnitude overflowed.
  if (magnitude == ULLONG_MAX && errno == ERANGE)
    return magnitude;
  return negative ? 0ULL - magnitude : magnitude;
}

unsigned long strtoul(const char *restrict text, char **restrict end, int base) {
  return (unsigned long)strtoull(text, end, base);
}

int atoi(const char *text) { return (int)strtol(text, 0, 10); }
long atol(const char *text) { return strtol(text, 0, 10); }
int abs(int value) { return value < 0 ? -value : value; }
long labs(long value) { return value < 0 ? -value : value; }
long long llabs(long long value) { return value < 0 ? -value : value; }

// ---- The exact decimal -------------------------------------------------------
//
// A decimal of at most 800 significant digits, 0.d1d2... times 10^point, and a
// flag that says that a digit that is not 0 was dropped after them. The exact
// value of a double has at most 767 significant digits, so the decimal holds
// it whole: strtod and the floating conversions of printf compute with
// integers only and give one result, whatever the rounding mode.

#define DECIMAL_DIGITS 800
#define DECIMAL_LARGEST_SHIFT 60

typedef struct Decimal {
  unsigned char digits[DECIMAL_DIGITS]; // Characters '0' to '9'.
  int count;
  int point;
  int negative;
  int truncated;
} Decimal;

static void decimal_trim(Decimal *decimal) {
  while (decimal->count > 0 && decimal->digits[decimal->count - 1] == '0')
    decimal->count--;
  if (decimal->count == 0)
    decimal->point = 0;
}

static void decimal_assign(Decimal *decimal, unsigned long long value) {
  unsigned char reversed[24];
  int count = 0;
  while (value > 0) {
    reversed[count++] = (unsigned char)('0' + value % 10);
    value /= 10;
  }
  decimal->count = 0;
  while (count > 0)
    decimal->digits[decimal->count++] = reversed[--count];
  decimal->point = decimal->count;
  decimal->truncated = 0;
  decimal_trim(decimal);
}

static void decimal_right_shift(Decimal *decimal, unsigned shift) {
  int read = 0;
  int write = 0;
  unsigned long long value = 0;
  for (; (value >> shift) == 0; read++) {
    if (read >= decimal->count) {
      if (value == 0) {
        decimal->count = 0;
        return;
      }
      while ((value >> shift) == 0) {
        value *= 10;
        read++;
      }
      break;
    }
    value = value * 10 + (unsigned long long)(decimal->digits[read] - '0');
  }
  decimal->point -= read - 1;
  unsigned long long mask = (1ULL << shift) - 1;
  for (; read < decimal->count; read++) {
    unsigned long long digit = value >> shift;
    value &= mask;
    decimal->digits[write++] = (unsigned char)('0' + digit);
    value = value * 10 + (unsigned long long)(decimal->digits[read] - '0');
  }
  while (value > 0) {
    unsigned long long digit = value >> shift;
    value &= mask;
    if (write < DECIMAL_DIGITS)
      decimal->digits[write++] = (unsigned char)('0' + digit);
    else if (digit > 0)
      decimal->truncated = 1;
    value *= 10;
  }
  decimal->count = write;
  decimal_trim(decimal);
}

static void decimal_left_shift(Decimal *decimal, unsigned shift) {
  unsigned char produced[DECIMAL_DIGITS + 24];
  int write = (int)sizeof produced;
  unsigned long long carry = 0;
  for (int read = decimal->count - 1; read >= 0; read--) {
    carry += (unsigned long long)(decimal->digits[read] - '0') << shift;
    produced[--write] = (unsigned char)('0' + carry % 10);
    carry /= 10;
  }
  while (carry > 0) {
    produced[--write] = (unsigned char)('0' + carry % 10);
    carry /= 10;
  }
  int total = (int)sizeof produced - write;
  decimal->point += total - decimal->count;
  int kept = total < DECIMAL_DIGITS ? total : DECIMAL_DIGITS;
  for (int index = 0; index < kept; index++)
    decimal->digits[index] = produced[write + index];
  for (int index = kept; index < total; index++)
    if (produced[write + index] != '0')
      decimal->truncated = 1;
  decimal->count = kept;
  decimal_trim(decimal);
}

static void decimal_shift(Decimal *decimal, int shift) {
  if (decimal->count == 0)
    return;
  while (shift > DECIMAL_LARGEST_SHIFT) {
    decimal_left_shift(decimal, DECIMAL_LARGEST_SHIFT);
    shift -= DECIMAL_LARGEST_SHIFT;
  }
  while (shift < -DECIMAL_LARGEST_SHIFT) {
    decimal_right_shift(decimal, DECIMAL_LARGEST_SHIFT);
    shift += DECIMAL_LARGEST_SHIFT;
  }
  if (shift > 0)
    decimal_left_shift(decimal, (unsigned)shift);
  else if (shift < 0)
    decimal_right_shift(decimal, (unsigned)-shift);
}

// Rounds to the nearest at the digit of the index, ties to even. A dropped
// digit that is not 0 puts the value above a tie.
static int decimal_should_round_up(const Decimal *decimal, int index) {
  if (index < 0 || index >= decimal->count)
    return 0;
  if (decimal->digits[index] == '5' && index + 1 == decimal->count) {
    if (decimal->truncated)
      return 1;
    return index > 0 && (decimal->digits[index - 1] - '0') % 2 == 1;
  }
  return decimal->digits[index] >= '5';
}

static void decimal_round(Decimal *decimal, int count) {
  if (count < 0) {
    // Every digit is below the place of the rounding: the value is 0.
    decimal->count = 0;
    decimal->point = 0;
    return;
  }
  if (count >= decimal->count)
    return;
  if (decimal_should_round_up(decimal, count)) {
    for (int index = count - 1; index >= 0; index--) {
      if (decimal->digits[index] < '9') {
        decimal->digits[index]++;
        decimal->count = index + 1;
        return;
      }
    }
    decimal->digits[0] = '1';
    decimal->count = 1;
    decimal->point++;
  } else {
    decimal->count = count;
    decimal_trim(decimal);
  }
}

static unsigned long long decimal_rounded_integer(const Decimal *decimal, int *inexact) {
  if (decimal->point > 20)
    return ~0ULL;
  unsigned long long value = 0;
  int index = 0;
  for (; index < decimal->point && index < decimal->count; index++)
    value = value * 10 + (unsigned long long)(decimal->digits[index] - '0');
  for (; index < decimal->point; index++)
    value *= 10;
  *inexact = decimal->truncated || decimal->count > (decimal->point > 0 ? decimal->point : 0);
  if (decimal_should_round_up(decimal, decimal->point))
    value++;
  return value;
}

// The double of an exact decimal, rounded to the nearest, ties to even.
static unsigned long long decimal_double_bits(Decimal *decimal, int *range_error) {
  static const int shifts[] = {1, 3, 6, 9, 13, 16, 19, 23, 26};
  const int mantissa_bits = 52;
  const int bias = -1023;
  unsigned long long mantissa = 0;
  int exponent = 0;
  *range_error = 0;

  if (decimal->count == 0) {
    exponent = bias;
    goto assemble;
  }
  if (decimal->point > 310)
    goto overflow;
  if (decimal->point < -330) {
    exponent = bias;
    *range_error = 1;
    goto assemble;
  }
  exponent = 0;
  while (decimal->point > 0) {
    int shift = decimal->point >= 9 ? 27 : shifts[decimal->point];
    decimal_shift(decimal, -shift);
    exponent += shift;
  }
  while (decimal->point < 0 || (decimal->point == 0 && decimal->digits[0] < '5')) {
    int shift = -decimal->point >= 9 ? 27 : shifts[-decimal->point];
    decimal_shift(decimal, shift);
    exponent -= shift;
  }
  // The range is [0.5, 1); the range of a double is [1, 2).
  exponent--;
  if (exponent < bias + 1) {
    int shift = bias + 1 - exponent;
    decimal_shift(decimal, -shift);
    exponent += shift;
  }
  if (exponent - bias >= (1 << 11) - 1)
    goto overflow;
  decimal_shift(decimal, 1 + mantissa_bits);
  int inexact = 0;
  mantissa = decimal_rounded_integer(decimal, &inexact);
  if (mantissa == (2ULL << mantissa_bits)) {
    mantissa >>= 1;
    exponent++;
    if (exponent - bias >= (1 << 11) - 1)
      goto overflow;
  }
  if ((mantissa & (1ULL << mantissa_bits)) == 0) {
    exponent = bias;
    if (inexact)
      *range_error = 1;
  }
  goto assemble;

overflow:
  mantissa = 0;
  exponent = (1 << 11) - 1 + bias;
  *range_error = 1;

assemble:;
  unsigned long long bits = mantissa & ((1ULL << mantissa_bits) - 1);
  bits |= (unsigned long long)((exponent - bias) & ((1 << 11) - 1)) << mantissa_bits;
  if (decimal->negative)
    bits |= 1ULL << 63;
  return bits;
}

static double double_of_bits(unsigned long long bits) {
  double value;
  memcpy(&value, &bits, sizeof value);
  return value;
}

static unsigned long long bits_of_double(double value) {
  unsigned long long bits;
  memcpy(&bits, &value, sizeof bits);
  return bits;
}

static int text_starts_with_word(const char *text, const char *word) {
  for (; *word; text++, word++)
    if (tolower((unsigned char)*text) != *word)
      return 0;
  return 1;
}

// A hexadecimal number keeps its first 64 bits and a flag for the bits after
// them, then rounds to 53 bits, ties to even.
#ifdef __chibicc__
static int modus_internal_clzll(unsigned long long value) {
  int count = 0;
  unsigned long long bit = 1ULL << 63;
  while (bit != 0 && (value & bit) == 0) {
    count++;
    bit >>= 1;
  }
  return count;
}
#endif

static unsigned long long hexadecimal_double_bits(unsigned long long mantissa, int sticky, long exponent, int negative,
                                                  int *range_error) {
  unsigned long long sign = negative ? 1ULL << 63 : 0;
  *range_error = 0;
  if (mantissa == 0)
    return sign;
#ifdef __chibicc__
  int leading = modus_internal_clzll(mantissa);
#else
  int leading = __builtin_clzll(mantissa);
#endif
  mantissa <<= leading;
  exponent -= leading;
  // The value is the mantissa times 2^exponent, with the top bit of the mantissa set.
  long unbiased = exponent + 63;
  if (unbiased > 1023) {
    *range_error = 1;
    return sign | 0x7ff0000000000000ULL;
  }
  long shift = 11;
  int subnormal = unbiased < -1022;
  if (subnormal)
    shift += -1022 - unbiased;
  unsigned long long result;
  int inexact;
  if (shift >= 64) {
    inexact = 1;
    if (shift == 64)
      result = (mantissa > (1ULL << 63) || (mantissa == (1ULL << 63) && sticky)) ? 1 : 0;
    else
      result = 0;
  } else {
    unsigned long long rest = mantissa & ((1ULL << shift) - 1);
    unsigned long long half = 1ULL << (shift - 1);
    result = mantissa >> shift;
    inexact = rest != 0 || sticky;
    if (rest > half || (rest == half && (sticky || (result & 1))))
      result++;
  }
  if (subnormal) {
    if (inexact)
      *range_error = 1;
    // A subnormal that rounds up to 2^52 is the least normal double.
    return sign | result;
  }
  if (result == (1ULL << 53)) {
    result >>= 1;
    unbiased++;
    if (unbiased > 1023) {
      *range_error = 1;
      return sign | 0x7ff0000000000000ULL;
    }
  }
  return sign | ((unsigned long long)(unbiased + 1023) << 52) | (result & ((1ULL << 52) - 1));
}

// Reads the exponent after 'e' or 'p'. A sign with no digit is no exponent,
// and the end stays before the letter.
static const char *read_exponent(const char *at, long *exponent) {
  const char *exponent_at = at + 1;
  int negative = 0;
  if (*exponent_at == '+' || *exponent_at == '-')
    negative = *exponent_at++ == '-';
  if (!isdigit((unsigned char)*exponent_at))
    return at;
  long written = 0;
  // Past 100000 the value is the same infinity or zero, so no count overflows.
  for (; isdigit((unsigned char)*exponent_at); exponent_at++)
    if (written < 100000)
      written = written * 10 + (*exponent_at - '0');
  *exponent += negative ? -written : written;
  return exponent_at;
}

double strtod(const char *restrict text, char **restrict end) {
  const char *at = text;
  while (isspace((unsigned char)*at))
    at++;
  int negative = 0;
  if (*at == '+' || *at == '-')
    negative = *at++ == '-';
  unsigned long long sign = negative ? 1ULL << 63 : 0;

  if (text_starts_with_word(at, "inf")) {
    at += text_starts_with_word(at, "infinity") ? 8 : 3;
    if (end)
      *end = (char *)at;
    return double_of_bits(sign | 0x7ff0000000000000ULL);
  }
  if (text_starts_with_word(at, "nan")) {
    at += 3;
    if (*at == '(') {
      const char *close = at + 1;
      while (isalnum((unsigned char)*close) || *close == '_')
        close++;
      if (*close == ')')
        at = close + 1;
    }
    if (end)
      *end = (char *)at;
    return double_of_bits(sign | 0x7ff8000000000000ULL);
  }

  if (at[0] == '0' && (at[1] == 'x' || at[1] == 'X') &&
      (isxdigit((unsigned char)at[2]) || (at[2] == '.' && isxdigit((unsigned char)at[3])))) {
    at += 2;
    unsigned long long mantissa = 0;
    int sticky = 0;
    long exponent = 0;
    int seen_point = 0;
    for (;; at++) {
      if (*at == '.' && !seen_point) {
        seen_point = 1;
        continue;
      }
      if (!isxdigit((unsigned char)*at))
        break;
      int digit = digit_value((unsigned char)*at);
      if (mantissa >> 60 == 0) {
        mantissa = mantissa * 16 + (unsigned long long)digit;
        if (seen_point)
          exponent -= 4;
      } else {
        sticky |= digit != 0;
        if (!seen_point)
          exponent += 4;
      }
    }
    if (*at == 'p' || *at == 'P')
      at = read_exponent(at, &exponent);
    if (end)
      *end = (char *)at;
    int range_error;
    unsigned long long bits = hexadecimal_double_bits(mantissa, sticky, exponent, negative, &range_error);
    if (range_error)
      errno = ERANGE;
    return double_of_bits(bits);
  }

  static Decimal decimal;
  decimal.count = 0;
  decimal.point = 0;
  decimal.negative = negative;
  decimal.truncated = 0;
  int seen_digit = 0;
  int seen_point = 0;
  for (;; at++) {
    if (*at == '.' && !seen_point) {
      seen_point = 1;
      continue;
    }
    if (!isdigit((unsigned char)*at))
      break;
    seen_digit = 1;
    if (*at == '0' && decimal.count == 0) {
      // A leading zero moves the point only when it is after the point.
      if (seen_point)
        decimal.point--;
      continue;
    }
    if (!seen_point)
      decimal.point++;
    if (decimal.count < DECIMAL_DIGITS)
      decimal.digits[decimal.count++] = (unsigned char)*at;
    else if (*at != '0')
      decimal.truncated = 1;
  }
  if (!seen_digit) {
    if (end)
      *end = (char *)text;
    return 0.0;
  }
  if (*at == 'e' || *at == 'E') {
    long exponent = 0;
    at = read_exponent(at, &exponent);
    decimal.point += (int)exponent;
  }
  if (end)
    *end = (char *)at;
  decimal_trim(&decimal);
  if (decimal.count == 0)
    return double_of_bits(sign);
  int range_error;
  unsigned long long bits = decimal_double_bits(&decimal, &range_error);
  if (range_error)
    errno = ERANGE;
  return double_of_bits(bits);
}

float strtof(const char *restrict text, char **restrict end) { return (float)strtod(text, end); }

// ---- Sorting -------------------------------------------------------------------

static void swap_bytes(unsigned char *left, unsigned char *right, size_t size) {
  for (size_t index = 0; index < size; index++) {
    unsigned char kept = left[index];
    left[index] = right[index];
    right[index] = kept;
  }
}

static void sift_down(unsigned char *base, size_t root, size_t count, size_t size,
                      int (*compare)(const void *, const void *)) {
  for (;;) {
    size_t child = 2 * root + 1;
    if (child >= count)
      return;
    if (child + 1 < count && compare(base + child * size, base + (child + 1) * size) < 0)
      child++;
    if (compare(base + root * size, base + child * size) >= 0)
      return;
    swap_bytes(base + root * size, base + child * size, size);
    root = child;
  }
}

// A heap sort: no memory, no recursion, and at most 2 n log n comparisons
// whatever the order of the input.
void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
  unsigned char *bytes = base;
  if (count < 2 || size == 0)
    return;
  for (size_t root = count / 2; root-- > 0;)
    sift_down(bytes, root, count, size, compare);
  for (size_t last = count - 1; last > 0; last--) {
    swap_bytes(bytes, bytes + last * size, size);
    sift_down(bytes, 0, last, size, compare);
  }
}

#ifdef __chibicc__
_Noreturn void abort(void) {
  asm("ud2");
  for (;;) {
  }
}
#else
_Noreturn void abort(void) { __builtin_trap(); }
#endif

// ---- Portable IEEE-754 helpers -------------------------------------------------

double modus_double_inf(void) { return double_of_bits(0x7ff0000000000000ULL); }
double modus_double_nan(void) { return double_of_bits(0x7ff8000000000000ULL); }

int modus_isnan(double value) {
  unsigned long long bits = bits_of_double(value) & ~(1ULL << 63);
  return bits > 0x7ff0000000000000ULL;
}

int modus_isinf(double value) {
  unsigned long long bits = bits_of_double(value) & ~(1ULL << 63);
  return bits == 0x7ff0000000000000ULL;
}

int modus_isfinite(double value) {
  unsigned long long bits = bits_of_double(value) & ~(1ULL << 63);
  return bits < 0x7ff0000000000000ULL;
}

int modus_signbit(double value) { return (int)(bits_of_double(value) >> 63); }

int modus_clzll(unsigned long long value) {
#ifdef __chibicc__
  return modus_internal_clzll(value);
#else
  return __builtin_clzll(value);
#endif
}

// ---- Floating point functions --------------------------------------------------

double fabs(double value) { return double_of_bits(bits_of_double(value) & ~(1ULL << 63)); }

double trunc(double value) {
  unsigned long long bits = bits_of_double(value);
  int exponent = (int)((bits >> 52) & 0x7ff) - 1023;
  if (exponent >= 52)
    return value;
  if (exponent < 0)
    return double_of_bits(bits & (1ULL << 63));
  unsigned long long fraction_mask = (1ULL << (52 - exponent)) - 1;
  return double_of_bits(bits & ~fraction_mask);
}

double floor(double value) {
  double whole = trunc(value);
  return (value < 0 && whole != value) ? whole - 1.0 : whole;
}

double ceil(double value) {
  double whole = trunc(value);
  return (value > 0 && whole != value) ? whole + 1.0 : whole;
}

#ifndef __chibicc__
// The instruction itself: the compiler turns __builtin_sqrt of a function
// named sqrt into a call of that same function. Under chibicc,
// modus_thin_libc_chibicc.s supplies the same sqrtsd instruction.
double sqrt(double value) {
  double root;
  __asm__("sqrtsd %1, %0" : "=x"(root) : "x"(value));
  return root;
}
#endif

double frexp(double value, int *exponent) {
  unsigned long long bits = bits_of_double(value);
  int raw = (int)((bits >> 52) & 0x7ff);
  if (raw == 0x7ff || value == 0.0) {
    *exponent = 0;
    return value;
  }
  if (raw == 0) {
    // A subnormal: scale it into the normal range first.
    double scaled = frexp(value * 0x1p64, exponent);
    *exponent -= 64;
    return scaled;
  }
  *exponent = raw - 1022;
  return double_of_bits((bits & ~(0x7ffULL << 52)) | (1022ULL << 52));
}

double ldexp(double value, int exponent) {
  // Steps of 2^1000 keep each factor a normal double. A result in the
  // subnormal range is reached by two factors so that it rounds once.
  while (exponent > 1023) {
    value *= 0x1p1023;
    exponent -= 1023;
    if (exponent > 1023 && modus_isinf(value))
      return value;
  }
  while (exponent < -1022) {
    if (exponent >= -1022 - 53) {
      value *= 0x1p-969; // 2^-1022 times 2^53
      exponent += 969;
      break;
    }
    value *= 0x1p-1022;
    exponent += 1022;
    if (value == 0.0)
      return value;
  }
  if (exponent < -1022) {
    value *= 0x1p-53;
    exponent += 53;
  }
  return value * double_of_bits((unsigned long long)(exponent + 1023) << 52);
}

// The exact remainder: each step subtracts a multiple of the denominator that
// is a power of two, which is exact in binary.
double fmod(double numerator, double denominator) {
  if (numerator != numerator || denominator != denominator || denominator == 0.0 || modus_isinf(numerator))
    return modus_double_nan();
  if (modus_isinf(denominator))
    return numerator;
  double remainder = fabs(numerator);
  double divisor = fabs(denominator);
  while (remainder >= divisor) {
    int remainder_exponent, divisor_exponent;
    frexp(remainder, &remainder_exponent);
    frexp(divisor, &divisor_exponent);
    double step = ldexp(divisor, remainder_exponent - divisor_exponent);
    if (step > remainder)
      step = ldexp(divisor, remainder_exponent - divisor_exponent - 1);
    remainder -= step;
  }
  // The result has the sign of the numerator, -0.0 included.
  return (bits_of_double(numerator) >> 63) ? -remainder : remainder;
}

// ---- Formatted output ------------------------------------------------------------

typedef struct Format_Sink {
  char *buffer;    // For a text: its bytes. 0 for a stream.
  size_t capacity; // For a text: its bytes with the terminating zero.
  FILE *stream;    // For a stream.
  size_t written;  // Each byte of the output, written or not.
  int failed;
} Format_Sink;

static void sink_byte(Format_Sink *sink, char character) {
  if (sink->stream) {
    if (fputc((unsigned char)character, sink->stream) == EOF)
      sink->failed = 1;
  } else if (sink->capacity > 0 && sink->written < sink->capacity - 1) {
    sink->buffer[sink->written] = character;
  }
  sink->written++;
}

static void sink_repeat(Format_Sink *sink, char character, long count) {
  for (long index = 0; index < count; index++)
    sink_byte(sink, character);
}

static void sink_bytes(Format_Sink *sink, const char *bytes, size_t count) {
  for (size_t index = 0; index < count; index++)
    sink_byte(sink, bytes[index]);
}

enum {
  FLAG_LEFT = 1,
  FLAG_PLUS = 2,
  FLAG_SPACE = 4,
  FLAG_ALTERNATE = 8,
  FLAG_ZERO = 16,
};

typedef enum Format_Length {
  FORMAT_LENGTH_INT,
  FORMAT_LENGTH_CHAR,
  FORMAT_LENGTH_SHORT,
  FORMAT_LENGTH_LONG,
  FORMAT_LENGTH_LONG_LONG,
  FORMAT_LENGTH_SIZE,
} Format_Length;

// Writes a prefix, then zeros, then the body, padded to the width.
static void sink_field(Format_Sink *sink, int flags, long width, const char *prefix, long zeros, const char *body,
                       size_t body_count) {
  size_t prefix_count = strlen(prefix);
  long total = (long)(prefix_count + body_count) + zeros;
  long padding = width > total ? width - total : 0;
  if (!(flags & FLAG_LEFT) && !(flags & FLAG_ZERO))
    sink_repeat(sink, ' ', padding);
  sink_bytes(sink, prefix, prefix_count);
  if (!(flags & FLAG_LEFT) && (flags & FLAG_ZERO))
    sink_repeat(sink, '0', padding);
  sink_repeat(sink, '0', zeros);
  sink_bytes(sink, body, body_count);
  if (flags & FLAG_LEFT)
    sink_repeat(sink, ' ', padding);
}

static void format_integer(Format_Sink *sink, unsigned long long magnitude, int negative, int base, int upper,
                           int flags, long width, long precision) {
  char body[72];
  int count = 0;
  const char *alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  char reversed[72];
  while (magnitude > 0) {
    reversed[count++] = alphabet[magnitude % (unsigned)base];
    magnitude /= (unsigned)base;
  }
  for (int index = 0; index < count; index++)
    body[index] = reversed[count - 1 - index];
  long zeros = precision > count ? precision - count : 0;
  if (precision < 0 && count == 0)
    zeros = 1;
  const char *prefix = "";
  if (negative)
    prefix = "-";
  else if (flags & FLAG_PLUS)
    prefix = "+";
  else if (flags & FLAG_SPACE)
    prefix = " ";
  // "#" puts 0x before a hexadecimal value that is not 0, and makes the
  // first digit of an octal value a 0, the value 0 with a precision of 0 too.
  if ((flags & FLAG_ALTERNATE) && base == 16 && count > 0)
    prefix = upper ? "0X" : "0x";
  if ((flags & FLAG_ALTERNATE) && base == 8 && zeros == 0 && (count == 0 || body[0] != '0'))
    zeros = 1;
  if (precision >= 0)
    flags &= ~FLAG_ZERO;
  sink_field(sink, flags, width, prefix, zeros, body, (size_t)count);
}

// The decimal of the exact value of a finite double that is not negative.
static void decimal_of_double(Decimal *decimal, double value) {
  unsigned long long bits = bits_of_double(value);
  int raw_exponent = (int)((bits >> 52) & 0x7ff);
  unsigned long long mantissa = bits & ((1ULL << 52) - 1);
  int exponent;
  if (raw_exponent == 0) {
    exponent = -1022 - 52;
  } else {
    mantissa |= 1ULL << 52;
    exponent = raw_exponent - 1023 - 52;
  }
  decimal_assign(decimal, mantissa);
  decimal->negative = 0;
  decimal_shift(decimal, exponent);
}

static char decimal_digit(const Decimal *decimal, int index) {
  return index >= 0 && index < decimal->count ? (char)decimal->digits[index] : '0';
}

// The longest body of a floating conversion: 309 digits before the point, the
// point, a precision of at most FORMAT_PRECISION_LIMIT, and an exponent.
#define FORMAT_PRECISION_LIMIT 1100
#define FORMAT_BODY_LIMIT (320 + FORMAT_PRECISION_LIMIT + 8)

static void format_double(Format_Sink *sink, double value, char conversion, int flags, long width, long precision) {
  unsigned long long bits = bits_of_double(value);
  int negative = (int)(bits >> 63);
  int upper = conversion >= 'A' && conversion <= 'Z';
  char lower_conversion = (char)tolower((unsigned char)conversion);
  const char *prefix = negative ? "-" : (flags & FLAG_PLUS) ? "+" : (flags & FLAG_SPACE) ? " " : "";
  if (((bits >> 52) & 0x7ff) == 0x7ff) {
    const char *word = (bits & ((1ULL << 52) - 1)) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
    sink_field(sink, flags & ~FLAG_ZERO, width, prefix, 0, word, 3);
    return;
  }
  if (precision < 0)
    precision = 6;
  // Past the limit, each digit of the exact value is already written: the
  // rest of the precision is zeros, which the sink writes without a body.
  long extra_zeros = 0;

  static Decimal decimal;
  decimal_of_double(&decimal, negative ? -value : value);
  static char body[FORMAT_BODY_LIMIT];
  int count = 0;
  int alternate = (flags & FLAG_ALTERNATE) != 0;
  int strip_zeros = 0;

  if (lower_conversion == 'g') {
    if (precision == 0)
      precision = 1;
    static Decimal rounded;
    rounded = decimal;
    decimal_round(&rounded, (int)(precision > FORMAT_PRECISION_LIMIT ? FORMAT_PRECISION_LIMIT : precision));
    long exponent = rounded.count == 0 ? 0 : rounded.point - 1;
    if (exponent < precision && exponent >= -4) {
      lower_conversion = 'f';
      precision = precision - 1 - exponent;
    } else {
      lower_conversion = 'e';
      precision = precision - 1;
    }
    strip_zeros = !alternate;
  }
  if (precision > FORMAT_PRECISION_LIMIT) {
    extra_zeros = strip_zeros ? 0 : precision - FORMAT_PRECISION_LIMIT;
    precision = FORMAT_PRECISION_LIMIT;
  }

  int exponent = 0;
  if (lower_conversion == 'e') {
    decimal_round(&decimal, (int)precision + 1);
    exponent = decimal.count == 0 ? 0 : decimal.point - 1;
    body[count++] = decimal_digit(&decimal, 0);
    if (precision > 0 || alternate)
      body[count++] = '.';
    for (int index = 1; index <= precision; index++)
      body[count++] = decimal_digit(&decimal, index);
  } else {
    decimal_round(&decimal, decimal.point + (int)precision);
    if (decimal.count == 0 || decimal.point <= 0) {
      body[count++] = '0';
    } else {
      for (int index = 0; index < decimal.point; index++)
        body[count++] = decimal_digit(&decimal, index);
    }
    if (precision > 0 || alternate)
      body[count++] = '.';
    for (int index = 0; index < precision; index++)
      body[count++] = decimal_digit(&decimal, decimal.point + index);
  }
  if (strip_zeros && memchr(body, '.', (size_t)count)) {
    while (body[count - 1] == '0')
      count--;
    if (body[count - 1] == '.')
      count--;
  }
  char exponent_text[8];
  int exponent_count = 0;
  if (lower_conversion == 'e') {
    exponent_text[exponent_count++] = upper ? 'E' : 'e';
    exponent_text[exponent_count++] = exponent < 0 ? '-' : '+';
    int magnitude = exponent < 0 ? -exponent : exponent;
    if (magnitude >= 100)
      exponent_text[exponent_count++] = (char)('0' + magnitude / 100);
    exponent_text[exponent_count++] = (char)('0' + magnitude / 10 % 10);
    exponent_text[exponent_count++] = (char)('0' + magnitude % 10);
  }
  long total = (long)strlen(prefix) + count + extra_zeros + exponent_count;
  long padding = width > total ? width - total : 0;
  if (!(flags & FLAG_LEFT) && !(flags & FLAG_ZERO))
    sink_repeat(sink, ' ', padding);
  sink_bytes(sink, prefix, strlen(prefix));
  if (!(flags & FLAG_LEFT) && (flags & FLAG_ZERO))
    sink_repeat(sink, '0', padding);
  sink_bytes(sink, body, (size_t)count);
  sink_repeat(sink, '0', extra_zeros);
  sink_bytes(sink, exponent_text, (size_t)exponent_count);
  if (flags & FLAG_LEFT)
    sink_repeat(sink, ' ', padding);
}

static int format_into(Format_Sink *sink, const char *format, va_list arguments) {
  for (const char *at = format; *at; at++) {
    if (*at != '%') {
      sink_byte(sink, *at);
      continue;
    }
    at++;
    int flags = 0;
    for (;; at++) {
      if (*at == '-')
        flags |= FLAG_LEFT;
      else if (*at == '+')
        flags |= FLAG_PLUS;
      else if (*at == ' ')
        flags |= FLAG_SPACE;
      else if (*at == '#')
        flags |= FLAG_ALTERNATE;
      else if (*at == '0')
        flags |= FLAG_ZERO;
      else
        break;
    }
    long width = 0;
    if (*at == '*') {
      width = va_arg(arguments, int);
      if (width < 0) {
        flags |= FLAG_LEFT;
        width = -width;
      }
      at++;
    } else {
      while (isdigit((unsigned char)*at) && width < INT_MAX / 10)
        width = width * 10 + (*at++ - '0');
    }
    long precision = -1;
    if (*at == '.') {
      at++;
      precision = 0;
      if (*at == '*') {
        precision = va_arg(arguments, int);
        at++;
      } else {
        while (isdigit((unsigned char)*at) && precision < INT_MAX / 10)
          precision = precision * 10 + (*at++ - '0');
      }
    }
    if (isdigit((unsigned char)*at)) {
      // A width or a precision past INT_MAX cannot be counted in an int.
      errno = EINVAL;
      return -1;
    }
    if (flags & FLAG_LEFT)
      flags &= ~FLAG_ZERO;
    Format_Length length = FORMAT_LENGTH_INT;
    if (*at == 'h') {
      length = at[1] == 'h' ? FORMAT_LENGTH_CHAR : FORMAT_LENGTH_SHORT;
      at += at[1] == 'h' ? 2 : 1;
    } else if (*at == 'l') {
      length = at[1] == 'l' ? FORMAT_LENGTH_LONG_LONG : FORMAT_LENGTH_LONG;
      at += at[1] == 'l' ? 2 : 1;
    } else if (*at == 'z' || *at == 'j' || *at == 't') {
      length = FORMAT_LENGTH_SIZE;
      at++;
    } else if (*at == 'L') {
      at++;
    }
    char conversion = *at;
    switch (conversion) {
    case 'd':
    case 'i': {
      long long value = 0;
      switch (length) {
      case FORMAT_LENGTH_CHAR:
        value = (signed char)va_arg(arguments, int);
        break;
      case FORMAT_LENGTH_SHORT:
        value = (short)va_arg(arguments, int);
        break;
      case FORMAT_LENGTH_INT:
        value = va_arg(arguments, int);
        break;
      case FORMAT_LENGTH_LONG:
        value = va_arg(arguments, long);
        break;
      case FORMAT_LENGTH_LONG_LONG:
      case FORMAT_LENGTH_SIZE:
        value = va_arg(arguments, long long);
        break;
      }
      unsigned long long magnitude = value < 0 ? 0ULL - (unsigned long long)value : (unsigned long long)value;
      format_integer(sink, magnitude, value < 0, 10, 0, flags, width, precision);
      break;
    }
    case 'u':
    case 'x':
    case 'X':
    case 'o': {
      unsigned long long value = 0;
      switch (length) {
      case FORMAT_LENGTH_CHAR:
        value = (unsigned char)va_arg(arguments, unsigned);
        break;
      case FORMAT_LENGTH_SHORT:
        value = (unsigned short)va_arg(arguments, unsigned);
        break;
      case FORMAT_LENGTH_INT:
        value = va_arg(arguments, unsigned);
        break;
      case FORMAT_LENGTH_LONG:
        value = va_arg(arguments, unsigned long);
        break;
      case FORMAT_LENGTH_LONG_LONG:
      case FORMAT_LENGTH_SIZE:
        value = va_arg(arguments, unsigned long long);
        break;
      }
      int base = conversion == 'u' ? 10 : conversion == 'o' ? 8 : 16;
      format_integer(sink, value, 0, base, conversion == 'X', flags & ~(FLAG_PLUS | FLAG_SPACE), width, precision);
      break;
    }
    case 'p': {
      unsigned long long value = (unsigned long long)(uintptr_t)va_arg(arguments, void *);
      format_integer(sink, value, 0, 16, 0, flags | FLAG_ALTERNATE, width, precision);
      break;
    }
    case 'c': {
      char character = (char)va_arg(arguments, int);
      sink_field(sink, flags & ~FLAG_ZERO, width, "", 0, &character, 1);
      break;
    }
    case 's': {
      const char *text = va_arg(arguments, const char *);
      if (!text)
        text = "(null)";
      size_t count = precision >= 0 ? strnlen(text, (size_t)precision) : strlen(text);
      sink_field(sink, flags & ~FLAG_ZERO, width, "", 0, text, count);
      break;
    }
    case 'f':
    case 'F':
    case 'e':
    case 'E':
    case 'g':
    case 'G':
      format_double(sink, va_arg(arguments, double), conversion, flags, width, precision);
      break;
    case '%':
      sink_byte(sink, '%');
      break;
    default:
      // A conversion that the thin libc does not know ends the output, as a
      // refusal: nothing guesses what the caller meant.
      errno = EINVAL;
      return -1;
    }
  }
  return 0;
}

int vsnprintf(char *restrict destination, size_t capacity, const char *restrict format, va_list arguments) {
  Format_Sink sink = {destination, capacity, 0, 0, 0};
  va_list copy;
  va_copy(copy, arguments);
  int status = format_into(&sink, format, copy);
  va_end(copy);
  if (capacity > 0)
    destination[sink.written < capacity ? sink.written : capacity - 1] = 0;
  if (status < 0 || sink.written > INT_MAX)
    return -1;
  return (int)sink.written;
}

int snprintf(char *restrict destination, size_t capacity, const char *restrict format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vsnprintf(destination, capacity, format, arguments);
  va_end(arguments);
  return count;
}

int sprintf(char *restrict destination, const char *restrict format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vsnprintf(destination, (size_t)INT_MAX, format, arguments);
  va_end(arguments);
  return count;
}

int vfprintf(FILE *restrict stream, const char *restrict format, va_list arguments) {
  if (!stream || !stream->open) {
    errno = EBADF;
    return -1;
  }
  Format_Sink sink = {0, 0, stream, 0, 0};
  va_list copy;
  va_copy(copy, arguments);
  int status = format_into(&sink, format, copy);
  va_end(copy);
  if (status < 0 || sink.failed || sink.written > INT_MAX)
    return -1;
  return (int)sink.written;
}

int fprintf(FILE *restrict stream, const char *restrict format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vfprintf(stream, format, arguments);
  va_end(arguments);
  return count;
}

int printf(const char *restrict format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vfprintf(stdout, format, arguments);
  va_end(arguments);
  return count;
}

// ---- Memory streams ------------------------------------------------------------------

FILE *modus_standard_input;
FILE *modus_standard_output;
FILE *modus_standard_diagnostic;

void modus_standard_streams_set(FILE *input, FILE *output, FILE *diagnostic) {
  modus_standard_input = input;
  modus_standard_output = output;
  modus_standard_diagnostic = diagnostic;
}

FILE *modus_memory_stream_open(FILE *stream, void *bytes, size_t capacity, size_t length, Modus_Stream_Mode mode) {
  if (!stream || (!bytes && capacity > 0) || length > capacity)
    return 0;
  switch (mode) {
  case MODUS_STREAM_READ:
  case MODUS_STREAM_APPEND:
    break;
  case MODUS_STREAM_WRITE:
    length = 0;
    break;
  default:
    // The border of the stream: a word that names no mode is refused.
    return 0;
  }
  stream->bytes = bytes;
  stream->capacity = capacity;
  stream->length = length;
  stream->position = mode == MODUS_STREAM_APPEND ? length : 0;
  stream->mode = mode;
  stream->open = 1;
  stream->error = 0;
  stream->end_of_file = 0;
  stream->pushed_back = -1;
  return stream;
}

// A program has no path: each name is refused, as a name that does not exist
// (docs/PROPERTIES.md, "8. No global, mutable, shared file system").
FILE *fopen(const char *restrict name, const char *restrict mode) {
  (void)name;
  (void)mode;
  errno = ENOENT;
  return 0;
}

// A program has no path to open again either: the stream is closed and the
// name is refused.
FILE *freopen(const char *restrict name, const char *restrict mode, FILE *restrict stream) {
  (void)mode;
  if (stream)
    stream->open = 0;
  errno = name ? ENOENT : EBADF;
  return 0;
}

int fclose(FILE *stream) {
  if (!stream || !stream->open) {
    errno = EBADF;
    return EOF;
  }
  stream->open = 0;
  return 0;
}

int fflush(FILE *stream) {
  if (stream && !stream->open) {
    errno = EBADF;
    return EOF;
  }
  return 0;
}

static int stream_writable(FILE *stream) {
  return stream && stream->open && stream->mode != MODUS_STREAM_READ;
}

static int stream_readable(FILE *stream) { return stream && stream->open && stream->mode == MODUS_STREAM_READ; }

size_t fwrite(const void *restrict source, size_t size, size_t count, FILE *restrict stream) {
  if (!stream_writable(stream)) {
    if (stream)
      stream->error = 1;
    errno = EBADF;
    return 0;
  }
  if (size == 0 || count == 0)
    return 0;
  if (count > (size_t)-1 / size) {
    stream->error = 1;
    return 0;
  }
  size_t wanted = size * count;
  size_t room = stream->capacity - stream->position;
  size_t taken = wanted < room ? wanted : room;
  memcpy(stream->bytes + stream->position, source, taken);
  stream->position += taken;
  if (stream->position > stream->length)
    stream->length = stream->position;
  if (taken < wanted)
    stream->error = 1;
  return taken / size;
}

int fputc(int character, FILE *stream) {
  unsigned char byte = (unsigned char)character;
  return fwrite(&byte, 1, 1, stream) == 1 ? byte : EOF;
}

int putc(int character, FILE *stream) { return fputc(character, stream); }
int putchar(int character) { return fputc(character, stdout); }

int fputs(const char *restrict text, FILE *restrict stream) {
  size_t count = strlen(text);
  return fwrite(text, 1, count, stream) == count ? 0 : EOF;
}

int puts(const char *text) { return fputs(text, stdout) == EOF || fputc('\n', stdout) == EOF ? EOF : 0; }

int fgetc(FILE *stream) {
  if (!stream_readable(stream)) {
    if (stream)
      stream->error = 1;
    errno = EBADF;
    return EOF;
  }
  if (stream->pushed_back >= 0) {
    int byte = stream->pushed_back;
    stream->pushed_back = -1;
    return byte;
  }
  if (stream->position >= stream->length) {
    stream->end_of_file = 1;
    return EOF;
  }
  return stream->bytes[stream->position++];
}

int getc(FILE *stream) { return fgetc(stream); }

int ungetc(int character, FILE *stream) {
  if (!stream_readable(stream) || character == EOF || stream->pushed_back >= 0)
    return EOF;
  stream->pushed_back = (unsigned char)character;
  stream->end_of_file = 0;
  return (unsigned char)character;
}

size_t fread(void *restrict destination, size_t size, size_t count, FILE *restrict stream) {
  if (size == 0 || count == 0)
    return 0;
  if (count > (size_t)-1 / size)
    return 0;
  unsigned char *bytes = destination;
  size_t wanted = size * count;
  size_t taken = 0;
  while (taken < wanted) {
    int byte = fgetc(stream);
    if (byte == EOF)
      break;
    bytes[taken++] = (unsigned char)byte;
  }
  return taken / size;
}

char *fgets(char *restrict destination, int count, FILE *restrict stream) {
  if (count <= 0)
    return 0;
  int taken = 0;
  while (taken < count - 1) {
    int byte = fgetc(stream);
    if (byte == EOF)
      break;
    destination[taken++] = (char)byte;
    if (byte == '\n')
      break;
  }
  if (taken == 0)
    return 0;
  destination[taken] = 0;
  return destination;
}

int fseek(FILE *stream, long offset, int origin) {
  if (!stream || !stream->open) {
    errno = EBADF;
    return -1;
  }
  long base;
  switch (origin) {
  case SEEK_SET:
    base = 0;
    break;
  case SEEK_CUR:
    base = (long)stream->position;
    break;
  case SEEK_END:
    base = (long)stream->length;
    break;
  default:
    errno = EINVAL;
    return -1;
  }
  if ((offset < 0 && base < -offset) || (offset > 0 && (unsigned long)offset > stream->capacity - (unsigned long)base)) {
    errno = EINVAL;
    return -1;
  }
  stream->position = (size_t)(base + offset);
  stream->pushed_back = -1;
  stream->end_of_file = 0;
  return 0;
}

long ftell(FILE *stream) {
  if (!stream || !stream->open) {
    errno = EBADF;
    return -1;
  }
  return (long)stream->position - (stream->pushed_back >= 0 ? 1 : 0);
}

void rewind(FILE *stream) {
  if (fseek(stream, 0, SEEK_SET) == 0)
    stream->error = 0;
}

int feof(FILE *stream) { return stream && stream->end_of_file; }
int ferror(FILE *stream) { return stream && stream->error; }
void clearerr(FILE *stream) {
  if (stream) {
    stream->error = 0;
    stream->end_of_file = 0;
  }
}

// ---- Non-local jumps ----------------------------------------------------------------

#ifndef __chibicc__
// setjmp keeps the registers that a call keeps, the stack pointer of the
// caller and its return address; longjmp puts them back and returns the value
// from setjmp, 1 in place of 0, as C asks. Under chibicc,
// modus_thin_libc_chibicc.s supplies the same routines.
__asm__(".text\n"
        ".globl setjmp\n"
        ".hidden setjmp\n"
        ".type setjmp,@function\n"
        "setjmp:\n"
        "  mov %rbx, 0(%rdi)\n"
        "  mov %rbp, 8(%rdi)\n"
        "  mov %r12, 16(%rdi)\n"
        "  mov %r13, 24(%rdi)\n"
        "  mov %r14, 32(%rdi)\n"
        "  mov %r15, 40(%rdi)\n"
        "  lea 8(%rsp), %rdx\n"
        "  mov %rdx, 48(%rdi)\n"
        "  mov (%rsp), %rdx\n"
        "  mov %rdx, 56(%rdi)\n"
        "  xor %eax, %eax\n"
        "  ret\n"
        ".size setjmp, .-setjmp\n"
        ".globl longjmp\n"
        ".hidden longjmp\n"
        ".type longjmp,@function\n"
        "longjmp:\n"
        "  mov %esi, %eax\n"
        "  test %eax, %eax\n"
        "  jnz 1f\n"
        "  inc %eax\n"
        "1:\n"
        "  mov 0(%rdi), %rbx\n"
        "  mov 8(%rdi), %rbp\n"
        "  mov 16(%rdi), %r12\n"
        "  mov 24(%rdi), %r13\n"
        "  mov 32(%rdi), %r14\n"
        "  mov 40(%rdi), %r15\n"
        "  mov 48(%rdi), %rsp\n"
        "  jmp *56(%rdi)\n"
        ".size longjmp, .-longjmp\n");
#endif

// ---- Time and locale --------------------------------------------------------------------

time_t time(time_t *place) {
  if (place)
    *place = 0;
  return 0;
}

clock_t clock(void) { return 0; }

static char decimal_point_text[] = ".";
static char empty_text[] = "";
static struct lconv c_locale = {decimal_point_text, empty_text, empty_text};
struct lconv *localeconv(void) { return &c_locale; }
