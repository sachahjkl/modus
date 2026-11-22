// The entry of chibicc in the module c_compiler, in place of its main.c
// (src/md/features/c_compiler.md, "The C entry"). It does what cc1 of
// main.c does for one file, with no file: the source is a file of the table
// of the thin libc, and the text of assembly is a stream in memory that the
// module copies into the memory that its caller lends.
#include "chibicc.h"
#include "include_table.h"
#include <thin_libc.h>

// The name of the source in the table of files, in a diagnostic and in
// __FILE__, when the caller gives no name.
#define SOURCE_NAME "source.c"

// What main.c of chibicc defines for the other files.
StringArray include_paths;
// A tentative definition is a variable of zeros in the data: the
// assembler has no common symbol.
bool opt_fcommon = false;
// The address of a variable is %rip and its label, which the assembler
// takes; a table of the linker is a form of ELF.
bool opt_fpic = false;
char *base_file = SOURCE_NAME;

bool file_exists(char *path) {
  return thin_libc_file_find(path) != NULL;
}

// The record of one call, which the module fills and reads. Each field is
// 8 bytes, so the Odin record of the module has the same layout with no
// padding (src/modules/system/c_compiler/c_compiler.odin, Compile_Call).
typedef struct {
  // Given by the caller.
  const char *source;
  size_t source_size;
  Memory_Provider *memory_provider;
  void *memory_provider_context;
  char *diagnostic;
  size_t diagnostic_capacity;
  // A unit of a program of several sources. The zero values compile one
  // source, named SOURCE_NAME, whose functions that are not static are the
  // exports.
  const char *source_name;            // Its folder is the folder of a quoted include.
  const Readable_File *program_files; // The other files of the program: its headers, and those of the thin libc.
  size_t program_file_count;
  const char *const *export_names;    // The functions that are exports; NULL: each function that is not static.
  size_t export_name_count;
  // Given back.
  char *text;
  size_t text_size;
  long error_offset; // The byte of the source that the diagnostic names; -1: none.
  size_t diagnostic_size;
} Compile_Call;

// The results of chibicc_compile.
enum {
  COMPILE_DONE = 0,    // The text is in the record.
  COMPILE_REFUSED = 1, // chibicc ended through exit: the diagnostic says why.
};

// Read after the jump of exit: a value that lives in a register at the
// setjmp is not restored, so the record is read from memory.
static Compile_Call *volatile current_call;
static volatile long error_offset = -1;

void error_place_record(char *filename, char *input, char *loc) {
  if (filename && input && loc && strcmp(filename, base_file) == 0 && loc >= input)
    error_offset = loc - input;
  else
    error_offset = -1;
}

// One source: external linkage marks an export. A program: the caller
// names its exports, and external linkage joins its units.
bool function_is_export(char *name) {
  if (!current_call->export_names)
    return true;
  for (size_t index = 0; index < current_call->export_name_count; index++)
    if (strcmp(current_call->export_names[index], name) == 0)
      return true;
  return false;
}

int chibicc_compile(Compile_Call *call) {
  current_call = call;
  error_offset = -1;
  thin_libc_memory_set(call->memory_provider, call->memory_provider_context);
  thin_libc_diagnostic_set(call->diagnostic, call->diagnostic_capacity);

  if (thin_libc_jump_set(thin_libc_exit_buffer)) {
    current_call->error_offset = error_offset;
    current_call->diagnostic_size = thin_libc_diagnostic_size();
    return COMPILE_REFUSED;
  }
  thin_libc_exit_ready = true;

  if (call->source_name)
    base_file = (char *)call->source_name;

  // The table of files: the source, the files of the program, then the
  // include files of chibicc.
  size_t include_count = 0;
  while (include_files[include_count].name)
    include_count++;
  size_t file_count = 1 + call->program_file_count + include_count;
  Readable_File *files = calloc(file_count, sizeof(Readable_File));
  files[0] = (Readable_File){.name = base_file, .bytes = call->source, .size = call->source_size};
  for (size_t index = 0; index < call->program_file_count; index++)
    files[1 + index] = call->program_files[index];
  for (size_t index = 0; index < include_count; index++)
    files[1 + call->program_file_count + index] = (Readable_File){.name = include_files[index].name, .bytes = include_files[index].text, .size = strlen(include_files[index].text)};
  thin_libc_files_set(files, file_count);
  // The include files of chibicc first, as its main.c orders them, then
  // the headers of the thin libc, which a program of several units gives.
  strarray_push(&include_paths, "include");
  strarray_push(&include_paths, "libc/include");

  init_macros();
  Token *tok = tokenize_file(base_file);
  if (!tok)
    error("%s: %s", base_file, strerror(errno));
  tok = preprocess(tok);
  Obj *prog = parse(tok);

  char *text;
  size_t text_size;
  FILE *out = open_memstream(&text, &text_size);
  codegen(prog, out);
  fclose(out);

  thin_libc_exit_ready = false;
  call->text = text;
  call->text_size = text_size;
  call->error_offset = -1;
  call->diagnostic_size = thin_libc_diagnostic_size();
  return COMPILE_DONE;
}

// The export of the compiler when it is a module of its own: an export
// takes Integer values, so the record is given by its address. clang hides
// each other symbol of the C part; chibicc.h makes the attribute empty for
// chibicc, whose exports the caller names.
__attribute__((visibility("default"))) long compile_record_at(long record_address) {
  return chibicc_compile((Compile_Call *)record_address);
}
