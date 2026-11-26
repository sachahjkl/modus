// Modus input backend for doomgeneric: keyboard and relative pointer events.
#include <stdint.h>
#include <modus_doom_host.h>

#include "doomtype.h"
#include "doomkeys.h"
#include "d_event.h"
#include "d_main.h"
#include "doomgeneric.h"

int vanilla_keyboard_mapping = 1;
static int shift_down = 0;

static const char shift_table[128] = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  ' ', '!', '"', '#', '$', '%', '&', '"', '(', ')', '*', '+', '<', '_', '>', '?',
  ')', '!', '@', '#', '$', '%', '^', '&', '*', '(', ':', ':', '<', '+', '>', '?',
  '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
  'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '[', '!', ']', '"', '_',
  '\'', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
  'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '{', '|', '}', '~', 127
};

static unsigned char typed_char_of(unsigned char key) {
  if (shift_down > 0) {
    return key < 128 ? (unsigned char)shift_table[key] : 0;
  }
  return key;
}

void I_GetEvent(void) {
  event_t event;
  int pressed = 0;
  unsigned char key = 0;

  while (DG_GetKey(&pressed, &key)) {
    if (key == KEY_RSHIFT) {
      shift_down += pressed ? 1 : -1;
      if (shift_down < 0) {
        shift_down = 0;
      }
    }
    if (key == 0) {
      continue;
    }
    event.type = pressed ? ev_keydown : ev_keyup;
    event.data1 = key;
    event.data2 = pressed ? typed_char_of(key) : 0;
    event.data3 = 0;
    D_PostEvent(&event);
  }

  if (modus_doom_host && modus_doom_host->poll_mouse) {
    int buttons = 0;
    int dx = 0;
    int dy = 0;
    while (modus_doom_host->poll_mouse(modus_doom_host->ctx, &buttons, &dx, &dy)) {
      event.type = ev_mouse;
      event.data1 = buttons;
      event.data2 = dx;
      event.data3 = -dy;
      D_PostEvent(&event);
    }
  }
}

void I_InitInput(void) {
  shift_down = 0;
}
