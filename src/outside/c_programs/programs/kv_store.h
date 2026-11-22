// A key-value store in C over the VFS of SQLite: a B+ tree of pages, read and
// written through the methods of sqlite3_io_methods, with a rollback journal
// that a later open plays back, as SQLite plays back a hot journal.
#ifndef MODUS_KV_STORE_H
#define MODUS_KV_STORE_H

#include "modus_thin_libc.h"
#include "modus_vfs.h"

#define KV_PAGE_SIZE 512
#define KV_PAGE_LIMIT 512

typedef enum Kv_Status {
  KV_STATUS_OK = 0,
  KV_STATUS_NOT_FOUND = 1,
  KV_STATUS_BUSY = -1,
  KV_STATUS_IO_ERROR = -2,
  KV_STATUS_FULL = -3,
  KV_STATUS_CORRUPT = -4,
  KV_STATUS_MISUSE = -5,
  KV_STATUS_NO_MEMORY = -6,
  KV_STATUS_INTERRUPTED = -7,
} Kv_Status;

typedef struct Kv_Store Kv_Store;

// Opens the database of the name, plays back a hot journal, and creates an
// empty tree in an empty file. The store takes its memory from the heap.
Kv_Status kv_open(Kv_Store **store_out, Modus_Heap *heap, sqlite3_vfs *vfs, const char *name);
Kv_Status kv_begin(Kv_Store *store);
Kv_Status kv_put(Kv_Store *store, long long key, long long value);
Kv_Status kv_get(Kv_Store *store, long long key, long long *value);
Kv_Status kv_sum(Kv_Store *store, long long low, long long high, long long *sum, long long *count);
// Writes the changed pages. A limit of 0 or more stops after that many pages
// and returns KV_STATUS_INTERRUPTED, as a machine that stops in the middle of
// a commit: the journal stays, and the next open plays it back.
Kv_Status kv_commit(Kv_Store *store, long page_write_limit);
Kv_Status kv_rollback(Kv_Store *store);
// Checks the order of the keys, the depth of the leaves, the chain of the
// leaves and the count of the records.
Kv_Status kv_check(Kv_Store *store, long long *record_count);
Kv_Status kv_close(Kv_Store *store);
// Releases the memory and the files of the store with no rollback and no
// removal of the journal: what a stop of the machine leaves.
void kv_abandon(Kv_Store *store);

#endif
