// The thin libc of the system: the number of the last refusal of a
// procedure of the library (src/md/features/c_compiler.md, "The thin libc").
// A module runs one call of a work at a time, so one variable is enough.
#ifndef THIN_LIBC_ERRNO_H
#define THIN_LIBC_ERRNO_H

extern int errno;

// The refusals that the thin libc gives, with the numbers that C programs
// expect from other systems: no program of the system reads the numbers.
#define ENOENT 2
#define ENOMEM 12
#define EINVAL 22
#define ERANGE 34

#endif
