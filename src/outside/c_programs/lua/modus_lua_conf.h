// The configuration of Lua 5.4 on modus (src/md/features/c_compiler.md,
// "The configuration of Lua"). The recipe of Lua adds one line to the end of
// luaconf.h, in its section "Local configuration":
//
//   #include "modus_lua_conf.h"
//
// so each definition here comes after the one of luaconf.h and replaces it.
// lauxlib.h reads lua_writestring and its kin only when they are not defined.
#ifndef MODUS_LUA_CONF_H
#define MODUS_LUA_CONF_H

#include <stddef.h>

// No part of the host: no POSIX, no Linux, no dynamic library, no line editor.
#undef LUA_USE_POSIX
#undef LUA_USE_LINUX
#undef LUA_USE_MACOSX
#undef LUA_USE_DLOPEN
#undef LUA_USE_READLINE
#undef LUA_DL_DLOPEN

// The output of print and the diagnostics of the auxiliary library go to the
// memory that the caller lends (modus_lua_output.c), not to a standard stream.
void modus_lua_output_bind(char *output, size_t output_capacity, char *diagnostic, size_t diagnostic_capacity);
void modus_lua_output_write(const char *bytes, size_t count);
void modus_lua_diagnostic_write(const char *format, const char *argument);
size_t modus_lua_output_length(void);
size_t modus_lua_diagnostic_length(void);
int modus_lua_output_overflowed(void);

#undef lua_writestring
#undef lua_writeline
#undef lua_writestringerror
#define lua_writestring(bytes, count) modus_lua_output_write((bytes), (count))
#define lua_writeline() modus_lua_output_write("\n", 1)
#define lua_writestringerror(format, argument) modus_lua_diagnostic_write((format), (argument))

// The one locale is "C".
#undef lua_getlocaledecpoint
#define lua_getlocaledecpoint() ('.')

// The thin libc has no "%a": with no lua_number2strx, string.format("%a")
// uses the conversion that Lua writes itself.
#undef lua_number2strx

// No shell, no process and no name of a file: os.execute says that no shell
// is there, io.popen fails with its message, and os.tmpname fails.
#undef l_system
#define l_system(command) ((command) == NULL ? 0 : -1)
#undef l_popen
#define l_popen(state, command, mode) (luaL_error((state), "'popen' not supported"), (FILE *)0)
#undef l_pclose
#define l_pclose(state, stream) ((void)(state), (void)(stream), -1)
#undef lua_tmpnam
#define lua_tmpnam(buffer, error)                                                                                      \
  {                                                                                                                    \
    (void)(buffer);                                                                                                    \
    error = 1;                                                                                                         \
  }

// The seed of the hashes of strings is a constant: a program reads no clock,
// and two runs give the same order of a table.
#undef luai_makeseed
#define luai_makeseed(state) ((void)(state), (unsigned int)0x6d6f6475u)

#endif
