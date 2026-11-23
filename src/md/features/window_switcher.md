# The window switcher

Alt+Tab is the way of the keyboard to the window used before. The compositor holds it: the keys never reach a window while the card of the switcher is open.

## Purpose

A principal who works in two windows goes from one to the other many times. The palette reaches each window by its name, and the menu of the windows by a press, but neither is one key from the hand that types. Each other desktop has Alt+Tab, and the hand knows it.

## Constraints

- The keys of a window stay the keys of the window: only Alt+Tab, Alt+Shift+Tab and the keys pressed while the card is open are the compositor's.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface": no new operation; the compositor already has the input and the order of the windows.

## The chosen form

- **The order of use is the order of the windows from back to front.** Each window that comes to the front goes to the end of `order`, so the order from the front is the order of use. A minimized window goes to the back, as the keys leave it.
- **The left Alt is a modifier.** The input service sets `display.MODIFIER_ALT` while the left Alt key is down; the right Alt key stays AltGr, which changes the character and sets no bit. A window that ignores the bit sees its keys as before.
- **The keys.** Alt+Tab opens the card and chooses the window behind the one in front; each Tab while Alt is down chooses the next one, from the last back to the first; Alt+Shift+Tab chooses from the last. The release of Alt brings the chosen window to the front, and restores it if it was minimized. Escape closes the card with no change, as does a press of the pointer. Control+Alt+Tab is not the switcher's.
- **The card** is in the middle of the screen, one line for each window from the front: the module icon and the title, the chosen line on the title blue, a minimized window in the dim color. It shows twelve lines at most, and moves with the choice.
- **The card keeps its windows.** At its open it copies the client index of each window from the front: a line names a window, never a place in the order. A window that opens or closes closes the card with no change, as a dialog of the trusted display or a menu that opens.
- **The card holds the keys while it is open**: it has each key before the dialogs and the menus, and it does not open over them. Control+Shift+Escape, the revocation of a wide grant, is the one key that it never holds: the card closes, and the key goes on to the revocation.
- **The rules are pure** (`bar.switcher_key` in `src/library/internal/compositor/bar`, with host tests); the compositor keeps the state, draws the card and raises the window (`window_switcher.odin`).

## The refused forms

- **Super+Tab or Control+Alt+Tab as well.** Two combinations for one act; the key Super alone opens the palette.
- **A switch at each Tab, with no card.** The principal does not see where a third Tab lands.
- **A Tab that a window receives while Alt is down.** The window would act on a key that the principal gave to the desktop.
- **The order of the plates of the bar.** It is the order of opening, so that the plates do not move ([desktop_shell_look.md](desktop_shell_look.md)); a switch goes by use.

## Subtle points

- **The press of Alt reaches the window**, as the switcher does not know yet that a Tab will come; its release, when it ends a switch, does not. A window that keeps the state of Alt reads it from the bit of the modifiers of each key, never from the presses alone.
- **A lost release of Alt.** A key pressed with no Alt bit while the card is open ends the switch, as a release would.
- **The Tab released after Alt** goes to no window: the switcher keeps that it took its press.
- **A minimized window gets no key and no pointer event.** With every window minimized, a key goes to none.

## State

Built: the Alt bit of the input service, the switcher with its card, the machine step that switches between two windows. Left: a picture of each window in its line.
