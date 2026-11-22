// The elementary functions of the thin libc: exp, log, log2, log10, pow and
// the circular functions, with the special cases of IEEE 754 and of Annex F
// of C, and no call to a library of the host (src/md/features/c_compiler.md,
// "The C programs").
//
// The circular functions take and give radians, as the C standard says: a
// ported program calls them unchanged. The code of the system itself uses
// turns (src/md/data/angles_in_turns.md).
//
// Accuracy comes from a double-double: a pair of doubles whose sum holds about
// 106 bits. log gives its result as a pair, so pow keeps about 70 good bits
// in y * log(x) before the exponential. The kernels of exp, sin, cos and atan,
// the reduction of an angle below 2^19 pi/2, atan2, and their coefficients
// follow fdlibm, whose notice is kept here as it asks:
//
//   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//
//   Developed at SunPro, a Sun Microsystems, Inc. business.
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
#include "modus_thin_libc.h"

// A fused multiply-add rounds once where the algorithms below count on two
// roundings, or on none: each product and each sum stays on its own.
#pragma STDC FP_CONTRACT OFF

typedef struct Double_Double {
  double high;
  double low; // |low| is at most half a unit in the last place of high.
} Double_Double;

static double double_from_bits(unsigned long long bits) {
  double value;
  __builtin_memcpy(&value, &bits, sizeof value);
  return value;
}

static unsigned long long bits_from_double(double value) {
  unsigned long long bits;
  __builtin_memcpy(&bits, &value, sizeof bits);
  return bits;
}

static int biased_exponent(double value) { return (int)((bits_from_double(value) >> 52) & 0x7ff); }

// ---- Exact sums and products ----------------------------------------------------------

static Double_Double sum_exact(double left, double right) {
  double sum = left + right;
  double right_part = sum - left;
  double error = (left - (sum - right_part)) + (right - right_part);
  return (Double_Double){sum, error};
}

// Exact when |left| >= |right| or left is zero.
static Double_Double sum_exact_ordered(double left, double right) {
  double sum = left + right;
  return (Double_Double){sum, right - (sum - left)};
}

// Splits a double below 2^996 into two halves of 26 bits each, so that the
// product of two halves is exact.
static void split_halves(double value, double *high, double *low) {
  double scaled = 134217729.0 * value; // 2^27 + 1
  *high = scaled - (scaled - value);
  *low = value - *high;
}

static Double_Double product_exact(double left, double right) {
  double product = left * right;
  double left_high, left_low, right_high, right_low;
  split_halves(left, &left_high, &left_low);
  split_halves(right, &right_high, &right_low);
  double error =
      ((left_high * right_high - product) + left_high * right_low + left_low * right_high) + left_low * right_low;
  return (Double_Double){product, error};
}

static Double_Double double_double_add(Double_Double left, Double_Double right) {
  Double_Double sum = sum_exact(left.high, right.high);
  sum.low += left.low + right.low;
  return sum_exact_ordered(sum.high, sum.low);
}

static Double_Double double_double_multiply(Double_Double left, Double_Double right) {
  Double_Double product = product_exact(left.high, right.high);
  product.low += left.high * right.low + left.low * right.high;
  return sum_exact_ordered(product.high, product.low);
}

static Double_Double double_double_divide_by_double(Double_Double numerator, double denominator) {
  double quotient = numerator.high / denominator;
  Double_Double back = product_exact(quotient, denominator);
  double remainder = ((numerator.high - back.high) - back.low) + numerator.low;
  return sum_exact_ordered(quotient, remainder / denominator);
}

// ---- The constants ------------------------------------------------------------------

// ln 2 in two parts: the high part ends in 21 zero bits, so k * LN2_HIGH is
// exact for each exponent k of a double.
static const double LN2_HIGH = 0x1.62e42fee00000p-1;
static const double LN2_LOW = 0x1.a39ef35793c76p-33;
static const Double_Double INVERSE_LN2 = {0x1.71547652b82fep+0, 0x1.777d0ffda0d24p-56};
static const Double_Double INVERSE_LN10 = {0x1.bcb7b1526e50ep-2, 0x1.95355baaafad3p-57};
static const double SQRT2 = 0x1.6a09e667f3bcdp+0;

static const double PI_HIGH = 0x1.921fb54442d18p+1;
static const double PI_LOW = 0x1.1a62633145c07p-53;
static const double HALF_PI_HIGH = 0x1.921fb54442d18p+0;
static const double HALF_PI_LOW = 0x1.1a62633145c07p-54;
static const double QUARTER_PI = 0x1.921fb54442d18p-1;
static const double INVERSE_HALF_PI = 0x1.45f306dc9c883p-1;

// pi/2 in three parts of 33 bits and their tails: n times a part is exact for
// n up to 2^20.
static const double HALF_PI_PART_1 = 0x1.921fb54400000p+0;
static const double HALF_PI_PART_1_TAIL = 0x1.0b4611a626331p-34;
static const double HALF_PI_PART_2 = 0x1.0b4611a600000p-34;
static const double HALF_PI_PART_2_TAIL = 0x1.3198a2e037073p-69;
static const double HALF_PI_PART_3 = 0x1.3198a2e000000p-69;
static const double HALF_PI_PART_3_TAIL = 0x1.b839a252049c1p-104;

// The first 1280 bits of 2/pi, most significant first: enough for the
// reduction of the largest double, whose exponent is 1023.
static const unsigned long long TWO_OVER_PI_WORDS[20] = {
    0xa2f9836e4e441529ULL, 0xfc2757d1f534ddc0ULL, 0xdb6295993c439041ULL, 0xfe5163abdebbc561ULL,
    0xb7246e3a424dd2e0ULL, 0x06492eea09d1921cULL, 0xfe1deb1cb129a73eULL, 0xe88235f52ebb4484ULL,
    0xe99c7026b45f7e41ULL, 0x3991d639835339f4ULL, 0x9c845f8bbdf9283bULL, 0x1ff897ffde05980fULL,
    0xef2f118b5a0a6d1fULL, 0x6d367ecf27cb09b7ULL, 0x4f463f669e5fea2dULL, 0x7527bac7ebe5f17bULL,
    0x3d0739f78a5292eaULL, 0x6bfb5fb11f8d5d08ULL, 0x56033046fc7b6babULL, 0xf0cfbc209af4361dULL,
};

static double positive_infinity(void) { return __builtin_inf(); }
static double quiet_nan(void) { return __builtin_nan(""); }

// ---- The logarithm --------------------------------------------------------------------

// ln(x) for a finite x above zero, as a double-double with about 70 good bits.
// x = 2^k * m with m in [sqrt(1/2), sqrt(2)], and ln(m) = 2 atanh(s) with
// s = (m - 1)/(m + 1), |s| < 0.172: the first three terms of the series are
// double-doubles, the rest is a double whose error is below 2^-72.
static Double_Double logarithm_double_double(double value) {
  int exponent = 0;
  if (biased_exponent(value) == 0) {
    value *= 0x1p54;
    exponent -= 54;
  }
  unsigned long long bits = bits_from_double(value);
  exponent += (int)(bits >> 52) - 1023;
  double mantissa = double_from_bits((bits & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL);
  if (mantissa > SQRT2) {
    mantissa *= 0.5;
    exponent += 1;
  }
  double numerator = mantissa - 1.0; // Exact: mantissa is within a factor 2 of 1.
  Double_Double denominator = sum_exact(1.0, mantissa);
  double ratio_high = numerator / denominator.high;
  Double_Double back = product_exact(ratio_high, denominator.high);
  double ratio_low = (((numerator - back.high) - back.low) - ratio_high * denominator.low) / denominator.high;
  Double_Double ratio = sum_exact_ordered(ratio_high, ratio_low);

  Double_Double square = double_double_multiply(ratio, ratio);
  Double_Double cube = double_double_multiply(ratio, square);
  Double_Double fifth = double_double_multiply(cube, square);
  double z = square.high;
  double tail_series =
      1.0 / 7.0 +
      z * (1.0 / 9.0 +
           z * (1.0 / 11.0 +
                z * (1.0 / 13.0 +
                     z * (1.0 / 15.0 +
                          z * (1.0 / 17.0 +
                               z * (1.0 / 19.0 + z * (1.0 / 21.0 + z * (1.0 / 23.0 + z * (1.0 / 25.0 + z / 27.0)))))))));
  double tail = fifth.high * z * tail_series;

  Double_Double series = double_double_add(double_double_divide_by_double(fifth, 5.0), (Double_Double){tail, 0.0});
  series = double_double_add(double_double_divide_by_double(cube, 3.0), series);
  series = double_double_add(ratio, series);
  series.high *= 2.0;
  series.low *= 2.0;

  double k = (double)exponent;
  Double_Double scaled = sum_exact_ordered(k * LN2_HIGH, k * LN2_LOW);
  return double_double_add(scaled, series);
}

// Gives 1 and the result when x is a special case of a logarithm.
static int logarithm_special(double value, double *result) {
  if (value != value) {
    *result = value + value;
    return 1;
  }
  if (value == 0.0) {
    errno = ERANGE;
    *result = -positive_infinity();
    return 1;
  }
  if (value < 0.0) {
    errno = EDOM;
    *result = quiet_nan();
    return 1;
  }
  if (__builtin_isinf(value)) {
    *result = value;
    return 1;
  }
  if (value == 1.0) {
    *result = 0.0;
    return 1;
  }
  return 0;
}

double log(double value) {
  double result;
  if (logarithm_special(value, &result))
    return result;
  Double_Double logarithm = logarithm_double_double(value);
  return logarithm.high + logarithm.low;
}

double log2(double value) {
  double result;
  if (logarithm_special(value, &result))
    return result;
  Double_Double logarithm = double_double_multiply(logarithm_double_double(value), INVERSE_LN2);
  return logarithm.high + logarithm.low;
}

double log10(double value) {
  double result;
  if (logarithm_special(value, &result))
    return result;
  Double_Double logarithm = double_double_multiply(logarithm_double_double(value), INVERSE_LN10);
  return logarithm.high + logarithm.low;
}

// ---- The exponential ------------------------------------------------------------------

// Above the first, e^x overflows; below the second, e^x rounds to zero.
static const double EXPONENTIAL_OVERFLOW = 7.09782712893383973096e+02;
static const double EXPONENTIAL_UNDERFLOW = -7.45133219101941108420e+02;

// e^(high + low) for a finite high, with low below half a unit of high:
// high + low = k ln 2 + r with |r| <= ln(2)/2, and e^r from the rational form
// of fdlibm, where the low part of the reduction carries low.
static double exponential_double_double(double high, double low) {
  if (high > EXPONENTIAL_OVERFLOW) {
    errno = ERANGE;
    return positive_infinity();
  }
  if (high < EXPONENTIAL_UNDERFLOW) {
    errno = ERANGE;
    return 0.0;
  }
  double scaled = high * INVERSE_LN2.high;
  int k = (int)(scaled < 0.0 ? scaled - 0.5 : scaled + 0.5);
  double reduced_high = high - (double)k * LN2_HIGH;
  double reduced_low = (double)k * LN2_LOW - low;
  double r = reduced_high - reduced_low;
  double z = r * r;
  double c = r - z * (1.66666666666666019037e-01 +
                      z * (-2.77777777770155933842e-03 +
                           z * (6.61375632143793436117e-05 +
                                z * (-1.65339022054652515390e-06 + z * 4.13813679705723846039e-08))));
  double y = 1.0 - ((reduced_low - (r * c) / (2.0 - c)) - reduced_high);
  double result = ldexp(y, k);
  if (result == 0.0 || __builtin_isinf(result))
    errno = ERANGE;
  return result;
}

double exp(double value) {
  if (value != value)
    return value + value;
  if (__builtin_isinf(value))
    return value > 0.0 ? value : 0.0;
  if (__builtin_fabs(value) < 0x1p-28)
    return 1.0 + value;
  return exponential_double_double(value, 0.0);
}

// ---- The power ------------------------------------------------------------------------

typedef enum Exponent_Class {
  EXPONENT_NOT_INTEGER,
  EXPONENT_ODD_INTEGER,
  EXPONENT_EVEN_INTEGER,
} Exponent_Class;

static Exponent_Class exponent_class(double y) {
  double magnitude = __builtin_fabs(y);
  if (__builtin_isinf(y))
    return EXPONENT_NOT_INTEGER;
  if (magnitude >= 0x1p53)
    return EXPONENT_EVEN_INTEGER;
  if (trunc(y) != y)
    return EXPONENT_NOT_INTEGER;
  return ((long long)magnitude & 1) ? EXPONENT_ODD_INTEGER : EXPONENT_EVEN_INTEGER;
}

double pow(double x, double y) {
  // Annex F of C: these two give 1 even for a NaN.
  if (y == 0.0 || x == 1.0)
    return 1.0;
  if (x != x || y != y)
    return x + y;
  Exponent_Class y_class = exponent_class(y);
  int odd = y_class == EXPONENT_ODD_INTEGER;
  if (__builtin_isinf(y)) {
    double magnitude = __builtin_fabs(x);
    if (magnitude == 1.0)
      return 1.0;
    return (magnitude > 1.0) == (y > 0.0) ? positive_infinity() : 0.0;
  }
  if (x == 0.0) {
    int negative = __builtin_signbit(x) != 0;
    if (y < 0.0) {
      errno = ERANGE;
      return odd && negative ? -positive_infinity() : positive_infinity();
    }
    return odd && negative ? -0.0 : 0.0;
  }
  if (__builtin_isinf(x)) {
    double magnitude = y < 0.0 ? 0.0 : positive_infinity();
    return x < 0.0 && odd ? -magnitude : magnitude;
  }
  double sign = 1.0;
  if (x < 0.0) {
    if (y_class == EXPONENT_NOT_INTEGER) {
      errno = EDOM;
      return quiet_nan();
    }
    if (odd)
      sign = -1.0;
    x = -x;
    if (x == 1.0)
      return sign;
  }
  // These are correctly rounded by one operation.
  if (y == 1.0)
    return sign * x;
  if (y == 2.0)
    return sign * (x * x);
  if (y == -1.0)
    return sign * (1.0 / x);
  if (y == 0.5)
    return sqrt(x);
  // x is not 1, so |ln x| is at least 2^-53: past 2^64, |y ln x| is past
  // 2000 and the result overflows or underflows. Below it, y splits exactly.
  if (__builtin_fabs(y) >= 0x1p64) {
    errno = ERANGE;
    return sign * ((x > 1.0) == (y > 0.0) ? positive_infinity() : 0.0);
  }
  Double_Double logarithm = logarithm_double_double(x);
  Double_Double product = product_exact(y, logarithm.high);
  product.low += y * logarithm.low;
  product = sum_exact_ordered(product.high, product.low);
  return sign * exponential_double_double(product.high, product.low);
}

// ---- The reduction of an angle -----------------------------------------------------------

// Bits [position, position + 64) of a number of five words, least significant
// word first; bits past the number are zero.
static unsigned long long bits_of_words(const unsigned long long words[5], int position) {
  int word = position / 64;
  int shift = position % 64;
  unsigned long long low = word < 5 ? words[word] >> shift : 0;
  unsigned long long high = (shift != 0 && word + 1 < 5) ? words[word + 1] << (64 - shift) : 0;
  return low | high;
}

// Payne and Hanek: x * 2/pi with the bits of 2/pi that reach the last two
// bits of the integer part and the first 128 bits of the fraction. Earlier
// bits give a multiple of 4; later bits are below 2^-138.
static int reduce_large_angle(double magnitude, Double_Double *reduced) {
  unsigned long long bits = bits_from_double(magnitude);
  int e = (int)(bits >> 52) - 1075; // magnitude = m * 2^e
  unsigned long long m = (bits & 0x000fffffffffffffULL) | 0x0010000000000000ULL;
  int first_word = e >= 66 ? (e - 66) / 64 + 1 : 0;
  unsigned long long product[5];
  unsigned long long carry = 0;
  for (int index = 0; index < 4; index++) {
    unsigned __int128 partial = (unsigned __int128)m * TWO_OVER_PI_WORDS[first_word + 3 - index] + carry;
    product[index] = (unsigned long long)partial;
    carry = (unsigned long long)(partial >> 64);
  }
  product[4] = carry;
  int point = 256 + 64 * first_word - e; // The binary point of the product.
  int quadrant = (int)(bits_of_words(product, point) & 3);
  unsigned __int128 fraction =
      ((unsigned __int128)bits_of_words(product, point - 64) << 64) | bits_of_words(product, point - 128);
  int negative = (int)(fraction >> 127);
  if (negative) {
    // A fraction past one half becomes a negative one of the next quadrant.
    quadrant += 1;
    fraction = (unsigned __int128)0 - fraction;
  }
  if (fraction == 0) {
    *reduced = (Double_Double){0.0, 0.0};
    return quadrant & 3;
  }
  unsigned long long fraction_high = (unsigned long long)(fraction >> 64);
  int leading_zeros =
      fraction_high != 0 ? __builtin_clzll(fraction_high) : 64 + __builtin_clzll((unsigned long long)fraction);
  fraction <<= leading_zeros;
  double high = ldexp((double)(unsigned long long)(fraction >> 75), -53 - leading_zeros);
  double low = ldexp((double)((unsigned long long)(fraction >> 22) & 0x001fffffffffffffULL), -106 - leading_zeros);
  Double_Double angle =
      double_double_multiply(sum_exact_ordered(high, low), (Double_Double){HALF_PI_HIGH, HALF_PI_LOW});
  if (negative) {
    angle.high = -angle.high;
    angle.low = -angle.low;
  }
  *reduced = angle;
  return quadrant & 3;
}

// x = n pi/2 + reduced with |reduced| <= pi/4; gives n modulo 4. Below
// 2^19 pi/2, the three parts of pi/2 subtract in turn, as many as the
// cancellation asks (fdlibm, e_rem_pio2.c).
static int reduce_angle(double x, Double_Double *reduced) {
  double magnitude = __builtin_fabs(x);
  int quadrant;
  if (magnitude < 0x1p19 * HALF_PI_HIGH) {
    int n = (int)(magnitude * INVERSE_HALF_PI + 0.5);
    double count = (double)n;
    double rest = magnitude - count * HALF_PI_PART_1;
    double subtracted = count * HALF_PI_PART_1_TAIL;
    double high = rest - subtracted;
    int exponent = biased_exponent(magnitude);
    if (exponent - biased_exponent(high) > 16) {
      double before = rest;
      subtracted = count * HALF_PI_PART_2;
      rest = before - subtracted;
      subtracted = count * HALF_PI_PART_2_TAIL - ((before - rest) - subtracted);
      high = rest - subtracted;
      if (exponent - biased_exponent(high) > 49) {
        before = rest;
        subtracted = count * HALF_PI_PART_3;
        rest = before - subtracted;
        subtracted = count * HALF_PI_PART_3_TAIL - ((before - rest) - subtracted);
        high = rest - subtracted;
      }
    }
    *reduced = (Double_Double){high, (rest - high) - subtracted};
    quadrant = n & 3;
  } else {
    quadrant = reduce_large_angle(magnitude, reduced);
  }
  if (x < 0.0) {
    reduced->high = -reduced->high;
    reduced->low = -reduced->low;
    quadrant = (4 - quadrant) & 3;
  }
  return quadrant;
}

// ---- Sine, cosine and tangent ----------------------------------------------------------

// sin(x + y) for |x| <= pi/4 and y below half a unit of x.
static double sine_kernel(double x, double y) {
  double z = x * x;
  double v = z * x;
  double r = 8.33333333332248946124e-03 +
             z * (-1.98412698298579493134e-04 +
                  z * (2.75573137070700676789e-06 + z * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10)));
  return x - ((z * (0.5 * y - v * r) - y) - v * -1.66666666666666324348e-01);
}

// cos(x + y) for |x| <= pi/4 and y below half a unit of x.
static double cosine_kernel(double x, double y) {
  double z = x * x;
  double w = z * z;
  double r = z * (4.16666666666666019037e-02 + z * (-1.38888888888741095749e-03 + z * 2.48015872894767294178e-05)) +
             w * w * (-2.75573143513906633035e-07 + z * (2.08757232129817482790e-09 + z * -1.13596475577881948265e-11));
  double half_z = 0.5 * z;
  w = 1.0 - half_z;
  return w + (((1.0 - w) - half_z) + (z * r - x * y));
}

// Gives 1 and a NaN for an infinity or a NaN, which have no sine.
static int angle_special(double x, double *result) {
  if (x != x) {
    *result = x + x;
    return 1;
  }
  if (__builtin_isinf(x)) {
    errno = EDOM;
    *result = quiet_nan();
    return 1;
  }
  return 0;
}

double sin(double x) {
  double result;
  if (angle_special(x, &result))
    return result;
  if (__builtin_fabs(x) <= QUARTER_PI)
    return __builtin_fabs(x) < 0x1p-27 ? x : sine_kernel(x, 0.0);
  Double_Double reduced;
  switch (reduce_angle(x, &reduced)) {
  case 0:
    return sine_kernel(reduced.high, reduced.low);
  case 1:
    return cosine_kernel(reduced.high, reduced.low);
  case 2:
    return -sine_kernel(reduced.high, reduced.low);
  default:
    return -cosine_kernel(reduced.high, reduced.low);
  }
}

double cos(double x) {
  double result;
  if (angle_special(x, &result))
    return result;
  if (__builtin_fabs(x) <= QUARTER_PI)
    return __builtin_fabs(x) < 0x1p-27 ? 1.0 : cosine_kernel(x, 0.0);
  Double_Double reduced;
  switch (reduce_angle(x, &reduced)) {
  case 0:
    return cosine_kernel(reduced.high, reduced.low);
  case 1:
    return -sine_kernel(reduced.high, reduced.low);
  case 2:
    return -cosine_kernel(reduced.high, reduced.low);
  default:
    return sine_kernel(reduced.high, reduced.low);
  }
}

double tan(double x) {
  double result;
  if (angle_special(x, &result))
    return result;
  if (__builtin_fabs(x) <= QUARTER_PI) {
    if (__builtin_fabs(x) < 0x1p-27)
      return x;
    return sine_kernel(x, 0.0) / cosine_kernel(x, 0.0);
  }
  Double_Double reduced;
  int quadrant = reduce_angle(x, &reduced);
  double sine = sine_kernel(reduced.high, reduced.low);
  double cosine = cosine_kernel(reduced.high, reduced.low);
  return (quadrant & 1) ? -cosine / sine : sine / cosine;
}

// ---- The inverse circular functions -------------------------------------------------------

// atan of 1/2, 1, 3/2 and infinity, as double-doubles.
static const double ARCTANGENT_HIGH[4] = {0x1.dac670561bb4fp-2, 0x1.921fb54442d18p-1, 0x1.f730bd281f69bp-1,
                                          0x1.921fb54442d18p+0};
static const double ARCTANGENT_LOW[4] = {0x1.a2b7f222f65e2p-56, 0x1.1a62633145c07p-55, 0x1.007887af0cbbdp-56,
                                         0x1.1a62633145c07p-54};

// atan(x) = atan(c) + atan((x - c)/(1 + c x)) for a c of 0, 1/2, 1, 3/2 or
// infinity, then an odd polynomial (fdlibm, s_atan.c).
double atan(double x) {
  if (x != x)
    return x + x;
  double magnitude = __builtin_fabs(x);
  if (magnitude >= 0x1p66)
    return x > 0.0 ? ARCTANGENT_HIGH[3] + ARCTANGENT_LOW[3] : -ARCTANGENT_HIGH[3] - ARCTANGENT_LOW[3];
  int interval;
  if (magnitude < 0.4375) {
    if (magnitude < 0x1p-27)
      return x;
    interval = -1;
  } else if (magnitude < 1.1875) {
    if (magnitude < 0.6875) {
      interval = 0;
      magnitude = (2.0 * magnitude - 1.0) / (2.0 + magnitude);
    } else {
      interval = 1;
      magnitude = (magnitude - 1.0) / (magnitude + 1.0);
    }
  } else if (magnitude < 2.4375) {
    interval = 2;
    magnitude = (magnitude - 1.5) / (1.0 + 1.5 * magnitude);
  } else {
    interval = 3;
    magnitude = -1.0 / magnitude;
  }
  double z = magnitude * magnitude;
  double w = z * z;
  double even = z * (3.33333333333329318027e-01 +
                     w * (1.42857142725034663711e-01 +
                          w * (9.09088713343650656196e-02 +
                               w * (6.66107313738753120669e-02 +
                                    w * (4.97687799461593236017e-02 + w * 1.62858201153657823623e-02)))));
  double odd = w * (-1.99999999998764832476e-01 +
                    w * (-1.11111104054623557880e-01 +
                         w * (-7.69187620504482999495e-02 +
                              w * (-5.83357013379057348645e-02 + w * -3.65315727442169155270e-02))));
  if (interval < 0)
    return x - x * (even + odd);
  double result = ARCTANGENT_HIGH[interval] - ((magnitude * (even + odd) - ARCTANGENT_LOW[interval]) - magnitude);
  return x < 0.0 ? -result : result;
}

// atan of a double-double above zero: atan(h + l) = atan(h) + l/(1 + h^2).
static double arctangent_double_double(Double_Double value) {
  if (__builtin_isinf(value.high))
    return HALF_PI_HIGH;
  return atan(value.high) + value.low / (1.0 + value.high * value.high);
}

// sqrt(1 - x^2) for 0 <= x < 1, as a double-double: the square is exact, and
// one step of Newton corrects the root.
static Double_Double complement_root(double magnitude) {
  Double_Double square = product_exact(magnitude, magnitude);
  Double_Double rest = sum_exact(1.0, -square.high);
  rest.low -= square.low;
  rest = sum_exact_ordered(rest.high, rest.low);
  double root = sqrt(rest.high);
  Double_Double root_square = product_exact(root, root);
  double correction = (((rest.high - root_square.high) - root_square.low) + rest.low) / (2.0 * root);
  return sum_exact_ordered(root, correction);
}

// asin(x) = atan(x / sqrt(1 - x^2)), with the quotient as a double-double.
double asin(double x) {
  if (x != x)
    return x + x;
  double magnitude = __builtin_fabs(x);
  if (magnitude > 1.0) {
    errno = EDOM;
    return quiet_nan();
  }
  if (magnitude < 0x1p-26)
    return x;
  double result = HALF_PI_HIGH;
  if (magnitude < 1.0) {
    Double_Double root = complement_root(magnitude);
    double quotient = magnitude / root.high;
    Double_Double back = product_exact(quotient, root.high);
    double remainder = ((magnitude - back.high) - back.low) - quotient * root.low;
    result = arctangent_double_double(sum_exact_ordered(quotient, remainder / root.high));
  }
  return x < 0.0 ? -result : result;
}

// acos(x) = atan(sqrt(1 - x^2) / x) for x above zero, and pi minus it below.
double acos(double x) {
  if (x != x)
    return x + x;
  double magnitude = __builtin_fabs(x);
  if (magnitude > 1.0) {
    errno = EDOM;
    return quiet_nan();
  }
  if (magnitude < 0x1p-57)
    return HALF_PI_HIGH;
  if (x == 1.0)
    return 0.0;
  if (x == -1.0)
    return PI_HIGH;
  double result = arctangent_double_double(double_double_divide_by_double(complement_root(magnitude), magnitude));
  return x > 0.0 ? result : PI_HIGH - (result - PI_LOW);
}

// The quadrant from the signs, the angle from atan(|y/x|) (fdlibm, e_atan2.c).
double atan2(double y, double x) {
  if (x != x || y != y)
    return x + y;
  if (x == 1.0)
    return atan(y);
  int quadrant = (__builtin_signbit(x) ? 2 : 0) | (__builtin_signbit(y) ? 1 : 0);
  if (y == 0.0) {
    switch (quadrant) {
    case 0:
    case 1:
      return y;
    case 2:
      return PI_HIGH + PI_LOW;
    default:
      return -PI_HIGH - PI_LOW;
    }
  }
  if (x == 0.0)
    return y < 0.0 ? -HALF_PI_HIGH - HALF_PI_LOW : HALF_PI_HIGH + HALF_PI_LOW;
  if (__builtin_isinf(x)) {
    if (__builtin_isinf(y)) {
      double angle = (quadrant & 2) ? 3.0 * QUARTER_PI : QUARTER_PI;
      return (quadrant & 1) ? -angle : angle;
    }
    double angle = (quadrant & 2) ? PI_HIGH + PI_LOW : 0.0;
    return (quadrant & 1) ? -angle : angle;
  }
  if (__builtin_isinf(y))
    return y < 0.0 ? -HALF_PI_HIGH - HALF_PI_LOW : HALF_PI_HIGH + HALF_PI_LOW;
  int exponent_difference = biased_exponent(y) - biased_exponent(x);
  double z;
  if (exponent_difference > 60) {
    z = HALF_PI_HIGH + 0.5 * PI_LOW;
    quadrant &= 1;
  } else if (x < 0.0 && exponent_difference < -60) {
    z = 0.0;
  } else {
    z = atan(__builtin_fabs(y / x));
  }
  switch (quadrant) {
  case 0:
    return z;
  case 1:
    return -z;
  case 2:
    return PI_HIGH - (z - PI_LOW);
  default:
    return (z - PI_LOW) - PI_HIGH;
  }
}
