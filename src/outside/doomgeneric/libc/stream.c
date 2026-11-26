// Freestanding FILE streams, printf/vsnprintf, and sscanf for doomgeneric.
// WAD reads serve directly from the preloaded in-memory WAD buffer; savegames
// and configuration files round-trip through the process private store hooks.
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include <modus_doom_host.h>

// Plan value: largest savegame or configuration file buffered in memory before
// committing to the private store (vanilla SAVEGAMESIZE is 180 KiB).
#define SAVE_FILE_LIMIT (512 * 1024)

// Inline capacity: one log line buffered before flushing to Odin log_line.
#define LOG_LINE_CAPACITY 512

typedef enum {
  STREAM_LOG,
  STREAM_READ_BORROWED,
  STREAM_READ_OWNED,
  STREAM_WRITE_SAVE,
} Stream_Kind;

struct Modus_Stream {
  Stream_Kind kind;
  uint8_t    *bytes;
  size_t      size;
  size_t      capacity;
  size_t      position;
  bool        eof_flag;
  bool        err_flag;
  char        name[128];
};

static struct Modus_Stream stdin_stream  = {.kind = STREAM_READ_BORROWED};
static struct Modus_Stream stdout_stream = {.kind = STREAM_LOG};
static struct Modus_Stream stderr_stream = {.kind = STREAM_LOG};

FILE *stdin  = &stdin_stream;
FILE *stdout = &stdout_stream;
FILE *stderr = &stderr_stream;

static char   log_line_buf[LOG_LINE_CAPACITY];
static size_t log_line_len = 0;

void modus_libc_flush_log(void) {
  if (log_line_len == 0) {
    return;
  }
  if (modus_doom_host && modus_doom_host->log_line) {
    modus_doom_host->log_line(modus_doom_host->ctx, log_line_buf, log_line_len);
  }
  log_line_len = 0;
}

static void log_emit_bytes(const char *data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    char ch = data[i];
    if (ch == '\r') {
      continue;
    }
    if (ch == '\n') {
      modus_libc_flush_log();
      continue;
    }
    if (log_line_len >= LOG_LINE_CAPACITY - 1) {
      modus_libc_flush_log();
    }
    log_line_buf[log_line_len++] = ch;
  }
}

// Strip leading "./" and directory prefixes so object names match the flat store.
static const char *normalize_store_name(const char *path) {
  if (!path) {
    return "";
  }
  const char *slash = strrchr(path, '/');
  if (slash) {
    return slash + 1;
  }
  return path;
}

static bool is_wad_path(const char *path) {
  if (!modus_doom_host || !modus_doom_host->wad_name || !modus_doom_host->wad_bytes) {
    return false;
  }
  const char *name = normalize_store_name(path);
  return strcasecmp(name, modus_doom_host->wad_name) == 0;
}

FILE *fopen(const char *path, const char *mode) {
  if (!path || !mode || !mode[0]) {
    errno = EINVAL;
    return NULL;
  }
  const char *name = normalize_store_name(path);
  if (name[0] == '\0') {
    errno = ENOENT;
    return NULL;
  }

  if (mode[0] == 'r') {
    if (is_wad_path(path)) {
      FILE *f = (FILE *)calloc(1, sizeof(FILE));
      if (!f) {
        errno = ENOMEM;
        return NULL;
      }
      f->kind = STREAM_READ_BORROWED;
      f->bytes = (uint8_t *)modus_doom_host->wad_bytes;
      f->size = modus_doom_host->wad_size;
      f->capacity = modus_doom_host->wad_size;
      return f;
    }
    if (!modus_doom_host || !modus_doom_host->save_read) {
      errno = ENOENT;
      return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc(SAVE_FILE_LIMIT);
    if (!buf) {
      errno = ENOMEM;
      return NULL;
    }
    size_t read_size = 0;
    if (!modus_doom_host->save_read(modus_doom_host->ctx, name, buf, SAVE_FILE_LIMIT, &read_size)) {
      free(buf);
      errno = ENOENT;
      return NULL;
    }
    FILE *f = (FILE *)calloc(1, sizeof(FILE));
    if (!f) {
      free(buf);
      errno = ENOMEM;
      return NULL;
    }
    f->kind = STREAM_READ_OWNED;
    f->bytes = buf;
    f->size = read_size;
    f->capacity = SAVE_FILE_LIMIT;
    return f;
  }

  if (mode[0] == 'w' || mode[0] == 'a') {
    FILE *f = (FILE *)calloc(1, sizeof(FILE));
    if (!f) {
      errno = ENOMEM;
      return NULL;
    }
    f->kind = STREAM_WRITE_SAVE;
    f->capacity = 4096;
    f->bytes = (uint8_t *)malloc(f->capacity);
    if (!f->bytes) {
      free(f);
      errno = ENOMEM;
      return NULL;
    }
    size_t nlen = strlen(name);
    if (nlen >= sizeof(f->name)) {
      nlen = sizeof(f->name) - 1;
    }
    memcpy(f->name, name, nlen);
    f->name[nlen] = '\0';
    return f;
  }

  errno = EINVAL;
  return NULL;
}

int fclose(FILE *stream) {
  if (!stream) {
    return EOF;
  }
  if (stream == stdout || stream == stderr) {
    modus_libc_flush_log();
    return 0;
  }
  if (stream == stdin) {
    return 0;
  }
  int rc = 0;
  if (stream->kind == STREAM_WRITE_SAVE) {
    if (modus_doom_host && modus_doom_host->save_write && stream->name[0] != '\0') {
      if (!modus_doom_host->save_write(modus_doom_host->ctx, stream->name, stream->bytes, stream->size)) {
        rc = EOF;
      }
    }
    free(stream->bytes);
  } else if (stream->kind == STREAM_READ_OWNED) {
    free(stream->bytes);
  }
  free(stream);
  return rc;
}

size_t fread(void *ptr, size_t size, size_t count, FILE *stream) {
  if (!stream || !ptr || size == 0 || count == 0) {
    return 0;
  }
  if (stream->kind != STREAM_READ_BORROWED && stream->kind != STREAM_READ_OWNED) {
    stream->err_flag = true;
    return 0;
  }
  if (count > SIZE_MAX / size) {
    stream->err_flag = true;
    return 0;
  }
  size_t wanted = size * count;
  size_t avail = stream->position < stream->size ? stream->size - stream->position : 0;
  if (avail < wanted) {
    stream->eof_flag = true;
  }
  size_t take = wanted < avail ? wanted : avail;
  take -= take % size;
  if (take > 0) {
    memcpy(ptr, stream->bytes + stream->position, take);
    stream->position += take;
  }
  return take / size;
}

size_t fwrite(const void *ptr, size_t size, size_t count, FILE *stream) {
  if (!stream || !ptr || size == 0 || count == 0) {
    return 0;
  }
  if (count > SIZE_MAX / size) {
    stream->err_flag = true;
    return 0;
  }
  size_t total = size * count;
  if (stream->kind == STREAM_LOG) {
    log_emit_bytes((const char *)ptr, total);
    return count;
  }
  if (stream->kind != STREAM_WRITE_SAVE) {
    stream->err_flag = true;
    return 0;
  }
  if (stream->position > SAVE_FILE_LIMIT || total > SAVE_FILE_LIMIT - stream->position) {
    stream->err_flag = true;
    return 0;
  }
  size_t end_pos = stream->position + total;
  if (end_pos > stream->capacity) {
    size_t new_cap = stream->capacity;
    while (new_cap < end_pos) {
      new_cap *= 2;
    }
    if (new_cap > SAVE_FILE_LIMIT) {
      new_cap = SAVE_FILE_LIMIT;
    }
    uint8_t *grown = (uint8_t *)realloc(stream->bytes, new_cap);
    if (!grown) {
      stream->err_flag = true;
      return 0;
    }
    stream->bytes = grown;
    stream->capacity = new_cap;
  }
  memcpy(stream->bytes + stream->position, ptr, total);
  stream->position = end_pos;
  if (end_pos > stream->size) {
    stream->size = end_pos;
  }
  return count;
}

int fseek(FILE *stream, long offset, int origin) {
  if (!stream || stream->kind == STREAM_LOG) {
    return -1;
  }
  long base = 0;
  switch (origin) {
  case SEEK_SET: base = 0; break;
  case SEEK_CUR: base = (long)stream->position; break;
  case SEEK_END: base = (long)stream->size; break;
  default: return -1;
  }
  long target = base + offset;
  if (target < 0) {
    return -1;
  }
  if ((size_t)target > stream->size && stream->kind != STREAM_WRITE_SAVE) {
    target = (long)stream->size;
  }
  stream->position = (size_t)target;
  stream->eof_flag = false;
  return 0;
}

long ftell(FILE *stream) {
  if (!stream || stream->kind == STREAM_LOG) {
    return -1;
  }
  return (long)stream->position;
}

int fflush(FILE *stream) {
  if (!stream || stream == stdout || stream == stderr) {
    modus_libc_flush_log();
  }
  return 0;
}

int feof(FILE *stream) {
  return stream && stream->eof_flag ? 1 : 0;
}

int ferror(FILE *stream) {
  return stream && stream->err_flag ? 1 : 0;
}

int fgetc(FILE *stream) {
  unsigned char ch = 0;
  if (fread(&ch, 1, 1, stream) != 1) {
    return EOF;
  }
  return (int)ch;
}

int getc(FILE *stream) {
  return fgetc(stream);
}

int fputc(int ch, FILE *stream) {
  unsigned char byte = (unsigned char)ch;
  if (fwrite(&byte, 1, 1, stream) != 1) {
    return EOF;
  }
  return (int)byte;
}

int putc(int ch, FILE *stream) {
  return fputc(ch, stream);
}

int putchar(int ch) {
  return fputc(ch, stdout);
}

int fputs(const char *s, FILE *stream) {
  size_t len = strlen(s);
  return fwrite(s, 1, len, stream) == len ? 0 : EOF;
}

int puts(const char *s) {
  if (fputs(s, stdout) == EOF) {
    return EOF;
  }
  return fputc('\n', stdout) == EOF ? EOF : 0;
}

char *fgets(char *buf, int count, FILE *stream) {
  if (!buf || count <= 0 || !stream) {
    return NULL;
  }
  int written = 0;
  while (written < count - 1) {
    int ch = fgetc(stream);
    if (ch == EOF) {
      if (written == 0) {
        return NULL;
      }
      break;
    }
    buf[written++] = (char)ch;
    if (ch == '\n') {
      break;
    }
  }
  buf[written] = '\0';
  return buf;
}

int remove(const char *path) {
  if (!modus_doom_host || !modus_doom_host->save_remove) {
    return -1;
  }
  return modus_doom_host->save_remove(modus_doom_host->ctx, normalize_store_name(path)) ? 0 : -1;
}

int rename(const char *old_path, const char *new_path) {
  if (!modus_doom_host || !modus_doom_host->save_read || !modus_doom_host->save_write) {
    return -1;
  }
  const char *old_name = normalize_store_name(old_path);
  const char *new_name = normalize_store_name(new_path);
  uint8_t *buf = (uint8_t *)malloc(SAVE_FILE_LIMIT);
  if (!buf) {
    return -1;
  }
  size_t size = 0;
  int ok = modus_doom_host->save_read(modus_doom_host->ctx, old_name, buf, SAVE_FILE_LIMIT, &size);
  if (ok) {
    ok = modus_doom_host->save_write(modus_doom_host->ctx, new_name, buf, size);
  }
  free(buf);
  if (ok && modus_doom_host->save_remove) {
    modus_doom_host->save_remove(modus_doom_host->ctx, old_name);
  }
  return ok ? 0 : -1;
}

int mkdir(const char *path, mode_t mode) {
  (void)path;
  (void)mode;
  return 0;
}

int stat(const char *path, struct stat *st) {
  if (!path || !st) {
    return -1;
  }
  memset(st, 0, sizeof(*st));
  if (is_wad_path(path)) {
    st->st_mode = S_IFREG | 0444;
    st->st_size = (off_t)modus_doom_host->wad_size;
    return 0;
  }
  if (strcmp(path, ".") == 0) {
    st->st_mode = S_IFDIR | 0755;
    return 0;
  }
  return -1;
}

int access(const char *path, int mode) {
  (void)mode;
  return is_wad_path(path) ? 0 : -1;
}

int isatty(int fd) {
  (void)fd;
  return 0;
}

// ---------------------------------------------------------------------------
// Formatted output (vsnprintf / snprintf / sprintf / vfprintf / printf)
// ---------------------------------------------------------------------------

typedef struct {
  char  *buf;
  size_t cap;
  size_t len;
} Out_Buf;

static void out_put(Out_Buf *out, char ch) {
  if (out->buf && out->len + 1 < out->cap) {
    out->buf[out->len] = ch;
  }
  out->len++;
}

static void out_pad(Out_Buf *out, char ch, int count) {
  for (int i = 0; i < count; i++) {
    out_put(out, ch);
  }
}

static void out_str(Out_Buf *out, const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    out_put(out, s[i]);
  }
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list args) {
  Out_Buf out = {.buf = buf, .cap = size, .len = 0};
  for (const char *p = fmt; *p != '\0'; p++) {
    if (*p != '%') {
      out_put(&out, *p);
      continue;
    }
    p++;
    bool left = false;
    bool zero = false;
    bool plus = false;
    bool space = false;
    bool alt = false;
    for (;;) {
      if (*p == '-') { left = true; p++; }
      else if (*p == '0') { zero = true; p++; }
      else if (*p == '+') { plus = true; p++; }
      else if (*p == ' ') { space = true; p++; }
      else if (*p == '#') { alt = true; p++; }
      else break;
    }
    int width = 0;
    if (*p == '*') {
      width = va_arg(args, int);
      if (width < 0) { left = true; width = -width; }
      p++;
    } else {
      while (isdigit((unsigned char)*p)) {
        width = width * 10 + (*p - '0');
        p++;
      }
    }
    int prec = -1;
    if (*p == '.') {
      p++;
      if (*p == '*') {
        prec = va_arg(args, int);
        p++;
      } else {
        prec = 0;
        while (isdigit((unsigned char)*p)) {
          prec = prec * 10 + (*p - '0');
          p++;
        }
      }
    }
    int length_mod = 0;
    while (*p == 'l' || *p == 'z' || *p == 'h') {
      if (*p == 'l') length_mod++;
      else if (*p == 'z') length_mod = 1;
      p++;
    }
    char spec = *p;
    if (spec == '\0') {
      break;
    }
    if (spec == '%') {
      out_put(&out, '%');
      continue;
    }
    if (spec == 'c') {
      char ch = (char)va_arg(args, int);
      if (!left && width > 1) out_pad(&out, ' ', width - 1);
      out_put(&out, ch);
      if (left && width > 1) out_pad(&out, ' ', width - 1);
      continue;
    }
    if (spec == 's') {
      const char *s = va_arg(args, const char *);
      if (!s) s = "(null)";
      size_t slen = prec >= 0 ? strnlen(s, (size_t)prec) : strlen(s);
      int pad = width > (int)slen ? width - (int)slen : 0;
      if (!left) out_pad(&out, ' ', pad);
      out_str(&out, s, slen);
      if (left) out_pad(&out, ' ', pad);
      continue;
    }
    if (spec == 'f' || spec == 'g') {
      double val = va_arg(args, double);
      if (val < 0.0) {
        out_put(&out, '-');
        val = -val;
      }
      int frac_digits = prec >= 0 ? prec : 6;
      if (frac_digits > 6) frac_digits = 6;
      unsigned long whole = (unsigned long)val;
      double rem = val - (double)whole;
      char num[32];
      int n = 0;
      if (whole == 0) {
        num[n++] = '0';
      } else {
        while (whole > 0 && n < 31) {
          num[n++] = (char)('0' + (whole % 10));
          whole /= 10;
        }
      }
      for (int i = n - 1; i >= 0; i--) out_put(&out, num[i]);
      if (frac_digits > 0) {
        out_put(&out, '.');
        for (int i = 0; i < frac_digits; i++) {
          rem *= 10.0;
          int d = (int)rem;
          if (d < 0) d = 0;
          if (d > 9) d = 9;
          out_put(&out, (char)('0' + d));
          rem -= (double)d;
        }
      }
      continue;
    }
    if (spec == 'd' || spec == 'i' || spec == 'u' || spec == 'x' || spec == 'X' || spec == 'o' || spec == 'p') {
      bool is_signed = (spec == 'd' || spec == 'i');
      unsigned int base = 10;
      const char *digits = "0123456789abcdef";
      if (spec == 'x' || spec == 'p') base = 16;
      else if (spec == 'X') { base = 16; digits = "0123456789ABCDEF"; }
      else if (spec == 'o') base = 8;

      unsigned long uval = 0;
      char sign_char = 0;
      if (spec == 'p') {
        uval = (unsigned long)(uintptr_t)va_arg(args, void *);
        alt = true;
      } else if (is_signed) {
        long sval = length_mod >= 1 ? va_arg(args, long) : (long)va_arg(args, int);
        if (sval < 0) {
          sign_char = '-';
          uval = (unsigned long)(-(sval + 1)) + 1UL;
        } else {
          if (plus) sign_char = '+';
          else if (space) sign_char = ' ';
          uval = (unsigned long)sval;
        }
      } else {
        uval = length_mod >= 1 ? va_arg(args, unsigned long) : (unsigned long)va_arg(args, unsigned int);
      }

      char tmp[32];
      int n = 0;
      if (uval == 0) {
        if (prec != 0) tmp[n++] = '0';
      } else {
        while (uval > 0) {
          tmp[n++] = digits[uval % base];
          uval /= base;
        }
      }
      int zero_prec = prec > n ? prec - n : 0;
      const char *prefix = "";
      int prefix_len = 0;
      if (alt && (spec == 'x' || spec == 'p')) { prefix = "0x"; prefix_len = 2; }
      else if (alt && spec == 'X') { prefix = "0X"; prefix_len = 2; }
      int total_len = (sign_char ? 1 : 0) + prefix_len + zero_prec + n;
      int pad = width > total_len ? width - total_len : 0;
      bool pad_zero = zero && !left && prec < 0;
      if (!left && !pad_zero) out_pad(&out, ' ', pad);
      if (sign_char) out_put(&out, sign_char);
      out_str(&out, prefix, (size_t)prefix_len);
      if (!left && pad_zero) out_pad(&out, '0', pad);
      out_pad(&out, '0', zero_prec);
      for (int i = n - 1; i >= 0; i--) out_put(&out, tmp[i]);
      if (left) out_pad(&out, ' ', pad);
      continue;
    }
    out_put(&out, '%');
    out_put(&out, spec);
  }
  if (out.buf && out.cap > 0) {
    out.buf[out.len < out.cap ? out.len : out.cap - 1] = '\0';
  }
  return (int)out.len;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(buf, size, fmt, args);
  va_end(args);
  return n;
}

int sprintf(char *buf, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(buf, SIZE_MAX, fmt, args);
  va_end(args);
  return n;
}

int vfprintf(FILE *stream, const char *fmt, va_list args) {
  char stack_buf[1024];
  va_list copy;
  va_copy(copy, args);
  int needed = vsnprintf(stack_buf, sizeof(stack_buf), fmt, args);
  if (needed < 0) {
    va_end(copy);
    return needed;
  }
  if ((size_t)needed < sizeof(stack_buf)) {
    va_end(copy);
    fwrite(stack_buf, 1, (size_t)needed, stream);
    return needed;
  }
  char *heap_buf = (char *)malloc((size_t)needed + 1);
  if (!heap_buf) {
    va_end(copy);
    fwrite(stack_buf, 1, sizeof(stack_buf) - 1, stream);
    return (int)(sizeof(stack_buf) - 1);
  }
  vsnprintf(heap_buf, (size_t)needed + 1, fmt, copy);
  va_end(copy);
  fwrite(heap_buf, 1, (size_t)needed, stream);
  free(heap_buf);
  return needed;
}

int fprintf(FILE *stream, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vfprintf(stream, fmt, args);
  va_end(args);
  return n;
}

int printf(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vfprintf(stdout, fmt, args);
  va_end(args);
  return n;
}

// ---------------------------------------------------------------------------
// Minimal sscanf covering m_config.c and m_misc.c
// ---------------------------------------------------------------------------

int sscanf(const char *str, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  const char *s = str;
  int matched = 0;

  for (const char *f = fmt; *f != '\0'; f++) {
    if (isspace((unsigned char)*f)) {
      while (isspace((unsigned char)*s)) s++;
      continue;
    }
    if (*f != '%') {
      if (*s != *f) break;
      s++;
      continue;
    }
    f++;
    if (*f == '%') {
      if (*s != '%') break;
      s++;
      continue;
    }
    bool suppress = false;
    if (*f == '*') {
      suppress = true;
      f++;
    }
    while (isdigit((unsigned char)*f)) {
      f++;
    }
    int long_mod = 0;
    while (*f == 'l') {
      long_mod++;
      f++;
    }
    char spec = *f;
    if (spec == 'd' || spec == 'i' || spec == 'x' || spec == 'X' || spec == 'o' || spec == 'u') {
      while (isspace((unsigned char)*s)) s++;
      int base = 10;
      if (spec == 'x' || spec == 'X') base = 16;
      else if (spec == 'o') base = 8;
      else if (spec == 'i') base = 0;
      char *end = NULL;
      long val = strtol(s, &end, base);
      if (end == s) break;
      s = end;
      if (!suppress) {
        if (spec == 'u' || spec == 'x' || spec == 'X' || spec == 'o') {
          if (long_mod) *va_arg(args, unsigned long *) = (unsigned long)val;
          else *va_arg(args, unsigned int *) = (unsigned int)val;
        } else {
          if (long_mod) *va_arg(args, long *) = val;
          else *va_arg(args, int *) = (int)val;
        }
        matched++;
      }
    } else if (spec == 's') {
      while (isspace((unsigned char)*s)) s++;
      if (*s == '\0') break;
      char *dst = suppress ? NULL : va_arg(args, char *);
      while (*s != '\0' && !isspace((unsigned char)*s)) {
        if (dst) *dst++ = *s;
        s++;
      }
      if (dst) {
        *dst = '\0';
        matched++;
      }
    } else if (spec == 'c') {
      if (*s == '\0') break;
      if (!suppress) {
        *va_arg(args, char *) = *s;
        matched++;
      }
      s++;
    } else {
      break;
    }
  }
  va_end(args);
  return matched;
}
