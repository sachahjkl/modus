#ifndef _ASSERT_H
#define _ASSERT_H

_Noreturn void modus_assertion_failed(const char *condition, const char *file, int line);

#define assert(condition) ((condition) ? (void)0 : modus_assertion_failed(#condition, __FILE__, __LINE__))

#endif
