// The header signal.h of the thin libc: a program receives no signal, so it
// holds the type that Lua keeps its hook flag in, and nothing else.
#ifndef MODUS_THIN_LIBC_SIGNAL_H
#define MODUS_THIN_LIBC_SIGNAL_H
typedef int sig_atomic_t;
#endif
