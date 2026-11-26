// Modus sound module for doomgeneric: forwards DMX SFX lumps to Odin's 48 kHz
// stereo timed_stream mixer when a sound device is present, and stays silent
// when absent.
#include <stdio.h>
#include <string.h>
#include <modus_doom_host.h>

#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"

static snddevice_t modus_sound_devices[] = {
  SNDDEVICE_SB,
  SNDDEVICE_PAS,
  SNDDEVICE_GUS,
  SNDDEVICE_WAVEBLASTER,
  SNDDEVICE_SOUNDCANVAS,
  SNDDEVICE_AWE32,
};

static boolean modus_sfx_use_prefix = true;

static boolean modus_sfx_init(boolean use_sfx_prefix) {
  modus_sfx_use_prefix = use_sfx_prefix;
  if (!modus_doom_host || !modus_doom_host->sound_available) {
    return false;
  }
  return modus_doom_host->sound_available(modus_doom_host->ctx) != 0;
}

static void modus_sfx_shutdown(void) {
}

static int modus_sfx_get_lump_num(sfxinfo_t *sfxinfo) {
  char namebuf[16];
  if (sfxinfo->link != NULL) {
    sfxinfo = sfxinfo->link;
  }
  if (modus_sfx_use_prefix) {
    snprintf(namebuf, sizeof(namebuf), "ds%s", sfxinfo->name);
  } else {
    snprintf(namebuf, sizeof(namebuf), "%s", sfxinfo->name);
  }
  return W_CheckNumForName(namebuf);
}

static void modus_sfx_update(void) {
  if (modus_doom_host && modus_doom_host->sound_mix_tic) {
    modus_doom_host->sound_mix_tic(modus_doom_host->ctx);
  }
}

static void modus_sfx_update_params(int channel, int vol, int sep) {
  if (modus_doom_host && modus_doom_host->sound_update_params) {
    modus_doom_host->sound_update_params(modus_doom_host->ctx, channel, vol, sep);
  }
}

static int modus_sfx_start_sound(sfxinfo_t *sfxinfo, int channel, int vol, int sep) {
  if (!modus_doom_host || !modus_doom_host->sound_start || !sfxinfo) {
    return -1;
  }
  if (sfxinfo->lumpnum < 0) {
    return -1;
  }
  int lump_len = W_LumpLength(sfxinfo->lumpnum);
  if (lump_len <= 8) {
    return -1;
  }
  const uint8_t *lump_data = (const uint8_t *)W_CacheLumpNum(sfxinfo->lumpnum, PU_STATIC);
  if (!lump_data) {
    return -1;
  }
  return modus_doom_host->sound_start(modus_doom_host->ctx, channel, lump_data, (size_t)lump_len, vol, sep);
}

static void modus_sfx_stop_sound(int channel) {
  if (modus_doom_host && modus_doom_host->sound_stop) {
    modus_doom_host->sound_stop(modus_doom_host->ctx, channel);
  }
}

static boolean modus_sfx_is_playing(int channel) {
  if (!modus_doom_host || !modus_doom_host->sound_is_playing) {
    return false;
  }
  return modus_doom_host->sound_is_playing(modus_doom_host->ctx, channel) != 0;
}

static void modus_sfx_cache_sounds(sfxinfo_t *sounds, int num_sounds) {
  (void)sounds;
  (void)num_sounds;
}

sound_module_t DG_sound_module = {
  modus_sound_devices,
  sizeof(modus_sound_devices) / sizeof(modus_sound_devices[0]),
  modus_sfx_init,
  modus_sfx_shutdown,
  modus_sfx_get_lump_num,
  modus_sfx_update,
  modus_sfx_update_params,
  modus_sfx_start_sound,
  modus_sfx_stop_sound,
  modus_sfx_is_playing,
  modus_sfx_cache_sounds,
};

// Silent music module stub: no MIDI/OPL synthesizer is wired in this phase.
static boolean modus_music_init(void) { return false; }
static void modus_music_shutdown(void) {}
static void modus_music_set_volume(int volume) { (void)volume; }
static void modus_music_pause(void) {}
static void modus_music_resume(void) {}
static void *modus_music_register(void *data, int len) { (void)data; (void)len; return NULL; }
static void modus_music_unregister(void *handle) { (void)handle; }
static void modus_music_play(void *handle, boolean looping) { (void)handle; (void)looping; }
static void modus_music_stop(void) {}
static boolean modus_music_is_playing(void) { return false; }
static void modus_music_poll(void) {}

music_module_t DG_music_module = {
  modus_sound_devices,
  sizeof(modus_sound_devices) / sizeof(modus_sound_devices[0]),
  modus_music_init,
  modus_music_shutdown,
  modus_music_set_volume,
  modus_music_pause,
  modus_music_resume,
  modus_music_register,
  modus_music_unregister,
  modus_music_play,
  modus_music_stop,
  modus_music_is_playing,
  modus_music_poll,
};
