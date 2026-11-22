// The test programs of the thin libc and of its adapters: a codec that uses
// the configuration of zstd, a scripting language that uses the configuration
// of Lua, and a key-value store that uses the VFS of SQLite.
#ifndef MODUS_C_PROGRAMS_H
#define MODUS_C_PROGRAMS_H

#include "modus_thin_libc.h"

typedef enum Codec_Refusal {
  CODEC_REFUSAL_BAD_ARGUMENT = -1,
  CODEC_REFUSAL_TRUNCATED = -2,
  CODEC_REFUSAL_BAD_MAGIC = -3,
  CODEC_REFUSAL_BAD_OFFSET = -4,
  CODEC_REFUSAL_SIZE_MISMATCH = -5,
  CODEC_REFUSAL_BAD_CHECKSUM = -6,
  CODEC_REFUSAL_OUTPUT_TOO_SMALL = -7,
  CODEC_REFUSAL_OUT_OF_MEMORY = -8,
  CODEC_REFUSAL_INPUT_TOO_LARGE = -9,
} Codec_Refusal;

unsigned int codec_crc32(const unsigned char *bytes, size_t count);
long codec_compress(Modus_Heap *heap, const unsigned char *input, size_t input_count, unsigned char *output,
                    size_t output_capacity);
long codec_decompress(const unsigned char *input, size_t input_count, unsigned char *output, size_t output_capacity);

typedef enum Script_Status {
  SCRIPT_STATUS_DONE = 0,
  SCRIPT_STATUS_SYNTAX_ERROR = -1,
  SCRIPT_STATUS_RUNTIME_ERROR = -2,
  SCRIPT_STATUS_OUT_OF_MEMORY = -3,
  SCRIPT_STATUS_STEP_LIMIT = -4,
  SCRIPT_STATUS_OUTPUT_OVERFLOW = -5,
  SCRIPT_STATUS_BAD_ARGUMENT = -6,
} Script_Status;

#define SCRIPT_STEP_LIMIT 5000000

// Compiles a source to the code of a stack machine and runs it. print writes
// through lua_writestring; an error writes its line through
// lua_writestringerror. Each allocation is released before the return.
Script_Status script_run(const char *source, size_t source_count, char *output, size_t output_capacity,
                         char *diagnostic, size_t diagnostic_capacity, Modus_Heap *heap);

#endif
