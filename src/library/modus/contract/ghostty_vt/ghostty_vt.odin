// Freestanding C-ABI allocator bridge and validated configuration contract
// for `libghostty-vt` (src/md/features/ghostty_vt.md).
//
// Provides a bounded fixed-arena implementation of `libghostty-vt`'s explicit
// `Ghostty_Allocator` vtable backed solely by caller-supplied static pages
// (zero host heap, zero kernel calls, deterministic OOM bounds).
package ghostty_vt

import "modus:contract/enum_word"

MIN_COLS :: u16(1)
MAX_COLS :: u16(512)
MIN_ROWS :: u16(1)
MAX_ROWS :: u16(256)
MAX_SCROLLBACK_BYTES :: u64(16 * 1024 * 1024)
MAX_ARENA_BLOCKS :: 256
MAX_ALIGNMENT :: uintptr(64)

Vt_Refusal :: enum u8 {
	None             = 0,
	Nil_Input        = 1,
	Invalid_Cols     = 2,
	Invalid_Rows     = 3,
	Scrollback_Limit = 4,
	Arena_Too_Small  = 5,
	Out_Of_Memory    = 6,
}

vt_refusal_of_word :: proc "contextless" (word: u64) -> (r: Vt_Refusal, ok: bool) {
	return enum_word.member_of_word(Vt_Refusal, word)
}

// C-ABI allocator vtable matching `libghostty-vt`'s explicit allocator border.
Ghostty_Alloc_Proc :: #type proc "c" (ctx: rawptr, len: uint, alignment: u8, ret_addr: uintptr) -> [^]u8
Ghostty_Resize_Proc :: #type proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, alignment: u8, new_len: uint, ret_addr: uintptr) -> bool
Ghostty_Remap_Proc :: #type proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, alignment: u8, new_len: uint, ret_addr: uintptr) -> [^]u8
Ghostty_Free_Proc :: #type proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, alignment: u8, ret_addr: uintptr)

Ghostty_Allocator :: struct {
	ctx:    rawptr,
	alloc:  Ghostty_Alloc_Proc,
	resize: Ghostty_Resize_Proc,
	remap:  Ghostty_Remap_Proc,
	free:   Ghostty_Free_Proc,
}

Terminal_Options :: struct {
	cols:                 u16,
	rows:                 u16,
	max_scrollback_bytes: u64,
}

terminal_options_validate :: proc "contextless" (opt: Terminal_Options) -> Vt_Refusal {
	if opt.cols < MIN_COLS || opt.cols > MAX_COLS {
		return .Invalid_Cols
	}
	if opt.rows < MIN_ROWS || opt.rows > MAX_ROWS {
		return .Invalid_Rows
	}
	if opt.max_scrollback_bytes > MAX_SCROLLBACK_BYTES {
		return .Scrollback_Limit
	}
	return .None
}

Arena_Block :: struct {
	active: bool,
	offset: uint,
	size:   uint,
}

// Fixed_Arena provides a bounded, alignment-safe, zero-heap allocator backing
// Ghostty_Allocator with live/peak tracking and last-block reuse + free coalescing.
Fixed_Arena :: struct {
	backing:          [^]u8,
	capacity:         uint,
	cursor:           uint,
	live_bytes:       uint,
	peak_bytes:       uint,
	failed_allocs:    u64,
	blocks:           [MAX_ARENA_BLOCKS]Arena_Block,
	active_blocks:    int,
}

fixed_arena_init :: proc "contextless" (arena: ^Fixed_Arena, backing: []u8) -> Vt_Refusal {
	if arena == nil {
		return .Nil_Input
	}
	if len(backing) < 64 {
		return .Arena_Too_Small
	}
	arena^ = {
		backing  = raw_data(backing),
		capacity = uint(len(backing)),
	}
	return .None
}

@(private = "file")
align_up :: proc "contextless" (val: uint, align_pow2: uint) -> (aligned: uint, ok: bool) {
	if align_pow2 == 0 || (align_pow2 & (align_pow2 - 1)) != 0 || align_pow2 > uint(MAX_ALIGNMENT) {
		return 0, false
	}
	mask := align_pow2 - 1
	if val > max(uint) - mask {
		return 0, false
	}
	return (val + mask) & ~mask, true
}

@(private = "file")
find_block_by_ptr :: proc "contextless" (arena: ^Fixed_Arena, ptr: [^]u8) -> int {
	if arena == nil || arena.backing == nil || ptr == nil {
		return -1
	}
	base := uintptr(arena.backing)
	p := uintptr(ptr)
	if p < base {
		return -1
	}
	off := uint(p - base)
	for &b, i in arena.blocks {
		if b.active && b.offset == off {
			return i
		}
	}
	return -1
}

@(private = "file")
arena_rewind_cursor :: proc "contextless" (arena: ^Fixed_Arena) {
	highest := uint(0)
	for &b in arena.blocks {
		if b.active {
			end := b.offset + b.size
			if end > highest {
				highest = end
			}
		}
	}
	arena.cursor = highest
}

ghostty_fixed_alloc :: proc "c" (ctx: rawptr, size: uint, alignment_log2: u8, _: uintptr) -> [^]u8 {
	arena := (^Fixed_Arena)(ctx)
	if arena == nil || arena.backing == nil || size == 0 || alignment_log2 > 6 {
		if arena != nil {
			arena.failed_allocs += 1
		}
		return nil
	}
	align := uint(1) << alignment_log2
	aligned_off, aok := align_up(arena.cursor, align)
	if !aok || size > arena.capacity || aligned_off > arena.capacity - size {
		arena.failed_allocs += 1
		return nil
	}
	slot := -1
	for &b, i in arena.blocks {
		if !b.active {
			slot = i
			break
		}
	}
	if slot < 0 {
		arena.failed_allocs += 1
		return nil
	}
	arena.blocks[slot] = {active = true, offset = aligned_off, size = size}
	arena.active_blocks += 1
	arena.cursor = aligned_off + size
	arena.live_bytes += size
	if arena.live_bytes > arena.peak_bytes {
		arena.peak_bytes = arena.live_bytes
	}
	return arena.backing[aligned_off:]
}

ghostty_fixed_resize :: proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, _: u8, new_len: uint, _: uintptr) -> bool {
	arena := (^Fixed_Arena)(ctx)
	if arena == nil || memory == nil || new_len == 0 {
		return false
	}
	idx := find_block_by_ptr(arena, memory)
	if idx < 0 || arena.blocks[idx].size != memory_len {
		return false
	}
	blk := &arena.blocks[idx]
	if new_len <= blk.size {
		diff := blk.size - new_len
		blk.size = new_len
		arena.live_bytes -= diff
		arena_rewind_cursor(arena)
		return true
	}
	// Grow in place only if this block sits at the arena tail.
	if blk.offset + blk.size != arena.cursor {
		return false
	}
	if new_len > arena.capacity || blk.offset > arena.capacity - new_len {
		return false
	}
	diff := new_len - blk.size
	blk.size = new_len
	arena.cursor = blk.offset + new_len
	arena.live_bytes += diff
	if arena.live_bytes > arena.peak_bytes {
		arena.peak_bytes = arena.live_bytes
	}
	return true
}

ghostty_fixed_free :: proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, _: u8, _: uintptr) {
	arena := (^Fixed_Arena)(ctx)
	if arena == nil || memory == nil {
		return
	}
	idx := find_block_by_ptr(arena, memory)
	if idx < 0 || arena.blocks[idx].size != memory_len {
		return
	}
	arena.live_bytes -= arena.blocks[idx].size
	arena.blocks[idx] = {}
	arena.active_blocks -= 1
	arena_rewind_cursor(arena)
}

ghostty_fixed_remap :: proc "c" (ctx: rawptr, memory: [^]u8, memory_len: uint, alignment_log2: u8, new_len: uint, ret_addr: uintptr) -> [^]u8 {
	if ghostty_fixed_resize(ctx, memory, memory_len, alignment_log2, new_len, ret_addr) {
		return memory
	}
	fresh := ghostty_fixed_alloc(ctx, new_len, alignment_log2, ret_addr)
	if fresh == nil {
		return nil
	}
	copy_n := min(memory_len, new_len)
	for i in uint(0) ..< copy_n {
		fresh[i] = memory[i]
	}
	ghostty_fixed_free(ctx, memory, memory_len, alignment_log2, ret_addr)
	return fresh
}

// fixed_arena_allocator returns the C-ABI Ghostty_Allocator bound to arena.
fixed_arena_allocator :: proc "contextless" (arena: ^Fixed_Arena) -> Ghostty_Allocator {
	return Ghostty_Allocator{
		ctx    = arena,
		alloc  = ghostty_fixed_alloc,
		resize = ghostty_fixed_resize,
		remap  = ghostty_fixed_remap,
		free   = ghostty_fixed_free,
	}
}
