// Bridge contract between the Odin Doom module and freestanding doomgeneric C code.
// Every field is 8-byte aligned so Odin and C struct layouts match with zero padding.
#ifndef MODUS_DOOM_HOST_H
#define MODUS_DOOM_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void *Modus_Alloc_Proc(void *ctx, size_t size, size_t alignment);
typedef void  Modus_Log_Proc(void *ctx, const char *text, size_t length);
typedef void  Modus_Draw_Indexed_Proc(void *ctx, const uint8_t *pixels, const uint32_t *palette_bgra);
typedef uint32_t Modus_Ticks_Ms_Proc(void *ctx);
typedef void  Modus_Sleep_Ms_Proc(void *ctx, uint32_t ms);
typedef int   Modus_Poll_Key_Proc(void *ctx, int *pressed, uint8_t *doom_key);
typedef int   Modus_Poll_Mouse_Proc(void *ctx, int *buttons, int *dx, int *dy);
typedef void  Modus_Set_Title_Proc(void *ctx, const char *title);
typedef int   Modus_Save_Read_Proc(void *ctx, const char *name, uint8_t *buffer, size_t capacity, size_t *out_size);
typedef int   Modus_Save_Write_Proc(void *ctx, const char *name, const uint8_t *buffer, size_t size);
typedef int   Modus_Save_Remove_Proc(void *ctx, const char *name);
typedef int   Modus_Sound_Available_Proc(void *ctx);
typedef int   Modus_Sound_Start_Proc(void *ctx, int channel, const uint8_t *dmx_data, size_t dmx_len, int vol, int sep);
typedef void  Modus_Sound_Update_Params_Proc(void *ctx, int channel, int vol, int sep);
typedef void  Modus_Sound_Stop_Proc(void *ctx, int channel);
typedef int   Modus_Sound_Is_Playing_Proc(void *ctx, int channel);
typedef void  Modus_Sound_Mix_Tic_Proc(void *ctx);

typedef struct {
  Modus_Alloc_Proc               *alloc;
  Modus_Log_Proc                 *log_line;
  Modus_Draw_Indexed_Proc        *draw_indexed;
  Modus_Ticks_Ms_Proc            *ticks_ms;
  Modus_Sleep_Ms_Proc            *sleep_ms;
  Modus_Poll_Key_Proc            *poll_key;
  Modus_Poll_Mouse_Proc          *poll_mouse;
  Modus_Set_Title_Proc           *set_title;
  const uint8_t                  *wad_bytes;
  size_t                          wad_size;
  const char                     *wad_name;
  Modus_Save_Read_Proc           *save_read;
  Modus_Save_Write_Proc          *save_write;
  Modus_Save_Remove_Proc         *save_remove;
  Modus_Sound_Available_Proc     *sound_available;
  Modus_Sound_Start_Proc         *sound_start;
  Modus_Sound_Update_Params_Proc *sound_update_params;
  Modus_Sound_Stop_Proc          *sound_stop;
  Modus_Sound_Is_Playing_Proc    *sound_is_playing;
  Modus_Sound_Mix_Tic_Proc       *sound_mix_tic;
  void                           *ctx;
} Modus_Doom_Host;

// Result codes returned across the C/Odin boundary.
enum {
  MODUS_DOOM_OK    = 0,
  MODUS_DOOM_QUIT  = 1,
  MODUS_DOOM_ERROR = 2,
};

extern const Modus_Doom_Host *modus_doom_host;

// Freestanding thin libc internal hooks.
void modus_libc_init(const Modus_Doom_Host *host);
void modus_libc_flush_log(void);

#define MODUS_JUMP_BUFFER_WORDS 8
extern void *modus_exit_jump_buffer[MODUS_JUMP_BUFFER_WORDS];
extern bool  modus_exit_jump_ready;
extern int   modus_exit_status;

// C entry points called from Odin.
int modus_doom_init(const Modus_Doom_Host *host);
int modus_doom_tick(void);

#endif
