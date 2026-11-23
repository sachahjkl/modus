package machine

import "core:testing"

// The report of a pixel lands on that pixel at each edge of the logical
// screen of the machines, and the report before it lands before the pixel:
// it is the smallest. A pixel outside the screen, a negative one and an
// extent past the axis give none.
@(test)
a_report_of_the_tablet_lands_on_its_pixel :: proc(t: ^testing.T) {
	extents := [2]int{LOGICAL_SCREEN_WIDTH, LOGICAL_SCREEN_HEIGHT}
	for extent in extents {
		for pixel in ([?]int{0, 1, extent / 2, extent - 2, extent - 1}) {
			report, ok := tablet_report_of_pixel(pixel, extent)
			testing.expectf(t, ok, "the pixel %d of %d has no report", pixel, extent)
			landed, landed_ok := tablet_pixel_of_report(report, extent)
			testing.expect(t, landed_ok && landed == pixel)
			if report > 0 {
				before, before_ok := tablet_pixel_of_report(report - 1, extent)
				testing.expect(t, before_ok && before < pixel)
			}
		}
		for pixel in ([?]int{-1, extent, extent + 1, max(int)}) {
			_, ok := tablet_report_of_pixel(pixel, extent)
			testing.expectf(t, !ok, "the pixel %d of %d has a report", pixel, extent)
		}
	}
	_, ok := tablet_report_of_pixel(0, TABLET_AXIS_MAXIMUM + 1)
	testing.expect(t, !ok)
	_, ok = tablet_report_of_pixel(0, 0)
	testing.expect(t, !ok)
	_, ok = tablet_pixel_of_report(-1, 100)
	testing.expect(t, !ok)
	_, ok = tablet_pixel_of_report(TABLET_AXIS_MAXIMUM + 1, 100)
	testing.expect(t, !ok)
	last, last_ok := tablet_pixel_of_report(TABLET_AXIS_MAXIMUM, LOGICAL_SCREEN_WIDTH)
	testing.expect(t, last_ok && last == LOGICAL_SCREEN_WIDTH - 1)
}

// The command carries the place and the button in one list of events.
@(test)
a_click_of_the_tablet_is_one_command :: proc(t: ^testing.T) {
	testing.expect_value(t, qmp_tablet_click_command(10, 20, true), "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":10}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":20}},{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"left\"}}]}}")
}
