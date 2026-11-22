// The VFS of SQLite on modus: each file of a database is a region of a
// store that the caller lends (src/md/features/c_compiler.md, "The VFS of
// SQLite"). No path, no system call, no clock.
#ifndef MODUS_VFS_H
#define MODUS_VFS_H

#ifdef MODUS_VFS_WITH_SQLITE
#include "sqlite3.h"
#else
#include "modus_sqlite3_abi.h"
#endif

#define MODUS_VFS_SLOT_LIMIT 8
#define MODUS_VFS_NAME_LIMIT 64 // With the terminating zero.
#define MODUS_VFS_SECTOR_SIZE 4096

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
  int shared_count;        // Open files of the slot at SHARED or above.
  Modus_Vfs_File *writer;  // The one file at RESERVED or above, or 0.
} Modus_Vfs_Slot;

typedef struct Modus_Vfs_Store {
  Modus_Vfs_Slot slots[MODUS_VFS_SLOT_LIMIT];
  int slot_count;
  unsigned int temporary_count;
  unsigned long long random_state;
} Modus_Vfs_Store;

struct Modus_Vfs_File {
  sqlite3_file base; // First: SQLite sees a Modus_Vfs_File as a sqlite3_file.
  Modus_Vfs_Store *store;
  Modus_Vfs_Slot *slot;
  Modus_Vfs_Lock_Level lock_level;
  int read_only;
  int delete_on_close;
};

// Splits the lent bytes into slots of the given capacities, in order. A file
// that SQLite creates takes the first free slot, so the first capacity is the
// one of the main database. Returns SQLITE_OK, or SQLITE_MISUSE when the
// capacities do not fit the bytes or the count is past the limit.
int modus_vfs_store_init(Modus_Vfs_Store *store, unsigned char *bytes, sqlite3_int64 byte_count,
                         const sqlite3_int64 *capacities, int slot_count, unsigned long long random_seed);

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
