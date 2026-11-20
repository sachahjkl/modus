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

long double strtold(const char *text, char **end) {
  if (end)
    *end = (char *)text;
  return 0;
}
