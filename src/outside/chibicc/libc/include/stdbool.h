// The thin libc of the system: the boolean type of C11
// (src/md/features/c_compiler.md, "The thin libc").
#ifndef THIN_LIBC_STDBOOL_H
#define THIN_LIBC_STDBOOL_H

#define bool _Bool
#define true 1
#define false 0
#define __bool_true_false_are_defined 1

#endif
