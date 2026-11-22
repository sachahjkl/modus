// The configuration of zstd on modus (src/md/features/c_compiler.md, "The
// configuration of zstd"). The recipe compiles each C file of the library
// with this header first (-include modus_zstd_conf.h): it takes the place of
// lib/common/zstd_deps.h, whose sections each start with a guard that this
// header defines, so zstd reads no header of a host C library.
#ifndef MODUS_ZSTD_CONF_H
#define MODUS_ZSTD_CONF_H

#include "modus_thin_libc.h"

// The advanced interface, with ZSTD_customMem; xxhash compiled inline.
#define ZSTD_STATIC_LINKING_ONLY
#define XXH_INLINE_ALL
#define XXH_NO_STDLIB

// No thread, no legacy format, no trace, no debug output, no assembly file
// of the host (huf_decompress_amd64.S is written for a host ELF object).
#undef ZSTD_MULTITHREAD
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1
#define ZSTD_HAVE_WEAK_SYMBOLS 0
#define DEBUGLEVEL 0

// No choice of code by the processor at run time: that choice reads cpuid,
// which a module does not run. The code of BMI2 is not compiled in, and the
// patch of cpu.h reads no cpuid under MODUS_ZSTD_NO_CPUID.
#define DYNAMIC_BMI2 0
#define MODUS_ZSTD_NO_CPUID

// The scalar code of zstd: the headers of the intrinsics (emmintrin.h) are
// headers of the compiler, which a module of C does not read (-nostdinc).
// Both forms write the same bytes.
#define ZSTD_NO_INTRINSICS

// The sections of zstd_deps.h, given here.
#define ZSTD_DEPS_COMMON
#define ZSTD_memcpy(destination, source, count) memcpy((destination), (source), (count))
#define ZSTD_memmove(destination, source, count) memmove((destination), (source), (count))
#define ZSTD_memset(destination, value, count) memset((destination), (value), (count))

// An allocation of zstd with no custom memory uses the heap that the program
// chose last (modus_heap_use).
#define ZSTD_DEPS_MALLOC
#define ZSTD_malloc(size) malloc(size)
#define ZSTD_calloc(count, size) calloc((count), (size))
#define ZSTD_free(address) free(address)

#define ZSTD_DEPS_MATH64
#define ZSTD_div64(dividend, divisor) ((dividend) / (divisor))

#define ZSTD_DEPS_ASSERT
#include <assert.h>

#define ZSTD_DEPS_IO
#define ZSTD_DEBUG_PRINT(...) ((void)0)

#define ZSTD_DEPS_STDINT
#include <stdint.h>

// The custom memory of zstd over a heap that the caller lends: each context
// that ZSTD_createCCtx_advanced or ZSTD_createDCtx_advanced makes takes its
// memory from that heap, and from nothing else.
static inline void *modus_zstd_allocate(void *heap, size_t size) {
  return modus_heap_allocate((Modus_Heap *)heap, size);
}

static inline void modus_zstd_free(void *heap, void *address) { modus_heap_release((Modus_Heap *)heap, address); }

// The ZSTD_customMem of a heap, for a source that includes zstd.h.
#define MODUS_ZSTD_CUSTOM_MEMORY(heap) ((ZSTD_customMem){modus_zstd_allocate, modus_zstd_free, (heap)})

#endif
