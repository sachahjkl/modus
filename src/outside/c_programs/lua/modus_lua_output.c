// The output of Lua on modus: print writes into memory that the caller
// lends, and a write past its end is cut and recorded, never lost in silence
// (src/md/features/c_compiler.md, "The configuration of Lua").
#include "modus_lua_conf.h"
#include "modus_thin_libc.h"

typedef struct Lua_Output_Sink {
  char *bytes;
  size_t capacity;
  size_t length;
  int overflowed;
} Lua_Output_Sink;

static Lua_Output_Sink output_sink;
static Lua_Output_Sink diagnostic_sink;

void modus_lua_output_bind(char *output, size_t output_capacity, char *diagnostic, size_t diagnostic_capacity) {
  output_sink = (Lua_Output_Sink){output, output ? output_capacity : 0, 0, 0};
  diagnostic_sink = (Lua_Output_Sink){diagnostic, diagnostic ? diagnostic_capacity : 0, 0, 0};
}

static void sink_append(Lua_Output_Sink *sink, const char *bytes, size_t count) {
  size_t room = sink->capacity - sink->length;
  size_t taken = count < room ? count : room;
  if (taken > 0)
    memcpy(sink->bytes + sink->length, bytes, taken);
  sink->length += taken;
  if (taken < count)
    sink->overflowed = 1;
}

void modus_lua_output_write(const char *bytes, size_t count) {
  if (bytes)
    sink_append(&output_sink, bytes, count);
}

void modus_lua_diagnostic_write(const char *format, const char *argument) {
  char line[256];
  int count = snprintf(line, sizeof line, format, argument);
  if (count < 0)
    return;
  if ((size_t)count >= sizeof line) {
    diagnostic_sink.overflowed = 1;
    count = (int)sizeof line - 1;
  }
  sink_append(&diagnostic_sink, line, (size_t)count);
}

size_t modus_lua_output_length(void) { return output_sink.length; }
size_t modus_lua_diagnostic_length(void) { return diagnostic_sink.length; }
int modus_lua_output_overflowed(void) { return output_sink.overflowed || diagnostic_sink.overflowed; }
