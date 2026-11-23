// Typed, store-backed exports of SQLite 3.54.1 on modus
// (src/md/features/db_browser.md).
//
// Memory ownership without dangling pointers:
// - SQLite memsys5 heap and VFS scratch slots (rollback journal + temp spill)
//   live in .bss, paid by the isolated child call host's memory budget and
//   taking zero bytes in sqlite.module.
// - main.db bytes are supplied per call through `database: bytes(change)` and
//   unbound to NULL before every export returns.
#include "modus_sqlite_contract.h"
#include "modus_thin_libc.h"
#include "modus_vfs.h"

// Computed from measured 10,000-row transactions plus VACUUM (< 2.5 MiB heap,
// < 1.5 MiB rollback journal) with headroom inside the child call host budget.
#define SQLITE_HEAP_CAPACITY (4U * 1024U * 1024U)
#define SQLITE_HEAP_MINIMUM (64U * 1024U)
#define SQLITE_SCRATCH_CAPACITY (2U * 1024U * 1024U)
#define SQLITE_SCRATCH_SLOTS 3
// Inline capacity for SQLite error diagnostics stored across isolated calls.
#define SQLITE_DIAGNOSTIC_CAPACITY 512U
// Inline capacity for SQL copy buffer (NUL-terminated copy for sqlite3_prepare_v2).
#define SQLITE_SQL_INLINE_CAPACITY (64U * 1024U)

// Deterministic default random seed (docs/PROPERTIES.md, "11. Reproducible system").
#define SESSION_DEFAULT_RANDOM_SEED 0x6d6f647573ULL

// Scratch slot sizes: 1 MiB rollback journal + two 512 KiB temporary spill slots.
static const sqlite3_int64 SCRATCH_SLOT_CAPACITIES[SQLITE_SCRATCH_SLOTS] = {
    1024 * 1024,
    512 * 1024,
    512 * 1024,
};

static unsigned char session_heap[SQLITE_HEAP_CAPACITY];
static unsigned char session_scratch[SQLITE_SCRATCH_CAPACITY];
static unsigned char session_dirty_bitmap[MODUS_VFS_DIRTY_BITMAP_BYTES];
static char session_sql_copy[SQLITE_SQL_INLINE_CAPACITY + 1U];
static char session_diagnostic[SQLITE_DIAGNOSTIC_CAPACITY];
static uint32_t session_diagnostic_length;

static Modus_Vfs_Store session_store;
static sqlite3 *session_database;
static uint8_t session_read_only;
static uint32_t session_page_size;

static Modus_Answer answer_ok(int64_t value) {
  Modus_Answer ans = {MODUS_CALL_OUTCOME_SUCCEEDED, value};
  return ans;
}

static Modus_Answer answer_fail(Modus_Error_Record *error, Modus_Call_Outcome outcome, int64_t kind, int64_t unit,
                                int64_t argument, int64_t value, int64_t limit, int64_t found) {
  if (error) {
    error->kind = kind;
    error->unit = unit;
    error->operation = 0;
    error->argument = argument;
    error->value = value;
    error->limit = limit;
    error->found = found;
  }
  Modus_Answer ans = {outcome, 0};
  return ans;
}

static size_t utf8_truncate_length(const uint8_t *bytes, size_t length, size_t max_bytes) {
  if (length <= max_bytes)
    return length;
  size_t cut = max_bytes;
  // Walk back past UTF-8 continuation bytes (10xxxxxx) so we never split a codepoint.
  while (cut > 0 && (bytes[cut] & 0xC0U) == 0x80U)
    cut--;
  return cut;
}

static void diagnostic_set(const char *message) {
  if (!message) {
    session_diagnostic_length = 0;
    session_diagnostic[0] = 0;
    return;
  }
  size_t full = strlen(message);
  size_t keep = utf8_truncate_length((const uint8_t *)message, full, SQLITE_DIAGNOSTIC_CAPACITY - 1U);
  memcpy(session_diagnostic, message, keep);
  session_diagnostic[keep] = 0;
  session_diagnostic_length = (uint32_t)keep;
}

static void diagnostic_append_to_place(Modus_Table_Place *place) {
  if (!place || !place->address || session_diagnostic_length == 0)
    return;
  if (place->count >= place->capacity)
    return;
  uint64_t room = place->capacity - place->count;
  size_t keep = utf8_truncate_length((const uint8_t *)session_diagnostic, (size_t)session_diagnostic_length,
                                     (size_t)room);
  if (keep > 0) {
    memcpy((uint8_t *)place->address + place->count, session_diagnostic, keep);
    place->count += (uint64_t)keep;
  }
}

static int ascii_contains_ci(const char *haystack, const char *needle) {
  if (!haystack || !needle)
    return 0;
  size_t nlen = strlen(needle);
  if (nlen == 0)
    return 1;
  for (const char *p = haystack; *p; p++) {
    size_t i = 0;
    while (i < nlen && p[i]) {
      char a = p[i];
      char b = needle[i];
      if (a >= 'a' && a <= 'z')
        a = (char)(a - ('a' - 'A'));
      if (b >= 'a' && b <= 'z')
        b = (char)(b - ('a' - 'A'));
      if (a != b)
        break;
      i++;
    }
    if (i == nlen)
      return 1;
  }
  return 0;
}

static Sqlite_Value_Kind declared_kind_of(const char *decltype) {
  if (!decltype || !decltype[0])
    return SQLITE_VALUE_KIND_NONE;
  if (ascii_contains_ci(decltype, "INT"))
    return SQLITE_VALUE_KIND_INTEGER;
  if (ascii_contains_ci(decltype, "CHAR") || ascii_contains_ci(decltype, "CLOB") || ascii_contains_ci(decltype, "TEXT"))
    return SQLITE_VALUE_KIND_TEXT;
  if (ascii_contains_ci(decltype, "BLOB"))
    return SQLITE_VALUE_KIND_BLOB;
  if (ascii_contains_ci(decltype, "REAL") || ascii_contains_ci(decltype, "FLOA") || ascii_contains_ci(decltype, "DOUB"))
    return SQLITE_VALUE_KIND_REAL_BITS;
  return SQLITE_VALUE_KIND_NONE;
}

static void fill_session_info(Sqlite_Session_Info *out) {
  memset(out, 0, sizeof *out);
  out->version_number = (int64_t)sqlite3_libversion_number();
  if (session_database) {
    out->database_bytes = (uint64_t)session_store.slots[0].size;
    out->dirty_pages = (uint64_t)modus_vfs_dirty_page_count(&session_store);
    out->page_size = session_page_size;
    out->open = 1U;
    out->read_only = session_read_only;
  }
}

static void append_session_info(Modus_Table_Place *info) {
  if (!info || !info->address)
    return;
  if (info->count < info->capacity) {
    Sqlite_Session_Info *rows = (Sqlite_Session_Info *)info->address;
    fill_session_info(&rows[info->count]);
  }
  info->count += 1ULL;
}

static Modus_Call_Outcome outcome_of_sqlite_code(int code, int64_t *error_kind, int64_t *error_unit) {
  int primary = code & 0xFF;
  switch (primary) {
  case SQLITE_NOMEM:
    *error_kind = MODUS_ERROR_KIND_FULL;
    *error_unit = MODUS_ERROR_UNIT_BYTES;
    return MODUS_CALL_OUTCOME_BUDGET_OR_CAPACITY_EXHAUSTED;
  case SQLITE_FULL:
    *error_kind = MODUS_ERROR_KIND_FULL;
    *error_unit = MODUS_ERROR_UNIT_BYTES;
    return MODUS_CALL_OUTCOME_BUDGET_OR_CAPACITY_EXHAUSTED;
  case SQLITE_CORRUPT:
  case SQLITE_NOTADB:
    *error_kind = MODUS_ERROR_KIND_DAMAGED;
    *error_unit = MODUS_ERROR_UNIT_BYTES;
    return MODUS_CALL_OUTCOME_DATA_DAMAGED;
  case SQLITE_READONLY:
    *error_kind = MODUS_ERROR_KIND_NO_GRANT;
    *error_unit = MODUS_ERROR_UNIT_CHANGES;
    return MODUS_CALL_OUTCOME_GRANT_OR_RIGHT_MISSING;
  case SQLITE_MISUSE:
    *error_kind = MODUS_ERROR_KIND_STATE;
    *error_unit = MODUS_ERROR_UNIT_NONE;
    return MODUS_CALL_OUTCOME_WRONG_STATE;
  default:
    *error_kind = MODUS_ERROR_KIND_BAD_VALUE;
    *error_unit = MODUS_ERROR_UNIT_NONE;
    return MODUS_CALL_OUTCOME_ARGUMENT_REFUSED;
  }
}

static const char *skip_sql_whitespace_and_comments(const char *p) {
  while (p && *p) {
    if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == '\f' || *p == '\v') {
      p++;
      continue;
    }
    if (p[0] == '-' && p[1] == '-') {
      p += 2;
      while (*p && *p != '\n')
        p++;
      continue;
    }
    if (p[0] == '/' && p[1] == '*') {
      p += 2;
      while (*p && !(p[0] == '*' && p[1] == '/'))
        p++;
      if (*p)
        p += 2;
      continue;
    }
    break;
  }
  return p;
}

static int starts_with_keyword_ci(const char *s, const char *kw) {
  size_t len = strlen(kw);
  for (size_t i = 0; i < len; i++) {
    char a = s[i];
    if (!a)
      return 0;
    if (a >= 'a' && a <= 'z')
      a = (char)(a - ('a' - 'A'));
    if (a != kw[i])
      return 0;
  }
  char after = s[len];
  if ((after >= 'A' && after <= 'Z') || (after >= 'a' && after <= 'z') || (after >= '0' && after <= '9') ||
      after == '_')
    return 0;
  return 1;
}

// Returns 1 if the SQL text has multiple statements and should be wrapped in an
// implicit savepoint so a failure in a later statement rolls back earlier
// writes. Explicit transactions and VACUUM/PRAGMA scripts run directly.
static int should_wrap_in_savepoint(const char *sql) {
  const char *p = skip_sql_whitespace_and_comments(sql);
  if (!p || !*p)
    return 0;
  if (starts_with_keyword_ci(p, "BEGIN") || starts_with_keyword_ci(p, "COMMIT") || starts_with_keyword_ci(p, "END") ||
      starts_with_keyword_ci(p, "ROLLBACK") || starts_with_keyword_ci(p, "SAVEPOINT") ||
      starts_with_keyword_ci(p, "RELEASE") || starts_with_keyword_ci(p, "VACUUM") ||
      starts_with_keyword_ci(p, "PRAGMA"))
    return 0;
  // Scan for a semicolon followed by another non-empty token; if any statement
  // is VACUUM or explicit transaction control, do not wrap.
  int in_single = 0;
  int in_double = 0;
  int statement_count = 1;
  for (const char *c = p; *c; c++) {
    if (in_single) {
      if (*c == '\'') {
        if (c[1] == '\'')
          c++;
        else
          in_single = 0;
      }
      continue;
    }
    if (in_double) {
      if (*c == '"') {
        if (c[1] == '"')
          c++;
        else
          in_double = 0;
      }
      continue;
    }
    if (*c == '\'') {
      in_single = 1;
    } else if (*c == '"') {
      in_double = 1;
    } else if (c[0] == '-' && c[1] == '-') {
      c += 2;
      while (*c && *c != '\n')
        c++;
      if (!*c)
        break;
    } else if (c[0] == '/' && c[1] == '*') {
      c += 2;
      while (*c && !(c[0] == '*' && c[1] == '/'))
        c++;
      if (!*c)
        break;
      c++;
    } else if (*c == ';') {
      const char *next = skip_sql_whitespace_and_comments(c + 1);
      if (next && *next) {
        statement_count++;
        if (starts_with_keyword_ci(next, "BEGIN") || starts_with_keyword_ci(next, "COMMIT") ||
            starts_with_keyword_ci(next, "END") || starts_with_keyword_ci(next, "ROLLBACK") ||
            starts_with_keyword_ci(next, "VACUUM") || starts_with_keyword_ci(next, "PRAGMA"))
          return 0;
      }
    }
  }
  return statement_count > 1;
}

static void shutdown_session_clean(void) {
  if (session_database) {
    sqlite3_close(session_database);
    session_database = 0;
  }
  sqlite3_shutdown();
  modus_vfs_bind_main_bytes(&session_store, 0, 0);
  session_read_only = 0;
  session_page_size = 0;
}

// ---- Exports ----------------------------------------------------------------------------

Modus_Answer session_open(const Sqlite_Open_Options *options, Modus_Table_Place *database, Modus_Table_Place *info,
                          Modus_Error_Record *error) {
  diagnostic_set(0);
  if (session_database)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 1, 0,
                       SQLITE_MISUSE);
  if (!options)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_NONE, 1,
                       0, 0, SQLITE_MISUSE);
  if (options->fresh > 1U)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_NONE, 1,
                       (int64_t)options->fresh, 1, SQLITE_MISUSE);
  if (options->read_only > 1U)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_NONE, 1,
                       (int64_t)options->read_only, 1, SQLITE_MISUSE);
  if (options->fresh && options->read_only)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_NONE, 1,
                       1, 0, SQLITE_MISUSE);
  uint32_t page_size = options->page_size == 0U ? SQLITE_REQUIRED_PAGE_SIZE : options->page_size;
  if (page_size != SQLITE_REQUIRED_PAGE_SIZE)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_NOT_MULTIPLE,
                       MODUS_ERROR_UNIT_BYTES, 1, (int64_t)page_size, (int64_t)SQLITE_REQUIRED_PAGE_SIZE,
                       (int64_t)(page_size % SQLITE_REQUIRED_PAGE_SIZE));
  uint32_t heap_bytes = options->heap_bytes == 0U ? SQLITE_HEAP_CAPACITY : options->heap_bytes;
  if (heap_bytes < SQLITE_HEAP_MINIMUM)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_SMALL, MODUS_ERROR_UNIT_BYTES,
                       1, (int64_t)heap_bytes, (int64_t)SQLITE_HEAP_MINIMUM, SQLITE_MISUSE);
  if (heap_bytes > SQLITE_HEAP_CAPACITY)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_LONG, MODUS_ERROR_UNIT_BYTES, 1,
                       (int64_t)heap_bytes, (int64_t)SQLITE_HEAP_CAPACITY, SQLITE_MISUSE);
  if (!database || (!database->address && database->count > 0))
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_BYTES,
                       2, 0, 0, SQLITE_MISUSE);
  uint64_t max_tracked_bytes = (uint64_t)MODUS_VFS_MAX_TRACKED_PAGES * (uint64_t)MODUS_VFS_SECTOR_SIZE;
  if (database->count > max_tracked_bytes)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_LONG, MODUS_ERROR_UNIT_BYTES, 2,
                       (int64_t)database->count, (int64_t)max_tracked_bytes, SQLITE_TOOBIG);
  if (!options->read_only && database->count < SQLITE_REQUIRED_PAGE_SIZE)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_SMALL, MODUS_ERROR_UNIT_BYTES,
                       2, (int64_t)database->count, (int64_t)SQLITE_REQUIRED_PAGE_SIZE, SQLITE_MISUSE);
  if (options->fresh && options->database_bytes != 0ULL)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_BYTES,
                       1, (int64_t)options->database_bytes, 0, SQLITE_MISUSE);
  if (options->database_bytes > database->count)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_OUT_OF_RANGE,
                       MODUS_ERROR_UNIT_BYTES, 1, (int64_t)options->database_bytes, (int64_t)database->count,
                       SQLITE_MISUSE);

  if (options->fresh && database->count > 0)
    memset(database->address, 0, (size_t)database->count);
  memset(session_heap, 0, (size_t)heap_bytes);
  memset(session_scratch, 0, sizeof session_scratch);

  uint64_t seed = options->random_seed ? options->random_seed : SESSION_DEFAULT_RANDOM_SEED;
  sqlite3_int64 initial_size = options->fresh ? 0 : (sqlite3_int64)options->database_bytes;
  int code = modus_vfs_store_init_split(&session_store, initial_size, session_scratch,
                                        (sqlite3_int64)sizeof session_scratch, SCRATCH_SLOT_CAPACITIES,
                                        SQLITE_SCRATCH_SLOTS, session_dirty_bitmap, MODUS_VFS_MAX_TRACKED_PAGES, seed);
  if (code != SQLITE_OK)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_REFUSED, MODUS_ERROR_UNIT_NONE, 0,
                       0, 0, code);

  modus_vfs_bind_main_bytes(&session_store, (unsigned char *)database->address, (sqlite3_int64)database->count);
  modus_vfs_bind_default_store(&session_store);

  code = sqlite3_config(SQLITE_CONFIG_HEAP, (void *)session_heap, (int)heap_bytes, 64);
  if (code != SQLITE_OK) {
    modus_vfs_bind_main_bytes(&session_store, 0, 0);
    return answer_fail(error, MODUS_CALL_OUTCOME_BUDGET_OR_CAPACITY_EXHAUSTED, MODUS_ERROR_KIND_REFUSED,
                       MODUS_ERROR_UNIT_BYTES, 1, (int64_t)heap_bytes, (int64_t)SQLITE_HEAP_CAPACITY, code);
  }
  code = sqlite3_initialize();
  if (code != SQLITE_OK) {
    modus_vfs_bind_main_bytes(&session_store, 0, 0);
    return answer_fail(error, MODUS_CALL_OUTCOME_BUDGET_OR_CAPACITY_EXHAUSTED, MODUS_ERROR_KIND_REFUSED,
                       MODUS_ERROR_UNIT_NONE, 0, 0, 0, code);
  }

  int open_flags = options->read_only ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
  code = sqlite3_open_v2("main.db", &session_database, open_flags, 0);
  if (code != SQLITE_OK) {
    int extended = session_database ? sqlite3_extended_errcode(session_database) : code;
    diagnostic_set(session_database ? sqlite3_errmsg(session_database) : "cannot open main.db");
    shutdown_session_clean();
    int64_t kind = 0, unit = 0;
    Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
    return answer_fail(error, outcome, kind, unit, 2, 0, 0, extended);
  }

  session_read_only = options->read_only;
  session_page_size = page_size;

  // Enforce rollback journal mode (no WAL) and 4 KiB pages on fresh writable DBs.
  if (!options->read_only) {
    char *pragma_err = 0;
    const char *setup_sql = options->fresh ? "PRAGMA page_size = 4096; PRAGMA journal_mode = DELETE;"
                                           : "PRAGMA journal_mode = DELETE;";
    code = sqlite3_exec(session_database, setup_sql, 0, 0, &pragma_err);
    if (pragma_err)
      sqlite3_free(pragma_err);
    if (code != SQLITE_OK) {
      int extended = sqlite3_extended_errcode(session_database);
      diagnostic_set(sqlite3_errmsg(session_database));
      shutdown_session_clean();
      int64_t kind = 0, unit = 0;
      Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
      return answer_fail(error, outcome, kind, unit, 2, 0, 0, extended);
    }
  }

  // Validate existing non-empty database bytes eagerly so corrupted images are
  // refused on open with Data_Damaged rather than waiting for the first query.
  if (!options->fresh && options->database_bytes > 0ULL) {
    sqlite3_stmt *check_stmt = 0;
    code = sqlite3_prepare_v2(session_database, "SELECT count(*) FROM sqlite_master;", -1, &check_stmt, 0);
    if (code == SQLITE_OK && check_stmt) {
      int step = sqlite3_step(check_stmt);
      sqlite3_finalize(check_stmt);
      if (step != SQLITE_ROW && step != SQLITE_DONE)
        code = step;
    }
    if (code != SQLITE_OK) {
      int extended = sqlite3_extended_errcode(session_database);
      diagnostic_set(sqlite3_errmsg(session_database));
      shutdown_session_clean();
      int64_t kind = 0, unit = 0;
      Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
      return answer_fail(error, outcome, kind, unit, 2, 0, 0, extended);
    }
    // Opening an existing database must not report dirty pages.
    modus_vfs_clear_dirty(&session_store);
  }

  append_session_info(info);
  // Always unbind main.db pointer before returning so no pointer persists.
  modus_vfs_bind_main_bytes(&session_store, 0, 0);
  return answer_ok(0);
}

Modus_Answer session_execute(const Modus_Text_Slice *sql, Modus_Table_Place *database, Modus_Table_Place *columns,
                             Modus_Table_Place *cells, Modus_Table_Place *payload, Modus_Table_Place *diagnostic,
                             Modus_Table_Place *summary, Modus_Error_Record *error) {
  diagnostic_set(0);
  if (!session_database)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 1,
                       SQLITE_MISUSE);
  if (!sql || (!sql->address && sql->count > 0))
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_BYTES,
                       1, 0, 0, SQLITE_MISUSE);
  if (sql->count > SQLITE_SQL_INLINE_CAPACITY)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_LONG, MODUS_ERROR_UNIT_BYTES, 1,
                       (int64_t)sql->count, (int64_t)SQLITE_SQL_INLINE_CAPACITY, SQLITE_TOOBIG);
  if (!database || (!database->address && database->count > 0))
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_BYTES,
                       2, 0, 0, SQLITE_MISUSE);
  if ((sqlite3_int64)database->count < session_store.slots[0].size)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_SMALL, MODUS_ERROR_UNIT_BYTES,
                       2, (int64_t)database->count, (int64_t)session_store.slots[0].size, SQLITE_MISUSE);
  uint64_t max_tracked_bytes = (uint64_t)MODUS_VFS_MAX_TRACKED_PAGES * (uint64_t)MODUS_VFS_SECTOR_SIZE;
  if (database->count > max_tracked_bytes)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_TOO_LONG, MODUS_ERROR_UNIT_BYTES, 2,
                       (int64_t)database->count, (int64_t)max_tracked_bytes, SQLITE_TOOBIG);
  if (!columns || !cells || !payload || !diagnostic || !summary)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_NONE, 0,
                       0, 0, SQLITE_MISUSE);

  if (sql->count > 0)
    memcpy(session_sql_copy, sql->address, (size_t)sql->count);
  session_sql_copy[sql->count] = 0;

  // Bind main.db for the duration of this call only; always unbound before return.
  modus_vfs_bind_main_bytes(&session_store, (unsigned char *)database->address, (sqlite3_int64)database->count);

  uint64_t entry_columns = columns->count;
  uint64_t entry_cells = cells->count;
  uint64_t entry_payload = payload->count;

  Sqlite_Query_Summary result_summary;
  memset(&result_summary, 0, sizeof result_summary);

  int wrapped_savepoint = 0;
  if (!session_read_only && sqlite3_get_autocommit(session_database) != 0 && should_wrap_in_savepoint(session_sql_copy)) {
    if (sqlite3_exec(session_database, "SAVEPOINT _modus_exec;", 0, 0, 0) == SQLITE_OK)
      wrapped_savepoint = 1;
  }

  int64_t last_changes = 0;
  const char *rest = session_sql_copy;
  while (*rest) {
    sqlite3_stmt *statement = 0;
    const char *next = 0;
    int code = sqlite3_prepare_v2(session_database, rest, -1, &statement, &next);
    if (code != SQLITE_OK) {
      int extended = sqlite3_extended_errcode(session_database);
      int err_offset = sqlite3_error_offset(session_database);
      int64_t full_offset = err_offset >= 0 ? (int64_t)((rest - session_sql_copy) + err_offset) : -1;
      diagnostic_set(sqlite3_errmsg(session_database));
      diagnostic_append_to_place(diagnostic);
      if (wrapped_savepoint) {
        sqlite3_exec(session_database, "ROLLBACK TO SAVEPOINT _modus_exec; RELEASE SAVEPOINT _modus_exec;", 0, 0, 0);
      }
      modus_vfs_bind_main_bytes(&session_store, 0, 0);
      int64_t kind = 0, unit = 0;
      Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
      return answer_fail(error, outcome, kind, unit, 1, full_offset, (int64_t)sql->count, extended);
    }
    const char *stmt_start = rest;
    rest = next ? next : (rest + strlen(rest));
    if (!statement)
      continue;

    int col_count = sqlite3_column_count(statement);
    if (col_count > 0) {
      // Multi-statement semantics: keep the last row-producing statement's results.
      columns->count = entry_columns;
      cells->count = entry_cells;
      payload->count = entry_payload;
      result_summary.column_count = (uint32_t)col_count;
      result_summary.row_count = 0U;
      result_summary.truncated_rows = 0U;
      result_summary.has_rows = 1U;

      for (int col = 0; col < col_count; col++) {
        if (columns->address && columns->count < columns->capacity) {
          Sqlite_Column_Row *row = &((Sqlite_Column_Row *)columns->address)[columns->count];
          memset(row, 0, sizeof *row);
          row->column_index = (uint32_t)col;
          row->declared_kind = declared_kind_of(sqlite3_column_decltype(statement, col));
          const char *cname = sqlite3_column_name(statement, col);
          if (cname) {
            size_t full_len = strlen(cname);
            size_t kept = utf8_truncate_length((const uint8_t *)cname, full_len, SQLITE_COLUMN_NAME_BYTES);
            memcpy(row->name, cname, kept);
            row->name_length = (uint8_t)kept;
            row->name_truncated = kept < full_len ? 1U : 0U;
          }
        }
        columns->count += 1ULL;
      }

      uint32_t row_index = 0U;
      int truncated = 0;
      while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
        // Atomic row emission: never emit a partial row when cells capacity fills.
        if (!cells->address || cells->count > cells->capacity || (uint64_t)col_count > cells->capacity - cells->count) {
          truncated = 1;
          break;
        }
        uint64_t base_cell = cells->count;
        Sqlite_Cell_Row *cell_rows = (Sqlite_Cell_Row *)cells->address;
        for (int col = 0; col < col_count; col++) {
          Sqlite_Cell_Row *cell = &cell_rows[base_cell + (uint64_t)col];
          memset(cell, 0, sizeof *cell);
          cell->row_index = row_index;
          cell->column_index = (uint32_t)col;
          int sqtype = sqlite3_column_type(statement, col);
          switch (sqtype) {
          case SQLITE_NULL:
            cell->value_kind = SQLITE_VALUE_KIND_NULL;
            break;
          case SQLITE_INTEGER:
            cell->value_kind = SQLITE_VALUE_KIND_INTEGER;
            cell->integer_or_bits = sqlite3_column_int64(statement, col);
            break;
          case SQLITE_FLOAT: {
            cell->value_kind = SQLITE_VALUE_KIND_REAL_BITS;
            double value = sqlite3_column_double(statement, col);
            uint64_t bits = 0ULL;
            memcpy(&bits, &value, sizeof bits);
            cell->integer_or_bits = (int64_t)bits;
            break;
          }
          case SQLITE_TEXT: {
            cell->value_kind = SQLITE_VALUE_KIND_TEXT;
            const unsigned char *text = sqlite3_column_text(statement, col);
            int byte_len = sqlite3_column_bytes(statement, col);
            if (byte_len < 0)
              byte_len = 0;
            cell->integer_or_bits = (int64_t)byte_len;
            uint64_t offset_now = payload->count - entry_payload;
            if (text && byte_len > 0 && payload->address && payload->count < payload->capacity) {
              uint64_t room = payload->capacity - payload->count;
              size_t copy_len = utf8_truncate_length(text, (size_t)byte_len, (size_t)room);
              memcpy((uint8_t *)payload->address + payload->count, text, copy_len);
              payload->count += (uint64_t)copy_len;
              cell->payload_offset = (uint32_t)offset_now;
              cell->payload_length = (uint32_t)copy_len;
              cell->truncated = copy_len < (size_t)byte_len ? 1U : 0U;
            } else {
              cell->payload_offset = (uint32_t)offset_now;
              cell->payload_length = 0U;
              cell->truncated = byte_len > 0 ? 1U : 0U;
            }
            break;
          }
          case SQLITE_BLOB: {
            cell->value_kind = SQLITE_VALUE_KIND_BLOB;
            const void *blob = sqlite3_column_blob(statement, col);
            int byte_len = sqlite3_column_bytes(statement, col);
            if (byte_len < 0)
              byte_len = 0;
            cell->integer_or_bits = (int64_t)byte_len;
            uint64_t offset_now = payload->count - entry_payload;
            if (blob && byte_len > 0 && payload->address && payload->count < payload->capacity) {
              uint64_t room = payload->capacity - payload->count;
              size_t copy_len = (uint64_t)byte_len <= room ? (size_t)byte_len : (size_t)room;
              memcpy((uint8_t *)payload->address + payload->count, blob, copy_len);
              payload->count += (uint64_t)copy_len;
              cell->payload_offset = (uint32_t)offset_now;
              cell->payload_length = (uint32_t)copy_len;
              cell->truncated = copy_len < (size_t)byte_len ? 1U : 0U;
            } else {
              cell->payload_offset = (uint32_t)offset_now;
              cell->payload_length = 0U;
              cell->truncated = byte_len > 0 ? 1U : 0U;
            }
            break;
          }
          default:
            cell->value_kind = SQLITE_VALUE_KIND_NULL;
            break;
          }
        }
        cells->count += (uint64_t)col_count;
        row_index++;
      }

      if (truncated) {
        result_summary.row_count = row_index;
        result_summary.truncated_rows = 1U;
        sqlite3_finalize(statement);
        continue;
      }

      if (code != SQLITE_DONE) {
        int extended = sqlite3_extended_errcode(session_database);
        diagnostic_set(sqlite3_errmsg(session_database));
        diagnostic_append_to_place(diagnostic);
        sqlite3_finalize(statement);
        if (wrapped_savepoint) {
          sqlite3_exec(session_database, "ROLLBACK TO SAVEPOINT _modus_exec; RELEASE SAVEPOINT _modus_exec;", 0, 0, 0);
        }
        modus_vfs_bind_main_bytes(&session_store, 0, 0);
        int64_t kind = 0, unit = 0;
        Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
        return answer_fail(error, outcome, kind, unit, 1, (int64_t)(stmt_start - session_sql_copy), (int64_t)sql->count,
                           extended);
      }
      result_summary.row_count = row_index;
      sqlite3_finalize(statement);
    } else {
      code = sqlite3_step(statement);
      if (code != SQLITE_DONE) {
        int extended = sqlite3_extended_errcode(session_database);
        diagnostic_set(sqlite3_errmsg(session_database));
        diagnostic_append_to_place(diagnostic);
        sqlite3_finalize(statement);
        if (wrapped_savepoint) {
          sqlite3_exec(session_database, "ROLLBACK TO SAVEPOINT _modus_exec; RELEASE SAVEPOINT _modus_exec;", 0, 0, 0);
        }
        modus_vfs_bind_main_bytes(&session_store, 0, 0);
        int64_t kind = 0, unit = 0;
        Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
        return answer_fail(error, outcome, kind, unit, 1, (int64_t)(stmt_start - session_sql_copy), (int64_t)sql->count,
                           extended);
      }
      if (!sqlite3_stmt_readonly(statement))
        last_changes = sqlite3_changes64(session_database);
      sqlite3_finalize(statement);
    }
  }

  if (wrapped_savepoint) {
    int rel_code = sqlite3_exec(session_database, "RELEASE SAVEPOINT _modus_exec;", 0, 0, 0);
    if (rel_code != SQLITE_OK) {
      int extended = sqlite3_extended_errcode(session_database);
      diagnostic_set(sqlite3_errmsg(session_database));
      diagnostic_append_to_place(diagnostic);
      sqlite3_exec(session_database, "ROLLBACK TO SAVEPOINT _modus_exec; RELEASE SAVEPOINT _modus_exec;", 0, 0, 0);
      modus_vfs_bind_main_bytes(&session_store, 0, 0);
      int64_t kind = 0, unit = 0;
      Modus_Call_Outcome outcome = outcome_of_sqlite_code(extended, &kind, &unit);
      return answer_fail(error, outcome, kind, unit, 1, 0, (int64_t)sql->count, extended);
    }
  }

  result_summary.changes = last_changes;
  result_summary.dirty_pages = (uint64_t)modus_vfs_dirty_page_count(&session_store);
  result_summary.database_bytes = (uint64_t)session_store.slots[0].size;

  if (summary->address && summary->count < summary->capacity) {
    ((Sqlite_Query_Summary *)summary->address)[summary->count] = result_summary;
  }
  summary->count += 1ULL;

  // Always unbind main.db before returning.
  modus_vfs_bind_main_bytes(&session_store, 0, 0);
  return answer_ok((int64_t)result_summary.row_count);
}

Modus_Answer session_dirty_ranges(Modus_Table_Place *ranges, Modus_Error_Record *error) {
  if (!session_database)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 1,
                       SQLITE_MISUSE);
  if (!ranges)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_RECORDS,
                       1, 0, 0, SQLITE_MISUSE);
  uint64_t room = ranges->count < ranges->capacity ? (ranges->capacity - ranges->count) : 0ULL;
  Modus_Vfs_Dirty_Range *dest =
      (ranges->address && room > 0ULL) ? &((Modus_Vfs_Dirty_Range *)ranges->address)[ranges->count] : 0;
  _Static_assert(sizeof(Modus_Vfs_Dirty_Range) == sizeof(Sqlite_Dirty_Range_Row), "Dirty range row layout match");
  sqlite3_int64 total = modus_vfs_dirty_ranges(&session_store, dest, (sqlite3_int64)room);
  ranges->count += (uint64_t)total;
  return answer_ok((int64_t)total);
}

Modus_Answer session_mark_synced(Modus_Error_Record *error) {
  if (!session_database)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 1,
                       SQLITE_MISUSE);
  modus_vfs_clear_dirty(&session_store);
  return answer_ok(0);
}

Modus_Answer session_info(Modus_Table_Place *info, Modus_Error_Record *error) {
  if (!info)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_RECORDS,
                       1, 0, 0, SQLITE_MISUSE);
  append_session_info(info);
  return answer_ok(session_database ? 1 : 0);
}

Modus_Answer session_last_diagnostic(Modus_Table_Place *diagnostic, Modus_Error_Record *error) {
  if (!diagnostic)
    return answer_fail(error, MODUS_CALL_OUTCOME_ARGUMENT_REFUSED, MODUS_ERROR_KIND_BAD_VALUE, MODUS_ERROR_UNIT_BYTES,
                       1, 0, 0, SQLITE_MISUSE);
  diagnostic_append_to_place(diagnostic);
  return answer_ok((int64_t)session_diagnostic_length);
}

Modus_Answer session_close(Modus_Table_Place *database, Modus_Error_Record *error) {
  if (!session_database)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 1,
                       SQLITE_MISUSE);
  if (database && database->address && database->count > 0)
    modus_vfs_bind_main_bytes(&session_store, (unsigned char *)database->address, (sqlite3_int64)database->count);
  int code = sqlite3_close(session_database);
  if (code != SQLITE_OK) {
    int extended = sqlite3_extended_errcode(session_database);
    diagnostic_set(sqlite3_errmsg(session_database));
    modus_vfs_bind_main_bytes(&session_store, 0, 0);
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 0,
                       extended);
  }
  session_database = 0;
  int shut = sqlite3_shutdown();
  modus_vfs_bind_main_bytes(&session_store, 0, 0);
  session_read_only = 0;
  session_page_size = 0;
  if (shut != SQLITE_OK)
    return answer_fail(error, MODUS_CALL_OUTCOME_WRONG_STATE, MODUS_ERROR_KIND_STATE, MODUS_ERROR_UNIT_NONE, 0, 0, 0,
                       shut);
  return answer_ok(0);
}

int64_t version_number(void) { return (int64_t)sqlite3_libversion_number(); }
