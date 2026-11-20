// The thin libc of the system: the arguments of a variadic function
// (src/md/features/c_compiler.md, "The thin libc"). The compiler knows the
// call form of the processor; these names only point at its built-ins.
#ifndef THIN_LIBC_STDARG_H
#define THIN_LIBC_STDARG_H

typedef __builtin_va_list va_list;

#define va_start(list, last) __builtin_va_start(list, last)
#define va_arg(list, type) __builtin_va_arg(list, type)
#define va_copy(destination, source) __builtin_va_copy(destination, source)
#define va_end(list) __builtin_va_end(list)

#endif
