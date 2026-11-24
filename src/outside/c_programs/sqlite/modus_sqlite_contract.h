// C11 contract definitions shared by sqlite.manifest and modus_sqlite_entry.c
// (src/md/features/db_browser.md). Every struct size, field offset, and enum
// value matches the Odin contract packages (call_outcome, errors, module) and
// sqlite.manifest exactly.
#ifndef MODUS_SQLITE_CONTRACT_H
#define MODUS_SQLITE_CONTRACT_H

#include <stddef.h>
#include <stdint.h>

// Call outcome values from src/library/modus/contract/call_outcome/call_outcome.odin.
typedef uint64_t Modus_Call_Outcome;
#define MODUS_CALL_OUTCOME_SUCCEEDED ((Modus_Call_Outcome)0ULL)
#define MODUS_CALL_OUTCOME_ARGUMENT_REFUSED ((Modus_Call_Outcome)1ULL)
#define MODUS_CALL_OUTCOME_GRANT_OR_RIGHT_MISSING ((Modus_Call_Outcome)4ULL)
#define MODUS_CALL_OUTCOME_BUDGET_OR_CAPACITY_EXHAUSTED ((Modus_Call_Outcome)6ULL)
#define MODUS_CALL_OUTCOME_WRONG_STATE ((Modus_Call_Outcome)7ULL)
#define MODUS_CALL_OUTCOME_DATA_DAMAGED ((Modus_Call_Outcome)10ULL)
#define MODUS_CALL_OUTCOME_STOPPED_AFTER_A_PARTIAL_CHANGE ((Modus_Call_Outcome)12ULL)

// Error kinds and units from src/library/modus/contract/errors/errors.odin.
#define MODUS_ERROR_KIND_NONE ((int64_t)0LL)
#define MODUS_ERROR_KIND_EMPTY ((int64_t)1LL)
#define MODUS_ERROR_KIND_TOO_LONG ((int64_t)2LL)
#define MODUS_ERROR_KIND_TOO_SMALL ((int64_t)3LL)
#define MODUS_ERROR_KIND_BAD_VALUE ((int64_t)4LL)
#define MODUS_ERROR_KIND_OVER_LIMIT ((int64_t)14LL)
#define MODUS_ERROR_KIND_FULL ((int64_t)15LL)
#define MODUS_ERROR_KIND_STATE ((int64_t)16LL)
#define MODUS_ERROR_KIND_DAMAGED ((int64_t)18LL)
#define MODUS_ERROR_KIND_NO_GRANT ((int64_t)20LL)
#define MODUS_ERROR_KIND_REFUSED ((int64_t)25LL)
#define MODUS_ERROR_KIND_OUT_OF_RANGE ((int64_t)30LL)
#define MODUS_ERROR_KIND_NOT_MULTIPLE ((int64_t)36LL)

#define MODUS_ERROR_UNIT_NONE ((int64_t)0LL)
#define MODUS_ERROR_UNIT_BYTES ((int64_t)1LL)
#define MODUS_ERROR_UNIT_PAGES ((int64_t)2LL)
#define MODUS_ERROR_UNIT_RECORDS ((int64_t)19LL)
#define MODUS_ERROR_UNIT_CHANGES ((int64_t)40LL)

// Direct-call return pair of an export with an error record (rax = outcome, rdx = value).
typedef struct Modus_Answer {
  Modus_Call_Outcome outcome;
  int64_t value;
} Modus_Answer;
_Static_assert(sizeof(Modus_Answer) == 16U, "Modus_Answer size");
_Static_assert(offsetof(Modus_Answer, outcome) == 0U, "Modus_Answer.outcome offset");
_Static_assert(offsetof(Modus_Answer, value) == 8U, "Modus_Answer.value offset");

// Error record matching modus:contract/errors.Error_Record.
typedef struct Modus_Error_Record {
  int64_t kind;
  int64_t unit;
  int64_t operation;
  int64_t argument;
  int64_t value;
  int64_t limit;
  int64_t found;
} Modus_Error_Record;
_Static_assert(sizeof(Modus_Error_Record) == 56U, "Modus_Error_Record size");
_Static_assert(offsetof(Modus_Error_Record, kind) == 0U, "Error_Record.kind");
_Static_assert(offsetof(Modus_Error_Record, unit) == 8U, "Error_Record.unit");
_Static_assert(offsetof(Modus_Error_Record, operation) == 16U, "Error_Record.operation");
_Static_assert(offsetof(Modus_Error_Record, argument) == 24U, "Error_Record.argument");
_Static_assert(offsetof(Modus_Error_Record, value) == 32U, "Error_Record.value");
_Static_assert(offsetof(Modus_Error_Record, limit) == 40U, "Error_Record.limit");
_Static_assert(offsetof(Modus_Error_Record, found) == 48U, "Error_Record.found");

// Text parameter descriptor (src/md/infrastructure/language_neutral_abi.md).
typedef struct Modus_Text_Slice {
  const uint8_t *address;
  uint64_t count;
} Modus_Text_Slice;
_Static_assert(sizeof(Modus_Text_Slice) == 16U, "Modus_Text_Slice size");

// Table / Bytes parameter descriptor matching module.Table_Place.
typedef struct Modus_Table_Place {
  void *address;
  uint64_t count;
  uint64_t capacity;
} Modus_Table_Place;
_Static_assert(sizeof(Modus_Table_Place) == 24U, "Modus_Table_Place size");

// Closed enum Value_Kind (sqlite.manifest).
typedef uint8_t Sqlite_Value_Kind;
#define SQLITE_VALUE_KIND_NONE ((Sqlite_Value_Kind)0U)
#define SQLITE_VALUE_KIND_NULL ((Sqlite_Value_Kind)1U)
#define SQLITE_VALUE_KIND_INTEGER ((Sqlite_Value_Kind)2U)
#define SQLITE_VALUE_KIND_REAL_BITS ((Sqlite_Value_Kind)3U)
#define SQLITE_VALUE_KIND_TEXT ((Sqlite_Value_Kind)4U)
#define SQLITE_VALUE_KIND_BLOB ((Sqlite_Value_Kind)5U)

// Inline display bound for Column_Row.name (64 bytes of UTF-8 text).
#define SQLITE_COLUMN_NAME_BYTES 64U

// Format property: SQLite page size matches the 4096-byte storage block size.
#define SQLITE_REQUIRED_PAGE_SIZE 4096U

typedef struct Sqlite_Open_Options {
  uint8_t fresh;
  uint8_t read_only;
  uint8_t reserved[2];
  uint32_t page_size;
  uint64_t random_seed;
  uint64_t database_bytes;
  uint32_t heap_bytes;
  uint32_t reserved_2;
} Sqlite_Open_Options;
_Static_assert(sizeof(Sqlite_Open_Options) == 32U, "Sqlite_Open_Options size");
_Static_assert(offsetof(Sqlite_Open_Options, fresh) == 0U, "Open_Options.fresh");
_Static_assert(offsetof(Sqlite_Open_Options, read_only) == 1U, "Open_Options.read_only");
_Static_assert(offsetof(Sqlite_Open_Options, page_size) == 4U, "Open_Options.page_size");
_Static_assert(offsetof(Sqlite_Open_Options, random_seed) == 8U, "Open_Options.random_seed");
_Static_assert(offsetof(Sqlite_Open_Options, database_bytes) == 16U, "Open_Options.database_bytes");
_Static_assert(offsetof(Sqlite_Open_Options, heap_bytes) == 24U, "Open_Options.heap_bytes");

typedef struct Sqlite_Session_Info {
  int64_t version_number;
  uint64_t database_bytes;
  uint64_t dirty_pages;
  uint32_t page_size;
  uint8_t open;
  uint8_t read_only;
  uint8_t reserved[2];
} Sqlite_Session_Info;
_Static_assert(sizeof(Sqlite_Session_Info) == 32U, "Sqlite_Session_Info size");
_Static_assert(offsetof(Sqlite_Session_Info, version_number) == 0U, "Session_Info.version_number");
_Static_assert(offsetof(Sqlite_Session_Info, database_bytes) == 8U, "Session_Info.database_bytes");
_Static_assert(offsetof(Sqlite_Session_Info, dirty_pages) == 16U, "Session_Info.dirty_pages");
_Static_assert(offsetof(Sqlite_Session_Info, page_size) == 24U, "Session_Info.page_size");
_Static_assert(offsetof(Sqlite_Session_Info, open) == 28U, "Session_Info.open");
_Static_assert(offsetof(Sqlite_Session_Info, read_only) == 29U, "Session_Info.read_only");

typedef struct Sqlite_Column_Row {
  uint32_t column_index;
  uint8_t declared_kind;
  uint8_t name_length;
  uint8_t name_truncated;
  uint8_t reserved;
  uint8_t name[SQLITE_COLUMN_NAME_BYTES];
} Sqlite_Column_Row;
_Static_assert(sizeof(Sqlite_Column_Row) == 72U, "Sqlite_Column_Row size");
_Static_assert(offsetof(Sqlite_Column_Row, column_index) == 0U, "Column_Row.column_index");
_Static_assert(offsetof(Sqlite_Column_Row, declared_kind) == 4U, "Column_Row.declared_kind");
_Static_assert(offsetof(Sqlite_Column_Row, name_length) == 5U, "Column_Row.name_length");
_Static_assert(offsetof(Sqlite_Column_Row, name_truncated) == 6U, "Column_Row.name_truncated");
_Static_assert(offsetof(Sqlite_Column_Row, name) == 8U, "Column_Row.name");

typedef struct Sqlite_Cell_Row {
  uint32_t row_index;
  uint32_t column_index;
  uint8_t value_kind;
  uint8_t truncated;
  uint8_t reserved[6];
  int64_t integer_or_bits;
  uint32_t payload_offset;
  uint32_t payload_length;
} Sqlite_Cell_Row;
_Static_assert(sizeof(Sqlite_Cell_Row) == 32U, "Sqlite_Cell_Row size");
_Static_assert(offsetof(Sqlite_Cell_Row, row_index) == 0U, "Cell_Row.row_index");
_Static_assert(offsetof(Sqlite_Cell_Row, column_index) == 4U, "Cell_Row.column_index");
_Static_assert(offsetof(Sqlite_Cell_Row, value_kind) == 8U, "Cell_Row.value_kind");
_Static_assert(offsetof(Sqlite_Cell_Row, truncated) == 9U, "Cell_Row.truncated");
_Static_assert(offsetof(Sqlite_Cell_Row, integer_or_bits) == 16U, "Cell_Row.integer_or_bits");
_Static_assert(offsetof(Sqlite_Cell_Row, payload_offset) == 24U, "Cell_Row.payload_offset");
_Static_assert(offsetof(Sqlite_Cell_Row, payload_length) == 28U, "Cell_Row.payload_length");

typedef struct Sqlite_Query_Summary {
  uint32_t column_count;
  uint32_t row_count;
  int64_t changes;
  uint64_t dirty_pages;
  uint64_t database_bytes;
  uint8_t truncated_rows;
  uint8_t has_rows;
  uint8_t reserved[6];
} Sqlite_Query_Summary;
_Static_assert(sizeof(Sqlite_Query_Summary) == 40U, "Sqlite_Query_Summary size");
_Static_assert(offsetof(Sqlite_Query_Summary, column_count) == 0U, "Query_Summary.column_count");
_Static_assert(offsetof(Sqlite_Query_Summary, row_count) == 4U, "Query_Summary.row_count");
_Static_assert(offsetof(Sqlite_Query_Summary, changes) == 8U, "Query_Summary.changes");
_Static_assert(offsetof(Sqlite_Query_Summary, dirty_pages) == 16U, "Query_Summary.dirty_pages");
_Static_assert(offsetof(Sqlite_Query_Summary, database_bytes) == 24U, "Query_Summary.database_bytes");
_Static_assert(offsetof(Sqlite_Query_Summary, truncated_rows) == 32U, "Query_Summary.truncated_rows");
_Static_assert(offsetof(Sqlite_Query_Summary, has_rows) == 33U, "Query_Summary.has_rows");

typedef struct Sqlite_Dirty_Range_Row {
  uint64_t byte_offset;
  uint64_t byte_length;
} Sqlite_Dirty_Range_Row;
_Static_assert(sizeof(Sqlite_Dirty_Range_Row) == 16U, "Sqlite_Dirty_Range_Row size");
_Static_assert(offsetof(Sqlite_Dirty_Range_Row, byte_offset) == 0U, "Dirty_Range_Row.byte_offset");
_Static_assert(offsetof(Sqlite_Dirty_Range_Row, byte_length) == 8U, "Dirty_Range_Row.byte_length");

#endif
