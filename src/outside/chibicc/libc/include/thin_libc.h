// The thin libc of the system: what the entry of a work gives it before
// the work runs (src/md/features/c_compiler.md, "The thin libc"). No file
// of the work includes this header: only the entry of the system does.
#ifndef THIN_LIBC_H
#define THIN_LIBC_H

#include <stdbool.h>
#include <stddef.h>

// The procedure that gives memory: `size` bytes at an address that is a
// multiple of `alignment`, from an arena of the budget of the process, or
// NULL when the budget cannot pay them. The module writes it in Odin, and
// keeps the record of the refusal.
typedef void *Memory_Provider(void *provider_context, size_t size, size_t alignment);
void thin_libc_memory_set(Memory_Provider *provider, void *provider_context);

// A file that `fopen` reads: a name of the table and its bytes.
typedef struct {
  const char *name;
  const char *bytes;
  size_t size;
} Readable_File;
// The files of the table: the list stays until the end of the work.
void thin_libc_files_set(const Readable_File *files, size_t count);
// The file of the table with this name, or NULL.
const Readable_File *thin_libc_file_find(const char *name);

// The stream of the diagnostic, `stderr` and `stdout`, over memory that
// the module gives: it never asks for memory, so it still writes after the
// budget refused a request. A byte past the capacity is dropped and counted.
void thin_libc_diagnostic_set(char *bytes, size_t capacity);
size_t thin_libc_diagnostic_size(void);
size_t thin_libc_diagnostic_dropped(void);

// The end of a work. The entry sets the buffer with thin_libc_jump_set,
// then sets `thin_libc_exit_ready`; `exit` jumps back there with
// thin_libc_jump, and thin_libc_jump_set then gives 1. With no entry
// ready, `exit` stops the process on a trap: it never returns into code
// that did not expect it.
#define THIN_LIBC_JUMP_BUFFER_WORDS 8
extern void *thin_libc_exit_buffer[THIN_LIBC_JUMP_BUFFER_WORDS];
#ifdef __chibicc__
// chibicc has no built-in of a jump: two procedures of assembly keep and
// restore the registers that a call keeps (self_host/jump.s).
int thin_libc_jump_set(void **buffer);
_Noreturn void thin_libc_jump(void **buffer);
#define thin_libc_trap() asm("ud2")
#else
#define thin_libc_jump_set(buffer) __builtin_setjmp(buffer)
#define thin_libc_jump(buffer) __builtin_longjmp(buffer, 1)
#define thin_libc_trap() __builtin_trap()
#endif
extern bool thin_libc_exit_ready;
extern int thin_libc_exit_status;

#endif
