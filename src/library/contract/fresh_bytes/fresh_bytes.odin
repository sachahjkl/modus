// The fresh bytes page (src/md/features/fresh_bytes.md): one page for each
// process that the root service starts, that the root service writes and
// the process reads. Every 30 seconds the root service reads the entropy
// device, mixes the bytes into its generator, and writes 32 bytes of its
// stream in the page of each process: each process has its own bytes. The
// random generator of the process mixes them into its key at its next
// refill, or before its next key or seed (modus:support/random,
// `fresh_bytes_attach`), and at no other draw.
//
// The root service maps the page with the right Read only, at PAGE_ADDRESS;
// the bit of the range Fresh_Bytes_Page in the context value
// op.CONTEXT_VALUE_FIXED_RANGES_MAPPED says that it is mapped. A process
// that another process starts has none.
//
// A change: the root service makes change_count odd, writes the bytes,
// then makes it even again. A reader copies the bytes while change_count
// stays even and the same (read). All zero is valid (ZII): no fresh bytes
// yet. A machine with no entropy device keeps each page at zero.
//
// ```odin
// bytes, change_count, fresh := fresh_bytes.read(fresh_bytes.page_of(ctx), last_change_count)
// ```
//
// See [fresh bytes page](term:fresh-bytes-page) and
// [fresh bytes refresh](term:fresh-bytes-refresh).
package fresh_bytes

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"

PAGE_ADDRESS :: fixed_addresses.FRESH_BYTES_PAGE_ADDRESS // Where a process maps its fresh bytes page.

BYTES :: 32 // The fresh bytes of one change: as many as a key of the generator.
WORDS :: BYTES / 8 // The words of the bytes: the writer stores each one whole.
CHANGE_STEP :: 2 // What one write adds to the change count: odd during the write, even after it.

// The fresh bytes page: what the root service writes and one process reads.
Page :: struct {
	change_count: u32, // Even when the page is stable. Each change adds CHANGE_STEP. 0: no fresh bytes yet.
	reserved:     u32, // 0.
	bytes:        [WORDS]u64, // The bytes, 8 in each word, the first byte in the low bits.
}
#assert(size_of(Page) <= 4096)

// page_of gives the fresh bytes page of a process, or nil.
page_of :: proc "contextless" (ctx: ^op.Context) -> ^Page {
	return .Fresh_Bytes_Page in fixed_addresses.ranges_mapped(&ctx.values) ? (^Page)(uintptr(PAGE_ADDRESS)) : nil
}

// READ_TRIES is the most reads of a page that changes, or that the root
// service left in the middle of a change: the reader then gives no bytes,
// and never waits for the root service.
READ_TRIES :: 64

// read gives the bytes of the page when they are new: the change count is
// even, not 0, and not last_change_count. fresh is false with no page, with
// no change since last_change_count, and when the page changed at each of
// READ_TRIES reads. The caller erases the bytes after their use.
read :: proc "contextless" (page: ^Page, last_change_count: u32) -> (bytes: [BYTES]u8, change_count: u32, fresh: bool) {
	if page == nil {
		return {}, last_change_count, false
	}
	for _ in 0 ..< READ_TRIES {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before == last_change_count || before == 0 {
			return {}, last_change_count, false
		}
		if before & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		words: [WORDS]u64
		for &word, index in words {
			word = intrinsics.atomic_load_explicit(&page.bytes[index], .Acquire)
		}
		if intrinsics.atomic_load_explicit(&page.change_count, .Acquire) != before {
			intrinsics.mem_zero_volatile(&words, size_of(words))
			continue
		}
		bytes = transmute([BYTES]u8)words
		intrinsics.mem_zero_volatile(&words, size_of(words))
		return bytes, before, true
	}
	return {}, last_change_count, false
}

// write sets new bytes, in one change of the page. The one writer is the
// root service.
write :: proc "contextless" (page: ^Page, bytes: ^[BYTES]u8) {
	if page == nil {
		return
	}
	words := transmute([WORDS]u64)bytes^
	before := page.change_count
	intrinsics.atomic_store_explicit(&page.change_count, before + 1, .Release)
	for word, index in words {
		intrinsics.atomic_store_explicit(&page.bytes[index], word, .Release)
	}
	intrinsics.atomic_store_explicit(&page.change_count, before + CHANGE_STEP, .Release)
	intrinsics.mem_zero_volatile(&words, size_of(words))
}

// clear writes the page to zero with the change count 0, for a new
// process: it reads no byte that the process before it read. The root
// service clears a page only while no process maps it.
clear :: proc "contextless" (page: ^Page) {
	if page == nil {
		return
	}
	for index in 0 ..< WORDS {
		intrinsics.atomic_store_explicit(&page.bytes[index], 0, .Release)
	}
	intrinsics.atomic_store_explicit(&page.change_count, 0, .Release)
}
