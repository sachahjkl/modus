// The exports of the module of SQLite 3.54.1 on modus: a session opens one
// database over two regions that the caller lends, the memory of SQLite and
// the bytes of its files, and runs SQL text. Each export takes and gives
// integers, as the module contract asks (src/md/features/c_compiler.md,
// "The C programs").
#include "modus_vfs.h"
#include "modus_thin_libc.h"

typedef long long Word;

// The main database, its rollback journal, and two files for SQLite to spill
// to: each slot takes a part of the lent bytes.
#define SESSION_SLOT_COUNT 4
static const int SESSION_SLOT_SHARES[SESSION_SLOT_COUNT] = {8, 4, 2, 2};

static Modus_Vfs_Store session_store;
static sqlite3 *session_database;

// The seed of the randomness of the VFS is a constant: two runs give the same
// bytes (docs/PROPERTIES.md, "11. Reproducible system").
#define SESSION_RANDOM_SEED 0x6d6f647573ULL

// SQLite gives memsys5 a whole arena; below this, it cannot start.
#define SESSION_SMALLEST_ARENA (64 * 1024)

// Opens the database "main.db" over the store. A store that holds a database
// already opens it again: the bytes of the store are the file.
Word sqlite_session_open(Word arena, Word arena_size, Word store_bytes, Word store_size, Word fresh_store) {
  if (session_database)
    return SQLITE_MISUSE;
  if (!arena || arena_size < SESSION_SMALLEST_ARENA || !store_bytes || store_size <= 0)
    return SQLITE_MISUSE;
  if (fresh_store) {
    int share_total = 0;
    for (int index = 0; index < SESSION_SLOT_COUNT; index++)
      share_total += SESSION_SLOT_SHARES[index];
    sqlite3_int64 capacities[SESSION_SLOT_COUNT];
    sqlite3_int64 unit = (sqlite3_int64)store_size / share_total / MODUS_VFS_SECTOR_SIZE * MODUS_VFS_SECTOR_SIZE;
    for (int index = 0; index < SESSION_SLOT_COUNT; index++)
      capacities[index] = unit * SESSION_SLOT_SHARES[index];
    int code = modus_vfs_store_init(&session_store, (unsigned char *)store_bytes, store_size, capacities,
                                    SESSION_SLOT_COUNT, SESSION_RANDOM_SEED);
    if (code != SQLITE_OK)
      return code;
  }
  modus_vfs_bind_default_store(&session_store);
  int code = sqlite3_config(SQLITE_CONFIG_HEAP, (void *)arena, (int)arena_size, 64);
  if (code != SQLITE_OK)
    return code;
  code = sqlite3_initialize();
  if (code != SQLITE_OK)
    return code;
  code = sqlite3_open_v2("main.db", &session_database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
  if (code != SQLITE_OK) {
    sqlite3_close(session_database);
    session_database = 0;
    sqlite3_shutdown();
  }
  return code;
}

typedef struct Output_Text {
  char *bytes;
  size_t capacity;
  size_t length;
  int overflowed;
} Output_Text;

static void output_append(Output_Text *output, const char *text, size_t count) {
  if (output->length + count + 1 > output->capacity) {
    output->overflowed = 1;
    return;
  }
  memcpy(output->bytes + output->length, text, count);
  output->length += count;
  output->bytes[output->length] = 0;
}

static void output_append_text(Output_Text *output, const char *text) { output_append(output, text, strlen(text)); }

// Runs each statement of the text. Each row is written as its columns joined
// by '|', then '\n', as the list mode of the shell of SQLite writes it; a
// NULL is written as an empty column. On a fault, the output holds the
// message of SQLite. Gives the code of SQLite; SQLITE_TOOBIG when the rows do
// not fit the output.
Word sqlite_session_execute(Word sql, Word output_bytes, Word output_capacity) {
  if (!session_database || !sql || !output_bytes || output_capacity <= 0)
    return SQLITE_MISUSE;
  Output_Text output = {(char *)output_bytes, (size_t)output_capacity, 0, 0};
  output.bytes[0] = 0;
  const char *rest = (const char *)sql;
  while (*rest) {
    sqlite3_stmt *statement = 0;
    const char *next = 0;
    int code = sqlite3_prepare_v2(session_database, rest, -1, &statement, &next);
    if (code != SQLITE_OK) {
      output.length = 0;
      output_append_text(&output, sqlite3_errmsg(session_database));
      return code;
    }
    rest = next;
    if (!statement)
      continue; // Blank text or a comment.
    int columns = sqlite3_column_count(statement);
    while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
      for (int column = 0; column < columns; column++) {
        if (column > 0)
          output_append(&output, "|", 1);
        const unsigned char *text = sqlite3_column_text(statement, column);
        if (text)
          output_append(&output, (const char *)text, (size_t)sqlite3_column_bytes(statement, column));
      }
      output_append(&output, "\n", 1);
    }
    if (code != SQLITE_DONE) {
      output.length = 0;
      output_append_text(&output, sqlite3_errmsg(session_database));
      sqlite3_finalize(statement);
      return sqlite3_extended_errcode(session_database);
    }
    sqlite3_finalize(statement);
  }
  return output.overflowed ? SQLITE_TOOBIG : SQLITE_OK;
}

Word sqlite_session_changes(void) { return session_database ? sqlite3_changes(session_database) : -1; }

// Closes the database and ends SQLite; the store keeps the bytes of the files.
Word sqlite_session_close(void) {
  if (!session_database)
    return SQLITE_MISUSE;
  int code = sqlite3_close(session_database);
  if (code != SQLITE_OK)
    return code;
  session_database = 0;
  return sqlite3_shutdown();
}

// The size of the file of the database in the store, or -1.
Word sqlite_session_database_size(void) {
  for (int index = 0; index < session_store.slot_count; index++) {
    Modus_Vfs_Slot *slot = &session_store.slots[index];
    if (slot->exists && strcmp(slot->name, "main.db") == 0)
      return slot->size;
  }
  return -1;
}

Word sqlite_version_number(void) { return sqlite3_libversion_number(); }
