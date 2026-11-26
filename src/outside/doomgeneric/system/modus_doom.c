// Modus entry points and DG_* platform hooks for doomgeneric.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <modus_doom_host.h>

#include "doomgeneric.h"
#include "m_argv.h"

pixel_t *DG_ScreenBuffer = NULL;

void M_FindResponseFile(void);
void D_DoomMain(void);

static char *modus_argv[4];

void DG_Init(void) {
}

void DG_DrawFrame(void) {
}

void DG_SleepMs(uint32_t ms) {
  if (modus_doom_host && modus_doom_host->sleep_ms) {
    modus_doom_host->sleep_ms(modus_doom_host->ctx, ms);
  }
}

uint32_t DG_GetTicksMs(void) {
  if (modus_doom_host && modus_doom_host->ticks_ms) {
    return modus_doom_host->ticks_ms(modus_doom_host->ctx);
  }
  return 0;
}

int DG_GetKey(int *pressed, unsigned char *key) {
  if (modus_doom_host && modus_doom_host->poll_key) {
    return modus_doom_host->poll_key(modus_doom_host->ctx, pressed, key);
  }
  return 0;
}

void DG_SetWindowTitle(const char *title) {
  if (modus_doom_host && modus_doom_host->set_title) {
    modus_doom_host->set_title(modus_doom_host->ctx, title);
  }
}

int modus_doom_init(const Modus_Doom_Host *host) {
  modus_libc_init(host);

  if (__builtin_setjmp(modus_exit_jump_buffer)) {
    modus_libc_flush_log();
    return modus_exit_status == 0 ? MODUS_DOOM_QUIT : MODUS_DOOM_ERROR;
  }
  modus_exit_jump_ready = true;

  modus_argv[0] = "doom";
  modus_argv[1] = "-iwad";
  modus_argv[2] = (char *)(host && host->wad_name ? host->wad_name : "freedoom1.wad");
  modus_argv[3] = NULL;

  myargc = 3;
  myargv = modus_argv;

  M_FindResponseFile();
  DG_Init();
  D_DoomMain();

  modus_exit_jump_ready = false;
  modus_libc_flush_log();
  return MODUS_DOOM_OK;
}

int modus_doom_tick(void) {
  if (__builtin_setjmp(modus_exit_jump_buffer)) {
    modus_libc_flush_log();
    return modus_exit_status == 0 ? MODUS_DOOM_QUIT : MODUS_DOOM_ERROR;
  }
  modus_exit_jump_ready = true;

  doomgeneric_Tick();

  modus_exit_jump_ready = false;
  modus_libc_flush_log();
  return MODUS_DOOM_OK;
}
