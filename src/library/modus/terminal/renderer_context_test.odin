#+build !freestanding
package terminal_records

import "core:testing"
import op "modus:contract/operation"
import "modus:system"

// The context of serial_terminal: the ports with no right in the slot of
// the device, no input ring, no screen value; each slot once. A slot that
// the caller took already is refused, and its handle stays.
@(test)
renderer_context_of_serial_terminal_takes_each_place_once :: proc(t: ^testing.T) {
	handles := Renderer_Handles{device = {handle = 21}, ring = 22, text = 23, writer = 24, log = {handle = 25, rights = {.Write}}}
	name := system.name_pack("console")
	taken: system.Context_Grants
	taken_values: system.Context_Values
	system.grant_put(&taken, GRANT_DEVICE, {handle = 99, rights = {.Read}})
	renderer_context_of(&taken, &taken_values, handles, name, 96, 26, {})
	testing.expect_value(t, taken.refusal, system.Context_Refusal{refused = true, place = GRANT_DEVICE})
	testing.expect_value(t, taken.grants[GRANT_DEVICE].handle, system.Handle(99))

	grants: system.Context_Grants
	values: system.Context_Values
	renderer_context_of(&grants, &values, handles, name, 96, 26, {})
	_, _, refused := system.context_refusal_of(&grants, &values)
	testing.expect(t, !refused)
	testing.expect_value(t, grants.grants[GRANT_DEVICE], system.Grant{handle = 21})
	testing.expect_value(t, grants.grants[GRANT_RING], system.Grant{handle = 22, rights = {.Read, .Write}})
	testing.expect_value(t, grants.grants[GRANT_TEXT], system.Grant{handle = 23, rights = {.Read}})
	testing.expect_value(t, grants.grants[GRANT_PROCESS], system.Grant{handle = 24, rights = {.Read}})
	testing.expect_value(t, grants.taken, bit_set[0 ..< op.CONTEXT_HANDLES; u32]{GRANT_DEVICE, GRANT_RING, GRANT_TEXT, GRANT_PROCESS, op.CONTEXT_LOG})
	testing.expect_value(t, values.values[VALUE_COLUMNS], u64(96))
	testing.expect_value(t, values.values[VALUE_ROWS], u64(26))
	testing.expect_value(t, values.values[VALUE_SCREEN_WIDTH], u64(0))
	testing.expect_value(t, values.values[VALUE_SCREEN_PIXELS_PER_LINE], u64(0))
}

// The context of grid_terminal: the framebuffer, the input ring and the
// size of the framebuffer. The slots of the renderer never meet the slots
// of the terminal, and the values of the screen never meet the seed.
@(test)
renderer_context_of_grid_terminal_holds_the_screen_and_the_input :: proc(t: ^testing.T) {
	handles := Renderer_Handles{device = {handle = 31, rights = {.Read, .Write}}, input = {handle = 32, rights = {.Read, .Write}}, ring = 33, text = 34, writer = 35, log = {handle = 36, rights = {.Write}}}
	grants: system.Context_Grants
	values: system.Context_Values
	renderer_context_of(&grants, &values, handles, system.name_pack("console"), 80, 25, {width = 1280, height = 800, pixels_per_line = 1280})
	_, _, refused := system.context_refusal_of(&grants, &values)
	testing.expect(t, !refused)
	testing.expect_value(t, grants.grants[GRANT_INPUT], system.Grant{handle = 32, rights = {.Read, .Write}})
	testing.expect_value(t, values.values[VALUE_SCREEN_WIDTH], u64(1280))
	testing.expect_value(t, values.values[VALUE_SCREEN_HEIGHT], u64(800))
	testing.expect_value(t, values.values[VALUE_SCREEN_PIXELS_PER_LINE], u64(1280))
	places := [?]int{GRANT_DEVICE, GRANT_INPUT, GRANT_RING, GRANT_TEXT, GRANT_PROCESS, op.CONTEXT_LOG}
	for place, index in places {
		for other in places[index + 1:] {
			testing.expectf(t, place != other, "the slot %d is taken twice", place)
		}
	}
	for value in ([?]int{VALUE_SCREEN_WIDTH, VALUE_SCREEN_HEIGHT, VALUE_SCREEN_PIXELS_PER_LINE}) {
		testing.expectf(t, value < op.CONTEXT_VALUE_SEED || value >= op.CONTEXT_VALUE_SEED + op.CONTEXT_VALUE_SEED_COUNT, "the value %d is a value of the seed", value)
		testing.expectf(t, value > VALUE_MEASURE, "the value %d is a value of the terminal", value)
	}
}
