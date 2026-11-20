// The thin libc of the system: streams in memory and the formats of
// printf (src/md/features/c_compiler.md, "The thin libc").
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <thin_libc.h>

typedef enum {
  STREAM_READ,    // A file of the table: fread takes its bytes.
  STREAM_GROWING, // open_memstream: a buffer of the arena that grows.
  STREAM_FIXED,   // The diagnostic: memory of the module that never grows.
} Stream_Kind;

struct Memory_Stream {
  Stream_Kind kind;
  char *bytes;
  size_t size;      // The bytes written, or the bytes of the file.
  size_t capacity;  // The bytes at `bytes`, the byte 0 after the text included.
  size_t position;  // The next byte that fread takes.
  size_t dropped;   // The bytes that a fixed stream had no room for.
  char **buffer_of_caller;
  size_t *size_of_caller;
};

static FILE input_stream = {.kind = STREAM_READ, .bytes = "", .size = 0};
static FILE diagnostic_stream = {.kind = STREAM_FIXED};

FILE *stdin = &input_stream;
FILE *stdout = &diagnostic_stream;
FILE *stderr = &diagnostic_stream;

static const Readable_File *table_files;
static size_t table_file_count;

void thin_libc_files_set(const Readable_File *files, size_t count) {
  table_files = files;
  table_file_count = count;
}

const Readable_File *thin_libc_file_find(const char *name) {
  for (size_t index = 0; index < table_file_count; index++)
    if (strcmp(table_files[index].name, name) == 0)
      return &table_files[index];
  return NULL;
}

void thin_libc_diagnostic_set(char *bytes, size_t capacity) {
  diagnostic_stream = (FILE){.kind = STREAM_FIXED, .bytes = bytes, .capacity = capacity};
  if (capacity > 0)
    bytes[0] = '\0';
}

size_t thin_libc_diagnostic_size(void) {
  return diagnostic_stream.size;
}

size_t thin_libc_diagnostic_dropped(void) {
  return diagnostic_stream.dropped;
}

FILE *fopen(const char *name, const char *mode) {
  if (strcmp(mode, "r") != 0 && strcmp(mode, "rb") != 0) {
    errno = EINVAL;
    return NULL;
  }
  const Readable_File *file = thin_libc_file_find(name);
  if (!file) {
    errno = ENOENT;
    return NULL;
  }
  FILE *stream = calloc(1, sizeof(FILE));
  stream->kind = STREAM_READ;
  stream->bytes = (char *)file->bytes;
  stream->size = file->size;
  return stream;
}

FILE *open_memstream(char **buffer, size_t *size) {
  FILE *stream = calloc(1, sizeof(FILE));
  stream->kind = STREAM_GROWING;
  stream->capacity = 256;
  stream->bytes = malloc(stream->capacity);
  stream->bytes[0] = '\0';
  stream->buffer_of_caller = buffer;
  stream->size_of_caller = size;
  *buffer = stream->bytes;
  *size = 0;
  return stream;
}

// stream_write gives the bytes that it wrote. A growing stream asks the
// arena for room, which ends the work when the budget refuses; a fixed
// stream drops what it has no room for, and counts it.
static size_t stream_write(FILE *stream, const char *bytes, size_t count) {
  switch (stream->kind) {
  case STREAM_READ:
    errno = EINVAL;
    return 0;
  case STREAM_FIXED: {
    size_t room = stream->capacity == 0 ? 0 : stream->capacity - 1 - stream->size;
    size_t taken = count < room ? count : room;
    memcpy(stream->bytes + stream->size, bytes, taken);
    stream->size += taken;
    stream->dropped += count - taken;
    if (stream->capacity > 0)
      stream->bytes[stream->size] = '\0';
    return taken;
  }
  case STREAM_GROWING: {
    if (count > SIZE_MAX - 1 - stream->size) {
      errno = ENOMEM;
      return 0;
    }
    size_t needed = stream->size + count + 1;
    if (needed > stream->capacity) {
      size_t capacity = stream->capacity;
      while (capacity < needed)
        capacity = capacity > SIZE_MAX / 2 ? needed : capacity * 2;
      stream->bytes = realloc(stream->bytes, capacity);
      stream->capacity = capacity;
    }
    memcpy(stream->bytes + stream->size, bytes, count);
    stream->size += count;
    stream->bytes[stream->size] = '\0';
    *stream->buffer_of_caller = stream->bytes;
    *stream->size_of_caller = stream->size;
    return count;
  }
  }
  return 0;
}

size_t fread(void *bytes, size_t size, size_t count, FILE *stream) {
  if (stream->kind != STREAM_READ || size == 0 || count > SIZE_MAX / size)
    return 0;
  size_t wanted = size * count;
  size_t available = stream->size - stream->position;
  size_t taken = wanted < available ? wanted : available;
  // Whole items only, as fread gives a count of items.
  taken -= taken % size;
  memcpy(bytes, stream->bytes + stream->position, taken);
  stream->position += taken;
  return taken / size;
}

size_t fwrite(const void *bytes, size_t size, size_t count, FILE *stream) {
  if (size == 0 || count > SIZE_MAX / size)
    return 0;
  return stream_write(stream, bytes, size * count) / size;
}

int fputc(int character, FILE *stream) {
  char byte = (char)character;
  return stream_write(stream, &byte, 1) == 1 ? (unsigned char)byte : EOF;
}

// The buffer and the size of the caller are right after each write.
int fflush(FILE *stream) {
  (void)stream;
  return 0;
}

// Ends nothing: the memory of the stream ends with the arena.
int fclose(FILE *stream) {
  (void)stream;
  return 0;
}

// One conversion of a format.
typedef struct {
  bool left;      // `-`: the padding after the text.
  bool plus;      // `+`: a sign also before a positive number.
  bool space;     // ` `: a blank before a positive number.
  bool zero;      // `0`: zeros in place of blanks, after the sign.
  bool alternate; // `#`: `0x` before a hexadecimal number, `0` before an octal one.
  int width;      // -1: none.
  int precision;  // -1: none.
} Conversion;

// The written bytes of one call of vfprintf: a format of more than
// INT_MAX bytes returns INT_MAX, as no caller of the work reads more.
typedef struct {
  FILE *stream;
  size_t count;
} Output;

static void output_bytes(Output *output, const char *bytes, size_t count) {
  output->count += stream_write(output->stream, bytes, count);
}

static void output_repeat(Output *output, char character, int count) {
  for (int index = 0; index < count; index++)
    output_bytes(output, &character, 1);
}

// output_padded writes a prefix (a sign, `0x`), zeros, then the text, with
// the padding of the width before or after.
static void output_padded(Output *output, Conversion *conversion, const char *prefix, int zeros, const char *text, size_t length) {
  size_t prefix_length = strlen(prefix);
  size_t total = prefix_length + (size_t)zeros + length;
  int padding = conversion->width > 0 && (size_t)conversion->width > total ? conversion->width - (int)total : 0;
  bool zero_padding = conversion->zero && !conversion->left;
  if (!conversion->left && !zero_padding)
    output_repeat(output, ' ', padding);
  output_bytes(output, prefix, prefix_length);
  if (zero_padding)
    output_repeat(output, '0', padding);
  output_repeat(output, '0', zeros);
  output_bytes(output, text, length);
  if (conversion->left)
    output_repeat(output, ' ', padding);
}

static void output_integer(Output *output, Conversion *conversion, unsigned long long magnitude, bool negative, int base, bool upper, bool is_signed, bool is_pointer) {
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  // C11 7.21.6.1: with a precision, the flag `0` is ignored for an integer.
  if (conversion->precision >= 0)
    conversion->zero = false;
  char buffer[32];
  int length = 0;
  for (unsigned long long rest = magnitude; rest > 0; rest /= (unsigned)base)
    buffer[sizeof(buffer) - 1 - length++] = digits[rest % (unsigned)base];
  // A precision of 0 writes no digit for 0; with no precision, 0 is "0".
  if (magnitude == 0 && conversion->precision != 0)
    buffer[sizeof(buffer) - 1 - length++] = '0';
  int zeros = conversion->precision > length ? conversion->precision - length : 0;
  const char *prefix = "";
  if (is_signed) {
    if (negative)
      prefix = "-";
    else if (conversion->plus)
      prefix = "+";
    else if (conversion->space)
      prefix = " ";
  } else if (is_pointer || (conversion->alternate && base == 16 && magnitude != 0)) {
    prefix = upper ? "0X" : "0x";
  } else if (conversion->alternate && base == 8 && zeros == 0 && (length == 0 || buffer[sizeof(buffer) - length] != '0')) {
    zeros = 1;
  }
  output_padded(output, conversion, prefix, zeros, buffer + sizeof(buffer) - length, (size_t)length);
}

int vfprintf(FILE *stream, const char *format, va_list arguments) {
  Output output = {.stream = stream};
  for (const char *place = format; *place; place++) {
    if (*place != '%') {
      output_bytes(&output, place, 1);
      continue;
    }
    const char *start = place;
    place++;
    Conversion conversion = {.width = -1, .precision = -1};
    for (;; place++) {
      if (*place == '-')
        conversion.left = true;
      else if (*place == '+')
        conversion.plus = true;
      else if (*place == ' ')
        conversion.space = true;
      else if (*place == '0')
        conversion.zero = true;
      else if (*place == '#')
        conversion.alternate = true;
      else
        break;
    }
    if (*place == '*') {
      int width = va_arg(arguments, int);
      if (width < 0) {
        conversion.left = true;
        width = width == INT32_MIN ? INT32_MAX : -width;
      }
      conversion.width = width;
      place++;
    } else {
      for (conversion.width = 0; *place >= '0' && *place <= '9'; place++)
        conversion.width = conversion.width < 100000 ? conversion.width * 10 + (*place - '0') : conversion.width;
    }
    if (*place == '.') {
      place++;
      if (*place == '*') {
        int precision = va_arg(arguments, int);
        conversion.precision = precision < 0 ? -1 : precision;
        place++;
      } else {
        for (conversion.precision = 0; *place >= '0' && *place <= '9'; place++)
          conversion.precision = conversion.precision < 100000 ? conversion.precision * 10 + (*place - '0') : conversion.precision;
      }
    }
    // The size of the argument: 0 int, 1 char, 2 short, 3 long, 4 long long.
    int size = 0;
    if (place[0] == 'h' && place[1] == 'h') {
      size = 1;
      place += 2;
    } else if (place[0] == 'h') {
      size = 2;
      place++;
    } else if (place[0] == 'l' && place[1] == 'l') {
      size = 4;
      place += 2;
    } else if (place[0] == 'l' || place[0] == 'z' || place[0] == 'j' || place[0] == 't' || place[0] == 'L') {
      size = 3;
      place++;
    }

    switch (*place) {
    case 'd':
    case 'i': {
      long long value;
      if (size == 3 || size == 4)
        value = size == 3 ? va_arg(arguments, long) : va_arg(arguments, long long);
      else
        value = va_arg(arguments, int);
      if (size == 1)
        value = (signed char)value;
      else if (size == 2)
        value = (short)value;
      bool negative = value < 0;
      unsigned long long magnitude = negative ? 0ULL - (unsigned long long)value : (unsigned long long)value;
      output_integer(&output, &conversion, magnitude, negative, 10, false, true, false);
      break;
    }
    case 'u':
    case 'x':
    case 'X':
    case 'o': {
      unsigned long long value;
      if (size == 3 || size == 4)
        value = size == 3 ? va_arg(arguments, unsigned long) : va_arg(arguments, unsigned long long);
      else
        value = va_arg(arguments, unsigned int);
      if (size == 1)
        value = (unsigned char)value;
      else if (size == 2)
        value = (unsigned short)value;
      int base = *place == 'o' ? 8 : *place == 'u' ? 10 : 16;
      output_integer(&output, &conversion, value, false, base, *place == 'X', false, false);
      break;
    }
    case 'p':
      output_integer(&output, &conversion, (uintptr_t)va_arg(arguments, void *), false, 16, false, false, true);
      break;
    case 'c': {
      char character = (char)va_arg(arguments, int);
      output_padded(&output, &conversion, "", 0, &character, 1);
      break;
    }
    case 's': {
      const char *text = va_arg(arguments, const char *);
      if (!text)
        text = "(null)";
      // A precision bounds the read: a view of a token has no byte 0.
      size_t length = 0;
      while ((conversion.precision < 0 || length < (size_t)conversion.precision) && text[length])
        length++;
      conversion.precision = -1;
      conversion.zero = false;
      output_padded(&output, &conversion, "", 0, text, length);
      break;
    }
    case 'f':
    case 'F':
    case 'e':
    case 'E':
    case 'g':
    case 'G':
    case 'a':
    case 'A':
      // No floating point: the argument is read, so the next ones stay
      // in place, and `?` says that the value is not written.
      (void)va_arg(arguments, double);
      output_bytes(&output, "?", 1);
      break;
    case '%':
      output_bytes(&output, "%", 1);
      break;
    case '\0':
      // A format that ends inside a conversion: its bytes as they are.
      output_bytes(&output, start, (size_t)(place - start));
      place--;
      break;
    default:
      output_bytes(&output, start, (size_t)(place - start + 1));
      break;
    }
  }
  return output.count > INT32_MAX ? INT32_MAX : (int)output.count;
}

int fprintf(FILE *stream, const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vfprintf(stream, format, arguments);
  va_end(arguments);
  return count;
}

int printf(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  int count = vfprintf(stdout, format, arguments);
  va_end(arguments);
  return count;
}
