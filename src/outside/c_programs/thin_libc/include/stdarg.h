// The header stdarg.h of the thin libc: the variable arguments of the
// System V AMD64 call, as the compiler builds them.
#ifndef MODUS_THIN_LIBC_STDARG_H
#define MODUS_THIN_LIBC_STDARG_H
typedef __builtin_va_list va_list;
#define va_start(list, last) __builtin_va_start(list, last)
#define va_end(list) __builtin_va_end(list)
#define va_arg(list, type) __builtin_va_arg(list, type)
#define va_copy(destination, source) __builtin_va_copy(destination, source)
#endif
