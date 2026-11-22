// The export of the module of Lua 5.4.7 on modus: it runs one script in a
// new state whose memory is a heap over an arena that the caller lends, with
// the libraries that reach no host: base, coroutine, table, string, math and
// utf8 (src/md/features/c_compiler.md, "The C programs").
#include "modus_thin_libc.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

typedef long long Word;

// The request of a run: the host test fills the first six words and reads
// the last four.
typedef struct Lua_Run_Request {
  void *arena;
  Word arena_size;
  const char *source; // Text that ends with a zero byte.
  char *output;
  Word output_capacity;
  char *diagnostic;
  Word diagnostic_capacity;
  Word status;            // LUA_OK, or the status of Lua that ended the run.
  Word output_length;
  Word diagnostic_length;
  Word live_bytes_after_close; // 0 when lua_close gave back each block.
} Lua_Run_Request;

static const luaL_Reg run_libraries[] = {
    {LUA_GNAME, luaopen_base},       {LUA_COLIBNAME, luaopen_coroutine}, {LUA_TABLIBNAME, luaopen_table},
    {LUA_STRLIBNAME, luaopen_string}, {LUA_MATHLIBNAME, luaopen_math},   {LUA_UTF8LIBNAME, luaopen_utf8},
    {0, 0},
};

static void diagnostic_append(Lua_Run_Request *request, const char *text) {
  size_t room = request->diagnostic_capacity > 0 ? (size_t)request->diagnostic_capacity - 1 : 0;
  size_t length = strnlen(text, room);
  memcpy(request->diagnostic, text, length);
  request->diagnostic[length] = 0;
  request->diagnostic_length = (Word)length;
}

Word script_run(Word request_address) {
  Lua_Run_Request *request = (Lua_Run_Request *)request_address;
  if (!request || !request->source || !request->output || !request->diagnostic || request->output_capacity <= 0 ||
      request->diagnostic_capacity <= 0)
    return LUA_ERRERR;
  Modus_Heap heap;
  request->output_length = 0;
  request->diagnostic_length = 0;
  request->live_bytes_after_close = 0;
  if (modus_heap_init(&heap, request->arena, (size_t)request->arena_size) != 0) {
    request->status = LUA_ERRMEM;
    return request->status;
  }
  modus_heap_use(&heap);
  modus_lua_output_bind(request->output, (size_t)request->output_capacity, request->diagnostic,
                        (size_t)request->diagnostic_capacity);
  lua_State *state = luaL_newstate();
  if (!state) {
    request->status = LUA_ERRMEM;
    modus_heap_use(0);
    return request->status;
  }
  for (const luaL_Reg *library = run_libraries; library->func; library++) {
    luaL_requiref(state, library->name, library->func, 1);
    lua_pop(state, 1);
  }
  // What luaL_dostring does, with the status of Lua kept: the macro gives
  // only whether a step failed.
  int status = luaL_loadstring(state, request->source);
  if (status == LUA_OK)
    status = lua_pcall(state, 0, LUA_MULTRET, 0);
  request->output_length = (Word)modus_lua_output_length();
  if (status != LUA_OK) {
    const char *message = lua_tostring(state, -1);
    diagnostic_append(request, message ? message : "(an error object that is not a string)");
  } else {
    request->diagnostic_length = (Word)modus_lua_diagnostic_length();
  }
  lua_close(state);
  request->live_bytes_after_close = (Word)heap.live_bytes;
  modus_heap_use(0);
  request->status = status;
  return status;
}

Word script_request_size(void) { return (Word)sizeof(Lua_Run_Request); }
