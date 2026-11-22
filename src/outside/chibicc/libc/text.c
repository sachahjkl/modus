// The thin libc of the system: bytes, texts and numbers
// (src/md/features/c_compiler.md, "The thin libc").
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

int errno;

// The classes of ASCII. A byte past ASCII, and EOF, are in no class: the
// system has no locale.
int isdigit(int character) { return character >= '0' && character <= '9'; }
int islower(int character) { return character >= 'a' && character <= 'z'; }
int isupper(int character) { return character >= 'A' && character <= 'Z'; }
int isalpha(int character) { return islower(character) || isupper(character); }
int isalnum(int character) { return isalpha(character) || isdigit(character); }
int isxdigit(int character) {
  return isdigit(character) || (character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F');
}
int isspace(int character) {
  return character == ' ' || (character >= '\t' && character <= '\r');
}
int ispunct(int character) {
  return character > ' ' && character < 0x7F && !isalnum(character);
}
int tolower(int character) { return isupper(character) ? character - 'A' + 'a' : character; }
int toupper(int character) { return islower(character) ? character - 'a' + 'A' : character; }

int memcmp(const void *first, const void *second, size_t size) {
  const unsigned char *left = first;
  const unsigned char *right = second;
  for (size_t index = 0; index < size; index++)
    if (left[index] != right[index])
      return left[index] < right[index] ? -1 : 1;
  return 0;
}

size_t strlen(const char *text) {
  size_t length = 0;
  while (text[length])
    length++;
  return length;
}

int strcmp(const char *first, const char *second) {
  const unsigned char *left = (const unsigned char *)first;
  const unsigned char *right = (const unsigned char *)second;
  while (*left && *left == *right) {
    left++;
    right++;
  }
  return *left < *right ? -1 : *left > *right;
}

int strncmp(const char *first, const char *second, size_t size) {
  const unsigned char *left = (const unsigned char *)first;
  const unsigned char *right = (const unsigned char *)second;
  for (size_t index = 0; index < size; index++) {
    if (left[index] != right[index])
      return left[index] < right[index] ? -1 : 1;
    if (!left[index])
      return 0;
  }
  return 0;
}

int strncasecmp(const char *first, const char *second, size_t size) {
  for (size_t index = 0; index < size; index++) {
    int left = tolower((unsigned char)first[index]);
    int right = tolower((unsigned char)second[index]);
    if (left != right)
      return left < right ? -1 : 1;
    if (!left)
      return 0;
  }
  return 0;
}

int strcasecmp(const char *first, const char *second) {
  return strncasecmp(first, second, SIZE_MAX);
}

char *strchr(const char *text, int character) {
  for (;; text++) {
    if (*text == (char)character)
      return (char *)text;
    if (!*text)
      return NULL;
  }
}

char *strrchr(const char *text, int character) {
  const char *found = NULL;
  for (;; text++) {
    if (*text == (char)character)
      found = text;
    if (!*text)
      return (char *)found;
  }
}

char *strstr(const char *text, const char *part) {
  size_t part_length = strlen(part);
  if (part_length == 0)
    return (char *)text;
  for (; *text; text++)
    if (*text == *part && strncmp(text, part, part_length) == 0)
      return (char *)text;
  return NULL;
}

// Copies at most `size` bytes, and fills the rest of the `size` bytes with
// zero, as C says: the result has no byte 0 when the source is as long.
char *strncpy(char *destination, const char *source, size_t size) {
  size_t index = 0;
  for (; index < size && source[index]; index++)
    destination[index] = source[index];
  for (; index < size; index++)
    destination[index] = '\0';
  return destination;
}

// Reads at most `size` bytes of `text`: a view of a token has no byte 0
// at its end.
char *strndup(const char *text, size_t size) {
  size_t length = 0;
  while (length < size && text[length])
    length++;
  char *copy = malloc(length + 1);
  memcpy(copy, text, length);
  copy[length] = '\0';
  return copy;
}

char *strdup(const char *text) {
  return strndup(text, SIZE_MAX);
}

char *strerror(int number) {
  switch (number) {
  case ENOENT:
    return "no file of the table has this name";
  case ENOMEM:
    return "the budget cannot pay the memory";
  case EINVAL:
    return "an argument that is not valid";
  case ERANGE:
    return "a number past its range";
  }
  return "an unknown error";
}

// The folder part of a name, in place: "include/stddef.h" gives "include",
// a name with no `/` gives ".", and "/x" gives "/".
char *dirname(char *path) {
  if (!path || !*path)
    return ".";
  size_t end = strlen(path);
  while (end > 1 && path[end - 1] == '/')
    end--;
  while (end > 0 && path[end - 1] != '/')
    end--;
  if (end == 0)
    return ".";
  while (end > 1 && path[end - 1] == '/')
    end--;
  path[end] = '\0';
  return path;
}

static int digit_value(int character) {
  if (isdigit(character))
    return character - '0';
  if (islower(character))
    return character - 'a' + 10;
  if (isupper(character))
    return character - 'A' + 10;
  return 99;
}

// C11 7.22.1.4: blanks, a sign, then the digits of `base` (0: the prefix
// `0x` gives 16, `0` gives 8, else 10). A value past the type gives the
// largest value and ERANGE. With no digit, `*end` is `text`.
unsigned long strtoul(const char *text, char **end, int base) {
  const char *place = text;
  while (isspace((unsigned char)*place))
    place++;
  bool negative = false;
  if (*place == '+' || *place == '-') {
    negative = *place == '-';
    place++;
  }
  if (base < 0 || base == 1 || base > 36) {
    errno = EINVAL;
    if (end)
      *end = (char *)text;
    return 0;
  }
  bool hexadecimal_prefix = place[0] == '0' && (place[1] == 'x' || place[1] == 'X') && isxdigit((unsigned char)place[2]);
  if ((base == 0 || base == 16) && hexadecimal_prefix) {
    place += 2;
    base = 16;
  } else if (base == 0) {
    base = place[0] == '0' ? 8 : 10;
  }
  const char *first_digit = place;
  unsigned long value = 0;
  bool past_range = false;
  for (; digit_value((unsigned char)*place) < base; place++) {
    unsigned long digit = (unsigned long)digit_value((unsigned char)*place);
    if (value > (UINT64_MAX - digit) / (unsigned long)base)
      past_range = true;
    else
      value = value * (unsigned long)base + digit;
  }
  if (place == first_digit) {
    if (end)
      *end = (char *)text;
    return 0;
  }
  if (end)
    *end = (char *)place;
  if (past_range) {
    errno = ERANGE;
    return UINT64_MAX;
  }
  return negative ? -value : value;
}

// The conversion of a text to a double, rounded to the nearest, ties to
// even. The thin libc is built with -mlong-double-64, so a long double is
// a double. The conversion uses integer arithmetic only: its result does
// not depend on the rounding mode or on the precision of a floating
// point unit, and it builds the 64 bits of the double itself.

// The bits of a double: 52 bits of the fraction, 11 of the exponent.
#define DOUBLE_FRACTION_BITS 52
#define DOUBLE_EXPONENT_BIAS 1023
#define DOUBLE_EXPONENT_ALL_ONES 0x7FF

// A decimal of at most DECIMAL_DIGITS_MOST significant digits: 0.d1d2...
// times 10^point. 800 digits hold each digit that can change the rounding
// of a double: the longest exact value of a double has 767. A digit past
// them only says that the value is above the digits kept.
#define DECIMAL_DIGITS_MOST 800
// The digits of 2^60, which a left shift by 60 bits adds at most.
#define DECIMAL_SHIFT_DIGITS_MOST 19
// The largest shift of one step: 10 times a value under 2^60 still fits
// in 64 bits.
#define DECIMAL_SHIFT_BITS_MOST 60
// A point past these gives infinity or zero with no shift: 0.1 x 10^310
// is above the largest double, and 0.9... x 10^-330 rounds to zero.
#define DECIMAL_POINT_MOST 310
#define DECIMAL_POINT_LEAST (-330)
// An exponent of a text is read up to this magnitude; a larger one gives
// the same infinity or zero, and the count cannot overflow.
#define EXPONENT_READ_MOST 100000

typedef struct {
  unsigned char digits[DECIMAL_DIGITS_MOST + DECIMAL_SHIFT_DIGITS_MOST]; // Values 0 to 9.
  int count;      // The digits used.
  int point;      // The place of the decimal point.
  bool truncated; // A digit that is not 0 was dropped after the last one.
} Decimal;

static void decimal_trim(Decimal *decimal) {
  while (decimal->count > 0 && decimal->digits[decimal->count - 1] == 0)
    decimal->count--;
  if (decimal->count == 0)
    decimal->point = 0;
}

// Divides the decimal by 2^shift, with shift at most DECIMAL_SHIFT_BITS_MOST.
static void decimal_shift_right(Decimal *decimal, int shift) {
  int read = 0;
  int write = 0;
  uint64_t value = 0;
  for (; (value >> shift) == 0; read++) {
    if (read >= decimal->count) {
      if (value == 0) {
        decimal->count = 0;
        return;
      }
      while ((value >> shift) == 0) {
        value *= 10;
        read++;
      }
      break;
    }
    value = value * 10 + decimal->digits[read];
  }
  decimal->point -= read - 1;
  uint64_t mask = ((uint64_t)1 << shift) - 1;
  for (; read < decimal->count; read++) {
    uint64_t digit = value >> shift;
    value &= mask;
    decimal->digits[write++] = (unsigned char)digit;
    value = value * 10 + decimal->digits[read];
  }
  while (value > 0) {
    uint64_t digit = value >> shift;
    value &= mask;
    if (write < DECIMAL_DIGITS_MOST)
      decimal->digits[write++] = (unsigned char)digit;
    else if (digit > 0)
      decimal->truncated = true;
    value *= 10;
  }
  decimal->count = write;
  decimal_trim(decimal);
}

// Multiplies the decimal by 2^shift, with shift at most
// DECIMAL_SHIFT_BITS_MOST. The count of new digits is known only at the
// end, so the digits are written from the last one, DECIMAL_SHIFT_DIGITS_MOST
// places to the right, then moved to the start.
static void decimal_shift_left(Decimal *decimal, int shift) {
  int end = decimal->count + DECIMAL_SHIFT_DIGITS_MOST;
  int write = end;
  uint64_t value = 0;
  for (int read = decimal->count - 1; read >= 0; read--) {
    value += (uint64_t)decimal->digits[read] << shift;
    decimal->digits[--write] = (unsigned char)(value % 10);
    value /= 10;
  }
  while (value > 0) {
    decimal->digits[--write] = (unsigned char)(value % 10);
    value /= 10;
  }
  int count = end - write;
  decimal->point += count - decimal->count;
  if (count > DECIMAL_DIGITS_MOST) {
    for (int index = write + DECIMAL_DIGITS_MOST; index < end; index++)
      if (decimal->digits[index] != 0)
        decimal->truncated = true;
    count = DECIMAL_DIGITS_MOST;
  }
  for (int index = 0; index < count; index++)
    decimal->digits[index] = decimal->digits[write + index];
  decimal->count = count;
  decimal_trim(decimal);
}

static void decimal_shift(Decimal *decimal, int shift) {
  if (decimal->count == 0)
    return;
  for (; shift > DECIMAL_SHIFT_BITS_MOST; shift -= DECIMAL_SHIFT_BITS_MOST)
    decimal_shift_left(decimal, DECIMAL_SHIFT_BITS_MOST);
  for (; shift < -DECIMAL_SHIFT_BITS_MOST; shift += DECIMAL_SHIFT_BITS_MOST)
    decimal_shift_right(decimal, DECIMAL_SHIFT_BITS_MOST);
  if (shift > 0)
    decimal_shift_left(decimal, shift);
  else if (shift < 0)
    decimal_shift_right(decimal, -shift);
}

// The integer part of the decimal, rounded to the nearest, ties to even. A
// tie with a dropped digit after it is above the tie. The caller keeps the
// integer part under 2^54.
static uint64_t decimal_rounded_integer(const Decimal *decimal) {
  uint64_t value = 0;
  int index = 0;
  for (; index < decimal->point && index < decimal->count; index++)
    value = value * 10 + decimal->digits[index];
  for (; index < decimal->point; index++)
    value *= 10;
  int place = decimal->point;
  if (place < 0 || place >= decimal->count)
    return value;
  bool up;
  if (decimal->digits[place] == 5 && place + 1 == decimal->count)
    up = decimal->truncated || (value & 1);
  else
    up = decimal->digits[place] >= 5;
  return value + up;
}

// The bits of a step of a shift for each place of the point: 10^point is
// under 2^bits, so the point moves down by one place at most in a step.
static const int decimal_power_bits[] = {1, 3, 6, 9, 13, 16, 19, 23, 26};
#define DECIMAL_POWER_PLACES 9
#define DECIMAL_POWER_BITS_LAST 27

// The bits of the double nearest to the decimal, with no sign. range is
// set when the value is past the largest double, or below the least
// normal double and not exact.
static uint64_t decimal_to_double_bits(Decimal *decimal, bool *range) {
  if (decimal->count == 0)
    return 0;
  if (decimal->point > DECIMAL_POINT_MOST)
    goto infinity;
  if (decimal->point < DECIMAL_POINT_LEAST) {
    *range = true;
    return 0;
  }
  // Scale by powers of 2 until the value is in [0.5, 1).
  int exponent = 0;
  while (decimal->point > 0) {
    int bits = decimal->point < DECIMAL_POWER_PLACES ? decimal_power_bits[decimal->point] : DECIMAL_POWER_BITS_LAST;
    decimal_shift(decimal, -bits);
    exponent += bits;
  }
  while (decimal->point < 0 || (decimal->point == 0 && decimal->digits[0] < 5)) {
    int bits = -decimal->point < DECIMAL_POWER_PLACES ? decimal_power_bits[-decimal->point] : DECIMAL_POWER_BITS_LAST;
    decimal_shift(decimal, bits);
    exponent -= bits;
  }
  // The fraction of a double is in [1, 2).
  exponent--;
  // Below the least exponent, the double is subnormal: fewer bits.
  if (exponent < 1 - DOUBLE_EXPONENT_BIAS) {
    decimal_shift(decimal, -(1 - DOUBLE_EXPONENT_BIAS - exponent));
    exponent = 1 - DOUBLE_EXPONENT_BIAS;
  }
  if (exponent + DOUBLE_EXPONENT_BIAS >= DOUBLE_EXPONENT_ALL_ONES)
    goto infinity;
  decimal_shift(decimal, 1 + DOUBLE_FRACTION_BITS);
  bool exact = !decimal->truncated && decimal->count <= decimal->point;
  uint64_t fraction = decimal_rounded_integer(decimal);
  // The rounding carried into a new bit.
  if (fraction == (uint64_t)2 << DOUBLE_FRACTION_BITS) {
    fraction >>= 1;
    exponent++;
    if (exponent + DOUBLE_EXPONENT_BIAS >= DOUBLE_EXPONENT_ALL_ONES)
      goto infinity;
  }
  uint64_t biased = (uint64_t)(exponent + DOUBLE_EXPONENT_BIAS);
  if ((fraction & ((uint64_t)1 << DOUBLE_FRACTION_BITS)) == 0) {
    biased = 0;
    if (!exact)
      *range = true;
  }
  return (biased << DOUBLE_FRACTION_BITS) | (fraction & (((uint64_t)1 << DOUBLE_FRACTION_BITS) - 1));
infinity:
  *range = true;
  return (uint64_t)DOUBLE_EXPONENT_ALL_ONES << DOUBLE_FRACTION_BITS;
}

// The bits of the double nearest to fraction x 2^exponent, with no sign.
// sticky says that a bit that is not 0 was dropped below the fraction.
static uint64_t binary_to_double_bits(uint64_t fraction, long exponent, bool sticky, bool *range) {
  if (fraction == 0)
    return 0;
  // The highest bit goes to bit 63: the place of each bit is then known.
  while ((fraction >> 63) == 0) {
    fraction <<= 1;
    exponent--;
  }
  // The value is 1.f x 2^(exponent + 63).
  long unbiased = exponent + 63;
  if (unbiased > DOUBLE_EXPONENT_BIAS)
    goto infinity;
  // The bits of the fraction that the double keeps: 53, fewer when subnormal.
  int drop = 63 - DOUBLE_FRACTION_BITS;
  if (unbiased < 1 - DOUBLE_EXPONENT_BIAS) {
    long below = (1 - DOUBLE_EXPONENT_BIAS) - unbiased;
    // Past 64 dropped bits the value is under half of the least subnormal.
    if (below > 64 - drop) {
      *range = true;
      return 0;
    }
    drop += (int)below;
    unbiased = 1 - DOUBLE_EXPONENT_BIAS;
  }
  uint64_t kept = drop == 64 ? 0 : fraction >> drop;
  uint64_t rest = drop == 64 ? fraction : fraction & (((uint64_t)1 << drop) - 1);
  uint64_t half = (uint64_t)1 << (drop - 1);
  bool exact = rest == 0 && !sticky;
  if (rest > half || (rest == half && (sticky || (kept & 1))))
    kept++;
  if (kept == (uint64_t)2 << DOUBLE_FRACTION_BITS) {
    kept >>= 1;
    unbiased++;
    if (unbiased > DOUBLE_EXPONENT_BIAS)
      goto infinity;
  }
  uint64_t biased = (uint64_t)(unbiased + DOUBLE_EXPONENT_BIAS);
  if ((kept & ((uint64_t)1 << DOUBLE_FRACTION_BITS)) == 0) {
    biased = 0;
    if (!exact)
      *range = true;
  }
  return (biased << DOUBLE_FRACTION_BITS) | (kept & (((uint64_t)1 << DOUBLE_FRACTION_BITS) - 1));
infinity:
  *range = true;
  return (uint64_t)DOUBLE_EXPONENT_ALL_ONES << DOUBLE_FRACTION_BITS;
}

// Reads an exponent at its letter: the letter, a sign, then decimal
// digits. With no digit, the letter is not part of the number: the
// result is 0 and place does not move.
static long exponent_read(const char **place) {
  const char *cursor = *place + 1;
  long sign = 1;
  if (*cursor == '+' || *cursor == '-') {
    sign = *cursor == '-' ? -1 : 1;
    cursor++;
  }
  if (!isdigit((unsigned char)*cursor))
    return 0;
  long value = 0;
  for (; isdigit((unsigned char)*cursor); cursor++)
    if (value < EXPONENT_READ_MOST)
      value = value * 10 + (*cursor - '0');
  *place = cursor;
  return sign * value;
}

// Reads the hexadecimal part of a number after `0x`: digits, a point,
// digits, then an optional exponent of 2 after `p`. found is false when
// no digit follows the prefix.
static uint64_t hexadecimal_read(const char **place, bool *found, bool *range) {
  const char *cursor = *place;
  uint64_t fraction = 0;
  long exponent = 0;
  bool sticky = false;
  bool point = false;
  bool digits = false;
  for (;; cursor++) {
    if (*cursor == '.' && !point) {
      point = true;
      continue;
    }
    if (!isxdigit((unsigned char)*cursor))
      break;
    digits = true;
    int digit = digit_value((unsigned char)*cursor);
    if ((fraction >> 60) == 0) {
      fraction = fraction << 4 | (uint64_t)digit;
      if (point && exponent > -EXPONENT_READ_MOST)
        exponent -= 4;
    } else {
      // A digit past 64 bits only says if the value is above the bits.
      sticky |= digit != 0;
      if (!point && exponent < EXPONENT_READ_MOST)
        exponent += 4;
    }
  }
  if (!digits) {
    *found = false;
    return 0;
  }
  *found = true;
  if (*cursor == 'p' || *cursor == 'P')
    exponent += exponent_read(&cursor);
  *place = cursor;
  return binary_to_double_bits(fraction, exponent, sticky, range);
}

// Reads the decimal part of a number: digits, a point, digits, then an
// optional exponent of 10 after `e`. found is false when the text has no
// digit.
static uint64_t decimal_read(const char **place, bool *found, bool *range) {
  Decimal decimal;
  decimal.count = 0;
  decimal.point = 0;
  decimal.truncated = false;
  const char *cursor = *place;
  long point = 0;
  // The significant digits, with those past DECIMAL_DIGITS_MOST: the point
  // of 10^900 is 901, not the count of the digits kept.
  long significant = 0;
  bool point_seen = false;
  bool digits = false;
  for (;; cursor++) {
    if (*cursor == '.' && !point_seen) {
      point_seen = true;
      // The zeros before the point are not significant: they moved nothing.
      point = significant;
      continue;
    }
    if (!isdigit((unsigned char)*cursor))
      break;
    digits = true;
    int digit = *cursor - '0';
    if (digit == 0 && decimal.count == 0) {
      // A zero before the first digit that is not 0 moves the point only.
      if (point > -EXPONENT_READ_MOST)
        point--;
      continue;
    }
    if (significant < EXPONENT_READ_MOST)
      significant++;
    if (decimal.count < DECIMAL_DIGITS_MOST)
      decimal.digits[decimal.count++] = (unsigned char)digit;
    else if (digit != 0)
      decimal.truncated = true;
  }
  if (!digits) {
    *found = false;
    return 0;
  }
  *found = true;
  if (!point_seen)
    point = significant;
  if (*cursor == 'e' || *cursor == 'E')
    point += exponent_read(&cursor);
  *place = cursor;
  if (point > EXPONENT_READ_MOST)
    point = EXPONENT_READ_MOST;
  if (point < -EXPONENT_READ_MOST)
    point = -EXPONENT_READ_MOST;
  decimal.point = (int)point;
  decimal_trim(&decimal);
  return decimal_to_double_bits(&decimal, range);
}

// Reads `word` at place, with no case.
static bool word_read(const char **place, const char *word) {
  size_t length = strlen(word);
  if (strncasecmp(*place, word, length) != 0)
    return false;
  *place += length;
  return true;
}

// C11 7.22.1.3: blanks, a sign, then a decimal number, a hexadecimal
// number after `0x`, `inf`, `infinity`, `nan` or `nan(...)`. A value past
// the largest double gives infinity and ERANGE; a value below the least
// normal double that is not exact gives ERANGE too. With no number,
// `*end` is `text` and the result is 0.
long double strtold(const char *text, char **end) {
  const char *place = text;
  while (isspace((unsigned char)*place))
    place++;
  bool negative = false;
  if (*place == '+' || *place == '-') {
    negative = *place == '-';
    place++;
  }
  uint64_t bits = 0;
  bool found = false;
  bool range = false;
  if (place[0] == '0' && (place[1] == 'x' || place[1] == 'X')) {
    const char *digits = place + 2;
    bits = hexadecimal_read(&digits, &found, &range);
    // `0x` with no digit after it is the number 0, and the `x` is not read.
    place = found ? digits : place + 1;
    found = true;
  } else if (word_read(&place, "infinity") || word_read(&place, "inf")) {
    bits = (uint64_t)DOUBLE_EXPONENT_ALL_ONES << DOUBLE_FRACTION_BITS;
    found = true;
  } else if (word_read(&place, "nan")) {
    // The quiet NaN: the characters in parentheses choose no payload.
    bits = (uint64_t)DOUBLE_EXPONENT_ALL_ONES << DOUBLE_FRACTION_BITS | (uint64_t)1 << (DOUBLE_FRACTION_BITS - 1);
    found = true;
    if (*place == '(') {
      const char *cursor = place + 1;
      while (isalnum((unsigned char)*cursor) || *cursor == '_')
        cursor++;
      if (*cursor == ')')
        place = cursor + 1;
    }
  } else {
    bits = decimal_read(&place, &found, &range);
  }
  if (!found) {
    if (end)
      *end = (char *)text;
    return 0;
  }
  if (end)
    *end = (char *)place;
  if (range)
    errno = ERANGE;
  if (negative)
    bits |= (uint64_t)1 << 63;
  union {
    uint64_t bits;
    double value;
  } result = {.bits = bits};
  return result.value;
}
