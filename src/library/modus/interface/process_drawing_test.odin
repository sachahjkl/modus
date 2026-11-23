#+build !freestanding
package interface

import "core:sync"

// The drawing state of a process is one for each process: the blend
// tables and the faces of its text state (graphics.text_state), and the
// private glyph cache of its copy of the text rendering, which counts its
// use in frames and evicts the glyphs of older frames. So one thread of a
// process draws at a time (src/md/features/glyphs_on_demand.md, "Subtle
// points"). The test runner runs the tests on several threads of one
// process: each test that draws a text, changes the text state, or
// presents (display.present starts a frame of the glyph cache) holds this
// lock from its first draw to its last check. A test that presented with
// no lock started frames of the cache while a test of the interface font
// drew: glyphs of its frame were evicted under it, and a frame drawn in
// its damage differed from the frame drawn whole in 1 to 9 of 200.
process_drawing_lock: sync.Mutex

// process_drawing_begin fills the table of the blend first, through
// blend_table, and holds the lock to the end of the scope of its caller.
@(deferred_none = process_drawing_end)
process_drawing_begin :: proc() {
	_ = blend_table()
	sync.mutex_lock(&process_drawing_lock)
}

process_drawing_end :: proc() {
	sync.mutex_unlock(&process_drawing_lock)
}
