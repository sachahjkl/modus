// The thin libc of the system: the types of the language
// (src/md/features/c_compiler.md, "The thin libc"). The compiler gives
// each type through a macro of its own, so this file holds no size.
#ifndef THIN_LIBC_STDDEF_H
#define THIN_LIBC_STDDEF_H

typedef __SIZE_TYPE__ size_t;
typedef __PTRDIFF_TYPE__ ptrdiff_t;
typedef __WCHAR_TYPE__ wchar_t;

#define NULL ((void *)0)
#define offsetof(type, member) __builtin_offsetof(type, member)

#endif
