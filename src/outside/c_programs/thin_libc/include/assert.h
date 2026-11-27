// The header assert.h of the thin libc. A failed check stops the program
// with a trap: the caller reads the fault of the module. As C asks, each
// inclusion defines assert again, after the NDEBUG of that place.
#undef assert
#ifdef NDEBUG
#define assert(condition) ((void)0)
#elif defined(__chibicc__)
void abort(void);
#define assert(condition) ((condition) ? (void)0 : abort())
#else
#define assert(condition) ((condition) ? (void)0 : __builtin_trap())
#endif
#ifndef static_assert
#define static_assert _Static_assert
#endif
