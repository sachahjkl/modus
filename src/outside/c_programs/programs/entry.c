// The exports of the test module of the C programs: each export takes and
// gives integers, as the module contract asks, and calls one procedure of the
// thin libc, of an adapter or of a test program. An address is an integer: the
// host test lends the memory and reads it back.
#include "kv_store.h"
#include "modus_lua_conf.h"
#include "modus_vfs.h"
#include "programs.h"

typedef long long Word;

static double double_of(Word bits) {
  double value;
  memcpy(&value, &bits, sizeof value);
  return value;
}

static Word bits_of(double value) {
  Word bits;
  memcpy(&bits, &value, sizeof bits);
  return bits;
}

Word call_format_double(Word output, Word capacity, Word format, Word bits) {
  return snprintf((char *)output, (size_t)capacity, (const char *)format, double_of(bits));
}

Word call_format_integer(Word output, Word capacity, Word format, Word value) {
  return snprintf((char *)output, (size_t)capacity, (const char *)format, (long long)value);
}

Word call_parse_double(Word text, Word end_place, Word error_place) {
  char *end;
  errno = 0;
  double value = strtod((const char *)text, &end);
  *(Word *)end_place = (Word)(end - (const char *)text);
  *(Word *)error_place = errno;
  return bits_of(value);
}

Word call_parse_integer(Word text, Word base, Word end_place, Word error_place) {
  char *end;
  errno = 0;
  long long value = strtoll((const char *)text, &end, (int)base);
  *(Word *)end_place = (Word)(end - (const char *)text);
  *(Word *)error_place = errno;
  return value;
}

Word call_parse_unsigned(Word text, Word base, Word end_place, Word error_place) {
  char *end;
  errno = 0;
  unsigned long long value = strtoull((const char *)text, &end, (int)base);
  *(Word *)end_place = (Word)(end - (const char *)text);
  *(Word *)error_place = errno;
  return (Word)value;
}

Word call_heap_record_size(void) { return (Word)sizeof(Modus_Heap); }
Word call_heap_init(Word heap, Word arena, Word size) { return modus_heap_init((Modus_Heap *)heap, (void *)arena, (size_t)size); }
Word call_heap_allocate(Word heap, Word size) { return (Word)modus_heap_allocate((Modus_Heap *)heap, (size_t)size); }
Word call_heap_release(Word heap, Word payload) { return modus_heap_release((Modus_Heap *)heap, (void *)payload); }
Word call_heap_resize(Word heap, Word payload, Word size) {
  return (Word)modus_heap_resize((Modus_Heap *)heap, (void *)payload, (size_t)size);
}
Word call_heap_check(Word heap) { return modus_heap_check((const Modus_Heap *)heap); }

static int compare_words(const void *left, const void *right) {
  Word a = *(const Word *)left;
  Word b = *(const Word *)right;
  return (a > b) - (a < b);
}

Word call_sort_integers(Word values, Word count) {
  qsort((void *)values, (size_t)count, sizeof(Word), compare_words);
  return 0;
}

static jmp_buf jump_target;
static volatile long jump_depth_reached;

// noinline: each level is a real frame, so longjmp unwinds a real stack.
__attribute__((noinline)) static void descend(long depth, long value) {
  char frame[64];
  memset(frame, (int)depth, sizeof frame);
  jump_depth_reached = depth;
  if (depth == 0)
    longjmp(jump_target, (int)value);
  descend(depth - 1, value + frame[depth % 64] - (char)depth);
}

Word call_jump(Word depth, Word value) {
  // Values that a call keeps must survive the jump.
  volatile long kept = 7;
  jump_depth_reached = -1;
  int result = setjmp(jump_target);
  if (result == 0) {
    descend(depth, value);
    return -1;
  }
  return (Word)result * 1000 + jump_depth_reached + (kept - 7);
}

Word call_stream_write(Word buffer, Word capacity, Word text, Word repeat) {
  FILE stream;
  if (!modus_memory_stream_open(&stream, (void *)buffer, (size_t)capacity, 0, MODUS_STREAM_WRITE))
    return -1;
  for (Word index = 0; index < repeat; index++)
    fprintf(&stream, "%s", (const char *)text);
  Word result = (Word)stream.length * 2 + ferror(&stream);
  fclose(&stream);
  return result;
}

Word call_stream_read_lines(Word buffer, Word length, Word line_count_place) {
  FILE stream;
  if (!modus_memory_stream_open(&stream, (void *)buffer, (size_t)length, (size_t)length, MODUS_STREAM_READ))
    return -1;
  Word sum = 0;
  Word lines = 0;
  char line[16];
  for (;;) {
    int first = fgetc(&stream);
    if (first == EOF)
      break;
    if (ungetc(first, &stream) != first)
      return -2;
    // A second ungetc is refused: one byte of push back only.
    if (ungetc('x', &stream) != EOF)
      return -3;
    if (!fgets(line, sizeof line, &stream))
      return -4;
    for (char *at = line; *at; at++)
      sum += (unsigned char)*at;
    if (strchr(line, '\n'))
      lines++;
  }
  if (!feof(&stream))
    return -5;
  *(Word *)line_count_place = lines;
  return sum;
}

Word call_open_by_name(Word name) {
  errno = 0;
  FILE *stream = fopen((const char *)name, "r");
  return stream == 0 && errno == ENOENT;
}

typedef enum Math_Operation {
  MATH_FLOOR = 1,
  MATH_CEIL = 2,
  MATH_TRUNC = 3,
  MATH_FABS = 4,
  MATH_FMOD = 5,
  MATH_SQRT = 6,
  MATH_LDEXP = 7,
  MATH_FREXP_FRACTION = 8,
  MATH_FREXP_EXPONENT = 9,
} Math_Operation;

Word call_math(Word operation, Word left_bits, Word right_bits) {
  double left = double_of(left_bits);
  double right = double_of(right_bits);
  int exponent = 0;
  switch ((Math_Operation)operation) {
  case MATH_FLOOR:
    return bits_of(floor(left));
  case MATH_CEIL:
    return bits_of(ceil(left));
  case MATH_TRUNC:
    return bits_of(trunc(left));
  case MATH_FABS:
    return bits_of(fabs(left));
  case MATH_FMOD:
    return bits_of(fmod(left, right));
  case MATH_SQRT:
    return bits_of(sqrt(left));
  case MATH_LDEXP:
    return bits_of(ldexp(left, (int)right_bits));
  case MATH_FREXP_FRACTION:
    return bits_of(frexp(left, &exponent));
  case MATH_FREXP_EXPONENT:
    frexp(left, &exponent);
    return exponent;
  }
  // The border of the export: a word that names no operation is refused.
  return 0x7ff8dead00000000LL;
}

Word call_codec_compress(Word heap, Word input, Word count, Word output, Word capacity) {
  return codec_compress((Modus_Heap *)heap, (const unsigned char *)input, (size_t)count, (unsigned char *)output,
                        (size_t)capacity);
}

Word call_codec_decompress(Word input, Word count, Word output, Word capacity) {
  return codec_decompress((const unsigned char *)input, (size_t)count, (unsigned char *)output, (size_t)capacity);
}

Word call_codec_crc32(Word bytes, Word count) { return codec_crc32((const unsigned char *)bytes, (size_t)count); }

// The request of a script: the host test fills the first seven words and
// reads the last two.
typedef struct Script_Request {
  const char *source;
  Word source_count;
  char *output;
  Word output_capacity;
  char *diagnostic;
  Word diagnostic_capacity;
  Modus_Heap *heap;
  Word output_length;
  Word diagnostic_length;
} Script_Request;

Word call_script_run(Word request_address) {
  Script_Request *request = (Script_Request *)request_address;
  Script_Status status = script_run(request->source, (size_t)request->source_count, request->output,
                                    (size_t)request->output_capacity, request->diagnostic,
                                    (size_t)request->diagnostic_capacity, request->heap);
  request->output_length = (Word)modus_lua_output_length();
  request->diagnostic_length = (Word)modus_lua_diagnostic_length();
  return status;
}

Word call_vfs_record_sizes(Word place) {
  Word *sizes = (Word *)place;
  sizes[0] = (Word)sizeof(Modus_Vfs_Store);
  sizes[1] = (Word)sizeof(sqlite3_vfs);
  sizes[2] = (Word)sizeof(Modus_Vfs_File);
  return 0;
}

Word call_vfs_store_init(Word store, Word bytes, Word byte_count, Word capacities, Word slot_count, Word seed) {
  return modus_vfs_store_init((Modus_Vfs_Store *)store, (unsigned char *)bytes, byte_count,
                              (const sqlite3_int64 *)capacities, (int)slot_count, (unsigned long long)seed);
}

Word call_vfs_make(Word vfs, Word store) {
  return (Word)modus_vfs_make((sqlite3_vfs *)vfs, (Modus_Vfs_Store *)store, "modus");
}

Word call_vfs_open(Word vfs, Word name, Word file, Word flags) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  int out_flags = 0;
  return v->xOpen(v, (const char *)name, (sqlite3_file *)file, (int)flags, &out_flags);
}

Word call_vfs_delete(Word vfs, Word name) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  return v->xDelete(v, (const char *)name, 0);
}

Word call_vfs_access(Word vfs, Word name, Word flags, Word place) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  int result = -1;
  int code = v->xAccess(v, (const char *)name, (int)flags, &result);
  *(Word *)place = result;
  return code;
}

Word call_vfs_full_pathname(Word vfs, Word name, Word count, Word output) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  return v->xFullPathname(v, (const char *)name, (int)count, (char *)output);
}

Word call_vfs_randomness(Word vfs, Word count, Word output) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  return v->xRandomness(v, (int)count, (char *)output);
}

Word call_vfs_current_time(Word vfs, Word place) {
  sqlite3_vfs *v = (sqlite3_vfs *)vfs;
  return v->xCurrentTimeInt64(v, (sqlite3_int64 *)place);
}

static const sqlite3_io_methods *methods_of(Word file) { return ((sqlite3_file *)file)->pMethods; }

Word call_file_read(Word file, Word buffer, Word amount, Word offset) {
  return methods_of(file)->xRead((sqlite3_file *)file, (void *)buffer, (int)amount, offset);
}

Word call_file_write(Word file, Word buffer, Word amount, Word offset) {
  return methods_of(file)->xWrite((sqlite3_file *)file, (const void *)buffer, (int)amount, offset);
}

Word call_file_truncate(Word file, Word size) { return methods_of(file)->xTruncate((sqlite3_file *)file, size); }

Word call_file_size(Word file, Word place) {
  return methods_of(file)->xFileSize((sqlite3_file *)file, (sqlite3_int64 *)place);
}

Word call_file_lock(Word file, Word level) { return methods_of(file)->xLock((sqlite3_file *)file, (int)level); }
Word call_file_unlock(Word file, Word level) { return methods_of(file)->xUnlock((sqlite3_file *)file, (int)level); }

Word call_file_reserved(Word file, Word place) {
  int reserved = -1;
  int code = methods_of(file)->xCheckReservedLock((sqlite3_file *)file, &reserved);
  *(Word *)place = reserved;
  return code;
}

Word call_file_close(Word file) { return methods_of(file)->xClose((sqlite3_file *)file); }

Word call_kv_open(Word place, Word heap, Word vfs, Word name) {
  return kv_open((Kv_Store **)place, (Modus_Heap *)heap, (sqlite3_vfs *)vfs, (const char *)name);
}
Word call_kv_begin(Word store) { return kv_begin((Kv_Store *)store); }
Word call_kv_put(Word store, Word key, Word value) { return kv_put((Kv_Store *)store, key, value); }
Word call_kv_get(Word store, Word key, Word place) { return kv_get((Kv_Store *)store, key, (long long *)place); }
Word call_kv_sum(Word store, Word low, Word high, Word sum_place, Word count_place) {
  return kv_sum((Kv_Store *)store, low, high, (long long *)sum_place, (long long *)count_place);
}
Word call_kv_commit(Word store, Word page_write_limit) { return kv_commit((Kv_Store *)store, (long)page_write_limit); }
Word call_kv_rollback(Word store) { return kv_rollback((Kv_Store *)store); }
Word call_kv_check(Word store, Word place) { return kv_check((Kv_Store *)store, (long long *)place); }
Word call_kv_close(Word store) { return kv_close((Kv_Store *)store); }
Word call_kv_abandon(Word store) {
  kv_abandon((Kv_Store *)store);
  return 0;
}
