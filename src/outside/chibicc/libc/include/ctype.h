// The thin libc of the system: the classes of an ASCII byte
// (src/md/features/c_compiler.md, "The thin libc"). The system has no
// locale: a byte past ASCII is in no class.
#ifndef THIN_LIBC_CTYPE_H
#define THIN_LIBC_CTYPE_H

int isalnum(int character);
int isalpha(int character);
int isdigit(int character);
int islower(int character);
int ispunct(int character);
int isspace(int character);
int isupper(int character);
int isxdigit(int character);
int tolower(int character);
int toupper(int character);

#endif
