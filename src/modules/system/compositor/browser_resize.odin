package compositor

// Live browser viewport resize (src/md/features/browser_machine.md):
// when the browser machine backs GRANT_FRAMEBUFFER with a trailing MODVRES1
// control page, the browser host can request new pixel dimensions at runtime.
// The compositor reallocates its frame and background canvases, updates
// desktop layout, bar, snap zones, and open windows, paints the full new frame
// into screen.pixels, and publishes ack_seq with .Release so the browser never
// observes a half-resized framebuffer.

import "base:intrinsics"
import info "modus:contract/boot_info"

browser_resize_page: ^info.Browser_Resize_Page
browser_resize_last_seq: u32
browser_resize_pending_seq: u32
browser_resize_ack_seq: u32

// browser_resize_open attaches the trailing MODVRES1 control page when present
// on a single-page browser machine framebuffer. On QEMU and real hardware no
// such magic page exists and browser_resize_page stays nil.
browser_resize_open :: proc "contextless" (framebuffer_pages: u64) {
	browser_resize_page = nil
	if screen_of_memory || display_registers != nil || screen.pixels == nil {
		return
	}
	if framebuffer_pages < info.BROWSER_RESIZE_TOTAL_PAGES {
		return
	}
	candidate := (^info.Browser_Resize_Page)(uintptr(screen.pixels) + info.BROWSER_RESIZE_MAX_BYTES)
	if intrinsics.atomic_load_explicit(&candidate.magic, .Acquire) != info.BROWSER_RESIZE_MAGIC {
		return
	}
	browser_resize_page = candidate
	seq := intrinsics.atomic_load_explicit(&candidate.req_seq, .Acquire)
	browser_resize_last_seq = seq
	browser_resize_pending_seq = seq
	browser_resize_ack_seq = seq
	candidate.ack_width = u32(screen.width)
	candidate.ack_height = u32(screen.height)
	intrinsics.atomic_store_explicit(&candidate.ack_seq, seq, .Release)
}

// browser_resize_poll checks for a pending live viewport resize request from
// the browser host and applies it before the frame draws.
browser_resize_poll :: proc "contextless" () -> bool {
	page := browser_resize_page
	if page == nil {
		return false
	}
	req_seq := intrinsics.atomic_load_explicit(&page.req_seq, .Acquire)
	if req_seq == browser_resize_last_seq {
		return false
	}
	browser_resize_last_seq = req_seq
	req_w := int(page.req_width)
	req_h := int(page.req_height)
	max_w := min(int(page.max_width), info.BROWSER_RESIZE_MAX_WIDTH)
	max_h := min(int(page.max_height), info.BROWSER_RESIZE_MAX_HEIGHT)

	valid := req_w >= info.BROWSER_RESIZE_MIN_WIDTH &&
		req_w <= max_w &&
		req_h >= info.BROWSER_RESIZE_MIN_HEIGHT &&
		req_h <= max_h &&
		u64(req_w) * u64(req_h) * 4 <= info.BROWSER_RESIZE_MAX_BYTES
	if !valid || (req_w == screen.width && req_h == screen.height) {
		browser_resize_pending_seq = req_seq
		damage_whole_screen()
		return true
	}

	// Allocate new frame first, then swap frame and rebuild background so peak
	// working memory during resize stays bounded by old_frame + new_frame
	// (never 2x old + 2x new simultaneously).
	new_frame, new_frame_memory, frame_made := canvas_try_create(req_w, req_h)
	if !frame_made {
		// Free old background temporarily to make headroom for a larger frame.
		canvas_free(background, background_memory_handle)
		background, background_memory_handle = {}, 0
		new_frame, new_frame_memory, frame_made = canvas_try_create(req_w, req_h)
		if !frame_made {
			// Restore previous background if budget cannot fit the requested size.
			if restored_bg, restored_mem, bg_ok := canvas_try_create(screen.width, screen.height); bg_ok {
				background, background_memory_handle = restored_bg, restored_mem
				background_build()
			}
			browser_resize_pending_seq = req_seq
			damage_whole_screen()
			return true
		}
	}

	old_frame, old_frame_mem := frame, frame_memory_handle
	old_bg, old_bg_mem := background, background_memory_handle
	capture_pictures_leave()
	canvas_free(old_bg, old_bg_mem)
	background, background_memory_handle = {}, 0
	canvas_free(old_frame, old_frame_mem)
	frame, frame_memory_handle = new_frame, new_frame_memory

	new_bg, new_bg_mem, bg_made := canvas_try_create(req_w, req_h)
	if !bg_made {
		// Fall back cleanly to previous size if background could not allocate.
		canvas_free(frame, frame_memory_handle)
		frame, frame_memory_handle = {}, 0
		if f, fm, ok := canvas_try_create(screen.width, screen.height); ok {
			frame, frame_memory_handle = f, fm
		}
		if b, bm, ok := canvas_try_create(screen.width, screen.height); ok {
			background, background_memory_handle = b, bm
			background_build()
		}
		browser_resize_pending_seq = req_seq
		damage_whole_screen()
		return true
	}
	background, background_memory_handle = new_bg, new_bg_mem

	screen.width = req_w
	screen.height = req_h
	screen.stride = req_w
	screen_pages[0] = screen
	desktop_size_follow_screen(true) // scale.odin
	background_build()
	bar_mark_build()
	bar_layout_update()
	pointer_drawn_valid = false
	pointer_update(0)
	for &client in clients {
		if client.ring.head == nil || !client.created {
			continue
		}
		work_area_send(&client)
		window_fit_now(&client) // scale.odin
	}
	damage_whole_screen()
	palette_refresh()
	browser_resize_pending_seq = req_seq
	return true
}

// browser_resize_ack_after_frame publishes the active dimensions and release
// sequence once draw() has painted the full resized desktop into screen.pixels.
browser_resize_ack_after_frame :: proc "contextless" () {
	page := browser_resize_page
	if page == nil || browser_resize_pending_seq == browser_resize_ack_seq {
		return
	}
	page.ack_width = u32(screen.width)
	page.ack_height = u32(screen.height)
	intrinsics.atomic_store_explicit(&page.ack_seq, browser_resize_pending_seq, .Release)
	browser_resize_ack_seq = browser_resize_pending_seq
}
