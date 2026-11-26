#ifndef _STDIO_H
#define _STDIO_H

#include <stdarg.h>
#include <stddef.h>

typedef struct Modus_Stream FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF      (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define FILENAME_MAX 256

FILE  *fopen(const char *path, const char *mode);
int    fclose(FILE *stream);
size_t fread(void *ptr, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t count, FILE *stream);
int    fseek(FILE *stream, long offset, int origin);
long   ftell(FILE *stream);
int    fflush(FILE *stream);
int    feof(FILE *stream);
int    ferror(FILE *stream);
int    fgetc(FILE *stream);
int    getc(FILE *stream);
int    fputc(int ch, FILE *stream);
int    putc(int ch, FILE *stream);
int    putchar(int ch);
int    puts(const char *s);
int    fputs(const char *s, FILE *stream);
char  *fgets(char *buf, int count, FILE *stream);
int    remove(const char *path);
int    rename(const char *old_path, const char *new_path);

int    printf(const char *fmt, ...);
int    fprintf(FILE *stream, const char *fmt, ...);
int    vfprintf(FILE *stream, const char *fmt, va_list args);
int    sprintf(char *buf, const char *fmt, ...);
int    snprintf(char *buf, size_t size, const char *fmt, ...);
int    vsnprintf(char *buf, size_t size, const char *fmt, va_list args);
int    sscanf(const char *str, const char *fmt, ...);

#endif
