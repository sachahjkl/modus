// Modus memory-mapped WAD backend for doomgeneric.
// Exposes the WAD buffer preloaded from storage at startup as wad_file_t.mapped
// so W_CacheLumpNum returns direct pointers with zero copies and zero RPCs.
#include <stddef.h>
#include <string.h>
#include <strings.h>
#include <modus_doom_host.h>

#include "w_file.h"
#include "z_zone.h"

extern wad_file_class_t stdc_wad_file;

static const char *base_name(const char *path) {
  if (!path) {
    return "";
  }
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

static wad_file_t *W_Modus_OpenFile(char *path) {
  if (!modus_doom_host || !modus_doom_host->wad_bytes || !modus_doom_host->wad_name) {
    return NULL;
  }
  if (strcasecmp(base_name(path), modus_doom_host->wad_name) != 0) {
    return NULL;
  }
  wad_file_t *result = (wad_file_t *)Z_Malloc(sizeof(wad_file_t), PU_STATIC, NULL);
  result->file_class = &stdc_wad_file;
  result->mapped = (byte *)modus_doom_host->wad_bytes;
  result->length = (unsigned int)modus_doom_host->wad_size;
  return result;
}

static void W_Modus_CloseFile(wad_file_t *wad) {
  if (wad) {
    Z_Free(wad);
  }
}

static size_t W_Modus_Read(wad_file_t *wad, unsigned int offset, void *buffer, size_t buffer_len) {
  if (!wad || !wad->mapped || offset >= wad->length) {
    return 0;
  }
  size_t avail = (size_t)(wad->length - offset);
  size_t take = buffer_len < avail ? buffer_len : avail;
  memcpy(buffer, wad->mapped + offset, take);
  return take;
}

wad_file_class_t stdc_wad_file = {
  W_Modus_OpenFile,
  W_Modus_CloseFile,
  W_Modus_Read,
};
