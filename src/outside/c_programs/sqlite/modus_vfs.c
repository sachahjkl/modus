// The VFS of SQLite on modus (src/md/features/c_compiler.md, "The VFS of
// SQLite"; src/md/features/db_browser.md). Built with -DSQLITE_OS_OTHER=1
// -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1, SQLite reaches its
// files through this file only: each file is a region of the store that the
// caller lends.
#include "modus_vfs.h"
#include "modus_thin_libc.h"

#define VFS_TEMPORARY_PREFIX "modus-temporary-"
#define VFS_MAIN_DB_NAME "main.db"

// The border of the contract: a word of SQLite becomes its enum here, and a
// word that names no member is refused.
static int lock_level_of_word(int word, Modus_Vfs_Lock_Level *level) {
  switch (word) {
  case SQLITE_LOCK_NONE:
    *level = MODUS_VFS_LOCK_NONE;
    return 1;
  case SQLITE_LOCK_SHARED:
    *level = MODUS_VFS_LOCK_SHARED;
    return 1;
  case SQLITE_LOCK_RESERVED:
    *level = MODUS_VFS_LOCK_RESERVED;
    return 1;
  case SQLITE_LOCK_PENDING:
    *level = MODUS_VFS_LOCK_PENDING;
    return 1;
  case SQLITE_LOCK_EXCLUSIVE:
    *level = MODUS_VFS_LOCK_EXCLUSIVE;
    return 1;
  }
  return 0;
}

static int access_of_word(int word, Modus_Vfs_Access *access) {
  switch (word) {
  case SQLITE_ACCESS_EXISTS:
    *access = MODUS_VFS_ACCESS_EXISTS;
    return 1;
  case SQLITE_ACCESS_READWRITE:
    *access = MODUS_VFS_ACCESS_READ_WRITE;
    return 1;
  case SQLITE_ACCESS_READ:
    *access = MODUS_VFS_ACCESS_READ;
    return 1;
  }
  return 0;
}

static void dirty_mark_range(Modus_Vfs_Store *store, sqlite3_int64 start_byte, sqlite3_int64 end_byte) {
  if (!store || !store->split_main || !store->dirty_bitmap || end_byte <= start_byte)
    return;
  if (start_byte < 0)
    start_byte = 0;
  sqlite3_int64 first_page = start_byte / MODUS_VFS_SECTOR_SIZE;
  sqlite3_int64 last_page = (end_byte - 1) / MODUS_VFS_SECTOR_SIZE;
  if (last_page >= store->dirty_max_pages)
    last_page = store->dirty_max_pages - 1;
  for (sqlite3_int64 page = first_page; page <= last_page; page++) {
    store->dirty_bitmap[page >> 3] |= (unsigned char)(1U << (page & 7));
  }
}

static void dirty_clear_from_page(Modus_Vfs_Store *store, sqlite3_int64 first_page) {
  if (!store || !store->split_main || !store->dirty_bitmap)
    return;
  if (first_page < 0)
    first_page = 0;
  for (sqlite3_int64 page = first_page; page < store->dirty_max_pages; page++) {
    store->dirty_bitmap[page >> 3] &= (unsigned char)~(1U << (page & 7));
  }
}

int modus_vfs_store_init(Modus_Vfs_Store *store, unsigned char *bytes, sqlite3_int64 byte_count,
                         const sqlite3_int64 *capacities, int slot_count, unsigned long long random_seed) {
  if (!store)
    return SQLITE_MISUSE;
  memset(store, 0, sizeof *store);
  if (!bytes || !capacities || slot_count <= 0 || slot_count > MODUS_VFS_SLOT_LIMIT || byte_count < 0)
    return SQLITE_MISUSE;
  sqlite3_int64 used = 0;
  for (int index = 0; index < slot_count; index++) {
    if (capacities[index] <= 0 || capacities[index] > byte_count - used)
      return SQLITE_MISUSE;
    store->slots[index].bytes = bytes + used;
    store->slots[index].capacity = capacities[index];
    used += capacities[index];
  }
  store->slot_count = slot_count;
  // xorshift has one fixed point, 0: a zero seed takes another constant.
  store->random_state = random_seed ? random_seed : 0x9e3779b97f4a7c15ULL;
  return SQLITE_OK;
}

int modus_vfs_store_init_split(Modus_Vfs_Store *store, sqlite3_int64 initial_main_size, unsigned char *scratch_bytes,
                               sqlite3_int64 scratch_byte_count, const sqlite3_int64 *scratch_capacities,
                               int scratch_slot_count, unsigned char *dirty_bitmap, sqlite3_int64 dirty_max_pages,
                               unsigned long long random_seed) {
  if (!store)
    return SQLITE_MISUSE;
  memset(store, 0, sizeof *store);
  if (initial_main_size < 0 || !scratch_bytes || !scratch_capacities || scratch_slot_count <= 0 ||
      scratch_slot_count + 1 > MODUS_VFS_SLOT_LIMIT || scratch_byte_count < 0 || !dirty_bitmap ||
      dirty_max_pages <= 0)
    return SQLITE_MISUSE;
  // Slot 0 is reserved permanently for main.db; its backing pointer is bound
  // per call via modus_vfs_bind_main_bytes so no pointer survives return.
  strcpy(store->slots[0].name, VFS_MAIN_DB_NAME);
  store->slots[0].exists = 1;
  store->slots[0].size = initial_main_size;
  store->slots[0].bytes = 0;
  store->slots[0].capacity = 0;

  sqlite3_int64 used = 0;
  for (int index = 0; index < scratch_slot_count; index++) {
    if (scratch_capacities[index] <= 0 || scratch_capacities[index] > scratch_byte_count - used)
      return SQLITE_MISUSE;
    store->slots[index + 1].bytes = scratch_bytes + used;
    store->slots[index + 1].capacity = scratch_capacities[index];
    used += scratch_capacities[index];
  }
  store->slot_count = scratch_slot_count + 1;
  store->split_main = 1;
  store->dirty_bitmap = dirty_bitmap;
  store->dirty_max_pages = dirty_max_pages;
  memset(dirty_bitmap, 0, (size_t)((dirty_max_pages + 7) / 8));
  store->random_state = random_seed ? random_seed : 0x9e3779b97f4a7c15ULL;
  return SQLITE_OK;
}

void modus_vfs_bind_main_bytes(Modus_Vfs_Store *store, unsigned char *bytes, sqlite3_int64 capacity) {
  if (!store || !store->split_main || store->slot_count <= 0)
    return;
  store->slots[0].bytes = bytes;
  store->slots[0].capacity = capacity;
}

sqlite3_int64 modus_vfs_dirty_page_count(const Modus_Vfs_Store *store) {
  if (!store || !store->split_main || !store->dirty_bitmap || store->slot_count <= 0)
    return 0;
  sqlite3_int64 size = store->slots[0].size;
  if (size <= 0)
    return 0;
  sqlite3_int64 active_pages = (size + MODUS_VFS_SECTOR_SIZE - 1) / MODUS_VFS_SECTOR_SIZE;
  if (active_pages > store->dirty_max_pages)
    active_pages = store->dirty_max_pages;
  sqlite3_int64 count = 0;
  for (sqlite3_int64 page = 0; page < active_pages; page++) {
    if ((store->dirty_bitmap[page >> 3] & (unsigned char)(1U << (page & 7))) != 0)
      count++;
  }
  return count;
}

sqlite3_int64 modus_vfs_dirty_ranges(const Modus_Vfs_Store *store, Modus_Vfs_Dirty_Range *out_ranges,
                                     sqlite3_int64 range_capacity) {
  if (!store || !store->split_main || !store->dirty_bitmap || store->slot_count <= 0)
    return 0;
  sqlite3_int64 size = store->slots[0].size;
  if (size <= 0)
    return 0;
  sqlite3_int64 active_pages = (size + MODUS_VFS_SECTOR_SIZE - 1) / MODUS_VFS_SECTOR_SIZE;
  if (active_pages > store->dirty_max_pages)
    active_pages = store->dirty_max_pages;
  sqlite3_int64 total = 0;
  sqlite3_int64 page = 0;
  while (page < active_pages) {
    if ((store->dirty_bitmap[page >> 3] & (unsigned char)(1U << (page & 7))) == 0) {
      page++;
      continue;
    }
    sqlite3_int64 run_start = page;
    while (page < active_pages && (store->dirty_bitmap[page >> 3] & (unsigned char)(1U << (page & 7))) != 0) {
      page++;
    }
    sqlite3_int64 byte_offset = run_start * MODUS_VFS_SECTOR_SIZE;
    sqlite3_int64 byte_end = page * MODUS_VFS_SECTOR_SIZE;
    // Clamp strictly to current database_bytes (e.g. after VACUUM shrink).
    if (byte_end > size)
      byte_end = size;
    if (byte_end > byte_offset) {
      if (out_ranges && total < range_capacity) {
        out_ranges[total].byte_offset = (unsigned long long)byte_offset;
        out_ranges[total].byte_length = (unsigned long long)(byte_end - byte_offset);
      }
      total++;
    }
  }
  return total;
}

void modus_vfs_clear_dirty(Modus_Vfs_Store *store) {
  if (!store || !store->split_main || !store->dirty_bitmap)
    return;
  memset(store->dirty_bitmap, 0, (size_t)((store->dirty_max_pages + 7) / 8));
}

static Modus_Vfs_Store *store_of(sqlite3_vfs *vfs) { return (Modus_Vfs_Store *)vfs->pAppData; }

static Modus_Vfs_Slot *slot_named(Modus_Vfs_Store *store, const char *name) {
  for (int index = 0; index < store->slot_count; index++)
    if (store->slots[index].exists && strcmp(store->slots[index].name, name) == 0)
      return &store->slots[index];
  return 0;
}

static Modus_Vfs_Slot *free_slot(Modus_Vfs_Store *store) {
  int first = store->split_main ? 1 : 0;
  for (int index = first; index < store->slot_count; index++)
    if (!store->slots[index].exists)
      return &store->slots[index];
  return 0;
}

// A deleted file leaves zeros: the bytes of the store are a function of the
// files that exist, so two runs give one image of the store.
static void slot_clear(Modus_Vfs_Slot *slot) {
  if (slot->bytes && slot->size > 0)
    memset(slot->bytes, 0, (size_t)slot->size);
  memset(slot->name, 0, sizeof slot->name);
  slot->size = 0;
  slot->exists = 0;
  slot->shared_count = 0;
  slot->writer = 0;
}

static Modus_Vfs_File *file_of(sqlite3_file *file) { return (Modus_Vfs_File *)file; }

// ---- The methods of a file ------------------------------------------------------

static int file_unlock(sqlite3_file *base, int word);

static int file_close(sqlite3_file *base) {
  Modus_Vfs_File *file = file_of(base);
  file_unlock(base, SQLITE_LOCK_NONE);
  Modus_Vfs_Slot *slot = file->slot;
  slot->open_count--;
  if (file->delete_on_close && slot->open_count == 0) {
    if (!(file->store->split_main && slot == &file->store->slots[0]))
      slot_clear(slot);
  }
  file->base.pMethods = 0;
  return SQLITE_OK;
}

// SQLite asks for zeros past the end of a file, and SQLITE_IOERR_SHORT_READ.
static int file_read(sqlite3_file *base, void *destination, int amount, sqlite3_int64 offset) {
  Modus_Vfs_Slot *slot = file_of(base)->slot;
  if (amount < 0 || offset < 0 || !destination)
    return SQLITE_IOERR_READ;
  if (slot->size > 0 && !slot->bytes)
    return SQLITE_IOERR_READ;
  sqlite3_int64 available = offset < slot->size ? slot->size - offset : 0;
  sqlite3_int64 taken = available < amount ? available : amount;
  if (taken > 0)
    memcpy(destination, slot->bytes + offset, (size_t)taken);
  if (taken < amount) {
    memset((unsigned char *)destination + taken, 0, (size_t)(amount - taken));
    return SQLITE_IOERR_SHORT_READ;
  }
  return SQLITE_OK;
}

static int file_write(sqlite3_file *base, const void *source, int amount, sqlite3_int64 offset) {
  Modus_Vfs_File *file = file_of(base);
  Modus_Vfs_Slot *slot = file->slot;
  if (amount < 0 || offset < 0 || !source || file->read_only || !slot->bytes)
    return SQLITE_IOERR_WRITE;
  if (offset > slot->capacity || amount > slot->capacity - offset)
    return SQLITE_FULL;
  sqlite3_int64 dirty_start = offset;
  // The bytes between the end and the offset read as zeros, as in a file
  // that grows with a hole.
  if (offset > slot->size) {
    memset(slot->bytes + slot->size, 0, (size_t)(offset - slot->size));
    dirty_start = slot->size;
  }
  memcpy(slot->bytes + offset, source, (size_t)amount);
  if (offset + amount > slot->size)
    slot->size = offset + amount;
  if (file->store->split_main && slot == &file->store->slots[0]) {
    dirty_mark_range(file->store, dirty_start, offset + amount);
  }
  return SQLITE_OK;
}

static int file_truncate(sqlite3_file *base, sqlite3_int64 size) {
  Modus_Vfs_File *file = file_of(base);
  Modus_Vfs_Slot *slot = file->slot;
  if (size < 0 || file->read_only)
    return SQLITE_IOERR_TRUNCATE;
  if (size > slot->capacity)
    return SQLITE_FULL;
  if (!slot->bytes && (size > 0 || slot->size > 0))
    return SQLITE_IOERR_TRUNCATE;
  sqlite3_int64 old_size = slot->size;
  // The bytes past the new end read as zeros when the file grows again, and
  // the store keeps no copy of what the file dropped.
  if (size > old_size) {
    memset(slot->bytes + old_size, 0, (size_t)(size - old_size));
    if (file->store->split_main && slot == &file->store->slots[0])
      dirty_mark_range(file->store, old_size, size);
  } else if (size < old_size) {
    memset(slot->bytes + size, 0, (size_t)(old_size - size));
    if (file->store->split_main && slot == &file->store->slots[0]) {
      sqlite3_int64 kept_pages = (size + MODUS_VFS_SECTOR_SIZE - 1) / MODUS_VFS_SECTOR_SIZE;
      dirty_clear_from_page(file->store, kept_pages);
      if (size > 0 && (size % MODUS_VFS_SECTOR_SIZE) != 0)
        dirty_mark_range(file->store, size - 1, size);
    }
  }
  slot->size = size;
  return SQLITE_OK;
}

// The store is the memory that the caller lends: a write is done when it
// returns, and the caller makes the store durable.
static int file_sync(sqlite3_file *base, int flags) {
  (void)base;
  (void)flags;
  return SQLITE_OK;
}

static int file_size(sqlite3_file *base, sqlite3_int64 *size) {
  if (!size)
    return SQLITE_IOERR_READ;
  *size = file_of(base)->slot->size;
  return SQLITE_OK;
}

// The locks of the files of one store, as SQLite describes them: many
// SHARED, one RESERVED, and EXCLUSIVE once each other SHARED is gone. PENDING
// is the state of a writer that waits for the readers to leave.
static int file_lock(sqlite3_file *base, int word) {
  Modus_Vfs_File *file = file_of(base);
  Modus_Vfs_Slot *slot = file->slot;
  Modus_Vfs_Lock_Level wanted;
  if (!lock_level_of_word(word, &wanted))
    return SQLITE_IOERR_LOCK;
  if (file->lock_level >= wanted)
    return SQLITE_OK;
  switch (wanted) {
  case MODUS_VFS_LOCK_NONE:
    return SQLITE_OK;
  case MODUS_VFS_LOCK_SHARED:
    if (slot->writer && slot->writer->lock_level >= MODUS_VFS_LOCK_PENDING)
      return SQLITE_BUSY;
    slot->shared_count++;
    file->lock_level = MODUS_VFS_LOCK_SHARED;
    return SQLITE_OK;
  case MODUS_VFS_LOCK_RESERVED:
    if (file->lock_level != MODUS_VFS_LOCK_SHARED)
      return SQLITE_IOERR_LOCK;
    if (slot->writer && slot->writer != file)
      return SQLITE_BUSY;
    slot->writer = file;
    file->lock_level = MODUS_VFS_LOCK_RESERVED;
    return SQLITE_OK;
  case MODUS_VFS_LOCK_PENDING:
    // SQLite never asks for PENDING: it is a step inside EXCLUSIVE.
    return SQLITE_IOERR_LOCK;
  case MODUS_VFS_LOCK_EXCLUSIVE:
    if (file->lock_level < MODUS_VFS_LOCK_SHARED)
      return SQLITE_IOERR_LOCK;
    if (slot->writer && slot->writer != file)
      return SQLITE_BUSY;
    slot->writer = file;
    if (slot->shared_count > 1) {
      file->lock_level = MODUS_VFS_LOCK_PENDING;
      return SQLITE_BUSY;
    }
    file->lock_level = MODUS_VFS_LOCK_EXCLUSIVE;
    return SQLITE_OK;
  }
  return SQLITE_IOERR_LOCK;
}

static int file_unlock(sqlite3_file *base, int word) {
  Modus_Vfs_File *file = file_of(base);
  Modus_Vfs_Slot *slot = file->slot;
  Modus_Vfs_Lock_Level wanted;
  if (!lock_level_of_word(word, &wanted))
    return SQLITE_IOERR_UNLOCK;
  switch (wanted) {
  case MODUS_VFS_LOCK_NONE:
  case MODUS_VFS_LOCK_SHARED:
    break;
  case MODUS_VFS_LOCK_RESERVED:
  case MODUS_VFS_LOCK_PENDING:
  case MODUS_VFS_LOCK_EXCLUSIVE:
    return SQLITE_IOERR_UNLOCK;
  }
  if (file->lock_level <= wanted)
    return SQLITE_OK;
  if (slot->writer == file)
    slot->writer = 0;
  if (wanted == MODUS_VFS_LOCK_NONE)
    slot->shared_count--;
  file->lock_level = wanted;
  return SQLITE_OK;
}

static int file_check_reserved_lock(sqlite3_file *base, int *reserved) {
  if (!reserved)
    return SQLITE_IOERR_LOCK;
  *reserved = file_of(base)->slot->writer != 0;
  return SQLITE_OK;
}

static int file_control(sqlite3_file *base, int operation, void *argument) {
  (void)base;
  (void)operation;
  (void)argument;
  return SQLITE_NOTFOUND;
}

static int file_sector_size(sqlite3_file *base) {
  (void)base;
  return MODUS_VFS_SECTOR_SIZE;
}

static int file_device_characteristics(sqlite3_file *base) {
  (void)base;
  return SQLITE_IOCAP_POWERSAFE_OVERWRITE;
}

// Version 1: no shared memory, so no WAL; no memory map.
static const sqlite3_io_methods file_methods = {
    1,
    file_close,
    file_read,
    file_write,
    file_truncate,
    file_sync,
    file_size,
    file_lock,
    file_unlock,
    file_check_reserved_lock,
    file_control,
    file_sector_size,
    file_device_characteristics,
    0,
    0,
    0,
    0,
    0,
    0,
};

// ---- The methods of the VFS -------------------------------------------------------

static int vfs_open(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *base, int flags, int *out_flags) {
  Modus_Vfs_Store *store = store_of(vfs);
  Modus_Vfs_File *file = file_of(base);
  // A failed open leaves no methods, so SQLite calls no xClose.
  base->pMethods = 0;
  int read_write = (flags & SQLITE_OPEN_READWRITE) != 0;
  int read_only = (flags & SQLITE_OPEN_READONLY) != 0;
  if (read_write == read_only)
    return SQLITE_CANTOPEN;
  if ((flags & SQLITE_OPEN_CREATE) && !read_write)
    return SQLITE_CANTOPEN;

  char temporary_name[MODUS_VFS_NAME_LIMIT];
  if (!name) {
    // A temporary file is written: one opened to read only is refused
    // before it takes a name.
    if (!read_write)
      return SQLITE_CANTOPEN;
    snprintf(temporary_name, sizeof temporary_name, VFS_TEMPORARY_PREFIX "%u", store->temporary_count++);
    name = temporary_name;
    flags |= SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE;
  }
  if (name[0] == 0 || strlen(name) >= MODUS_VFS_NAME_LIMIT)
    return SQLITE_CANTOPEN;

  Modus_Vfs_Slot *slot = slot_named(store, name);
  if (slot && (flags & SQLITE_OPEN_EXCLUSIVE) && (flags & SQLITE_OPEN_CREATE))
    return SQLITE_CANTOPEN;
  if (!slot) {
    if (!(flags & SQLITE_OPEN_CREATE))
      return SQLITE_CANTOPEN;
    slot = free_slot(store);
    if (!slot)
      return SQLITE_CANTOPEN;
    slot_clear(slot);
    strcpy(slot->name, name);
    slot->exists = 1;
  }
  memset(file, 0, sizeof *file);
  file->store = store;
  file->slot = slot;
  file->lock_level = MODUS_VFS_LOCK_NONE;
  file->read_only = read_only;
  file->delete_on_close = (flags & SQLITE_OPEN_DELETEONCLOSE) != 0;
  slot->open_count++;
  base->pMethods = &file_methods;
  if (out_flags)
    *out_flags = flags;
  return SQLITE_OK;
}

static int vfs_delete(sqlite3_vfs *vfs, const char *name, int sync_directory) {
  (void)sync_directory;
  if (!name)
    return SQLITE_IOERR_DELETE;
  Modus_Vfs_Store *store = store_of(vfs);
  Modus_Vfs_Slot *slot = slot_named(store, name);
  if (!slot)
    return SQLITE_IOERR_DELETE_NOENT;
  if (slot->open_count > 0)
    return SQLITE_IOERR_DELETE;
  if (store->split_main && slot == &store->slots[0])
    return SQLITE_IOERR_DELETE;
  slot_clear(slot);
  return SQLITE_OK;
}

// EXISTS is true for a file with bytes only, as the VFS of Unix answers: an
// empty journal is no hot journal.
static int vfs_access(sqlite3_vfs *vfs, const char *name, int word, int *result) {
  Modus_Vfs_Access access;
  if (!name || !result || !access_of_word(word, &access))
    return SQLITE_IOERR_ACCESS;
  Modus_Vfs_Slot *slot = slot_named(store_of(vfs), name);
  switch (access) {
  case MODUS_VFS_ACCESS_EXISTS:
    *result = slot && slot->size > 0;
    break;
  case MODUS_VFS_ACCESS_READ_WRITE:
  case MODUS_VFS_ACCESS_READ:
    *result = slot != 0;
    break;
  }
  return SQLITE_OK;
}

// A name is its own full path: the store has no folders.
static int vfs_full_pathname(sqlite3_vfs *vfs, const char *name, int out_count, char *out) {
  (void)vfs;
  if (!name || !out || out_count <= 0)
    return SQLITE_CANTOPEN;
  size_t length = strlen(name);
  if (length >= (size_t)out_count || length >= MODUS_VFS_NAME_LIMIT)
    return SQLITE_CANTOPEN;
  memcpy(out, name, length + 1);
  return SQLITE_OK;
}

// The bytes come from the seed that the caller gave: two runs with one seed
// give one database.
static int vfs_randomness(sqlite3_vfs *vfs, int count, char *out) {
  Modus_Vfs_Store *store = store_of(vfs);
  if (count < 0 || !out)
    return 0;
  for (int index = 0; index < count; index++) {
    unsigned long long state = store->random_state;
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    store->random_state = state;
    out[index] = (char)(state >> 56);
  }
  return count;
}

// A program reads no clock: it does not sleep, and its time is the start of
// the epoch, 1970-01-01 at 00:00, as a Julian day.
static int vfs_sleep(sqlite3_vfs *vfs, int microseconds) {
  (void)vfs;
  (void)microseconds;
  return 0;
}

static int vfs_current_time(sqlite3_vfs *vfs, double *julian_day) {
  (void)vfs;
  if (!julian_day)
    return SQLITE_ERROR;
  *julian_day = 2440587.5;
  return SQLITE_OK;
}

static int vfs_current_time_milliseconds(sqlite3_vfs *vfs, sqlite3_int64 *julian_milliseconds) {
  (void)vfs;
  if (!julian_milliseconds)
    return SQLITE_ERROR;
  *julian_milliseconds = 210866760000000LL;
  return SQLITE_OK;
}

static int vfs_last_error(sqlite3_vfs *vfs, int count, char *out) {
  (void)vfs;
  if (out && count > 0)
    out[0] = 0;
  return 0;
}

sqlite3_vfs *modus_vfs_make(sqlite3_vfs *vfs, Modus_Vfs_Store *store, const char *name) {
  if (!vfs || !store || !name)
    return 0;
  memset(vfs, 0, sizeof *vfs);
  vfs->iVersion = 2;
  vfs->szOsFile = (int)sizeof(Modus_Vfs_File);
  vfs->mxPathname = MODUS_VFS_NAME_LIMIT - 1;
  vfs->zName = name;
  vfs->pAppData = store;
  vfs->xOpen = vfs_open;
  vfs->xDelete = vfs_delete;
  vfs->xAccess = vfs_access;
  vfs->xFullPathname = vfs_full_pathname;
  vfs->xRandomness = vfs_randomness;
  vfs->xSleep = vfs_sleep;
  vfs->xCurrentTime = vfs_current_time;
  vfs->xGetLastError = vfs_last_error;
  vfs->xCurrentTimeInt64 = vfs_current_time_milliseconds;
  return vfs;
}

#ifdef MODUS_VFS_WITH_SQLITE
static Modus_Vfs_Store *default_store;
static sqlite3_vfs default_vfs;

void modus_vfs_bind_default_store(Modus_Vfs_Store *store) { default_store = store; }

int sqlite3_os_init(void) {
  if (!default_store)
    return SQLITE_ERROR;
  modus_vfs_make(&default_vfs, default_store, "modus");
  return sqlite3_vfs_register(&default_vfs, 1);
}

int sqlite3_os_end(void) { return SQLITE_OK; }
#endif
