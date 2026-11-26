#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);

_Noreturn void exit(int status);
_Noreturn void abort(void);

int           atoi(const char *s);
long          atol(const char *s);
double        atof(const char *s);
long          strtol(const char *s, char **endptr, int base);
unsigned long strtoul(const char *s, char **endptr, int base);
int           abs(int value);
long          labs(long value);
void          qsort(void *base, size_t count, size_t size, int (*cmp)(const void *, const void *));
char         *getenv(const char *name);
int           system(const char *command);

#endif
