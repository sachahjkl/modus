// The VFS of SQLite on modus: each file of a database is a region of a
// store that the caller lends (src/md/features/c_compiler.md, "The VFS of
// SQLite"; src/md/features/db_browser.md). No path, no system call, no clock.
#ifndef MODUS_VFS_H
#define MODUS_VFS_H

#ifdef MODUS_VFS_WITH_SQLITE
#include "sqlite3.h"
#else
#include "modus_sqlite3_abi.h"
#endif

// Format properties: 8 internal file slots, 64-byte internal file names, and
// 4096-byte sectors matching the storage block size.
#define MODUS_VFS_SLOT_LIMIT 8
#define MODUS_VFS_NAME_LIMIT 64 // With the terminating zero.
#define MODUS_VFS_SECTOR_SIZE 4096

// Computed dirty-page tracking ceiling: 131072 pages of 4 KiB = 512 MiB
// database represented in a 16 KiB bitmap.
#define MODUS_VFS_MAX_TRACKED_PAGES 131072
#define MODUS_VFS_DIRTY_BITMAP_BYTES (MODUS_VFS_MAX_TRACKED_PAGES / 8)

// The lock levels of a file, with the values of the contract of SQLite.
typedef enum Modus_Vfs_Lock_Level {
  MODUS_VFS_LOCK_NONE = SQLITE_LOCK_NONE,
  MODUS_VFS_LOCK_SHARED = SQLITE_LOCK_SHARED,
  MODUS_VFS_LOCK_RESERVED = SQLITE_LOCK_RESERVED,
  MODUS_VFS_LOCK_PENDING = SQLITE_LOCK_PENDING,
  MODUS_VFS_LOCK_EXCLUSIVE = SQLITE_LOCK_EXCLUSIVE,
} Modus_Vfs_Lock_Level;

// What xAccess asks, with the values of the contract of SQLite.
typedef enum Modus_Vfs_Access {
  MODUS_VFS_ACCESS_EXISTS = SQLITE_ACCESS_EXISTS,
  MODUS_VFS_ACCESS_READ_WRITE = SQLITE_ACCESS_READWRITE,
  MODUS_VFS_ACCESS_READ = SQLITE_ACCESS_READ,
} Modus_Vfs_Access;

typedef struct Modus_Vfs_File Modus_Vfs_File;

// One file of the store: a fixed region of the lent bytes.
typedef struct Modus_Vfs_Slot {
  char name[MODUS_VFS_NAME_LIMIT];
  unsigned char *bytes;
  sqlite3_int64 capacity;
  sqlite3_int64 size;
  int exists;
  int open_count;
  int shared_count;       // Open files of the slot at SHARED or above.
  Modus_Vfs_File *writer; // The one file at RESERVED or above, or 0.
} Modus_Vfs_Slot;

typedef struct Modus_Vfs_Store {
  Modus_Vfs_Slot slots[MODUS_VFS_SLOT_LIMIT];
  int slot_count;
  unsigned int temporary_count;
  unsigned long long random_state;
  int split_main;                // 1 when slot 0 is the per-call bound main.db with dirty tracking.
  unsigned char *dirty_bitmap;   // 1 bit per 4 KiB page of slot 0.
  sqlite3_int64 dirty_max_pages; // Number of 4 KiB pages representable in dirty_bitmap.
} Modus_Vfs_Store;

struct Modus_Vfs_File {
  sqlite3_file base; // First: SQLite sees a Modus_Vfs_File as a sqlite3_file.
  Modus_Vfs_Store *store;
  Modus_Vfs_Slot *slot;
  Modus_Vfs_Lock_Level lock_level;
  int read_only;
  int delete_on_close;
};

typedef struct Modus_Vfs_Dirty_Range {
  unsigned long long byte_offset;
  unsigned long long byte_length;
} Modus_Vfs_Dirty_Range;

// Splits the lent bytes into slots of the given capacities, in order. A file
// that SQLite creates takes the first free slot, so the first capacity is the
// one of the main database. Returns SQLITE_OK, or SQLITE_MISUSE when the
// capacities do not fit the bytes or the count is past the limit.
int modus_vfs_store_init(Modus_Vfs_Store *store, unsigned char *bytes, sqlite3_int64 byte_count,
                         const sqlite3_int64 *capacities, int slot_count, unsigned long long random_seed);

// Initializes slot 0 for "main.db" (bound per call via modus_vfs_bind_main_bytes
// so no pointer persists across calls) and slots 1..scratch_slot_count from
// scratch_bytes for rollback journals and temporary files. dirty_bitmap tracks
// modified 4 KiB pages of slot 0.
int modus_vfs_store_init_split(Modus_Vfs_Store *store, sqlite3_int64 initial_main_size, unsigned char *scratch_bytes,
                               sqlite3_int64 scratch_byte_count, const sqlite3_int64 *scratch_capacities,
                               int scratch_slot_count, unsigned char *dirty_bitmap, sqlite3_int64 dirty_max_pages,
                               unsigned long long random_seed);

// Binds or unbinds (bytes = 0, capacity = 0) the backing buffer of slot 0
// ("main.db") for the duration of one call.
void modus_vfs_bind_main_bytes(Modus_Vfs_Store *store, unsigned char *bytes, sqlite3_int64 capacity);

// Returns the number of dirty 4 KiB pages within the current size of main.db.
sqlite3_int64 modus_vfs_dirty_page_count(const Modus_Vfs_Store *store);

// Emits coalesced dirty 4 KiB byte ranges of main.db clamped strictly to
// slot 0's current size. Writes at most range_capacity entries and returns the
// total number of coalesced ranges.
sqlite3_int64 modus_vfs_dirty_ranges(const Modus_Vfs_Store *store, Modus_Vfs_Dirty_Range *out_ranges,
                                     sqlite3_int64 range_capacity);

// Clears all dirty bits of slot 0 after the caller commits them to storage.
void modus_vfs_clear_dirty(Modus_Vfs_Store *store);

// Fills a VFS whose files are the slots of the store.
sqlite3_vfs *modus_vfs_make(sqlite3_vfs *vfs, Modus_Vfs_Store *store, const char *name);

#ifdef MODUS_VFS_WITH_SQLITE
// SQLITE_OS_OTHER asks the program for these two. The store is bound before
// sqlite3_initialize; with no store, the initialization fails.
void modus_vfs_bind_default_store(Modus_Vfs_Store *store);
int sqlite3_os_init(void);
int sqlite3_os_end(void);
#endif

#endif
