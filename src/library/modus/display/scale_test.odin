#+build !freestanding
package display

import "core:testing"
import "modus:contract/scale_factor"
import "modus:contract/settings"

// With no settings page, and with a page that read refuses (the all-zero
// page, whose scale word 0 names no scale), the scale of a new surface is
// the default, never the zero of the type. A page with a scale gives it.
@(test)
the_scale_in_force_of_a_page :: proc(t: ^testing.T) {
	saved := settings_page
	defer settings_page = saved
	settings_page = nil
	testing.expect_value(t, scale_in_force(), scale_factor.DEFAULT)
	page: settings.Page
	settings_page = &page
	testing.expect_value(t, scale_in_force(), scale_factor.DEFAULT)
	page.change_count = 1 // A writer left in its change.
	testing.expect_value(t, scale_in_force(), scale_factor.DEFAULT)
	page = {}
	choice := settings.choice_default()
	choice.scale = .Eleven_Eighths
	settings.write(&page, choice, 0, .Dark)
	testing.expect_value(t, scale_in_force(), scale_factor.Scale.Eleven_Eighths)
	// The ends of the range are taken; a word one past each end is refused
	// with the page.
	for scale in ([?]scale_factor.Scale{.Eight_Eighths, .Sixteen_Eighths}) {
		choice.scale = scale
		settings.write(&page, choice, 0, .Dark)
		testing.expect_value(t, scale_in_force(), scale)
	}
	for word in ([?]u32{scale_factor.EIGHTHS_OF_ONE - 1, u32(scale_factor.Scale.Sixteen_Eighths) + 1}) {
		page.values[settings.Setting.Scale] = word
		testing.expect_value(t, scale_in_force(), scale_factor.DEFAULT)
	}
}

// The size of a surface: a logical size at a scale, by the rule of each
// edge; 1 logical pixel is at least 1 pixel of the screen, and the largest
// logical size at the largest scale is SURFACE_SCREEN_LIMIT.
@(test)
the_size_of_a_surface :: proc(t: ^testing.T) {
	width, height := surface_size_of(560, 592, .Ten_Eighths)
	testing.expect_value(t, width, 700)
	testing.expect_value(t, height, 740)
	width, height = surface_size_of(1, 1, .Ten_Eighths)
	testing.expect_value(t, width, 1)
	testing.expect_value(t, height, 1)
	largest_width, largest_height := surface_size_of(SURFACE_LIMIT, SURFACE_LIMIT, scale_factor.LARGEST)
	testing.expect_value(t, largest_width, SURFACE_SCREEN_LIMIT)
	testing.expect_value(t, largest_height, SURFACE_SCREEN_LIMIT)
}

@(private = "file")
steady_at :: proc(scale: scale_factor.Scale, serial: u64) -> Rescale_Machine {
	return {phase = .Steady, scale = scale, wanted = scale, serial = serial}
}

// The sequence of one change: the release, the offer of the next serial at
// the scale named, the answer taken. An answer of another serial changes
// nothing at each step, and the same scale named again changes nothing.
@(test)
one_change_of_the_scale :: proc(t: ^testing.T) {
	machine := steady_at(.Ten_Eighths, 4)
	action, refused := rescale_step(&machine, {kind = .Scale_Named, scale = .Ten_Eighths})
	testing.expect(t, action == .None && !refused && machine.phase == .Steady)
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	testing.expect_value(t, action, Rescale_Action.Release)
	testing.expect_value(t, machine.phase, Rescale_Phase.Releasing)
	testing.expect(t, !rescale_draws(&machine))
	// Answers of other serials: older requests.
	for serial in ([?]u64{0, 3, 5, max(u64)}) {
		before := machine
		stale, _ := rescale_step(&machine, {kind = .Released, serial = serial})
		testing.expect(t, stale == .None && machine == before)
		_, _ = rescale_step(&machine, {kind = .Taken, serial = serial})
		_, _ = rescale_step(&machine, {kind = .Refused, serial = serial})
		testing.expect(t, machine == before)
	}
	action, _ = rescale_step(&machine, {kind = .Released, serial = 4})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Offered, scale = .Eleven_Eighths, wanted = .Eleven_Eighths, serial = 5})
	testing.expect(t, rescale_draws(&machine))
	// A Released again, of the old serial, changes nothing now.
	before := machine
	_, _ = rescale_step(&machine, {kind = .Released, serial = 4})
	testing.expect(t, machine == before)
	action, refused = rescale_step(&machine, {kind = .Taken, serial = 5})
	testing.expect(t, action == .None && !refused)
	testing.expect_value(t, machine, steady_at(.Eleven_Eighths, 5))
}

// Two changes before a Present: the second scale named while the window
// releases, and a third while it offers. The window follows the newest
// scale once the answer of its request came, and never sends a second
// request before an answer.
@(test)
two_changes_before_a_present :: proc(t: ^testing.T) {
	machine := steady_at(.Ten_Eighths, 1)
	action, _ := rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	testing.expect_value(t, action, Rescale_Action.Release)
	// Back to 1.25 while the release waits: no second release.
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Ten_Eighths})
	testing.expect_value(t, action, Rescale_Action.None)
	testing.expect_value(t, machine.phase, Rescale_Phase.Releasing)
	// The released surface: the offer is at the scale wanted now, 1.25.
	action, _ = rescale_step(&machine, {kind = .Released, serial = 1})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine.scale, scale_factor.Scale.Ten_Eighths)
	testing.expect_value(t, machine.serial, 2)
	// 1.375 again while the offer waits: no second offer before the answer.
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	testing.expect_value(t, action, Rescale_Action.None)
	// The offer is taken; the scale wanted differs: a release at once.
	action, _ = rescale_step(&machine, {kind = .Taken, serial = 2})
	testing.expect_value(t, action, Rescale_Action.Release)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Releasing, scale = .Ten_Eighths, wanted = .Eleven_Eighths, serial = 2})
}

// A change between an accepted rescale and its Present: the window is
// Steady at the offered scale, and the next scale gives a release of that
// serial, which the compositor holds pending; it answers Released for it.
@(test)
a_change_between_a_taken_rescale_and_its_present :: proc(t: ^testing.T) {
	machine := Rescale_Machine{phase = .Offered, scale = .Eleven_Eighths, wanted = .Eleven_Eighths, serial = 2}
	action, _ := rescale_step(&machine, {kind = .Taken, serial = 2})
	testing.expect_value(t, action, Rescale_Action.None)
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Ten_Eighths})
	testing.expect_value(t, action, Rescale_Action.Release)
	testing.expect_value(t, machine.serial, 2)
	action, _ = rescale_step(&machine, {kind = .Released, serial = 2})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Offered, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 3})
}

// The window and the compositor read different scales: the window offers
// the scale that the compositor named before, the compositor has moved on
// and refuses it, and names its new scale. The refusal is told, the window
// waits with no surface, and the scale named makes the next offer. A
// refusal whose scale wanted already differs offers again at once. The
// window never stays with no surface and no request.
@(test)
the_window_and_the_compositor_at_two_scales :: proc(t: ^testing.T) {
	machine := Rescale_Machine{phase = .Offered, scale = .Eleven_Eighths, wanted = .Eleven_Eighths, serial = 3}
	action, refused := rescale_step(&machine, {kind = .Refused, serial = 3})
	testing.expect(t, refused && action == .None)
	testing.expect_value(t, machine.phase, Rescale_Phase.Released)
	testing.expect(t, !rescale_draws(&machine))
	action, refused = rescale_step(&machine, {kind = .Scale_Named, scale = .Ten_Eighths})
	testing.expect(t, action == .Offer && !refused)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Offered, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 4})
	// The scale named arrives before the refusal of the older offer.
	_, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	action, refused = rescale_step(&machine, {kind = .Refused, serial = 4})
	testing.expect(t, refused && action == .Offer)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Offered, scale = .Eleven_Eighths, wanted = .Eleven_Eighths, serial = 5})
	// The same scale named again in Released offers again: the compositor
	// names a scale only at a change of its own or to a new surface.
	machine = Rescale_Machine{phase = .Released, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 6}
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Ten_Eighths})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine.serial, 7)
}

// The picture that a window owes. No picture is owed in the phases with no
// surface to draw, whatever serial was presented, nor after a Present of
// the serial of the machine. A picture is owed for the first surface before
// its first Present, for a taken rescale before the Present of its serial
// (the window that froze), for an offered surface and a resize, and after
// a refused resize, whose surface before it must be drawn again.
@(test)
the_picture_that_a_window_owes :: proc(t: ^testing.T) {
	for phase in ([?]Rescale_Phase{.Releasing, .Released}) {
		for presented in ([?]u64{0, 4, 5, max(u64)}) {
			testing.expectf(t, !picture_owed_of({phase = phase, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 5}, presented), "a picture is owed in %v", phase)
		}
	}
	for phase in ([?]Rescale_Phase{.Steady, .Offered, .Resizing}) {
		testing.expect(t, !picture_owed_of({phase = phase, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 5}, 5))
	}
	testing.expect(t, picture_owed_of({phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 1}, 0))
	// The sequence of a change of the scale: the taken offer is Steady at
	// the new serial, and owes its picture until a Present names it.
	machine := Rescale_Machine{phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 1}
	presented: u64 = 1
	_, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	testing.expect(t, !picture_owed_of(machine, presented))
	_, _ = rescale_step(&machine, {kind = .Released, serial = 1})
	testing.expect(t, picture_owed_of(machine, presented))
	_, _ = rescale_step(&machine, {kind = .Taken, serial = 2})
	testing.expect_value(t, machine.phase, Rescale_Phase.Steady)
	testing.expect(t, picture_owed_of(machine, presented))
	presented = machine.serial
	testing.expect(t, !picture_owed_of(machine, presented))
	// A refused resize: the window drew the new surface, and owes a
	// picture of the surface before it.
	_, _ = rescale_step(&machine, {kind = .Resize_Offered})
	testing.expect(t, picture_owed_of(machine, presented))
	presented = machine.serial
	_, _ = rescale_step(&machine, {kind = .Resize_Refused, serial = 3})
	testing.expect(t, picture_owed_of(machine, presented))
}

// The answers of a resize. Refusals first: an answer of a resize in each
// phase that is not Resizing, and of another serial, changes nothing and
// ends no resize; a resize offered outside Steady takes no serial. Then the
// refused resize: the window is Steady again at the serial that the
// compositor shows, draws the surface before it, and tells it. Then a scale
// named during the resize: no release before the answer, one release after
// it, of the serial that the compositor then holds. The taken resize last.
@(test)
the_answers_of_a_resize :: proc(t: ^testing.T) {
	for phase in ([?]Rescale_Phase{.Steady, .Releasing, .Released, .Offered}) {
		machine := Rescale_Machine{phase = phase, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 3}
		for kind in ([?]Rescale_Input_Kind{.Resize_Taken, .Resize_Refused}) {
			before := machine
			input := Rescale_Input{kind = kind, serial = 3}
			testing.expect_value(t, resize_end_of(before, input), Resize_End.None)
			action, refused := rescale_step(&machine, input)
			testing.expectf(t, action == .None && !refused && machine == before, "a resize answer in %v changed the machine", phase)
		}
		if phase != .Steady {
			before := machine
			_, _ = rescale_step(&machine, {kind = .Resize_Offered})
			testing.expectf(t, machine == before, "a resize offered in %v took a serial", phase)
		}
	}
	machine := Rescale_Machine{phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 3}
	_, _ = rescale_step(&machine, {kind = .Resize_Offered})
	testing.expect_value(t, machine, Rescale_Machine{phase = .Resizing, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 4})
	testing.expect(t, rescale_draws(&machine))
	for serial in ([?]u64{0, 3, 5, max(u64)}) {
		before := machine
		input := Rescale_Input{kind = .Resize_Refused, serial = serial}
		testing.expect_value(t, resize_end_of(before, input), Resize_End.None)
		_, _ = rescale_step(&machine, input)
		testing.expect(t, machine == before)
	}
	// The answers of a rescale change nothing in Resizing.
	for kind in ([?]Rescale_Input_Kind{.Released, .Taken, .Refused}) {
		before := machine
		_, _ = rescale_step(&machine, {kind = kind, serial = 4})
		testing.expect(t, machine == before)
	}
	refused_input := Rescale_Input{kind = .Resize_Refused, serial = 4}
	testing.expect_value(t, resize_end_of(machine, refused_input), Resize_End.Back_To_Shown)
	action, refused := rescale_step(&machine, refused_input)
	testing.expect(t, action == .None && refused)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 3})

	// A scale named during the resize waits for the answer.
	_, _ = rescale_step(&machine, {kind = .Resize_Offered})
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Eleven_Eighths})
	testing.expect_value(t, action, Rescale_Action.None)
	testing.expect_value(t, machine.phase, Rescale_Phase.Resizing)
	taken_input := Rescale_Input{kind = .Resize_Taken, serial = 4}
	testing.expect_value(t, resize_end_of(machine, taken_input), Resize_End.Keep_New)
	action, refused = rescale_step(&machine, taken_input)
	testing.expect(t, action == .Release && !refused)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Releasing, scale = .Ten_Eighths, wanted = .Eleven_Eighths, serial = 4})

	// A refused resize with a scale named: the release of the serial shown.
	machine = Rescale_Machine{phase = .Resizing, scale = .Ten_Eighths, wanted = .Eleven_Eighths, serial = 8}
	action, refused = rescale_step(&machine, {kind = .Resize_Refused, serial = 8})
	testing.expect(t, action == .Release && refused)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Releasing, scale = .Ten_Eighths, wanted = .Eleven_Eighths, serial = 7})

	// The taken resize.
	machine = Rescale_Machine{phase = .Resizing, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 2}
	action, refused = rescale_step(&machine, {kind = .Resize_Taken, serial = 2})
	testing.expect(t, action == .None && !refused)
	testing.expect_value(t, machine, Rescale_Machine{phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 2})
}
// A decline: the budget did not pay the offer. The machine leaves Offered
// for Released with the serial of the offer, draws nothing, ignores a
// Scale_Named of the declined scale, and at another scale offers the serial
// after it. A decline in another phase changes nothing.
@(test)
a_declined_scale_waits_for_another_scale :: proc(t: ^testing.T) {
	machine := Rescale_Machine{phase = .Steady, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 3}
	action, _ := rescale_step(&machine, {kind = .Scale_Named, scale = .Sixteen_Eighths})
	testing.expect_value(t, action, Rescale_Action.Release)
	action, _ = rescale_step(&machine, {kind = .Released, serial = 3})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine.serial, 4)
	rescale_declined_step(&machine)
	testing.expect_value(t, machine.phase, Rescale_Phase.Released)
	testing.expect_value(t, machine.serial, 4)
	testing.expect(t, !rescale_draws(&machine))
	testing.expect(t, !picture_owed_of(machine, 3))
	// An answer of the offer that was never sent changes nothing.
	action, _ = rescale_step(&machine, {kind = .Refused, serial = 4})
	testing.expect_value(t, action, Rescale_Action.None)
	testing.expect_value(t, machine.phase, Rescale_Phase.Released)
	// The declined scale named again, as each change of another setting
	// names it: no offer, the machine stays as it is.
	declined := machine
	for _ in 0 ..< 3 {
		action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Sixteen_Eighths})
		testing.expect_value(t, action, Rescale_Action.None)
		testing.expect_value(t, machine, declined)
	}
	// Another scale: the offer of the next serial.
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Twelve_Eighths})
	testing.expect_value(t, action, Rescale_Action.Offer)
	testing.expect_value(t, machine.serial, 5)
	testing.expect_value(t, machine.scale, scale_factor.Scale.Twelve_Eighths)
	testing.expect(t, !machine.declined)
	// Back to the declined scale after the other one: an offer again, as
	// the budget may pay it now.
	_, _ = rescale_step(&machine, {kind = .Taken, serial = 5})
	action, _ = rescale_step(&machine, {kind = .Scale_Named, scale = .Sixteen_Eighths})
	testing.expect_value(t, action, Rescale_Action.Release)
	for phase in ([?]Rescale_Phase{.Steady, .Releasing, .Released, .Resizing}) {
		other := Rescale_Machine{phase = phase, scale = .Ten_Eighths, wanted = .Ten_Eighths, serial = 7}
		before := other
		rescale_declined_step(&other)
		testing.expectf(t, other == before, "a decline in %v changed the machine", phase)
	}
}
