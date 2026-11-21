// Headless virtual framebuffer contract and state model
// (src/md/features/remote_display.md, "The screen of memory").
//
// When a machine has no hardware display, the compositor draws into a screen
// of memory whose initial size comes from the start list and which a remote
// viewer with input authority can resize at the next frame. This contract
// package validates geometry and byte budgets, tracks damage rectangles for
// remote display and agent capture, and applies resize transitions atomically.
//
// This package allocates no memory, calls no kernel operation, and imports
// only other contract packages.
package memory_screen

import "modus:contract/enum_word"
import "modus:contract/reference_screen"

// Pixel format: 32-bit opaque 0x00RRGGBB, matching reference_screen and
// remote_display.
BYTES_PER_PIXEL :: 4
PAGE_SIZE :: 4096

// Minimum and maximum dimensions of a headless memory screen, in pixels.
// The maximum matches the reference screen because the compositor budget and
// window bounds are sized for it.
MIN_WIDTH :: 320
MIN_HEIGHT :: 240
MAX_WIDTH :: reference_screen.WIDTH
MAX_HEIGHT :: reference_screen.HEIGHT

// Maximum framebuffer size in bytes and pages (1920 x 1080 x 4 = 8,294,400 B).
MAX_FRAMEBUFFER_BYTES :: u64(MAX_WIDTH) * u64(MAX_HEIGHT) * BYTES_PER_PIXEL
MAX_FRAMEBUFFER_PAGES :: (MAX_FRAMEBUFFER_BYTES + PAGE_SIZE - 1) / PAGE_SIZE

// Capacity of the damage rectangle list before merging into a bounding box.
DAMAGE_CAPACITY :: 8

// Origin of a memory screen geometry.
Source :: enum u8 {
	None       = 0,
	Start_List = 1,
	Viewer     = 2,
}

// Reason a memory screen geometry or resize transition was refused.
Validation_Error :: enum u8 {
	None              = 0,
	Zero_Dimension    = 1,
	Below_Minimum     = 2,
	Above_Maximum     = 3,
	Stride_Too_Small  = 4,
	Stride_Misaligned = 5,
	Size_Overflow     = 6,
	Over_Byte_Budget  = 7,
	Invalid_Source    = 8,
	Not_Active        = 9,
	Input_Not_Allowed = 10,
}

// Validated geometry of a headless memory framebuffer.
Geometry :: struct {
	width:        u32,
	height:       u32,
	stride_bytes: u32,
	byte_size:    u64,
	page_count:   u64,
}

// Half-open damage rectangle [left, right) x [top, bottom) in screen pixels.
Damage_Rectangle :: struct {
	left:   u32,
	top:    u32,
	right:  u32,
	bottom: u32,
}

// Accumulated damage rectangles awaiting remote display or agent capture.
Damage_Set :: struct {
	rectangles: [DAMAGE_CAPACITY]Damage_Rectangle,
	count:      int,
	merges:     u64,
}

// Viewer-requested resize waiting for the compositor to commit at its next frame.
Pending_Resize :: struct {
	pending:       bool,
	geometry:      Geometry,
	viewer_serial: u64,
}

// Backing state of an active headless memory screen.
Memory_Screen :: struct {
	active:          bool,
	source:          Source,
	generation:      u64,
	byte_budget:     u64,
	geometry:        Geometry,
	damage:          Damage_Set,
	pending_resize:  Pending_Resize,
	resize_commits:  u64,
	resize_refusals: u64,
}

// source_of_word decodes a transport word into Source, refusing None and any
// value that names no member.
source_of_word :: proc "contextless" (word: u64) -> (source: Source, ok: bool) {
	member := enum_word.member_of_word(Source, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// packed_stride gives the tightly packed scanline stride in bytes for width,
// or 0 if width exceeds MAX_WIDTH.
packed_stride :: proc "contextless" (width: u32) -> u32 {
	if width == 0 || width > MAX_WIDTH {
		return 0
	}
	return width * BYTES_PER_PIXEL
}

// geometry_validate checks a requested (width, height, stride_bytes) against
// pixel bounds, alignment, integer overflow, and byte_budget. Inputs are u64
// so transport words are validated before narrowing to u32.
geometry_validate :: proc "contextless" (
	width: u64,
	height: u64,
	stride_bytes: u64,
	byte_budget: u64 = MAX_FRAMEBUFFER_BYTES,
) -> (geo: Geometry, err: Validation_Error) {
	if width == 0 || height == 0 {
		return {}, .Zero_Dimension
	}
	// Check every multiplication for u64 overflow before evaluating bounds.
	if width > max(u64) / BYTES_PER_PIXEL {
		return {}, .Size_Overflow
	}
	if width > max(u64) / height {
		return {}, .Size_Overflow
	}
	pixel_count := width * height
	if pixel_count > max(u64) / BYTES_PER_PIXEL {
		return {}, .Size_Overflow
	}
	if stride_bytes > 0 && height > max(u64) / stride_bytes {
		return {}, .Size_Overflow
	}
	if width < MIN_WIDTH || height < MIN_HEIGHT {
		return {}, .Below_Minimum
	}
	if width > MAX_WIDTH || height > MAX_HEIGHT {
		return {}, .Above_Maximum
	}
	if stride_bytes % BYTES_PER_PIXEL != 0 {
		return {}, .Stride_Misaligned
	}
	min_stride := width * BYTES_PER_PIXEL
	if stride_bytes < min_stride {
		return {}, .Stride_Too_Small
	}
	if stride_bytes > u64(max(u32)) {
		return {}, .Over_Byte_Budget
	}
	total_bytes := height * stride_bytes
	effective_budget := min(byte_budget, MAX_FRAMEBUFFER_BYTES)
	if total_bytes > effective_budget {
		return {}, .Over_Byte_Budget
	}
	pages := (total_bytes + PAGE_SIZE - 1) / PAGE_SIZE
	return Geometry{
		width        = u32(width),
		height       = u32(height),
		stride_bytes = u32(stride_bytes),
		byte_size    = total_bytes,
		page_count   = pages,
	}, .None
}

// rectangle_clip intersects rect with [0, screen_width) x [0, screen_height).
// Returns ok = false when the clipped rectangle is empty.
rectangle_clip :: proc "contextless" (
	rect: Damage_Rectangle,
	screen_width, screen_height: u32,
) -> (clipped: Damage_Rectangle, ok: bool) {
	if screen_width == 0 || screen_height == 0 {
		return {}, false
	}
	if rect.left >= rect.right || rect.top >= rect.bottom {
		return {}, false
	}
	if rect.left >= screen_width || rect.top >= screen_height {
		return {}, false
	}
	clipped = {
		left   = rect.left,
		top    = rect.top,
		right  = min(rect.right, screen_width),
		bottom = min(rect.bottom, screen_height),
	}
	if clipped.right <= clipped.left || clipped.bottom <= clipped.top {
		return {}, false
	}
	return clipped, true
}

// rectangle_union returns the smallest rectangle enclosing both a and b.
rectangle_union :: proc "contextless" (a, b: Damage_Rectangle) -> Damage_Rectangle {
	return {
		left   = min(a.left, b.left),
		top    = min(a.top, b.top),
		right  = max(a.right, b.right),
		bottom = max(a.bottom, b.bottom),
	}
}

// rectangle_contains tells whether outer encloses inner completely.
rectangle_contains :: proc "contextless" (outer, inner: Damage_Rectangle) -> bool {
	return outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom
}

// damage_add clips rect to the screen and adds it to damage. When damage is
// full, all existing rectangles and rect merge into one bounding rectangle
// and merges is incremented so no changed pixel is ever dropped.
damage_add :: proc "contextless" (
	damage: ^Damage_Set,
	rect: Damage_Rectangle,
	screen_width, screen_height: u32,
) -> bool {
	if damage == nil {
		return false
	}
	clipped, ok := rectangle_clip(rect, screen_width, screen_height)
	if !ok {
		return false
	}
	for index in 0 ..< damage.count {
		if rectangle_contains(damage.rectangles[index], clipped) {
			return true
		}
	}
	if damage.count < DAMAGE_CAPACITY {
		damage.rectangles[damage.count] = clipped
		damage.count += 1
		return true
	}
	merged := clipped
	for index in 0 ..< damage.count {
		merged = rectangle_union(merged, damage.rectangles[index])
	}
	damage.rectangles[0] = merged
	damage.count = 1
	damage.merges += 1
	return true
}

// damage_bounding_box computes the union of all rectangles currently in damage.
damage_bounding_box :: proc "contextless" (damage: ^Damage_Set) -> (box: Damage_Rectangle, has_damage: bool) {
	if damage == nil || damage.count <= 0 {
		return {}, false
	}
	box = damage.rectangles[0]
	for index in 1 ..< damage.count {
		box = rectangle_union(box, damage.rectangles[index])
	}
	return box, true
}

// damage_mark_full replaces the damage set with one rectangle covering the
// entire screen.
damage_mark_full :: proc "contextless" (damage: ^Damage_Set, width, height: u32) {
	if damage == nil || width == 0 || height == 0 {
		return
	}
	damage.rectangles[0] = {0, 0, width, height}
	damage.count = 1
}

// damage_reset clears pending rectangles while keeping the merge count.
damage_reset :: proc "contextless" (damage: ^Damage_Set) {
	if damage != nil {
		damage.count = 0
	}
}

// screen_init validates the requested geometry and initializes a headless
// Memory_Screen atomically. On refusal, screen is untouched.
screen_init :: proc "contextless" (
	screen: ^Memory_Screen,
	width, height, stride_bytes: u64,
	byte_budget: u64 = MAX_FRAMEBUFFER_BYTES,
	source: Source = .Start_List,
) -> Validation_Error {
	if screen == nil {
		return .Not_Active
	}
	if source == .None {
		return .Invalid_Source
	}
	geo, err := geometry_validate(width, height, stride_bytes, byte_budget)
	if err != .None {
		return err
	}
	screen^ = {
		active      = true,
		source      = source,
		generation  = 1,
		byte_budget = min(byte_budget, MAX_FRAMEBUFFER_BYTES),
		geometry    = geo,
	}
	damage_mark_full(&screen.damage, geo.width, geo.height)
	return .None
}

// screen_damage_add records a damaged rectangle against the active screen.
screen_damage_add :: proc "contextless" (screen: ^Memory_Screen, rect: Damage_Rectangle) -> bool {
	if screen == nil || !screen.active {
		return false
	}
	return damage_add(&screen.damage, rect, screen.geometry.width, screen.geometry.height)
}

// screen_damage_take copies pending damage rectangles into out and resets
// the screen's damage list. If out is smaller than the pending count (and
// non-empty), the rectangles are collapsed into one bounding box in out[0]
// so no pixel is lost. If out is empty, pending damage is preserved.
screen_damage_take :: proc "contextless" (
	screen: ^Memory_Screen,
	out: []Damage_Rectangle,
) -> (count: int, merged_all: bool) {
	if screen == nil || !screen.active || screen.damage.count == 0 || len(out) == 0 {
		return 0, false
	}
	if screen.damage.count <= len(out) {
		count = screen.damage.count
		copy(out[:count], screen.damage.rectangles[:count])
		damage_reset(&screen.damage)
		return count, false
	}
	box, has := damage_bounding_box(&screen.damage)
	if !has {
		return 0, false
	}
	out[0] = box
	screen.damage.merges += 1
	damage_reset(&screen.damage)
	return 1, true
}

// screen_request_viewer_resize validates and stages a viewer-requested resize.
// Only a viewer with input authority may resize a headless screen. When two
// viewers submit valid requests before the next frame, the last valid request
// holds. Any invalid request is refused atomically without disturbing active
// geometry or a previously staged valid request.
screen_request_viewer_resize :: proc "contextless" (
	screen: ^Memory_Screen,
	width, height, stride_bytes: u64,
	has_input_grant: bool,
	viewer_serial: u64 = 0,
) -> Validation_Error {
	if screen == nil || !screen.active {
		return .Not_Active
	}
	if !has_input_grant {
		screen.resize_refusals += 1
		return .Input_Not_Allowed
	}
	geo, err := geometry_validate(width, height, stride_bytes, screen.byte_budget)
	if err != .None {
		screen.resize_refusals += 1
		return err
	}
	screen.pending_resize = {
		pending       = true,
		geometry      = geo,
		viewer_serial = viewer_serial,
	}
	return .None
}

// screen_commit_resize atomically applies a staged viewer resize at the start
// of the next frame, incrementing generation and marking the whole new screen
// damaged so every viewer receives the new size and a full frame.
screen_commit_resize :: proc "contextless" (screen: ^Memory_Screen) -> (changed: bool, geo: Geometry) {
	if screen == nil || !screen.active {
		return false, {}
	}
	if !screen.pending_resize.pending {
		return false, screen.geometry
	}
	next_geo := screen.pending_resize.geometry
	screen.pending_resize = {}
	screen.geometry = next_geo
	screen.source = .Viewer
	screen.generation += 1
	screen.resize_commits += 1
	damage_mark_full(&screen.damage, next_geo.width, next_geo.height)
	return true, next_geo
}

// screen_apply_resize validates and immediately commits a viewer resize in
// one atomic step. On refusal, active geometry, generation, and damage remain
// completely unchanged.
screen_apply_resize :: proc "contextless" (
	screen: ^Memory_Screen,
	width, height, stride_bytes: u64,
	has_input_grant: bool,
	viewer_serial: u64 = 0,
) -> Validation_Error {
	err := screen_request_viewer_resize(screen, width, height, stride_bytes, has_input_grant, viewer_serial)
	if err != .None {
		return err
	}
	_, _ = screen_commit_resize(screen)
	return .None
}
