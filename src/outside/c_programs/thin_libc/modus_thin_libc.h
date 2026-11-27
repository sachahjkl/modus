// The thin libc of the C programs of modus: the part of a C library that
// SQLite, Lua and zstd call, with no system call, no path and no clock
// (src/md/features/c_compiler.md, "The thin libc of the C programs").
//
// Each standard header of thin_libc/include includes this file only. The
// memory of a program is an arena that the caller lends (docs/PROPERTIES.md,
// "14. Memory is supplied by the caller").
#ifndef MODUS_THIN_LIBC_H
#define MODUS_THIN_LIBC_H

#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define MODUS_THIN_LIBC_NORETURN _Noreturn

// ---- The heap over a lent arena -------------------------------------------

// Each block is a header of 16 bytes, then its payload. 16 bytes keep each
// payload on the alignment of the largest scalar of the processor.
#define MODUS_HEAP_ALIGNMENT 16
#define MODUS_HEAP_HEADER_SIZE 16
#define MODUS_HEAP_SMALLEST_PAYLOAD 16

typedef struct Modus_Heap_Block Modus_Heap_Block;

typedef struct Modus_Heap {
  unsigned char *start;          // First byte of the arena, aligned.
  size_t capacity;               // Bytes for the blocks; the map of their starts follows.
  size_t top;                    // Bytes from start that blocks ever took.
  Modus_Heap_Block *free_blocks; // Free blocks below top, by address.
  size_t live_bytes;             // Payload bytes of the blocks in use.
  size_t peak_bytes;             // The largest top seen.
  size_t refused_requests;       // Requests that the arena could not pay.
  size_t refused_releases;       // Releases of a pointer that is no block in use.
} Modus_Heap;

// The result of a check of the blocks of a heap.
typedef enum Modus_Heap_Fault {
  MODUS_HEAP_FAULT_NONE = 0,
  MODUS_HEAP_FAULT_NOT_INITIALIZED = 1,
  MODUS_HEAP_FAULT_DAMAGED_HEADER = 2,
  MODUS_HEAP_FAULT_BLOCK_PAST_TOP = 3,
  MODUS_HEAP_FAULT_FREE_LIST_DISORDER = 4,
  MODUS_HEAP_FAULT_ADJACENT_FREE_BLOCKS = 5,
  MODUS_HEAP_FAULT_LIVE_COUNT_MISMATCH = 6,
  MODUS_HEAP_FAULT_FREE_BLOCK_AT_TOP = 7,
} Modus_Heap_Fault;

// Returns 0, or -1 when the arena cannot hold one block of the smallest size.
int modus_heap_init(Modus_Heap *heap, void *arena, size_t arena_size);
void *modus_heap_allocate(Modus_Heap *heap, size_t size);
// Returns 0, or -1 when the pointer is no block in use: nothing changes.
int modus_heap_release(Modus_Heap *heap, void *payload);
void *modus_heap_resize(Modus_Heap *heap, void *payload, size_t size);
Modus_Heap_Fault modus_heap_check(const Modus_Heap *heap);

// malloc, calloc, realloc and free use the heap that the program chose last.
void modus_heap_use(Modus_Heap *heap);
Modus_Heap *modus_heap_current(void);

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *payload, size_t size);
void free(void *payload);

// ---- Memory and text -------------------------------------------------------

void *memcpy(void *restrict destination, const void *restrict source, size_t count);
void *memmove(void *destination, const void *source, size_t count);
void *memset(void *destination, int value, size_t count);
int memcmp(const void *left, const void *right, size_t count);
void *memchr(const void *bytes, int value, size_t count);

size_t strlen(const char *text);
size_t strnlen(const char *text, size_t limit);
int strcmp(const char *left, const char *right);
int strncmp(const char *left, const char *right, size_t count);
int strcoll(const char *left, const char *right);
char *strchr(const char *text, int character);
char *strrchr(const char *text, int character);
char *strstr(const char *text, const char *pattern);
char *strpbrk(const char *text, const char *accepted);
size_t strspn(const char *text, const char *accepted);
size_t strcspn(const char *text, const char *rejected);
char *strcpy(char *restrict destination, const char *restrict source);
char *strncpy(char *restrict destination, const char *restrict source, size_t count);
char *strcat(char *restrict destination, const char *restrict source);
char *strdup(const char *text);
char *strerror(int error_number);

int isalnum(int character);
int isalpha(int character);
int iscntrl(int character);
int isdigit(int character);
int isgraph(int character);
int islower(int character);
int isprint(int character);
int ispunct(int character);
int isspace(int character);
int isupper(int character);
int isxdigit(int character);
int tolower(int character);
int toupper(int character);

// ---- Numbers ---------------------------------------------------------------

#define ERANGE 34
#define EINVAL 22
#define ENOENT 2
#define ENOMEM 12
#define EBADF 9
#define EDOM 33
int *modus_errno_place(void);
#define errno (*modus_errno_place())

long strtol(const char *restrict text, char **restrict end, int base);
unsigned long strtoul(const char *restrict text, char **restrict end, int base);
long long strtoll(const char *restrict text, char **restrict end, int base);
unsigned long long strtoull(const char *restrict text, char **restrict end, int base);
double strtod(const char *restrict text, char **restrict end);
float strtof(const char *restrict text, char **restrict end);
int atoi(const char *text);
long atol(const char *text);
int abs(int value);
long labs(long value);
long long llabs(long long value);

void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *));
MODUS_THIN_LIBC_NORETURN void abort(void);

double floor(double value);
double ceil(double value);
double trunc(double value);
double fabs(double value);
double fmod(double numerator, double denominator);
double sqrt(double value);
double frexp(double value, int *exponent);
double ldexp(double value, int exponent);

// The elementary functions (modus_thin_libc_math.c). The circular functions
// take radians, as the C standard says.
double exp(double value);
double log(double value);
double log2(double value);
double log10(double value);
double pow(double base, double exponent);
double sin(double angle);
double cos(double angle);
double tan(double angle);
double asin(double value);
double acos(double value);
double atan(double value);
double atan2(double y, double x);

// Portable IEEE-754 classification and bit helpers used by chibicc where
// GCC/Clang compiler builtins are absent.
double modus_double_inf(void);
double modus_double_nan(void);
int modus_isnan(double value);
int modus_isinf(double value);
int modus_isfinite(double value);
int modus_signbit(double value);
int modus_clzll(unsigned long long value);

// ---- Formatted output and memory streams ------------------------------------

typedef enum Modus_Stream_Mode {
  MODUS_STREAM_READ = 1,   // Reads the bytes that the caller lent.
  MODUS_STREAM_WRITE = 2,  // Writes from the start; the length starts at 0.
  MODUS_STREAM_APPEND = 3, // Writes after the bytes that the caller lent.
} Modus_Stream_Mode;

typedef struct Modus_File {
  unsigned char *bytes;
  size_t capacity;
  size_t length;
  size_t position;
  Modus_Stream_Mode mode;
  int open;
  int error;
  int end_of_file;
  int pushed_back; // A byte of ungetc, or -1.
} Modus_File;

typedef Modus_File FILE;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define BUFSIZ 1024

// Returns the stream, or 0 for a null buffer or a length past the capacity.
FILE *modus_memory_stream_open(FILE *stream, void *bytes, size_t capacity, size_t length, Modus_Stream_Mode mode);
// The standard streams are memory streams that the program binds; an unbound
// stream refuses each operation.
void modus_standard_streams_set(FILE *input, FILE *output, FILE *diagnostic);
extern FILE *modus_standard_input;
extern FILE *modus_standard_output;
extern FILE *modus_standard_diagnostic;
#define stdin modus_standard_input
#define stdout modus_standard_output
#define stderr modus_standard_diagnostic

FILE *fopen(const char *restrict name, const char *restrict mode);
FILE *freopen(const char *restrict name, const char *restrict mode, FILE *restrict stream);
int fclose(FILE *stream);
int fflush(FILE *stream);
size_t fread(void *restrict destination, size_t size, size_t count, FILE *restrict stream);
size_t fwrite(const void *restrict source, size_t size, size_t count, FILE *restrict stream);
int fputc(int character, FILE *stream);
int putc(int character, FILE *stream);
int putchar(int character);
int fputs(const char *restrict text, FILE *restrict stream);
int puts(const char *text);
int fgetc(FILE *stream);
int getc(FILE *stream);
int ungetc(int character, FILE *stream);
char *fgets(char *restrict destination, int count, FILE *restrict stream);
int fseek(FILE *stream, long offset, int origin);
long ftell(FILE *stream);
void rewind(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);
void clearerr(FILE *stream);

int vsnprintf(char *restrict destination, size_t capacity, const char *restrict format, va_list arguments);
int snprintf(char *restrict destination, size_t capacity, const char *restrict format, ...);
int sprintf(char *restrict destination, const char *restrict format, ...);
int vfprintf(FILE *restrict stream, const char *restrict format, va_list arguments);
int fprintf(FILE *restrict stream, const char *restrict format, ...);
int printf(const char *restrict format, ...);

// ---- Non-local jumps ---------------------------------------------------------

// rbx, rbp, r12, r13, r14, r15, the stack pointer after the return, and the
// return address: the registers that the System V AMD64 call keeps.
typedef unsigned long jmp_buf[8];
#ifdef __GNUC__
__attribute__((returns_twice)) int setjmp(jmp_buf environment);
#else
int setjmp(jmp_buf environment);
#endif
MODUS_THIN_LIBC_NORETURN void longjmp(jmp_buf environment, int value);
#define _setjmp setjmp
#define _longjmp longjmp

// ---- Time and locale ---------------------------------------------------------

// A program reads no clock: each time is the start of the epoch, so that two
// runs give the same bytes (docs/PROPERTIES.md, "11. Reproducible system").
typedef long time_t;
typedef long clock_t;
#define CLOCKS_PER_SEC 1000000L
time_t time(time_t *place);
clock_t clock(void);

struct lconv {
  char *decimal_point;
  char *thousands_sep;
  char *grouping;
};
struct lconv *localeconv(void);

#endif
