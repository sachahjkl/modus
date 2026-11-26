// Freestanding string, ctype, numeric parsing, and qsort routines for doomgeneric.
// memcpy, memmove, and memset come from src/runtime/memory.asm.
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

int isalpha(int c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

int isdigit(int c) {
  return c >= '0' && c <= '9';
}

int isxdigit(int c) {
  return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

int isalnum(int c) {
  return isalpha(c) || isdigit(c);
}

int isspace(int c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

int isupper(int c) {
  return c >= 'A' && c <= 'Z';
}

int islower(int c) {
  return c >= 'a' && c <= 'z';
}

int isprint(int c) {
  return c >= 0x20 && c <= 0x7E;
}

int iscntrl(int c) {
  return (c >= 0 && c < 0x20) || c == 0x7F;
}

int ispunct(int c) {
  return isprint(c) && !isalnum(c) && c != ' ';
}

int toupper(int c) {
  return islower(c) ? c - ('a' - 'A') : c;
}

int tolower(int c) {
  return isupper(c) ? c + ('a' - 'A') : c;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *pa = (const unsigned char *)a;
  const unsigned char *pb = (const unsigned char *)b;
  for (size_t i = 0; i < n; i++) {
    if (pa[i] != pb[i]) {
      return (int)pa[i] - (int)pb[i];
    }
  }
  return 0;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n] != '\0') {
    n++;
  }
  return n;
}

size_t strnlen(const char *s, size_t max_len) {
  size_t n = 0;
  while (n < max_len && s[n] != '\0') {
    n++;
  }
  return n;
}

char *strcpy(char *dst, const char *src) {
  char *out = dst;
  while ((*dst++ = *src++) != '\0') {
  }
  return out;
}

char *strncpy(char *dst, const char *src, size_t n) {
  size_t i = 0;
  for (; i < n && src[i] != '\0'; i++) {
    dst[i] = src[i];
  }
  for (; i < n; i++) {
    dst[i] = '\0';
  }
  return dst;
}

char *strcat(char *dst, const char *src) {
  char *end = dst + strlen(dst);
  strcpy(end, src);
  return dst;
}

char *strncat(char *dst, const char *src, size_t n) {
  char *end = dst + strlen(dst);
  size_t i = 0;
  for (; i < n && src[i] != '\0'; i++) {
    end[i] = src[i];
  }
  end[i] = '\0';
  return dst;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (a[i] != b[i] || a[i] == '\0') {
      return (unsigned char)a[i] - (unsigned char)b[i];
    }
  }
  return 0;
}

int strcasecmp(const char *a, const char *b) {
  while (*a && tolower((unsigned char)*a) == tolower((unsigned char)*b)) {
    a++;
    b++;
  }
  return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

int strncasecmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    int ca = tolower((unsigned char)a[i]);
    int cb = tolower((unsigned char)b[i]);
    if (ca != cb || ca == '\0') {
      return ca - cb;
    }
  }
  return 0;
}

char *strchr(const char *s, int ch) {
  unsigned char target = (unsigned char)ch;
  for (;;) {
    if ((unsigned char)*s == target) {
      return (char *)s;
    }
    if (*s == '\0') {
      return NULL;
    }
    s++;
  }
}

char *strrchr(const char *s, int ch) {
  unsigned char target = (unsigned char)ch;
  const char *last = NULL;
  for (;;) {
    if ((unsigned char)*s == target) {
      last = s;
    }
    if (*s == '\0') {
      return (char *)last;
    }
    s++;
  }
}

char *strstr(const char *haystack, const char *needle) {
  if (*needle == '\0') {
    return (char *)haystack;
  }
  size_t needle_len = strlen(needle);
  for (; *haystack != '\0'; haystack++) {
    if (*haystack == *needle && strncmp(haystack, needle, needle_len) == 0) {
      return (char *)haystack;
    }
  }
  return NULL;
}

char *strdup(const char *s) {
  size_t len = strlen(s) + 1;
  char *copy = (char *)malloc(len);
  if (copy) {
    memcpy(copy, s, len);
  }
  return copy;
}

char *strerror(int errnum) {
  switch (errnum) {
  case 0:      return "no error";
  case ENOENT: return "no such object";
  case ENOMEM: return "out of memory";
  case EINVAL: return "refused argument";
  case EIO:    return "storage read or write failed";
  default:     return "error";
  }
}

int abs(int value) {
  return value < 0 ? -value : value;
}

long labs(long value) {
  return value < 0 ? -value : value;
}

static int digit_value(int ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'z') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'Z') return ch - 'A' + 10;
  return -1;
}

unsigned long strtoul(const char *s, char **endptr, int base) {
  const char *p = s;
  while (isspace((unsigned char)*p)) {
    p++;
  }
  bool negative = false;
  if (*p == '-') {
    negative = true;
    p++;
  } else if (*p == '+') {
    p++;
  }
  if (base == 0) {
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
      base = 16;
      p += 2;
    } else if (p[0] == '0') {
      base = 8;
      p++;
    } else {
      base = 10;
    }
  } else if (base == 16 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
    p += 2;
  }
  unsigned long acc = 0;
  bool any = false;
  for (;;) {
    int d = digit_value((unsigned char)*p);
    if (d < 0 || d >= base) {
      break;
    }
    acc = acc * (unsigned long)base + (unsigned long)d;
    any = true;
    p++;
  }
  if (endptr) {
    *endptr = (char *)(any ? p : s);
  }
  return negative ? (unsigned long)(-(long)acc) : acc;
}

long strtol(const char *s, char **endptr, int base) {
  const char *p = s;
  while (isspace((unsigned char)*p)) {
    p++;
  }
  bool negative = false;
  if (*p == '-') {
    negative = true;
    p++;
  } else if (*p == '+') {
    p++;
  }
  char *after = NULL;
  unsigned long mag = strtoul(p, &after, base);
  if (endptr) {
    *endptr = (after == p) ? (char *)s : after;
  }
  return negative ? -(long)mag : (long)mag;
}

int atoi(const char *s) {
  return (int)strtol(s, NULL, 10);
}

long atol(const char *s) {
  return strtol(s, NULL, 10);
}

double atof(const char *s) {
  const char *p = s;
  while (isspace((unsigned char)*p)) {
    p++;
  }
  double sign = 1.0;
  if (*p == '-') {
    sign = -1.0;
    p++;
  } else if (*p == '+') {
    p++;
  }
  double result = 0.0;
  while (isdigit((unsigned char)*p)) {
    result = result * 10.0 + (double)(*p - '0');
    p++;
  }
  if (*p == '.') {
    p++;
    double scale = 0.1;
    while (isdigit((unsigned char)*p)) {
      result += (double)(*p - '0') * scale;
      scale *= 0.1;
      p++;
    }
  }
  return sign * result;
}

static void swap_bytes(unsigned char *a, unsigned char *b, size_t size) {
  for (size_t i = 0; i < size; i++) {
    unsigned char tmp = a[i];
    a[i] = b[i];
    b[i] = tmp;
  }
}

// Heapsort avoids deep recursion and worst-case O(n^2) stack growth.
void qsort(void *base, size_t count, size_t size, int (*cmp)(const void *, const void *)) {
  if (count < 2 || size == 0) {
    return;
  }
  unsigned char *arr = (unsigned char *)base;
  for (size_t start = count / 2; start > 0; start--) {
    size_t root = start - 1;
    for (;;) {
      size_t child = root * 2 + 1;
      if (child >= count) {
        break;
      }
      if (child + 1 < count && cmp(arr + child * size, arr + (child + 1) * size) < 0) {
        child++;
      }
      if (cmp(arr + root * size, arr + child * size) < 0) {
        swap_bytes(arr + root * size, arr + child * size, size);
        root = child;
      } else {
        break;
      }
    }
  }
  for (size_t end = count - 1; end > 0; end--) {
    swap_bytes(arr, arr + end * size, size);
    size_t root = 0;
    for (;;) {
      size_t child = root * 2 + 1;
      if (child >= end) {
        break;
      }
      if (child + 1 < end && cmp(arr + child * size, arr + (child + 1) * size) < 0) {
        child++;
      }
      if (cmp(arr + root * size, arr + child * size) < 0) {
        swap_bytes(arr + root * size, arr + child * size, size);
        root = child;
      } else {
        break;
      }
    }
  }
}
