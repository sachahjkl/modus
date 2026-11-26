// Modus video backend for doomgeneric.
// Hands the 320x200 8-bit indexed Doom framebuffer and active 256-entry
// 0x00RRGGBB palette directly to Odin's SIMD blitter with zero intermediate copy.
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <modus_doom_host.h>

#include "config.h"
#include "v_video.h"
#include "d_event.h"
#include "d_main.h"
#include "i_video.h"
#include "i_system.h"
#include "tables.h"
#include "z_zone.h"
#include "doomgeneric.h"

int fb_scaling = 2;
int usemouse = 1;
byte *I_VideoBuffer = NULL;
boolean screensaver_mode = false;
boolean screenvisible = true;
float mouse_acceleration = 2.0f;
int mouse_threshold = 10;
int usegamma = 0;

static uint32_t modus_palette_bgra[256];
static uint8_t  modus_palette_r[256];
static uint8_t  modus_palette_g[256];
static uint8_t  modus_palette_b[256];

void I_GetEvent(void);
void I_InitInput(void);

void I_InitGraphics(void) {
  I_VideoBuffer = (byte *)Z_Malloc(SCREENWIDTH * SCREENHEIGHT, PU_STATIC, NULL);
  memset(I_VideoBuffer, 0, SCREENWIDTH * SCREENHEIGHT);
  screenvisible = true;
  I_InitInput();
}

void I_ShutdownGraphics(void) {
  if (I_VideoBuffer) {
    Z_Free(I_VideoBuffer);
    I_VideoBuffer = NULL;
  }
}

void I_StartFrame(void) {
}

void I_StartTic(void) {
  I_GetEvent();
}

void I_UpdateNoBlit(void) {
}

void I_FinishUpdate(void) {
  if (modus_doom_host && modus_doom_host->draw_indexed && I_VideoBuffer) {
    modus_doom_host->draw_indexed(modus_doom_host->ctx, I_VideoBuffer, modus_palette_bgra);
  }
  DG_DrawFrame();
}

void I_ReadScreen(byte *scr) {
  memcpy(scr, I_VideoBuffer, SCREENWIDTH * SCREENHEIGHT);
}

void I_SetPalette(byte *palette) {
  for (int i = 0; i < 256; i++) {
    uint8_t r = gammatable[usegamma][*palette++];
    uint8_t g = gammatable[usegamma][*palette++];
    uint8_t b = gammatable[usegamma][*palette++];
    modus_palette_r[i] = r;
    modus_palette_g[i] = g;
    modus_palette_b[i] = b;
    modus_palette_bgra[i] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
  }
}

int I_GetPaletteIndex(int r, int g, int b) {
  int best = 0;
  int best_diff = INT_MAX;
  for (int i = 0; i < 256; i++) {
    int dr = r - (int)modus_palette_r[i];
    int dg = g - (int)modus_palette_g[i];
    int db = b - (int)modus_palette_b[i];
    int diff = dr * dr + dg * dg + db * db;
    if (diff < best_diff) {
      best = i;
      best_diff = diff;
      if (diff == 0) {
        break;
      }
    }
  }
  return best;
}

void I_BeginRead(void) {}
void I_EndRead(void) {}

void I_SetWindowTitle(char *title) {
  DG_SetWindowTitle(title);
}

void I_GraphicsCheckCommandLine(void) {}
void I_SetGrabMouseCallback(grabmouse_callback_t func) { (void)func; }
void I_EnableLoadingDisk(void) {}
void I_BindVideoVariables(void) {}
void I_DisplayFPSDots(boolean dots_on) { (void)dots_on; }
void I_CheckIsScreensaver(void) {}
