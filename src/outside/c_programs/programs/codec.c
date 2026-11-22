// A compression codec in C, the test program of the configuration of zstd:
// LZ77 with a hash table, runs as matches at distance 1, and a frame with
// the size and the CRC32 of the content. Its memory comes from the custom
// memory callbacks of modus_zstd_conf.h, as the contexts of zstd do.
#include "programs.h"
#include "modus_zstd_conf.h"

#define CODEC_MAGIC 0x315a434dU // "MCZ1"
#define CODEC_HEADER_SIZE 12
#define CODEC_HASH_BITS 12
#define CODEC_MINIMUM_MATCH 4
#define CODEC_LARGEST_OFFSET 65535

static unsigned int crc32_table[256];
static int crc32_table_ready;

unsigned int codec_crc32(const unsigned char *bytes, size_t count) {
  if (!crc32_table_ready) {
    for (unsigned int index = 0; index < 256; index++) {
      unsigned int value = index;
      for (int bit = 0; bit < 8; bit++)
        value = (value >> 1) ^ (0xEDB88320U & (0U - (value & 1U)));
      crc32_table[index] = value;
    }
    crc32_table_ready = 1;
  }
  unsigned int crc = 0xFFFFFFFFU;
  for (size_t index = 0; index < count; index++)
    crc = crc32_table[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
  return ~crc;
}

static void write_u32(unsigned char *at, unsigned int value) {
  at[0] = (unsigned char)value;
  at[1] = (unsigned char)(value >> 8);
  at[2] = (unsigned char)(value >> 16);
  at[3] = (unsigned char)(value >> 24);
}

static unsigned int read_u32(const unsigned char *at) {
  return (unsigned int)at[0] | (unsigned int)at[1] << 8 | (unsigned int)at[2] << 16 | (unsigned int)at[3] << 24;
}

static unsigned int hash_of(const unsigned char *at) {
  return (read_u32(at) * 2654435761U) >> (32 - CODEC_HASH_BITS);
}

typedef struct Codec_Writer {
  unsigned char *bytes;
  size_t capacity;
  size_t length;
  int full;
} Codec_Writer;

static void put_byte(Codec_Writer *writer, unsigned char value) {
  if (writer->length < writer->capacity)
    writer->bytes[writer->length++] = value;
  else
    writer->full = 1;
}

static void put_length(Codec_Writer *writer, size_t rest) {
  while (rest >= 255) {
    put_byte(writer, 255);
    rest -= 255;
  }
  put_byte(writer, (unsigned char)rest);
}

// One sequence: a token, the literals, then the offset and the length of a
// match. The last sequence of a frame has literals only.
static void put_sequence(Codec_Writer *writer, const unsigned char *literals, size_t literal_count, size_t offset,
                         size_t match_length) {
  size_t literal_code = literal_count < 15 ? literal_count : 15;
  size_t match_code = 0;
  if (match_length > 0)
    match_code = match_length - CODEC_MINIMUM_MATCH < 15 ? match_length - CODEC_MINIMUM_MATCH : 15;
  put_byte(writer, (unsigned char)(literal_code << 4 | match_code));
  if (literal_code == 15)
    put_length(writer, literal_count - 15);
  for (size_t index = 0; index < literal_count; index++)
    put_byte(writer, literals[index]);
  if (match_length == 0)
    return;
  put_byte(writer, (unsigned char)offset);
  put_byte(writer, (unsigned char)(offset >> 8));
  if (match_code == 15)
    put_length(writer, match_length - CODEC_MINIMUM_MATCH - 15);
}

long codec_compress(Modus_Heap *heap, const unsigned char *input, size_t input_count, unsigned char *output,
                    size_t output_capacity) {
  if (!heap || (!input && input_count > 0) || !output)
    return CODEC_REFUSAL_BAD_ARGUMENT;
  if (input_count > 0xFFFFFFFFU)
    return CODEC_REFUSAL_INPUT_TOO_LARGE;
  if (output_capacity < CODEC_HEADER_SIZE + 1)
    return CODEC_REFUSAL_OUTPUT_TOO_SMALL;
  unsigned int *table = modus_zstd_allocate(heap, sizeof(unsigned int) << CODEC_HASH_BITS);
  if (!table)
    return CODEC_REFUSAL_OUT_OF_MEMORY;
  memset(table, 0xFF, sizeof(unsigned int) << CODEC_HASH_BITS);

  Codec_Writer writer = {output, output_capacity, CODEC_HEADER_SIZE, 0};
  write_u32(output, CODEC_MAGIC);
  write_u32(output + 4, (unsigned int)input_count);
  write_u32(output + 8, codec_crc32(input, input_count));

  size_t anchor = 0;
  size_t at = 0;
  // The last match ends 5 bytes before the end, so that the reader of a
  // match never needs a byte past the input.
  size_t match_limit = input_count > 5 ? input_count - 5 : 0;
  while (at + CODEC_MINIMUM_MATCH <= match_limit && !writer.full) {
    unsigned int hash = hash_of(input + at);
    unsigned int candidate = table[hash];
    table[hash] = (unsigned int)at;
    size_t offset = at - candidate;
    if (candidate != 0xFFFFFFFFU && offset > 0 && offset <= CODEC_LARGEST_OFFSET &&
        read_u32(input + candidate) == read_u32(input + at)) {
      size_t length = CODEC_MINIMUM_MATCH;
      while (at + length < match_limit && input[candidate + length] == input[at + length])
        length++;
      put_sequence(&writer, input + anchor, at - anchor, offset, length);
      at += length;
      anchor = at;
      continue;
    }
    at++;
  }
  put_sequence(&writer, input + anchor, input_count - anchor, 0, 0);
  modus_zstd_free(heap, table);
  if (writer.full)
    return CODEC_REFUSAL_OUTPUT_TOO_SMALL;
  return (long)writer.length;
}

static int take_length(const unsigned char *input, size_t input_count, size_t *at, size_t *length) {
  for (;;) {
    if (*at >= input_count)
      return 0;
    unsigned char part = input[(*at)++];
    if (*length > ((size_t)1 << 40))
      return 0;
    *length += part;
    if (part != 255)
      return 1;
  }
}

// Each read and each write is checked against its bound: a damaged frame is
// refused with its reason, and the output holds no byte past its capacity.
long codec_decompress(const unsigned char *input, size_t input_count, unsigned char *output, size_t output_capacity) {
  if ((!input && input_count > 0) || (!output && output_capacity > 0))
    return CODEC_REFUSAL_BAD_ARGUMENT;
  if (input_count < CODEC_HEADER_SIZE + 1)
    return CODEC_REFUSAL_TRUNCATED;
  if (read_u32(input) != CODEC_MAGIC)
    return CODEC_REFUSAL_BAD_MAGIC;
  size_t content_size = read_u32(input + 4);
  unsigned int expected_crc = read_u32(input + 8);
  if (content_size > output_capacity)
    return CODEC_REFUSAL_OUTPUT_TOO_SMALL;
  size_t at = CODEC_HEADER_SIZE;
  size_t written = 0;
  for (;;) {
    if (at >= input_count)
      return CODEC_REFUSAL_TRUNCATED;
    unsigned char token = input[at++];
    size_t literal_count = token >> 4;
    if (literal_count == 15 && !take_length(input, input_count, &at, &literal_count))
      return CODEC_REFUSAL_TRUNCATED;
    if (literal_count > input_count - at)
      return CODEC_REFUSAL_TRUNCATED;
    if (literal_count > content_size - written)
      return CODEC_REFUSAL_SIZE_MISMATCH;
    memcpy(output + written, input + at, literal_count);
    at += literal_count;
    written += literal_count;
    if (at == input_count) {
      if ((token & 15) != 0)
        return CODEC_REFUSAL_TRUNCATED;
      break;
    }
    if (input_count - at < 2)
      return CODEC_REFUSAL_TRUNCATED;
    size_t offset = (size_t)input[at] | (size_t)input[at + 1] << 8;
    at += 2;
    if (offset == 0 || offset > written)
      return CODEC_REFUSAL_BAD_OFFSET;
    size_t match_length = token & 15;
    if (match_length == 15 && !take_length(input, input_count, &at, &match_length))
      return CODEC_REFUSAL_TRUNCATED;
    match_length += CODEC_MINIMUM_MATCH;
    if (match_length > content_size - written)
      return CODEC_REFUSAL_SIZE_MISMATCH;
    // Byte by byte: a match may overlap the bytes that it writes (a run).
    for (size_t index = 0; index < match_length; index++)
      output[written + index] = output[written + index - offset];
    written += match_length;
  }
  if (written != content_size)
    return CODEC_REFUSAL_SIZE_MISMATCH;
  if (codec_crc32(output, written) != expected_crc)
    return CODEC_REFUSAL_BAD_CHECKSUM;
  return (long)written;
}
