// The disk program page (src/md/features/programs_from_a_disk.md, "The
// grants of a disk program"): one page that the root service writes, with
// one row for each disk program that runs: its program slot, its program
// serial, its nickname and the whole hash of its file. The root service
// maps it with the right Read only, at PAGE_ADDRESS, into each program that
// it starts with the right Inspect of the machine; the bit of the range
// Disk_Program_Page in the context value op.CONTEXT_VALUE_FIXED_RANGES_MAPPED
// says that it is mapped. The monitor reads the program slot and the
// program serial of each program from the kernel, and finds the nickname
// and the hash here (row_find).
//
// A change: the root service makes change_count odd, writes the words of
// one row, then makes it even again. A reader copies a row while
// change_count stays even and the same. All zero is valid (ZII): no disk
// program runs.
//
// The hash prefix is the first HASH_PREFIX_DIGITS hexadecimal digits of the
// hash, the first byte first: the menu of the windows and the monitor show
// it faded beside the nickname (hash_prefix_write).
//
// ```odin
// row, found := disk_program_page.row_find(disk_program_page.page_of(ctx), slot, report.program_serial)
// ```
//
// See [disk program page](term:disk-program-page) and
// [hash prefix](term:hash-prefix).
package disk_program_page

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"

PAGE_ADDRESS :: fixed_addresses.DISK_PROGRAM_PAGE_ADDRESS // Where a program maps the disk program page.

// The rows of the page: the root service starts 32 programs at most, and a
// row is the place of the slot of the program in its table of started
// programs.
ROW_CAPACITY :: 32

// The most bytes of a nickname: three words of a row, with a zero byte
// after it, as the root ring carries it.
NICKNAME_LIMIT :: 23

HASH_SIZE :: 32 // The bytes of the hash of a module file.
HASH_PREFIX_DIGITS :: 16 // The hexadecimal digits of the hash prefix: the first 8 bytes of the hash.

// One disk program that runs. Each field is whole words, so that a reader
// loads each word once.
Row :: struct {
	slot:           u64, // The program slot, as Inspect numbers it. 0: the row is free.
	program_serial: u64, // The program serial of the program in that slot (op.Program_Report).
	nickname:       [3]u64, // The bytes of the nickname, then zero bytes: NICKNAME_LIMIT at most.
	hash:           [4]u64, // The BLAKE3 hash of the module file, as the root service checked it.
}
#assert(size_of(Row) == 72)

// The disk program page: what the root service writes and the monitor reads.
Page :: struct {
	change_count: u64, // Even when the page is stable. Each change adds 2.
	rows:         [ROW_CAPACITY]Row,
}
#assert(size_of(Page) <= 4096)

// page_of gives the disk program page of a program, or nil.
page_of :: proc "contextless" (ctx: ^op.Context) -> ^Page {
	return .Disk_Program_Page in fixed_addresses.ranges_mapped(&ctx.values) ? (^Page)(uintptr(PAGE_ADDRESS)) : nil
}

// READ_TRIES is the most reads of a page that changes, or that the root
// service left in the middle of a change: the reader then gives no row,
// and never waits for the root service.
READ_TRIES :: 64

// row_find gives the row of the program in a program slot, when its program
// serial is the serial of the row. found is false when the program has no
// page, when no row names that program, and when the page changed at each
// of READ_TRIES reads.
row_find :: proc "contextless" (page: ^Page, slot: u64, program_serial: u64) -> (row: Row, found: bool) {
	if page == nil || slot == 0 {
		return {}, false
	}
	for _ in 0 ..< READ_TRIES {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		copied: Row
		matched := false
		for &place in page.rows {
			if intrinsics.atomic_load_explicit(&place.slot, .Acquire) != slot || intrinsics.atomic_load_explicit(&place.program_serial, .Acquire) != program_serial {
				continue
			}
			copied.slot, copied.program_serial = slot, program_serial
			for &word, index in copied.nickname {
				word = intrinsics.atomic_load_explicit(&place.nickname[index], .Acquire)
			}
			for &word, index in copied.hash {
				word = intrinsics.atomic_load_explicit(&place.hash[index], .Acquire)
			}
			matched = true
			break
		}
		if intrinsics.atomic_load_explicit(&page.change_count, .Acquire) != before {
			continue
		}
		return copied, matched
	}
	return {}, false
}

// row_write sets the row at index. The one writer is the root service.
row_write :: proc "contextless" (page: ^Page, index: int, row: Row) {
	if page == nil || index < 0 || index >= ROW_CAPACITY {
		return
	}
	place := &page.rows[index]
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_store_explicit(&place.slot, row.slot, .Release)
	intrinsics.atomic_store_explicit(&place.program_serial, row.program_serial, .Release)
	for word, number in row.nickname {
		intrinsics.atomic_store_explicit(&place.nickname[number], word, .Release)
	}
	for word, number in row.hash {
		intrinsics.atomic_store_explicit(&place.hash[number], word, .Release)
	}
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}

// row_of gives the row of a disk program: its place in the kernel, its
// nickname, cut to NICKNAME_LIMIT bytes (the root service refuses a longer
// one before the start), and the hash of its file.
row_of :: proc "contextless" (slot: u64, program_serial: u64, nickname: string, hash: [HASH_SIZE]u8) -> (row: Row) {
	row.slot, row.program_serial = slot, program_serial
	bytes: [NICKNAME_LIMIT + 1]u8
	copy(bytes[:NICKNAME_LIMIT], nickname)
	row.nickname = transmute([3]u64)bytes
	row.hash = transmute([4]u64)hash
	return row
}

// Nickname: the bytes of a nickname in the memory of its reader.
Nickname :: struct {
	bytes:  [NICKNAME_LIMIT]u8,
	length: int,
}

// nickname_of gives the nickname of three words: the bytes before the
// first zero byte, NICKNAME_LIMIT at most. A word with no zero byte in its
// last place still ends the nickname at NICKNAME_LIMIT.
nickname_of :: proc "contextless" (words: [3]u64) -> (nickname: Nickname) {
	bytes := transmute([NICKNAME_LIMIT + 1]u8)words
	for nickname.length < NICKNAME_LIMIT && bytes[nickname.length] != 0 {
		nickname.bytes[nickname.length] = bytes[nickname.length]
		nickname.length += 1
	}
	return nickname
}

// nickname_text gives the text of a nickname that nickname_of filled.
nickname_text :: proc "contextless" (nickname: ^Nickname) -> string {
	return string(nickname.bytes[:nickname.length])
}

// hash_head gives the first 8 bytes of a hash as one word: what the record
// Client_Add carries to the compositor, and what the hash prefix shows.
hash_head :: proc "contextless" (hash: [HASH_SIZE]u8) -> u64 {
	words := transmute([4]u64)hash
	return words[0]
}

// hash_prefix_write writes the hash prefix of a hash whose first 8 bytes
// are head (hash_head): 16 hexadecimal digits in lower case, the first byte
// first, as the 64 digits of the whole hash start.
hash_prefix_write :: proc "contextless" (out: ^[HASH_PREFIX_DIGITS]u8, head: u64) {
	digits := "0123456789abcdef"
	for index in 0 ..< HASH_PREFIX_DIGITS / 2 {
		byte := u8(head >> uint(8 * index))
		out[2 * index] = digits[byte >> 4]
		out[2 * index + 1] = digits[byte & 15]
	}
}
