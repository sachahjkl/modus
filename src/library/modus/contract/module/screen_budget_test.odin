#+build !freestanding
package module

import "core:testing"

// The screen pictures of a request: a count past the limit and a screen
// past the bound of a side are refused; then the pages of 1080p, 1440p, 4K
// and 8K are added, a plan row lowers them and never raises them, and a
// request with no picture gains nothing.
@(test)
screen_pictures_follow_the_screen_and_a_plan_lowers_them :: proc(t: ^testing.T) {
	_, past := budget_request_of_screen({pages = 100, screen_pictures = SCREEN_PICTURES_LIMIT + 1}, 1920, 1080)
	testing.expect(t, !past, "a request past the limit of screen pictures was taken")
	_, huge := budget_request_of_screen({pages = 100, screen_pictures = 1}, (1 << 20) + 1, 1)
	testing.expect(t, !huge, "a screen past the bound of a side was taken")
	_, wraps := budget_request_of_screen({pages = max(u64) - 10, screen_pictures = 1}, 1920, 1080)
	testing.expect(t, !wraps, "a sum past 64 bits was taken")
	screens := [?]struct {
		width, height, pages: u64,
	}{{1920, 1080, 2025}, {2560, 1440, 3600}, {3840, 2160, 8100}, {5120, 2880, 14400}, {7680, 4320, 32400}}
	for screen in screens {
		testing.expect_value(t, screen_picture_pages(screen.width, screen.height), screen.pages)
		with, ok := budget_request_of_screen({pages = 500, processes = 1, threads = 1, screen_pictures = 3}, screen.width, screen.height)
		testing.expect(t, ok && with.pages == 500 + 3 * screen.pages && with.screen_pictures == 0 && with.threads == 1)
		lowered, lowered_ok := budget_request_of_screen({pages = 500, screen_pictures = 3}, screen.width, screen.height, 1000)
		testing.expect(t, lowered_ok && lowered.pages == 1500)
		above, above_ok := budget_request_of_screen({pages = 500, screen_pictures = 3}, screen.width, screen.height, 10 * 32400)
		testing.expect(t, above_ok && above.pages == 500 + 3 * screen.pages, "a plan row raised the pages of the screen")
	}
	none, none_ok := budget_request_of_screen({pages = 700}, 7680, 4320)
	testing.expect(t, none_ok && none.pages == 700)
}
