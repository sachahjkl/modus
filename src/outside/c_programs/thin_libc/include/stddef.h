// The header stddef.h of the thin libc, from the types that the compiler
// predefines for its target.
#ifndef MODUS_THIN_LIBC_STDDEF_H
#define MODUS_THIN_LIBC_STDDEF_H
typedef __SIZE_TYPE__ size_t;
typedef __PTRDIFF_TYPE__ ptrdiff_t;
typedef __WCHAR_TYPE__ wchar_t;
typedef struct {
  long long largest_integer __attribute__((aligned(__alignof__(long long))));
  long double largest_float __attribute__((aligned(__alignof__(long double))));
} max_align_t;
#define NULL ((void *)0)
#define offsetof(type, member) __builtin_offsetof(type, member)
#endif
