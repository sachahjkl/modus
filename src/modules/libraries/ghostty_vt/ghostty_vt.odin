// Freestanding library module exposing the fixed-arena libghostty-vt C-ABI
// bridge and ANSI/VT100/xterm terminal grid exports (src/md/features/ghostty_vt.md).
package ghostty_vt_module

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ghostty_vt"

// vt_arena_bytes returns the fixed memory footprint required by one terminal
// instance for the requested (cols, rows, scrollback) grid, or an error record
// when dimensions exceed the bounded contract limits.
@(export, link_name = "vt_arena_bytes")
vt_arena_bytes :: proc "c" (cols: i64, rows: i64, scrollback: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if cols <= 0 || cols > i64(ghostty_vt.MAX_COLS) {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Counts, 1, cols, i64(ghostty_vt.MAX_COLS))
	}
	if rows <= 0 || rows > i64(ghostty_vt.MAX_ROWS) {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Counts, 2, rows, i64(ghostty_vt.MAX_ROWS))
	}
	if scrollback < 0 || u64(scrollback) > ghostty_vt.MAX_SCROLLBACK_BYTES {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 3, scrollback, i64(ghostty_vt.MAX_SCROLLBACK_BYTES))
	}
	opts := ghostty_vt.Terminal_Options{
		cols                 = u16(cols),
		rows                 = u16(rows),
		max_scrollback_bytes = u64(scrollback),
	}
	if ghostty_vt.terminal_options_validate(opts) != .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Counts, 1)
	}
	return .Succeeded, i64(u64(cols) * u64(rows) * 16 + u64(scrollback) + 65536)
}

// vt_allocator_smoke exercises the freestanding C-ABI Ghostty_Allocator fixed
// arena (alloc -> free) and returns the number of bytes allocated, proving zero
// host dependencies inside the loaded library module.
@(export, link_name = "vt_allocator_smoke")
vt_allocator_smoke :: proc "c" (request_bytes: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if request_bytes <= 0 || request_bytes > 4096 {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Counts, 1, request_bytes, 4096)
	}
	backing: [8192]u8
	arena: ghostty_vt.Fixed_Arena
	if ghostty_vt.fixed_arena_init(&arena, backing[:]) != .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 1)
	}
	alloc := ghostty_vt.fixed_arena_allocator(&arena)
	ptr := alloc.alloc(alloc.ctx, uint(request_bytes), 3, 0)
	if ptr == nil {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 1)
	}
	used := arena.cursor
	alloc.free(alloc.ctx, ptr, uint(request_bytes), 3, 0)
	return .Succeeded, i64(used)
}
