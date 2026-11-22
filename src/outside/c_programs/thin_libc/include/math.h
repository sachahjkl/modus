// The header math.h of the thin libc of the C programs: one file declares
// the whole thin libc (thin_libc/modus_thin_libc.h).
#ifndef MODUS_THIN_LIBC_MATH_H
#define MODUS_THIN_LIBC_MATH_H
#include "../modus_thin_libc.h"

#define HUGE_VAL (__builtin_huge_val())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define isnan(value) __builtin_isnan(value)
#define isinf(value) __builtin_isinf(value)
#define isfinite(value) __builtin_isfinite(value)
#define signbit(value) __builtin_signbit(value)
#endif
