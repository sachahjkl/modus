// The thin libc of the system: streams in memory
// (src/md/features/c_compiler.md, "The thin libc").
//
// A FILE is a stream over bytes in memory: a file of the table of files,
// which `fopen` opens to read, or a buffer that grows, which
// `open_memstream` opens to write. There is no path and no standard
// stream of a terminal: `stderr` and `stdout` are one stream of the
// diagnostic, which the entry of the work gives to the module, and
// `stdin` gives no byte.
#ifndef THIN_LIBC_STDIO_H
#define THIN_LIBC_STDIO_H

#include <stdarg.h>
#include <stddef.h>

typedef struct Memory_Stream FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)

// Opens a file of the table of files to read: `mode` is "r". Each other
// name or mode gives NULL, with errno ENOENT or EINVAL.
FILE *fopen(const char *name, const char *mode);
// Opens a stream that writes into a buffer that grows. After each write,
// `*buffer` is the first byte and `*size` the bytes written; a byte 0
// follows them, which `*size` does not count.
FILE *open_memstream(char **buffer, size_t *size);
size_t fread(void *bytes, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *bytes, size_t size, size_t count, FILE *stream);
int fputc(int character, FILE *stream);
int fflush(FILE *stream);
int fclose(FILE *stream);

// The formats: the flags `-`, `+`, space, `0` and `#`, a width and a
// precision as digits or `*`, the sizes `hh`, `h`, `l`, `ll`, `z` and `j`,
// and the conversions `d`, `i`, `u`, `x`, `X`, `o`, `c`, `s`, `p` and `%`.
// A conversion of floating point writes `?`.
int vfprintf(FILE *stream, const char *format, va_list arguments);
int fprintf(FILE *stream, const char *format, ...) __attribute__((format(printf, 2, 3)));
int printf(const char *format, ...) __attribute__((format(printf, 1, 2)));

#endif
