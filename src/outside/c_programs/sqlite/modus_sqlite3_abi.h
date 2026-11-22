// The part of the interface of SQLite 3 that a VFS implements, with the
// layout and the values of sqlite3.h. A build with the SQLite source defines
// MODUS_VFS_WITH_SQLITE and reads sqlite3.h itself; the host test of the
// adapter reads this file, and compares both when sqlite3.h is at hand.
#ifndef MODUS_SQLITE3_ABI_H
#define MODUS_SQLITE3_ABI_H

typedef long long int sqlite3_int64;
typedef const char *sqlite3_filename;
typedef struct sqlite3_file sqlite3_file;
typedef struct sqlite3_io_methods sqlite3_io_methods;
typedef struct sqlite3_vfs sqlite3_vfs;
typedef void (*sqlite3_syscall_ptr)(void);

struct sqlite3_file {
  const struct sqlite3_io_methods *pMethods;
};

struct sqlite3_io_methods {
  int iVersion;
  int (*xClose)(sqlite3_file *);
  int (*xRead)(sqlite3_file *, void *, int iAmt, sqlite3_int64 iOfst);
  int (*xWrite)(sqlite3_file *, const void *, int iAmt, sqlite3_int64 iOfst);
  int (*xTruncate)(sqlite3_file *, sqlite3_int64 size);
  int (*xSync)(sqlite3_file *, int flags);
  int (*xFileSize)(sqlite3_file *, sqlite3_int64 *pSize);
  int (*xLock)(sqlite3_file *, int);
  int (*xUnlock)(sqlite3_file *, int);
  int (*xCheckReservedLock)(sqlite3_file *, int *pResOut);
  int (*xFileControl)(sqlite3_file *, int op, void *pArg);
  int (*xSectorSize)(sqlite3_file *);
  int (*xDeviceCharacteristics)(sqlite3_file *);
  int (*xShmMap)(sqlite3_file *, int iPg, int pgsz, int, void volatile **);
  int (*xShmLock)(sqlite3_file *, int offset, int n, int flags);
  void (*xShmBarrier)(sqlite3_file *);
  int (*xShmUnmap)(sqlite3_file *, int deleteFlag);
  int (*xFetch)(sqlite3_file *, sqlite3_int64 iOfst, int iAmt, void **pp);
  int (*xUnfetch)(sqlite3_file *, sqlite3_int64 iOfst, void *p);
};

struct sqlite3_vfs {
  int iVersion;
  int szOsFile;
  int mxPathname;
  sqlite3_vfs *pNext;
  const char *zName;
  void *pAppData;
  int (*xOpen)(sqlite3_vfs *, sqlite3_filename zName, sqlite3_file *, int flags, int *pOutFlags);
  int (*xDelete)(sqlite3_vfs *, const char *zName, int syncDir);
  int (*xAccess)(sqlite3_vfs *, const char *zName, int flags, int *pResOut);
  int (*xFullPathname)(sqlite3_vfs *, const char *zName, int nOut, char *zOut);
  void *(*xDlOpen)(sqlite3_vfs *, const char *zFilename);
  void (*xDlError)(sqlite3_vfs *, int nByte, char *zErrMsg);
  void (*(*xDlSym)(sqlite3_vfs *, void *, const char *zSymbol))(void);
  void (*xDlClose)(sqlite3_vfs *, void *);
  int (*xRandomness)(sqlite3_vfs *, int nByte, char *zOut);
  int (*xSleep)(sqlite3_vfs *, int microseconds);
  int (*xCurrentTime)(sqlite3_vfs *, double *);
  int (*xGetLastError)(sqlite3_vfs *, int, char *);
  int (*xCurrentTimeInt64)(sqlite3_vfs *, sqlite3_int64 *);
  int (*xSetSystemCall)(sqlite3_vfs *, const char *zName, sqlite3_syscall_ptr);
  sqlite3_syscall_ptr (*xGetSystemCall)(sqlite3_vfs *, const char *zName);
  const char *(*xNextSystemCall)(sqlite3_vfs *, const char *zName);
};

#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define SQLITE_BUSY 5
#define SQLITE_NOMEM 7
#define SQLITE_READONLY 8
#define SQLITE_IOERR 10
#define SQLITE_NOTFOUND 12
#define SQLITE_FULL 13
#define SQLITE_CANTOPEN 14
#define SQLITE_MISUSE 21

#define SQLITE_IOERR_READ (SQLITE_IOERR | (1 << 8))
#define SQLITE_IOERR_SHORT_READ (SQLITE_IOERR | (2 << 8))
#define SQLITE_IOERR_WRITE (SQLITE_IOERR | (3 << 8))
#define SQLITE_IOERR_TRUNCATE (SQLITE_IOERR | (6 << 8))
#define SQLITE_IOERR_UNLOCK (SQLITE_IOERR | (8 << 8))
#define SQLITE_IOERR_DELETE (SQLITE_IOERR | (10 << 8))
#define SQLITE_IOERR_ACCESS (SQLITE_IOERR | (13 << 8))
#define SQLITE_IOERR_LOCK (SQLITE_IOERR | (15 << 8))
#define SQLITE_IOERR_DELETE_NOENT (SQLITE_IOERR | (23 << 8))

#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_DELETEONCLOSE 0x00000008
#define SQLITE_OPEN_EXCLUSIVE 0x00000010
#define SQLITE_OPEN_MAIN_DB 0x00000100
#define SQLITE_OPEN_TEMP_DB 0x00000200
#define SQLITE_OPEN_MAIN_JOURNAL 0x00000800

#define SQLITE_LOCK_NONE 0
#define SQLITE_LOCK_SHARED 1
#define SQLITE_LOCK_RESERVED 2
#define SQLITE_LOCK_PENDING 3
#define SQLITE_LOCK_EXCLUSIVE 4

#define SQLITE_ACCESS_EXISTS 0
#define SQLITE_ACCESS_READWRITE 1
#define SQLITE_ACCESS_READ 2

#define SQLITE_IOCAP_POWERSAFE_OVERWRITE 0x00001000

#endif
