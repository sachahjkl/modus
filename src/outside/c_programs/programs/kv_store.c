// A key-value store over the VFS of SQLite (programs/kv_store.h). Each read
// and each write of a page goes through sqlite3_io_methods, as the pager of
// SQLite does, so the store tests the VFS with the calls of a database.
#include "kv_store.h"

#define KV_MAGIC 0x31564b4dU         // "MKV1"
#define KV_JOURNAL_MAGIC 0x314a4b4dU // "MKJ1"
#define KV_JOURNAL_HEADER_SIZE 16
#define KV_JOURNAL_ENTRY_SIZE (4 + KV_PAGE_SIZE)
#define KV_NODE_HEADER_SIZE 8
#define KV_LEAF_CAPACITY 31
#define KV_INNER_CAPACITY 40
#define KV_INNER_CHILDREN_OFFSET 8
#define KV_INNER_KEYS_OFFSET 176
#define KV_DEPTH_LIMIT 16

typedef enum Kv_Node_Kind {
  KV_NODE_LEAF = 1,
  KV_NODE_INNER = 2,
} Kv_Node_Kind;

typedef struct Kv_Page {
  unsigned char bytes[KV_PAGE_SIZE];
  int dirty;
  int journaled;
} Kv_Page;

struct Kv_Store {
  Modus_Heap *heap;
  sqlite3_vfs *vfs;
  sqlite3_file *database;
  sqlite3_file *journal;
  char database_name[MODUS_VFS_NAME_LIMIT];
  char journal_name[MODUS_VFS_NAME_LIMIT];
  Kv_Page *pages[KV_PAGE_LIMIT];
  unsigned int page_count;
  unsigned int original_page_count;
  unsigned int journal_entries;
  int in_transaction;
};

// ---- Words in a page ---------------------------------------------------------------

static unsigned int get_u16(const unsigned char *at) { return (unsigned int)at[0] | (unsigned int)at[1] << 8; }
static void set_u16(unsigned char *at, unsigned int value) {
  at[0] = (unsigned char)value;
  at[1] = (unsigned char)(value >> 8);
}
static unsigned int get_u32(const unsigned char *at) { return get_u16(at) | get_u16(at + 2) << 16; }
static void set_u32(unsigned char *at, unsigned int value) {
  set_u16(at, value & 0xFFFF);
  set_u16(at + 2, value >> 16);
}
static long long get_i64(const unsigned char *at) {
  return (long long)((unsigned long long)get_u32(at) | (unsigned long long)get_u32(at + 4) << 32);
}
static void set_i64(unsigned char *at, long long value) {
  set_u32(at, (unsigned int)(unsigned long long)value);
  set_u32(at + 4, (unsigned int)((unsigned long long)value >> 32));
}

static Kv_Status status_of_vfs(int code) {
  switch (code & 0xFF) {
  case SQLITE_OK:
    return KV_STATUS_OK;
  case SQLITE_BUSY:
    return KV_STATUS_BUSY;
  case SQLITE_FULL:
    return KV_STATUS_FULL;
  }
  return KV_STATUS_IO_ERROR;
}

static sqlite3_file *file_open(Kv_Store *store, const char *name, int flags, int *code) {
  sqlite3_file *file = modus_heap_allocate(store->heap, (size_t)store->vfs->szOsFile);
  if (!file) {
    *code = SQLITE_NOMEM;
    return 0;
  }
  *code = store->vfs->xOpen(store->vfs, name, file, flags, 0);
  if (*code != SQLITE_OK) {
    modus_heap_release(store->heap, file);
    return 0;
  }
  return file;
}

static void file_close(Kv_Store *store, sqlite3_file *file) {
  if (!file)
    return;
  if (file->pMethods)
    file->pMethods->xClose(file);
  modus_heap_release(store->heap, file);
}

// ---- Pages --------------------------------------------------------------------------

static void cache_drop(Kv_Store *store) {
  for (int index = 0; index < KV_PAGE_LIMIT; index++) {
    modus_heap_release(store->heap, store->pages[index]);
    store->pages[index] = 0;
  }
}

static Kv_Status page_get(Kv_Store *store, unsigned int number, Kv_Page **page_out) {
  if (number >= store->page_count || number >= KV_PAGE_LIMIT)
    return KV_STATUS_CORRUPT;
  if (!store->pages[number]) {
    Kv_Page *page = modus_heap_allocate(store->heap, sizeof(Kv_Page));
    if (!page)
      return KV_STATUS_NO_MEMORY;
    memset(page, 0, sizeof *page);
    int code = store->database->pMethods->xRead(store->database, page->bytes, KV_PAGE_SIZE,
                                                (sqlite3_int64)number * KV_PAGE_SIZE);
    // A page of a new tree is past the end of the file until the commit.
    if (code != SQLITE_OK && code != SQLITE_IOERR_SHORT_READ) {
      modus_heap_release(store->heap, page);
      return status_of_vfs(code);
    }
    store->pages[number] = page;
  }
  *page_out = store->pages[number];
  return KV_STATUS_OK;
}

// Before the first change of a page that the file held at the start of the
// transaction, its old bytes go to the journal, and the count of the entries
// in the header of the journal follows them.
static Kv_Status page_change(Kv_Store *store, unsigned int number, Kv_Page **page_out) {
  if (!store->in_transaction)
    return KV_STATUS_MISUSE;
  Kv_Status status = page_get(store, number, page_out);
  if (status != KV_STATUS_OK)
    return status;
  Kv_Page *page = *page_out;
  if (!page->journaled && number < store->original_page_count) {
    unsigned char entry[KV_JOURNAL_ENTRY_SIZE];
    set_u32(entry, number);
    memcpy(entry + 4, page->bytes, KV_PAGE_SIZE);
    sqlite3_int64 offset = KV_JOURNAL_HEADER_SIZE + (sqlite3_int64)store->journal_entries * KV_JOURNAL_ENTRY_SIZE;
    int code = store->journal->pMethods->xWrite(store->journal, entry, KV_JOURNAL_ENTRY_SIZE, offset);
    if (code != SQLITE_OK)
      return status_of_vfs(code);
    store->journal_entries++;
    unsigned char count[4];
    set_u32(count, store->journal_entries);
    code = store->journal->pMethods->xWrite(store->journal, count, 4, 4);
    if (code != SQLITE_OK)
      return status_of_vfs(code);
    code = store->journal->pMethods->xSync(store->journal, 0);
    if (code != SQLITE_OK)
      return status_of_vfs(code);
  }
  page->journaled = 1;
  page->dirty = 1;
  return KV_STATUS_OK;
}

static Kv_Status page_new(Kv_Store *store, Kv_Node_Kind kind, unsigned int *number_out, Kv_Page **page_out) {
  if (store->page_count >= KV_PAGE_LIMIT)
    return KV_STATUS_FULL;
  unsigned int number = store->page_count++;
  Kv_Status status = page_change(store, number, page_out);
  if (status != KV_STATUS_OK) {
    store->page_count--;
    return status;
  }
  memset((*page_out)->bytes, 0, KV_PAGE_SIZE);
  set_u16((*page_out)->bytes, kind);
  *number_out = number;
  return KV_STATUS_OK;
}

// ---- The header page ----------------------------------------------------------------

static unsigned int header_root(Kv_Store *store) { return get_u32(store->pages[0]->bytes + 8); }

static Kv_Status header_update(Kv_Store *store, unsigned int root, long long record_delta) {
  Kv_Page *header;
  Kv_Status status = page_change(store, 0, &header);
  if (status != KV_STATUS_OK)
    return status;
  set_u32(header->bytes + 4, store->page_count);
  set_u32(header->bytes + 8, root);
  set_i64(header->bytes + 16, get_i64(header->bytes + 16) + record_delta);
  return KV_STATUS_OK;
}

// ---- The journal ----------------------------------------------------------------------

static Kv_Status journal_play_back(Kv_Store *store) {
  int code;
  sqlite3_file *journal = file_open(store, store->journal_name, SQLITE_OPEN_READWRITE | SQLITE_OPEN_MAIN_JOURNAL, &code);
  if (!journal)
    return status_of_vfs(code);
  unsigned char header[KV_JOURNAL_HEADER_SIZE];
  Kv_Status status = KV_STATUS_OK;
  code = journal->pMethods->xRead(journal, header, KV_JOURNAL_HEADER_SIZE, 0);
  if (code != SQLITE_OK || get_u32(header) != KV_JOURNAL_MAGIC) {
    // A journal with no whole header was written before any page changed.
    status = KV_STATUS_OK;
  } else {
    unsigned int entries = get_u32(header + 4);
    unsigned int original_page_count = get_u32(header + 8);
    for (unsigned int index = 0; index < entries && status == KV_STATUS_OK; index++) {
      unsigned char entry[KV_JOURNAL_ENTRY_SIZE];
      code = journal->pMethods->xRead(journal, entry, KV_JOURNAL_ENTRY_SIZE,
                                      KV_JOURNAL_HEADER_SIZE + (sqlite3_int64)index * KV_JOURNAL_ENTRY_SIZE);
      if (code != SQLITE_OK) {
        status = KV_STATUS_CORRUPT;
        break;
      }
      unsigned int number = get_u32(entry);
      if (number >= original_page_count) {
        status = KV_STATUS_CORRUPT;
        break;
      }
      code = store->database->pMethods->xWrite(store->database, entry + 4, KV_PAGE_SIZE,
                                               (sqlite3_int64)number * KV_PAGE_SIZE);
      status = status_of_vfs(code);
    }
    if (status == KV_STATUS_OK) {
      code = store->database->pMethods->xTruncate(store->database, (sqlite3_int64)original_page_count * KV_PAGE_SIZE);
      status = status_of_vfs(code);
    }
  }
  file_close(store, journal);
  if (status == KV_STATUS_OK)
    status = status_of_vfs(store->vfs->xDelete(store->vfs, store->journal_name, 0));
  return status;
}

// ---- Open, begin, commit, rollback, close ---------------------------------------------

static Kv_Status store_finish_transaction(Kv_Store *store, int delete_journal) {
  file_close(store, store->journal);
  store->journal = 0;
  Kv_Status status = KV_STATUS_OK;
  if (delete_journal)
    status = status_of_vfs(store->vfs->xDelete(store->vfs, store->journal_name, 0));
  store->database->pMethods->xUnlock(store->database, SQLITE_LOCK_SHARED);
  store->in_transaction = 0;
  for (int index = 0; index < KV_PAGE_LIMIT; index++)
    if (store->pages[index]) {
      store->pages[index]->dirty = 0;
      store->pages[index]->journaled = 0;
    }
  return status;
}

Kv_Status kv_begin(Kv_Store *store) {
  if (!store || store->in_transaction)
    return KV_STATUS_MISUSE;
  int code = store->database->pMethods->xLock(store->database, SQLITE_LOCK_RESERVED);
  if (code != SQLITE_OK)
    return status_of_vfs(code);
  store->journal = file_open(store, store->journal_name,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MAIN_JOURNAL, &code);
  if (!store->journal) {
    store->database->pMethods->xUnlock(store->database, SQLITE_LOCK_SHARED);
    return status_of_vfs(code);
  }
  unsigned char header[KV_JOURNAL_HEADER_SIZE] = {0};
  set_u32(header, KV_JOURNAL_MAGIC);
  set_u32(header + 8, store->page_count);
  code = store->journal->pMethods->xWrite(store->journal, header, KV_JOURNAL_HEADER_SIZE, 0);
  if (code != SQLITE_OK) {
    store_finish_transaction(store, 1);
    return status_of_vfs(code);
  }
  store->original_page_count = store->page_count;
  store->journal_entries = 0;
  store->in_transaction = 1;
  return KV_STATUS_OK;
}

Kv_Status kv_commit(Kv_Store *store, long page_write_limit) {
  if (!store || !store->in_transaction)
    return KV_STATUS_MISUSE;
  int code = store->database->pMethods->xLock(store->database, SQLITE_LOCK_EXCLUSIVE);
  if (code != SQLITE_OK)
    return status_of_vfs(code);
  long written = 0;
  for (unsigned int number = 0; number < store->page_count; number++) {
    Kv_Page *page = store->pages[number];
    if (!page || !page->dirty)
      continue;
    if (page_write_limit >= 0 && written == page_write_limit)
      return KV_STATUS_INTERRUPTED;
    code = store->database->pMethods->xWrite(store->database, page->bytes, KV_PAGE_SIZE,
                                             (sqlite3_int64)number * KV_PAGE_SIZE);
    if (code != SQLITE_OK)
      return status_of_vfs(code);
    written++;
  }
  if (page_write_limit >= 0 && written == page_write_limit)
    return KV_STATUS_INTERRUPTED;
  code = store->database->pMethods->xTruncate(store->database, (sqlite3_int64)store->page_count * KV_PAGE_SIZE);
  if (code != SQLITE_OK)
    return status_of_vfs(code);
  store->database->pMethods->xSync(store->database, 0);
  return store_finish_transaction(store, 1);
}

// The pages in memory go, so each later read comes from the file again; the
// file itself changed nothing before the commit, unless a commit that failed
// wrote some pages: then the journal puts them back.
Kv_Status kv_rollback(Kv_Store *store) {
  if (!store || !store->in_transaction)
    return KV_STATUS_MISUSE;
  cache_drop(store);
  store->page_count = store->original_page_count;
  file_close(store, store->journal);
  store->journal = 0;
  Kv_Status status = journal_play_back(store);
  store->database->pMethods->xUnlock(store->database, SQLITE_LOCK_SHARED);
  store->in_transaction = 0;
  if (status != KV_STATUS_OK)
    return status;
  Kv_Page *header;
  return page_get(store, 0, &header);
}

static Kv_Status store_load(Kv_Store *store) {
  sqlite3_int64 size = 0;
  int code = store->database->pMethods->xFileSize(store->database, &size);
  if (code != SQLITE_OK)
    return status_of_vfs(code);
  if (size == 0) {
    // An empty file: a header page and an empty leaf, in one transaction.
    store->page_count = 0;
    Kv_Status status = kv_begin(store);
    if (status != KV_STATUS_OK)
      return status;
    unsigned int header_number, root_number;
    Kv_Page *header, *root;
    if ((status = page_new(store, KV_NODE_LEAF, &header_number, &header)) != KV_STATUS_OK ||
        (status = page_new(store, KV_NODE_LEAF, &root_number, &root)) != KV_STATUS_OK) {
      kv_rollback(store);
      return status;
    }
    memset(header->bytes, 0, KV_PAGE_SIZE);
    set_u32(header->bytes, KV_MAGIC);
    set_u32(header->bytes + 4, store->page_count);
    set_u32(header->bytes + 8, root_number);
    return kv_commit(store, -1);
  }
  if (size % KV_PAGE_SIZE != 0 || size / KV_PAGE_SIZE > KV_PAGE_LIMIT || size < 2 * KV_PAGE_SIZE)
    return KV_STATUS_CORRUPT;
  store->page_count = (unsigned int)(size / KV_PAGE_SIZE);
  Kv_Page *header;
  Kv_Status status = page_get(store, 0, &header);
  if (status != KV_STATUS_OK)
    return status;
  if (get_u32(header->bytes) != KV_MAGIC || get_u32(header->bytes + 4) != store->page_count ||
      header_root(store) == 0 || header_root(store) >= store->page_count)
    return KV_STATUS_CORRUPT;
  return KV_STATUS_OK;
}

Kv_Status kv_open(Kv_Store **store_out, Modus_Heap *heap, sqlite3_vfs *vfs, const char *name) {
  if (!store_out || !heap || !vfs || !name)
    return KV_STATUS_MISUSE;
  *store_out = 0;
  size_t name_length = strlen(name);
  if (name_length == 0 || name_length + sizeof "-journal" > MODUS_VFS_NAME_LIMIT)
    return KV_STATUS_MISUSE;
  Kv_Store *store = modus_heap_allocate(heap, sizeof(Kv_Store));
  if (!store)
    return KV_STATUS_NO_MEMORY;
  memset(store, 0, sizeof *store);
  store->heap = heap;
  store->vfs = vfs;
  memcpy(store->database_name, name, name_length + 1);
  memcpy(store->journal_name, name, name_length);
  memcpy(store->journal_name + name_length, "-journal", sizeof "-journal");
  int code;
  store->database =
      file_open(store, store->database_name, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MAIN_DB, &code);
  if (!store->database) {
    modus_heap_release(heap, store);
    return status_of_vfs(code);
  }
  Kv_Status status = status_of_vfs(store->database->pMethods->xLock(store->database, SQLITE_LOCK_SHARED));
  int hot = 0;
  if (status == KV_STATUS_OK)
    status = status_of_vfs(vfs->xAccess(vfs, store->journal_name, SQLITE_ACCESS_EXISTS, &hot));
  if (status == KV_STATUS_OK && hot) {
    // A hot journal: a commit stopped in the middle. Its pages go back first.
    status = status_of_vfs(store->database->pMethods->xLock(store->database, SQLITE_LOCK_RESERVED));
    if (status == KV_STATUS_OK)
      status = status_of_vfs(store->database->pMethods->xLock(store->database, SQLITE_LOCK_EXCLUSIVE));
    if (status == KV_STATUS_OK)
      status = journal_play_back(store);
    store->database->pMethods->xUnlock(store->database, SQLITE_LOCK_SHARED);
  }
  if (status == KV_STATUS_OK)
    status = store_load(store);
  if (status != KV_STATUS_OK) {
    kv_abandon(store);
    return status;
  }
  *store_out = store;
  return KV_STATUS_OK;
}

Kv_Status kv_close(Kv_Store *store) {
  if (!store)
    return KV_STATUS_MISUSE;
  Kv_Status status = KV_STATUS_OK;
  if (store->in_transaction)
    status = kv_rollback(store);
  kv_abandon(store);
  return status;
}

void kv_abandon(Kv_Store *store) {
  if (!store)
    return;
  cache_drop(store);
  file_close(store, store->journal);
  file_close(store, store->database);
  modus_heap_release(store->heap, store);
}

// ---- The tree ---------------------------------------------------------------------------

static unsigned int node_kind(const Kv_Page *page) { return get_u16(page->bytes); }
static unsigned int node_count(const Kv_Page *page) { return get_u16(page->bytes + 2); }
static unsigned int leaf_next(const Kv_Page *page) { return get_u32(page->bytes + 4); }
static long long leaf_key(const Kv_Page *page, unsigned int index) { return get_i64(page->bytes + 8 + 16 * index); }
static long long leaf_value(const Kv_Page *page, unsigned int index) {
  return get_i64(page->bytes + 16 + 16 * index);
}
static unsigned int inner_child(const Kv_Page *page, unsigned int index) {
  return get_u32(page->bytes + KV_INNER_CHILDREN_OFFSET + 4 * index);
}
static long long inner_key(const Kv_Page *page, unsigned int index) {
  return get_i64(page->bytes + KV_INNER_KEYS_OFFSET + 8 * index);
}

// The index of the child of an inner node that holds the key: the keys of
// child i are below key i, and at or above key i - 1.
static unsigned int inner_child_index(const Kv_Page *page, long long key) {
  unsigned int index = 0;
  while (index < node_count(page) && key >= inner_key(page, index))
    index++;
  return index;
}

static Kv_Status node_checked(Kv_Store *store, unsigned int number, Kv_Page **page_out) {
  Kv_Status status = page_get(store, number, page_out);
  if (status != KV_STATUS_OK)
    return status;
  unsigned int kind = node_kind(*page_out);
  unsigned int count = node_count(*page_out);
  if (number == 0 || (kind == KV_NODE_LEAF && count > KV_LEAF_CAPACITY) ||
      (kind == KV_NODE_INNER && (count == 0 || count > KV_INNER_CAPACITY)) ||
      (kind != KV_NODE_LEAF && kind != KV_NODE_INNER))
    return KV_STATUS_CORRUPT;
  return KV_STATUS_OK;
}

typedef struct Kv_Split {
  int happened;
  long long key;
  unsigned int page;
} Kv_Split;

static Kv_Status leaf_insert(Kv_Store *store, unsigned int number, long long key, long long value, Kv_Split *split,
                             int *added) {
  Kv_Page *page;
  Kv_Status status = page_change(store, number, &page);
  if (status != KV_STATUS_OK)
    return status;
  unsigned int count = node_count(page);
  unsigned int position = 0;
  while (position < count && leaf_key(page, position) < key)
    position++;
  if (position < count && leaf_key(page, position) == key) {
    set_i64(page->bytes + 16 + 16 * position, value);
    *added = 0;
    return KV_STATUS_OK;
  }
  *added = 1;
  long long keys[KV_LEAF_CAPACITY + 1], values[KV_LEAF_CAPACITY + 1];
  for (unsigned int index = 0, from = 0; index <= count; index++) {
    if (index == position) {
      keys[index] = key;
      values[index] = value;
    } else {
      keys[index] = leaf_key(page, from);
      values[index] = leaf_value(page, from);
      from++;
    }
  }
  count++;
  unsigned int left_count = count;
  if (count > KV_LEAF_CAPACITY) {
    unsigned int right_number;
    Kv_Page *right;
    status = page_new(store, KV_NODE_LEAF, &right_number, &right);
    if (status != KV_STATUS_OK)
      return status;
    left_count = count / 2;
    unsigned int right_count = count - left_count;
    for (unsigned int index = 0; index < right_count; index++) {
      set_i64(right->bytes + 8 + 16 * index, keys[left_count + index]);
      set_i64(right->bytes + 16 + 16 * index, values[left_count + index]);
    }
    set_u16(right->bytes + 2, right_count);
    set_u32(right->bytes + 4, leaf_next(page));
    set_u32(page->bytes + 4, right_number);
    split->happened = 1;
    split->key = keys[left_count];
    split->page = right_number;
  }
  for (unsigned int index = 0; index < left_count; index++) {
    set_i64(page->bytes + 8 + 16 * index, keys[index]);
    set_i64(page->bytes + 16 + 16 * index, values[index]);
  }
  set_u16(page->bytes + 2, left_count);
  return KV_STATUS_OK;
}

static Kv_Status node_insert(Kv_Store *store, unsigned int number, long long key, long long value, Kv_Split *split,
                             int *added, int depth) {
  if (depth > KV_DEPTH_LIMIT)
    return KV_STATUS_CORRUPT;
  Kv_Page *page;
  Kv_Status status = node_checked(store, number, &page);
  if (status != KV_STATUS_OK)
    return status;
  if (node_kind(page) == KV_NODE_LEAF)
    return leaf_insert(store, number, key, value, split, added);

  unsigned int child_index = inner_child_index(page, key);
  Kv_Split child_split = {0, 0, 0};
  status = node_insert(store, inner_child(page, child_index), key, value, &child_split, added, depth + 1);
  if (status != KV_STATUS_OK || !child_split.happened)
    return status;

  status = page_change(store, number, &page);
  if (status != KV_STATUS_OK)
    return status;
  unsigned int count = node_count(page);
  long long keys[KV_INNER_CAPACITY + 1];
  unsigned int children[KV_INNER_CAPACITY + 2];
  for (unsigned int index = 0, from = 0; index <= count; index++) {
    if (index == child_index) {
      keys[index] = child_split.key;
    } else {
      keys[index] = inner_key(page, from);
      from++;
    }
  }
  for (unsigned int index = 0, from = 0; index <= count + 1; index++) {
    if (index == child_index + 1) {
      children[index] = child_split.page;
    } else {
      children[index] = inner_child(page, from);
      from++;
    }
  }
  count++;
  unsigned int left_count = count;
  if (count > KV_INNER_CAPACITY) {
    unsigned int right_number;
    Kv_Page *right;
    status = page_new(store, KV_NODE_INNER, &right_number, &right);
    if (status != KV_STATUS_OK)
      return status;
    left_count = count / 2;
    // The middle key moves up: it is in neither half.
    unsigned int right_count = count - left_count - 1;
    for (unsigned int index = 0; index < right_count; index++)
      set_i64(right->bytes + KV_INNER_KEYS_OFFSET + 8 * index, keys[left_count + 1 + index]);
    for (unsigned int index = 0; index <= right_count; index++)
      set_u32(right->bytes + KV_INNER_CHILDREN_OFFSET + 4 * index, children[left_count + 1 + index]);
    set_u16(right->bytes + 2, right_count);
    split->happened = 1;
    split->key = keys[left_count];
    split->page = right_number;
  }
  for (unsigned int index = 0; index < left_count; index++)
    set_i64(page->bytes + KV_INNER_KEYS_OFFSET + 8 * index, keys[index]);
  for (unsigned int index = 0; index <= left_count; index++)
    set_u32(page->bytes + KV_INNER_CHILDREN_OFFSET + 4 * index, children[index]);
  set_u16(page->bytes + 2, left_count);
  return KV_STATUS_OK;
}

Kv_Status kv_put(Kv_Store *store, long long key, long long value) {
  if (!store || !store->in_transaction)
    return KV_STATUS_MISUSE;
  unsigned int root = header_root(store);
  Kv_Split split = {0, 0, 0};
  int added = 0;
  Kv_Status status = node_insert(store, root, key, value, &split, &added, 0);
  if (status != KV_STATUS_OK)
    return status;
  if (split.happened) {
    unsigned int new_root;
    Kv_Page *page;
    status = page_new(store, KV_NODE_INNER, &new_root, &page);
    if (status != KV_STATUS_OK)
      return status;
    set_u16(page->bytes + 2, 1);
    set_u32(page->bytes + KV_INNER_CHILDREN_OFFSET, root);
    set_u32(page->bytes + KV_INNER_CHILDREN_OFFSET + 4, split.page);
    set_i64(page->bytes + KV_INNER_KEYS_OFFSET, split.key);
    root = new_root;
  }
  return header_update(store, root, added);
}

static Kv_Status leaf_of_key(Kv_Store *store, long long key, Kv_Page **leaf) {
  unsigned int number = header_root(store);
  for (int depth = 0; depth <= KV_DEPTH_LIMIT; depth++) {
    Kv_Status status = node_checked(store, number, leaf);
    if (status != KV_STATUS_OK)
      return status;
    if (node_kind(*leaf) == KV_NODE_LEAF)
      return KV_STATUS_OK;
    number = inner_child(*leaf, inner_child_index(*leaf, key));
  }
  return KV_STATUS_CORRUPT;
}

Kv_Status kv_get(Kv_Store *store, long long key, long long *value) {
  if (!store || !value)
    return KV_STATUS_MISUSE;
  Kv_Page *leaf;
  Kv_Status status = leaf_of_key(store, key, &leaf);
  if (status != KV_STATUS_OK)
    return status;
  for (unsigned int index = 0; index < node_count(leaf); index++)
    if (leaf_key(leaf, index) == key) {
      *value = leaf_value(leaf, index);
      return KV_STATUS_OK;
    }
  return KV_STATUS_NOT_FOUND;
}

// The sum of the values of the keys in [low, high]: the leaf of low, then the
// chain of the leaves, as SELECT SUM(value) WHERE key BETWEEN low AND high.
Kv_Status kv_sum(Kv_Store *store, long long low, long long high, long long *sum, long long *count) {
  if (!store || !sum || !count || low > high)
    return KV_STATUS_MISUSE;
  *sum = 0;
  *count = 0;
  Kv_Page *leaf;
  Kv_Status status = leaf_of_key(store, low, &leaf);
  for (unsigned int steps = 0; status == KV_STATUS_OK; steps++) {
    if (steps > store->page_count)
      return KV_STATUS_CORRUPT;
    for (unsigned int index = 0; index < node_count(leaf); index++) {
      long long key = leaf_key(leaf, index);
      if (key > high)
        return KV_STATUS_OK;
      if (key >= low) {
        *sum = (long long)((unsigned long long)*sum + (unsigned long long)leaf_value(leaf, index));
        (*count)++;
      }
    }
    unsigned int next = leaf_next(leaf);
    if (next == 0)
      return KV_STATUS_OK;
    status = node_checked(store, next, &leaf);
    if (status == KV_STATUS_OK && node_kind(leaf) != KV_NODE_LEAF)
      return KV_STATUS_CORRUPT;
  }
  return status;
}

typedef struct Kv_Check_State {
  int leaf_depth;
  long long records;
  unsigned int first_leaf;
} Kv_Check_State;

static Kv_Status check_node(Kv_Store *store, unsigned int number, int depth, int has_low, long long low, int has_high,
                            long long high, Kv_Check_State *state) {
  if (depth > KV_DEPTH_LIMIT)
    return KV_STATUS_CORRUPT;
  Kv_Page *page;
  Kv_Status status = node_checked(store, number, &page);
  if (status != KV_STATUS_OK)
    return status;
  unsigned int count = node_count(page);
  if (node_kind(page) == KV_NODE_LEAF) {
    if (state->leaf_depth < 0) {
      state->leaf_depth = depth;
      state->first_leaf = number;
    } else if (state->leaf_depth != depth) {
      return KV_STATUS_CORRUPT;
    }
    for (unsigned int index = 0; index < count; index++) {
      long long key = leaf_key(page, index);
      if ((has_low && key < low) || (has_high && key >= high) || (index > 0 && key <= leaf_key(page, index - 1)))
        return KV_STATUS_CORRUPT;
    }
    state->records += count;
    return KV_STATUS_OK;
  }
  for (unsigned int index = 0; index < count; index++) {
    long long key = inner_key(page, index);
    if ((has_low && key < low) || (has_high && key >= high) || (index > 0 && key <= inner_key(page, index - 1)))
      return KV_STATUS_CORRUPT;
  }
  for (unsigned int index = 0; index <= count; index++) {
    int child_has_low = index > 0 || has_low;
    long long child_low = index > 0 ? inner_key(page, index - 1) : low;
    int child_has_high = index < count || has_high;
    long long child_high = index < count ? inner_key(page, index) : high;
    status = check_node(store, inner_child(page, index), depth + 1, child_has_low, child_low, child_has_high,
                        child_high, state);
    if (status != KV_STATUS_OK)
      return status;
  }
  return KV_STATUS_OK;
}

Kv_Status kv_check(Kv_Store *store, long long *record_count) {
  if (!store || !record_count)
    return KV_STATUS_MISUSE;
  Kv_Check_State state = {-1, 0, 0};
  Kv_Status status = check_node(store, header_root(store), 0, 0, 0, 0, 0, &state);
  if (status != KV_STATUS_OK)
    return status;
  // The chain of the leaves holds each record once, in order.
  long long chained = 0;
  int has_previous = 0;
  long long previous = 0;
  unsigned int number = state.first_leaf;
  for (unsigned int steps = 0; number != 0; steps++) {
    if (steps > store->page_count)
      return KV_STATUS_CORRUPT;
    Kv_Page *leaf;
    status = node_checked(store, number, &leaf);
    if (status != KV_STATUS_OK || node_kind(leaf) != KV_NODE_LEAF)
      return KV_STATUS_CORRUPT;
    for (unsigned int index = 0; index < node_count(leaf); index++) {
      long long key = leaf_key(leaf, index);
      if (has_previous && key <= previous)
        return KV_STATUS_CORRUPT;
      previous = key;
      has_previous = 1;
      chained++;
    }
    number = leaf_next(leaf);
  }
  if (chained != state.records || get_i64(store->pages[0]->bytes + 16) != state.records)
    return KV_STATUS_CORRUPT;
  *record_count = state.records;
  return KV_STATUS_OK;
}
