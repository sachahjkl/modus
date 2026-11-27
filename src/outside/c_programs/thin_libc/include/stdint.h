// The header stdint.h of the thin libc, from the types that the compiler
// predefines for its target, with LP64 definitions for chibicc.
#ifndef MODUS_THIN_LIBC_STDINT_H
#define MODUS_THIN_LIBC_STDINT_H
#ifdef __chibicc__
typedef signed char int8_t;
typedef short int16_t;
typedef int int32_t;
typedef long int64_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long uint64_t;
typedef signed char int_least8_t;
typedef short int_least16_t;
typedef int int_least32_t;
typedef long int_least64_t;
typedef unsigned char uint_least8_t;
typedef unsigned short uint_least16_t;
typedef unsigned int uint_least32_t;
typedef unsigned long uint_least64_t;
typedef signed char int_fast8_t;
typedef long int_fast16_t;
typedef long int_fast32_t;
typedef long int_fast64_t;
typedef unsigned char uint_fast8_t;
typedef unsigned long uint_fast16_t;
typedef unsigned long uint_fast32_t;
typedef unsigned long uint_fast64_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;
typedef long intmax_t;
typedef unsigned long uintmax_t;
#define INT8_MIN (-128)
#define INT8_MAX 127
#define UINT8_MAX 255
#define INT16_MIN (-32768)
#define INT16_MAX 32767
#define UINT16_MAX 65535
#define INT32_MIN (-2147483647 - 1)
#define INT32_MAX 2147483647
#define UINT32_MAX 4294967295U
#define INT64_MIN (-9223372036854775807L - 1)
#define INT64_MAX 9223372036854775807L
#define UINT64_MAX 18446744073709551615UL
#define INTPTR_MIN INT64_MIN
#define INTPTR_MAX INT64_MAX
#define UINTPTR_MAX UINT64_MAX
#define INTMAX_MIN INT64_MIN
#define INTMAX_MAX INT64_MAX
#define UINTMAX_MAX UINT64_MAX
#define PTRDIFF_MIN INT64_MIN
#define PTRDIFF_MAX INT64_MAX
#define SIZE_MAX UINT64_MAX
#else
typedef __INT8_TYPE__ int8_t;
typedef __INT16_TYPE__ int16_t;
typedef __INT32_TYPE__ int32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INT_LEAST8_TYPE__ int_least8_t;
typedef __INT_LEAST16_TYPE__ int_least16_t;
typedef __INT_LEAST32_TYPE__ int_least32_t;
typedef __INT_LEAST64_TYPE__ int_least64_t;
typedef __UINT_LEAST8_TYPE__ uint_least8_t;
typedef __UINT_LEAST16_TYPE__ uint_least16_t;
typedef __UINT_LEAST32_TYPE__ uint_least32_t;
typedef __UINT_LEAST64_TYPE__ uint_least64_t;
typedef __INT_FAST8_TYPE__ int_fast8_t;
typedef __INT_FAST16_TYPE__ int_fast16_t;
typedef __INT_FAST32_TYPE__ int_fast32_t;
typedef __INT_FAST64_TYPE__ int_fast64_t;
typedef __UINT_FAST8_TYPE__ uint_fast8_t;
typedef __UINT_FAST16_TYPE__ uint_fast16_t;
typedef __UINT_FAST32_TYPE__ uint_fast32_t;
typedef __UINT_FAST64_TYPE__ uint_fast64_t;
typedef __INTPTR_TYPE__ intptr_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef __INTMAX_TYPE__ intmax_t;
typedef __UINTMAX_TYPE__ uintmax_t;
#define INT8_MIN (-INT8_MAX - 1)
#define INT8_MAX __INT8_MAX__
#define UINT8_MAX __UINT8_MAX__
#define INT16_MIN (-INT16_MAX - 1)
#define INT16_MAX __INT16_MAX__
#define UINT16_MAX __UINT16_MAX__
#define INT32_MIN (-INT32_MAX - 1)
#define INT32_MAX __INT32_MAX__
#define UINT32_MAX __UINT32_MAX__
#define INT64_MIN (-INT64_MAX - 1)
#define INT64_MAX __INT64_MAX__
#define UINT64_MAX __UINT64_MAX__
#define INTPTR_MIN (-INTPTR_MAX - 1)
#define INTPTR_MAX __INTPTR_MAX__
#define UINTPTR_MAX __UINTPTR_MAX__
#define INTMAX_MIN (-INTMAX_MAX - 1)
#define INTMAX_MAX __INTMAX_MAX__
#define UINTMAX_MAX __UINTMAX_MAX__
#define PTRDIFF_MIN (-PTRDIFF_MAX - 1)
#define PTRDIFF_MAX __PTRDIFF_MAX__
#define SIZE_MAX __SIZE_MAX__
#endif
#define INT8_C(value) value
#define INT16_C(value) value
#define INT32_C(value) value
#define INT64_C(value) value##LL
#define UINT8_C(value) value
#define UINT16_C(value) value
#define UINT32_C(value) value##U
#define UINT64_C(value) value##ULL
#define INTMAX_C(value) value##LL
#define UINTMAX_C(value) value##ULL
#endif
