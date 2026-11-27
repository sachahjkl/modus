// Native Doom (`doomgeneric`) as a confined window application on modus.
//
// **What it is for.** Runs classic Doom directly on modus with no POSIX layer
// and no guest machine (src/md/features/doom.md). The Odin shell owns the
// 640x400 window, SSE2 palette blit, 35 Hz frame pacing, 56 KiB chunked WAD
// reads from the private store, opt-in pointer lock, and optional 48 kHz
// stereo DMX sound mixing.
//
// **Start**: `start("doom")` in the console, or from the desktop start menu.
// Place an IWAD (`freedoom1.wad`, `doom1.wad`, `doom.wad`, `freedoom2.wad`, or
// `doom2.wad`) in the private store `doom`.
package doom

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:storage"
import "modus:system"

// The circular audio sample region shared with the sound service before ready.
MODULE_START_OBJECTS :: [?]system.Start_Object{SOUND_REGION_PAGES}

// The tool counts the module, its load, its thread, its 640x400 window at the
// largest scale, and the sound sample region. The WAD and Doom zone arena
// allocate after ready from doom's default plan budget row.
MODULE_BUDGET :: system.Stated_Budget{
	processes     = 1,
	threads       = 1,
	window_width  = WINDOW_WIDTH,
	window_height = WINDOW_HEIGHT,
}

// Plan value: 56 KiB chunk size for storage.read_range inside the 64 KiB call
// region, leaving 8 KiB headroom for isolated call framing metadata.
WAD_CHUNK_BYTES :: 57_344

// Format property: Doom game simulation runs at 35 tics per second.
TIC_NANOSECONDS :: u64(28_571_428)

// Plan value: cap catch-up tics per loop iteration so a host pause never spirals.
MAX_CATCHUP_TICS :: 4

// Plan value: report measured FPS every 35 rendered frames (once per second at 35 Hz).
FPS_REPORT_INTERVAL :: u64(35)

// Closed result set crossing the C/Odin border from modus_doom_init / modus_doom_tick.
Doom_Step_Result :: enum i32 {
	Ok    = 0,
	Quit  = 1,
	Error = 2,
}

// Bridge record matching Modus_Doom_Host in src/outside/doomgeneric/libc/include/modus_doom_host.h.
Doom_Host :: struct {
	alloc:               proc "c" (ctx: rawptr, size: u64, alignment: u64) -> rawptr,
	log_line:            proc "c" (ctx: rawptr, text: [^]u8, length: u64),
	draw_indexed:        proc "c" (ctx: rawptr, pixels: [^]u8, palette_bgra: [^]u32),
	ticks_ms:            proc "c" (ctx: rawptr) -> u32,
	sleep_ms:            proc "c" (ctx: rawptr, ms: u32),
	poll_key:            proc "c" (ctx: rawptr, pressed: ^i32, doom_key: ^u8) -> i32,
	poll_mouse:          proc "c" (ctx: rawptr, buttons: ^i32, dx: ^i32, dy: ^i32) -> i32,
	set_title:           proc "c" (ctx: rawptr, title: cstring),
	wad_bytes:           [^]u8,
	wad_size:            u64,
	wad_name:            cstring,
	save_read:           proc "c" (ctx: rawptr, name: cstring, buffer: [^]u8, capacity: u64, out_size: ^u64) -> i32,
	save_write:          proc "c" (ctx: rawptr, name: cstring, buffer: [^]u8, size: u64) -> i32,
	save_remove:         proc "c" (ctx: rawptr, name: cstring) -> i32,
	sound_available:     proc "c" (ctx: rawptr) -> i32,
	sound_start:         proc "c" (ctx: rawptr, channel: i32, dmx_data: [^]u8, dmx_len: u64, vol: i32, sep: i32) -> i32,
	sound_update_params: proc "c" (ctx: rawptr, channel: i32, vol: i32, sep: i32),
	sound_stop:          proc "c" (ctx: rawptr, channel: i32),
	sound_is_playing:    proc "c" (ctx: rawptr, channel: i32) -> i32,
	sound_mix_tic:       proc "c" (ctx: rawptr),
	ctx:                 rawptr,
}
#assert(size_of(Doom_Host) == 21 * 8)

Doom_State :: struct {
	window:              display.Window,
	store:               storage.Client,
	store_open:          bool,
	arena:               system.Arena,
	sound:               Sound_Output,
	keys:                Key_Queue,
	mouse:               Mouse_Input,
	start_ns:            u64,
	wad_size:            u64,
	frames_presented:    u64,
	fps_window_start_ns: u64,
	fps_window_frames:   u64,
	running_logged:      bool,
	quit_requested:      bool,
}

state: Doom_State

// Candidate IWAD object names checked in priority order in the private store.
@(rodata)
WAD_CANDIDATES := [?]cstring{
	"freedoom1.wad",
	"doom1.wad",
	"doom.wad",
	"freedoom2.wad",
	"doom2.wad",
}

@(private = "file")
doom_step_result_of_word :: proc "contextless" (word: i32) -> (result: Doom_Step_Result, ok: bool) {
	if word < 0 {
		return .Error, false
	}
	return enum_word.member_of_word(Doom_Step_Result, u64(word))
}

@(private = "file")
pointer_lock_reason_text :: proc "contextless" (reason: display.Pointer_Lock_Reason) -> string {
	switch reason {
	case .Window_Request: return "window request"
	case .Super_Key:      return "Super key"
	case .Focus_Lost:     return "focus lost"
	case .Refused:        return "refused"
	}
	return "unknown"
}

@(private = "file")
cstring_to_string :: proc "contextless" (cs: cstring) -> string {
	if cs == nil {
		return ""
	}
	bytes := ([^]u8)(cs)
	n := 0
	for bytes[n] != 0 {
		n += 1
	}
	return string(bytes[:n])
}

// Drain all pending display events into Doom's key queue and mouse accumulator.
@(private = "file")
events_drain :: proc "contextless" (s: ^Doom_State) {
	for ev in display.next_event(&s.window) {
		switch ev.kind {
		case .Key:
			dk := doom_key_of_event(ev.code, ev.character)
			if dk != 0 {
				key_queue_push(&s.keys, ev.pressed, dk)
				if ev.pressed && ev.key_serial != 0 {
					display.key_shown(&s.window, ev.key_serial)
				}
			}
		case .Pointer:
			if !display.pointer_locked(&s.window) {
				// Clicking inside the surface acquires relative pointer lock.
				if ev.buttons & display.BUTTON_LEFT != 0 && ev.x >= 0 && ev.y >= 0 && ev.x < s.window.view_width && ev.y < s.window.view_height {
					_ = display.pointer_lock_set(&s.window, true)
				} else {
					mouse_input_set_buttons(&s.mouse, ev.buttons)
				}
			} else {
				mouse_input_set_buttons(&s.mouse, ev.buttons)
			}
		case .Pointer_Delta:
			mouse_input_add(&s.mouse, ev.dx, ev.dy, ev.buttons)
		case .Pointer_Lock_Changed:
			if !ev.pointer_locked {
				mouse_input_clear(&s.mouse)
			}
			state_text := ev.pointer_locked ? "acquired" : "released"
			reason_text := pointer_lock_reason_text(ev.pointer_lock_reason)
			system.log_fact(.Info, Pointer_Lock_Event{
				state  = value_kinds.text_field(state_text, STATE_FIELD_BYTES),
				reason = value_kinds.text_field(reason_text, REASON_FIELD_BYTES),
			})
		case .None, .Presentation, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Surface_Answer, .Capture_Disconnect, .Work_Area, .Capture_Opened:
		}
	}
}

// ---------------------------------------------------------------------------
// C host callbacks
// ---------------------------------------------------------------------------

@(private = "file")
host_alloc :: proc "c" (ctx: rawptr, size: u64, alignment: u64) -> rawptr {
	s := (^Doom_State)(ctx)
	align := alignment < 8 ? u64(8) : alignment
	refusal: errors.Error_Record
	ptr, status := system.arena_push(&s.arena, size, align, &refusal)
	if status != .Succeeded {
		return nil
	}
	return ptr
}

@(private = "file")
host_log_line :: proc "c" (ctx: rawptr, text: [^]u8, length: u64) {
	_ = ctx
	if text == nil || length == 0 {
		return
	}
	bounded := min(int(length), LOG_LINE_FIELD_BYTES - 1)
	system.log_fact(.Info, Engine_Log{line = value_kinds.text_field(string(text[:bounded]), LOG_LINE_FIELD_BYTES)})
}

@(private = "file")
host_draw_indexed :: proc "c" (ctx: rawptr, pixels: [^]u8, palette_bgra: [^]u32) {
	s := (^Doom_State)(ctx)
	if pixels == nil || palette_bgra == nil {
		return
	}
	if !display.canvas_wait(&s.window) {
		return
	}
	palette := (^[256]graphics.Color)(palette_bgra)
	blit_indexed_frame(s.window.canvas, pixels, DOOM_WIDTH, DOOM_HEIGHT, palette)
	if !display.present(&s.window) {
		return
	}
	s.frames_presented += 1
	s.fps_window_frames += 1
	if !s.running_logged {
		s.running_logged = true
		s.fps_window_start_ns = system.nanoseconds()
		system.log_fact(.Info, Running{
			width    = u64(s.window.view_width),
			height   = u64(s.window.view_height),
			wad_size = value_kinds.Size_In_Bytes(s.wad_size),
		})
	} else if s.fps_window_frames >= FPS_REPORT_INTERVAL {
		now := system.nanoseconds()
		elapsed := now - s.fps_window_start_ns
		fps := elapsed > 0 ? (s.fps_window_frames * 1_000_000_000) / elapsed : 0
		system.log_fact(.Info, Fps_Measured{frame = s.frames_presented, fps = fps})
		s.fps_window_start_ns = now
		s.fps_window_frames = 0
	}
}

@(private = "file")
host_ticks_ms :: proc "c" (ctx: rawptr) -> u32 {
	s := (^Doom_State)(ctx)
	elapsed_ns := system.nanoseconds() - s.start_ns
	return u32(elapsed_ns / 1_000_000)
}

@(private = "file")
host_sleep_ms :: proc "c" (ctx: rawptr, ms: u32) {
	s := (^Doom_State)(ctx)
	events_drain(s)
	if ms == 0 || s.quit_requested {
		return
	}
	deadline := system.time() + u64(ms)
	_ = display.wait(&s.window, deadline)
	events_drain(s)
}

@(private = "file")
host_poll_key :: proc "c" (ctx: rawptr, pressed: ^i32, doom_key: ^u8) -> i32 {
	s := (^Doom_State)(ctx)
	events_drain(s)
	item, ok := key_queue_pop(&s.keys)
	if !ok {
		return 0
	}
	pressed^ = item.pressed ? 1 : 0
	doom_key^ = item.key
	return 1
}

@(private = "file")
host_poll_mouse :: proc "c" (ctx: rawptr, buttons: ^i32, dx: ^i32, dy: ^i32) -> i32 {
	s := (^Doom_State)(ctx)
	b, mx, my, ok := mouse_input_take(&s.mouse)
	if !ok {
		return 0
	}
	buttons^ = b
	dx^ = mx
	dy^ = my
	return 1
}

@(private = "file")
host_set_title :: proc "c" (ctx: rawptr, title: cstring) {
	_ = ctx
	_ = title
}

@(private = "file")
host_save_read :: proc "c" (ctx: rawptr, name: cstring, buffer: [^]u8, capacity: u64, out_size: ^u64) -> i32 {
	s := (^Doom_State)(ctx)
	if !s.store_open || name == nil || buffer == nil || capacity == 0 {
		return 0
	}
	obj_name := cstring_to_string(name)
	obj_size, size_status := storage.size(&s.store, storage.ROOT, obj_name)
	if size_status != .Ok || obj_size < 0 || u64(obj_size) > capacity {
		return 0
	}
	offset := u64(0)
	total := u64(obj_size)
	for offset < total {
		chunk := min(u64(WAD_CHUNK_BYTES), total - offset)
		part, read_status := storage.read_range(&s.store, storage.ROOT, obj_name, offset, buffer[offset : offset + chunk])
		if read_status != .Ok || len(part) == 0 {
			return 0
		}
		offset += u64(len(part))
	}
	out_size^ = total
	return 1
}

@(private = "file")
host_save_write :: proc "c" (ctx: rawptr, name: cstring, buffer: [^]u8, size: u64) -> i32 {
	s := (^Doom_State)(ctx)
	if !s.store_open || name == nil {
		return 0
	}
	obj_name := cstring_to_string(name)
	data: []u8
	if size > 0 && buffer != nil {
		data = buffer[:size]
	}
	_, write_status := storage.write_whole(&s.store, storage.ROOT, obj_name, data)
	return write_status == .Ok ? 1 : 0
}

@(private = "file")
host_save_remove :: proc "c" (ctx: rawptr, name: cstring) -> i32 {
	s := (^Doom_State)(ctx)
	if !s.store_open || name == nil {
		return 0
	}
	obj_name := cstring_to_string(name)
	_, status := storage.remove(&s.store, storage.ROOT, obj_name)
	return status == .Ok || status == .Absent ? 1 : 0
}

@(private = "file")
host_sound_available :: proc "c" (ctx: rawptr) -> i32 {
	s := (^Doom_State)(ctx)
	return s.sound.active ? 1 : 0
}

@(private = "file")
host_sound_start :: proc "c" (ctx: rawptr, channel: i32, dmx_data: [^]u8, dmx_len: u64, vol: i32, sep: i32) -> i32 {
	s := (^Doom_State)(ctx)
	if !s.sound.active || dmx_data == nil || dmx_len == 0 {
		return -1
	}
	if !sound_mixer_start(&s.sound.mixer, int(channel), dmx_data[:dmx_len], int(vol), int(sep)) {
		return -1
	}
	return channel
}

@(private = "file")
host_sound_update_params :: proc "c" (ctx: rawptr, channel: i32, vol: i32, sep: i32) {
	s := (^Doom_State)(ctx)
	sound_mixer_update_params(&s.sound.mixer, int(channel), int(vol), int(sep))
}

@(private = "file")
host_sound_stop :: proc "c" (ctx: rawptr, channel: i32) {
	s := (^Doom_State)(ctx)
	sound_mixer_stop(&s.sound.mixer, int(channel))
}

@(private = "file")
host_sound_is_playing :: proc "c" (ctx: rawptr, channel: i32) -> i32 {
	s := (^Doom_State)(ctx)
	return sound_mixer_is_playing(&s.sound.mixer, int(channel)) ? 1 : 0
}

@(private = "file")
host_sound_mix_tic :: proc "c" (ctx: rawptr) {
	s := (^Doom_State)(ctx)
	sound_submit_tic(&s.sound)
}

// ---------------------------------------------------------------------------
// Startup WAD loading (56 KiB chunked reads into arena, zero I/O in gameplay)
// ---------------------------------------------------------------------------

@(private = "file")
wad_load_from_store :: proc "contextless" (s: ^Doom_State) -> (name: cstring, bytes: [^]u8, size: u64, found: bool) {
	if !s.store_open {
		return nil, nil, 0, false
	}
	candidates := WAD_CANDIDATES
	for candidate in candidates {
		cand_str := cstring_to_string(candidate)
		obj_size, size_status := storage.size(&s.store, storage.ROOT, cand_str)
		if size_status == .Absent {
			continue
		}
		if size_status != .Ok || obj_size <= 0 {
			system.log_fact(.Warning, Wad_Read_Failed{status = u64(size_status)})
			return nil, nil, 0, false
		}
		refusal: errors.Error_Record
		buf_ptr, alloc_status := system.arena_push(&s.arena, u64(obj_size), 16, &refusal)
		if alloc_status != .Succeeded {
			system.log_fact(.Warning, Wad_Read_Failed{status = u64(storage_status.Status.Refused)})
			return nil, nil, 0, false
		}
		dst := ([^]u8)(buf_ptr)
		offset := u64(0)
		total := u64(obj_size)
		for offset < total {
			chunk := min(u64(WAD_CHUNK_BYTES), total - offset)
			part, read_status := storage.read_range(&s.store, storage.ROOT, cand_str, offset, dst[offset : offset + chunk])
			if read_status != .Ok || len(part) == 0 {
				system.log_fact(.Warning, Wad_Read_Failed{status = u64(read_status)})
				return nil, nil, 0, false
			}
			offset += u64(len(part))
		}
		return candidate, dst, total, true
	}
	return nil, nil, 0, false
}

@(private = "file")
show_missing_wad_screen :: proc "contextless" (s: ^Doom_State) -> ! {
	system.log_fact(.Warning, Wad_Missing{})
	if display.canvas_wait(&s.window) {
		graphics.clear(s.window.canvas, graphics.rgb(0x16, 0x18, 0x1D))
		graphics.text(s.window.canvas, 32, 32, "No WAD file found in the doom store.", graphics.rgb(0xF0, 0xF2, 0xF5))
		graphics.text(s.window.canvas, 32, 56, "Store freedoom1.wad or doom1.wad, then start doom again.", graphics.rgb(0xA8, 0xB0, 0xBE))
		_ = display.present(&s.window)
	}
	for {
		_ = display.wait(&s.window, system.WAIT_FOREVER)
		for ev in display.next_event(&s.window) {
			if ev.kind == .Key && ev.pressed && ev.code == display.KEY_ESCAPE {
				system.stop(.Done)
			}
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, window_ok := display.open(ctx, WINDOW_WIDTH, WINDOW_HEIGHT, "doom")
	if !window_ok {
		system.stop(.Failed)
	}
	state.window = window
	state.start_ns = system.nanoseconds()

	state.store, state.store_open = storage.open(ctx)
	sound_open(&state.sound, ctx)
	// Wait for root to read the startup peak before reserving the WAD and Doom
	// zone arena that draws from doom's plan budget beyond its floor.
	system.ready_at_end()

	amounts, budget_status := system.budget_read()
	if budget_status != .Succeeded {
		system.stop(.Failed)
	}
	arena_refusal: errors.Error_Record
	arena_status: call_outcome.Call_Outcome
	state.arena, arena_status = system.arena_create(system.arena_reservation_pages(amounts.pages), 0, &arena_refusal)
	if arena_status != .Succeeded {
		system.stop(.Failed)
	}

	wad_name, wad_bytes, wad_size, wad_found := wad_load_from_store(&state)
	if !wad_found {
		show_missing_wad_screen(&state)
	}
	state.wad_size = wad_size

	host := Doom_Host {
		alloc               = host_alloc,
		log_line            = host_log_line,
		draw_indexed        = host_draw_indexed,
		ticks_ms            = host_ticks_ms,
		sleep_ms            = host_sleep_ms,
		poll_key            = host_poll_key,
		poll_mouse          = host_poll_mouse,
		set_title           = host_set_title,
		wad_bytes           = wad_bytes,
		wad_size            = wad_size,
		wad_name            = wad_name,
		save_read           = host_save_read,
		save_write          = host_save_write,
		save_remove         = host_save_remove,
		sound_available     = host_sound_available,
		sound_start         = host_sound_start,
		sound_update_params = host_sound_update_params,
		sound_stop          = host_sound_stop,
		sound_is_playing    = host_sound_is_playing,
		sound_mix_tic       = host_sound_mix_tic,
		ctx                 = &state,
	}

	init_result, init_known := doom_step_result_of_word(modus_doom_init(&host))
	if !init_known || init_result != .Ok {
		reason := init_result == .Quit ? "quit during startup" : "startup error"
		system.log_fact(.Warning, Engine_Stopped{reason = value_kinds.text_field(reason, REASON_FIELD_BYTES)})
		system.stop(init_result == .Quit ? .Done : .Failed)
	}

	next_tic_ns := system.nanoseconds() + TIC_NANOSECONDS
	for !state.quit_requested {
		events_drain(&state)
		if state.quit_requested {
			break
		}
		now := system.nanoseconds()
		if now < next_tic_ns {
			remaining_ms := (next_tic_ns - now) / 1_000_000
			if remaining_ms > 0 {
				_ = display.wait(&state.window, system.time() + remaining_ms)
				continue
			}
		}
		tics := 0
		for tics < MAX_CATCHUP_TICS && !state.quit_requested {
			step_result, step_known := doom_step_result_of_word(modus_doom_tick())
			if !step_known || step_result != .Ok {
				reason := step_result == .Quit ? "quit" : "runtime error"
				system.log_fact(.Info, Engine_Stopped{reason = value_kinds.text_field(reason, REASON_FIELD_BYTES)})
				system.stop(step_result == .Quit ? .Done : .Failed)
			}
			next_tic_ns += TIC_NANOSECONDS
			tics += 1
			if system.nanoseconds() < next_tic_ns {
				break
			}
		}
		// Resynchronize after long stalls rather than running unbounded catch-up tics.
		if now_after := system.nanoseconds(); next_tic_ns + TIC_NANOSECONDS * MAX_CATCHUP_TICS < now_after {
			next_tic_ns = now_after + TIC_NANOSECONDS
		}
	}

	if display.pointer_locked(&state.window) {
		_ = display.pointer_lock_set(&state.window, false)
	}
	system.stop(.Done)
}
