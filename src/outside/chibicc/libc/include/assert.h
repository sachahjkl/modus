// The thin libc of the system: the check of a condition
// (src/md/features/c_compiler.md, "The thin libc"). A failed check ends the
// work through `exit`, with the condition, its file and its line in the
// diagnostic: the module never stops on it.
#ifndef THIN_LIBC_ASSERT_H
#define THIN_LIBC_ASSERT_H

_Noreturn void assertion_failed(const char *condition, const char *file, int line);

#define assert(condition) ((condition) ? (void)0 : assertion_failed(#condition, __FILE__, __LINE__))

#endif
