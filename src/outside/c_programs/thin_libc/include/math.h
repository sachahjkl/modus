// The header math.h of the thin libc of the C programs: one file declares
// the whole thin libc (thin_libc/modus_thin_libc.h).
#ifndef MODUS_THIN_LIBC_MATH_H
#define MODUS_THIN_LIBC_MATH_H
#include "../modus_thin_libc.h"

#ifdef __chibicc__
#define HUGE_VAL (modus_double_inf())
#define INFINITY ((float)modus_double_inf())
#define NAN ((float)modus_double_nan())
#define isnan(value) (modus_isnan((double)(value)))
#define isinf(value) (modus_isinf((double)(value)))
#define isfinite(value) (modus_isfinite((double)(value)))
#define signbit(value) (modus_signbit((double)(value)))
#else
#define HUGE_VAL (__builtin_huge_val())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define isnan(value) __builtin_isnan(value)
#define isinf(value) __builtin_isinf(value)
#define isfinite(value) __builtin_isfinite(value)
#define signbit(value) __builtin_signbit(value)
#endif
#endif
