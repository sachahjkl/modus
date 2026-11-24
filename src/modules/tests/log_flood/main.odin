// The writer of the machine test of the record output `log`
// (src/md/features/log_facts.md, "The record output `log`"). The test
// module `output_wiring` starts it with a wiring list whose one row wires
// its `log` to the asker. Its log budget holds 0 records of each second
// (the root service, budgets.odin), so the kernel refuses each of its log
// calls, whatever the speed of the machine, and none of its lines is in
// the log of the kernel. Its wired `log` holds each one.
//
// It writes, in this order:
//
// 1. FLOOD_LINES lines "log_flood: line <n>", each with its number as a
//    value run: more than the default capacity of a ring, so the asker
//    holds it at least once;
// 2. one line of LONG_LINE_BYTES letters, which the cut of the kernel puts
//    in three records joined by `more`;
// 3. the fact Flood_Fact, at the level Warning;
// 4. the line "log_flood: the kernel refused <n> lines", with the count of
//    the calls that the kernel refused before it (system.log_lines_refused);
// 5. HELD_LINES more lines, which the asker never reads: the ring fills,
//    and this process waits for room. The asker closes its end; the end
//    word ends the wait, the library removes the ring, and the rest of the
//    lines go to the kernel log only, which refuses them. Then it stops
//    with Done: a writer of log is never held past the end of its reader.
//
// The asker checks each record of 1 to 4, and that the count of the last
// line is the count of the calls before it: the log of the kernel lost each
// line, and `log` none. Then it checks the outcome Done.
//
// No step of a machine test waits for a line of this process: the kernel
// keeps none of them.
//
// **Start**: by `output_wiring` only. **What a reader sees**: nothing in
// the log of the kernel. It stops itself with the outcome Done.
package log_flood

import "base:intrinsics"
import "modus:system"

// The counts of the test, which the asker shares.
FLOOD_LINES :: 600
LONG_LINE_BYTES :: 400
FLOOD_MARK :: 0x5a5a_a5a5
// More lines than a ring of the default capacity holds: this process waits
// for room while its asker does not read.
HELD_LINES :: 600

// The one fact of the test: the asker compares its bytes.
@(log_fact = "log_flood: the fact {number} with the mark {mark}")
Flood_Fact :: struct {
	number: u64,
	mark:   u64,
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	for line in u64(0) ..< FLOOD_LINES {
		system.log(.Info, "log_flood: line ", line)
	}
	long: [LONG_LINE_BYTES]u8
	for &letter, index in long {
		letter = 'a' + u8(index % 26)
	}
	system.log(.Info, string(long[:]))
	system.log_fact(.Warning, Flood_Fact{number = FLOOD_LINES, mark = FLOOD_MARK})
	system.log(.Info, "log_flood: the kernel refused ", intrinsics.atomic_load(&system.log_lines_refused), " lines")
	for line in u64(0) ..< HELD_LINES {
		system.log(.Info, "log_flood: a held line ", line)
	}
	system.stop(.Done)
}

// The tool counts the module and thread stack; working memory holds the wiring
// ring mappings and tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256}
