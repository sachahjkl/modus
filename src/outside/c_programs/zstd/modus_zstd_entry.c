// The exports of the module of zstd 1.5.7 on modus: compression and
// decompression with contexts whose memory is a heap over an arena that the
// caller lends (src/md/features/c_compiler.md, "The C programs").
#include "modus_zstd_conf.h"
#include "zstd.h"

typedef long long Word;

static Modus_Heap codec_heap;
static int codec_heap_ready;

// Gives 0, or -1 when the arena cannot hold one block.
Word zstd_heap_bind(Word arena, Word arena_size) {
  codec_heap_ready = modus_heap_init(&codec_heap, (void *)arena, (size_t)arena_size) == 0;
  return codec_heap_ready ? 0 : -1;
}

Word zstd_heap_live_bytes(void) { return codec_heap_ready ? (Word)codec_heap.live_bytes : -1; }

// A result of zstd: a count, or the negated ZSTD_ErrorCode of a fault.
static Word codec_result(size_t result) {
  return ZSTD_isError(result) ? -(Word)ZSTD_getErrorCode(result) : (Word)result;
}

Word zstd_compress_bound(Word count) { return (Word)ZSTD_compressBound((size_t)count); }

// One frame at the level, with the content size and the checksum of the
// content in the frame.
Word zstd_compress(Word source, Word count, Word destination, Word capacity, Word level) {
  if (!codec_heap_ready)
    return -(Word)ZSTD_error_memory_allocation;
  ZSTD_CCtx *context = ZSTD_createCCtx_advanced(MODUS_ZSTD_CUSTOM_MEMORY(&codec_heap));
  if (!context)
    return -(Word)ZSTD_error_memory_allocation;
  size_t result = ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, (int)level);
  if (!ZSTD_isError(result))
    result = ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1);
  if (!ZSTD_isError(result))
    result = ZSTD_compress2(context, (void *)destination, (size_t)capacity, (const void *)source, (size_t)count);
  ZSTD_freeCCtx(context);
  return codec_result(result);
}

Word zstd_decompress(Word source, Word count, Word destination, Word capacity) {
  if (!codec_heap_ready)
    return -(Word)ZSTD_error_memory_allocation;
  ZSTD_DCtx *context = ZSTD_createDCtx_advanced(MODUS_ZSTD_CUSTOM_MEMORY(&codec_heap));
  if (!context)
    return -(Word)ZSTD_error_memory_allocation;
  size_t result =
      ZSTD_decompressDCtx(context, (void *)destination, (size_t)capacity, (const void *)source, (size_t)count);
  ZSTD_freeDCtx(context);
  return codec_result(result);
}

// The content size that a frame declares, or the negated code of a fault.
Word zstd_frame_content_size(Word source, Word count) {
  unsigned long long size = ZSTD_getFrameContentSize((const void *)source, (size_t)count);
  if (size == ZSTD_CONTENTSIZE_ERROR)
    return -(Word)ZSTD_error_prefix_unknown;
  if (size == ZSTD_CONTENTSIZE_UNKNOWN)
    return -(Word)ZSTD_error_frameParameter_unsupported;
  return (Word)size;
}

Word zstd_version_number(void) { return (Word)ZSTD_versionNumber(); }
