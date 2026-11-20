// The include files of chibicc as a table (src/md/features/c_compiler.md,
// "The thin libc"). The flake writes include_table.c from the folder
// include of the work: the module reads no file.
#ifndef INCLUDE_TABLE_H
#define INCLUDE_TABLE_H

typedef struct {
  const char *name; // "include/stddef.h": the folder of the include path, and the name.
  const char *text;
} Include_File;

// The last entry has no name.
extern const Include_File include_files[];

#endif
