#+build !freestanding
package page_attributes

import "core:testing"
import op "modus:contract/operation"

// The word of the table of the kernel, entry by entry, and back.
@(test)
kernel_table_word_matches_its_entries :: proc(t: ^testing.T) {
	testing.expect_value(t, table_word(KERNEL_TABLE), KERNEL_TABLE_WORD)
	table, ok := table_of_word(KERNEL_TABLE_WORD)
	testing.expect(t, ok)
	testing.expect_value(t, table, KERNEL_TABLE)
	reset, reset_ok := table_of_word(RESET_TABLE_WORD)
	testing.expect(t, reset_ok)
	testing.expect_value(t, reset, [8]Memory_Type{.Write_Back, .Write_Through, .Uncacheable_Minus, .Uncacheable, .Write_Back, .Write_Through, .Uncacheable_Minus, .Uncacheable})
	// The kernel changes the entries 1 and 5 only: each other entry keeps
	// its type at reset, so a mapping made before the write keeps it.
	kernel_table := KERNEL_TABLE
	for index in 0 ..< 8 {
		changed := kernel_table[index] != reset[index]
		testing.expectf(t, changed == (index == 1 || index == 5), "entry %v changed %v", index, changed)
	}
}

// A word with a reserved type or a bit above the three bits of an entry is
// refused: the processor faults on its write.
@(test)
table_of_word_refuses_reserved_entries :: proc(t: ^testing.T) {
	for index in u64(0) ..< 8 {
		for bad in ([?]u64{2, 3, 8, 0x10, 0x80, 0xFF}) {
			word := KERNEL_TABLE_WORD &~ (u64(0xFF) << (index * 8)) | bad << (index * 8)
			_, ok := table_of_word(word)
			testing.expectf(t, !ok, "entry %v with %x", index, bad)
		}
	}
	_, ok := table_of_word(max(u64))
	testing.expect(t, !ok)
	// The successful cases last: the word of zeros is a table of UC.
	zero, zero_ok := table_of_word(0)
	testing.expect(t, zero_ok)
	testing.expect_value(t, zero, [8]Memory_Type{})
}

// The bits of each entry that the kernel maps select the type that its name
// says, and only the bits PWT, PCD and PAT count.
@(test)
entry_bits_select_their_type :: proc(t: ^testing.T) {
	testing.expect_value(t, type_of_entry(KERNEL_TABLE, PAGE_WRITE_BACK), Memory_Type.Write_Back)
	testing.expect_value(t, type_of_entry(KERNEL_TABLE, PAGE_WRITE_COMBINING), Memory_Type.Write_Combining)
	testing.expect_value(t, type_of_entry(KERNEL_TABLE, PAGE_UNCACHEABLE), Memory_Type.Uncacheable)
	testing.expect_value(t, type_of_entry(KERNEL_TABLE, PAGE_CACHE_DISABLE), Memory_Type.Uncacheable_Minus)
	// The other bits of an entry (present, write, user, the address, no
	// execute) select nothing.
	other := u64(1) << 0 | u64(1) << 1 | u64(1) << 2 | u64(0x000F_FFFF_FFFF_F000) | u64(1) << 63
	for bits in ([?]u64{PAGE_WRITE_BACK, PAGE_WRITE_COMBINING, PAGE_UNCACHEABLE}) {
		testing.expectf(t, type_of_entry(KERNEL_TABLE, bits | other) == type_of_entry(KERNEL_TABLE, bits), "bits %x", bits)
		testing.expectf(t, bits &~ PAGE_CACHE_TYPE_BITS == 0, "bits %x outside the cache type bits", bits)
	}
	// The bit PAT selects the upper half, which repeats the lower half.
	for bits in ([?]u64{PAGE_WRITE_BACK, PAGE_WRITE_COMBINING, PAGE_UNCACHEABLE, PAGE_CACHE_DISABLE}) {
		testing.expectf(t, type_of_entry(KERNEL_TABLE, bits | 1 << 7) == type_of_entry(KERNEL_TABLE, bits), "bits %x with PAT", bits)
	}
	// Under the table at reset, the bits of write-combining gave
	// write-through: the change of the table is what makes them WC.
	reset, _ := table_of_word(RESET_TABLE_WORD)
	testing.expect_value(t, type_of_entry(reset, PAGE_WRITE_COMBINING), Memory_Type.Write_Through)
	testing.expect_value(t, type_of_entry(reset, PAGE_UNCACHEABLE), Memory_Type.Uncacheable)
}

// The cache type of the bits of an entry: PCD alone, which the kernel never
// writes, names none; the other bits of an entry do not count.
@(test)
mapping_cache_type_of_each_entry :: proc(t: ^testing.T) {
	_, ok := mapping_cache_type_of_bits(PAGE_CACHE_DISABLE)
	testing.expect(t, !ok)
	_, ok = mapping_cache_type_of_bits(PAGE_CACHE_DISABLE | 1 << 0 | 1 << 63)
	testing.expect(t, !ok)
	// The successful cases last.
	other := u64(1) << 0 | u64(1) << 1 | u64(1) << 2 | u64(0x000F_FFFF_FFFF_F000) | u64(1) << 63
	expected := [3]Mapping_Cache_Type{.Default, .Write_Combining, .Uncacheable}
	for bits, index in ([3]u64{PAGE_WRITE_BACK, PAGE_WRITE_COMBINING, PAGE_UNCACHEABLE}) {
		type, type_ok := mapping_cache_type_of_bits(bits | other)
		testing.expectf(t, type_ok && type == expected[index], "bits %x", bits)
	}
}

// The flag of the report of a mapping: none for the entry 0 (a screen,
// normal memory) and for PCD alone; Uncached for the registers of a
// device; Write_Combining for a write-combining mapping, never both.
@(test)
report_flag_of_each_entry :: proc(t: ^testing.T) {
	_, named := report_flag_of_bits(PAGE_WRITE_BACK)
	testing.expect(t, !named)
	_, named = report_flag_of_bits(PAGE_CACHE_DISABLE)
	testing.expect(t, !named)
	flag: op.Process_Mapping_Flag
	flag, named = report_flag_of_bits(PAGE_UNCACHEABLE | 1 << 0)
	testing.expect(t, named && flag == .Uncached)
	flag, named = report_flag_of_bits(PAGE_WRITE_COMBINING | 1 << 0 | 1 << 1)
	testing.expect(t, named && flag == .Write_Combining)
	testing.expect_value(t, op.Process_Mapping_Flag.Write_Combining, op.Process_Mapping_Flag(11))
}

// One cache type for each frame: a mapping joins the live mappings of an
// object only when none has another type; an object with no mapping takes
// any type.
@(test)
cache_type_joins_only_its_own_type :: proc(t: ^testing.T) {
	for type in Mapping_Cache_Type {
		for other in Mapping_Cache_Type {
			counts: Mapping_Cache_Counts
			counts[other] = 1
			testing.expectf(t, cache_type_joins(counts, type) == (type == other), "%v over one %v", type, other)
			counts[other] = max(u32)
			testing.expectf(t, cache_type_joins(counts, type) == (type == other), "%v over many %v", type, other)
		}
		// Two other types live (a state that the claim never lets happen):
		// refused whatever the type.
		mixed: Mapping_Cache_Counts
		mixed[.Default], mixed[.Write_Combining], mixed[.Uncacheable] = 1, 1, 1
		testing.expectf(t, !cache_type_joins(mixed, type), "%v over each type", type)
		// The successful case last: no live mapping.
		testing.expectf(t, cache_type_joins({}, type), "%v over none", type)
	}
}

// Two ranges of physical pages overlap when they share one page: touching
// ranges do not, one page in common does.
@(test)
ranges_overlap_at_their_edges :: proc(t: ^testing.T) {
	testing.expect(t, !ranges_overlap(0x1000, 1, 0x2000, 1))
	testing.expect(t, !ranges_overlap(0x2000, 1, 0x1000, 1))
	testing.expect(t, !ranges_overlap(0x1000, 0, 0x1000, 4))
	testing.expect(t, !ranges_overlap(0xF_FFFF_F000, 1, 0x10_0000_0000, 16))
	// The successful cases last.
	testing.expect(t, ranges_overlap(0x1000, 2, 0x2000, 1))
	testing.expect(t, ranges_overlap(0x2000, 1, 0x1000, 2))
	testing.expect(t, ranges_overlap(0x1000, 16, 0x5000, 1))
	testing.expect(t, ranges_overlap(0x1000, 1, 0x1000, 1))
	testing.expect(t, ranges_overlap(u64(1) << 51, 1 << 20, (u64(1) << 51) + 0xFFFF_F000, 1))
}
