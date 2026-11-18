// The fixed addresses of the mappings that the system gives a process: one
// table of named ranges. The owner of each range (the contract that
// describes what is mapped there) takes its address from here.
//
// One process can receive several of these mappings at one time: the root
// service gives each process with a surface the settings page, the glyph
// caches and the date page, and the same process can also have the files
// of its modules, a storage file or the pointer themes. So no two ranges
// overlap.
//
// The enumeration Fixed_Range is the table, and the only place of a range:
// the range of a member is the slot of its number, and each named address
// below is the address of a member. A new range is a new member; an
// address written another way is not a fixed range. So two ranges cannot
// overlap, and the compiler checks that the band holds every member.
//
// An address of the band has no other source than this table. No other
// file computes an address from BAND_START or SLOT: `modustool check`
// refuses a file of contract, support, processes or modules outside this
// folder that names them (tools/modustool/fixed_addresses_check.odin).
//
// A mapping that a process places by its own choice goes outside the
// band, at OWN_CHOICE_START or after. The modules that a process loads
// end at MODULES_END or before: src/library/support/system (load.odin) refuses a
// module that passes it.
//
// Example: the settings page of each process with a surface is at
// `SETTINGS_PAGE_ADDRESS`, 0x0000_3200_0000_0000: the slot 2 of the band.
// A process reads it only when the bit `Settings_Page` of
// `ranges_mapped(&ctx.values)` is set.
//
// See [fixed range](term:fixed-range) and [mapped ranges](term:mapped-ranges).
package fixed_addresses

import op "modus:contract/operation"

// The band of the fixed ranges: one slot of 1 TiB for each range.
BAND_START :: 0x0000_3000_0000_0000
SLOT :: 0x0000_0100_0000_0000 // 1 TiB: the addresses of one range.
SLOT_COUNT :: 16 // The slots of the band: the most members of Fixed_Range.
BAND_END :: BAND_START + SLOT_COUNT * SLOT
// The first address of a mapping that a process places by its own choice.
OWN_CHOICE_START :: BAND_END
// The end of the addresses where a process loads its modules, from
// op.MODULE_BASE: the band starts there.
MODULES_END :: BAND_START
// The span of each range: one slot.
RANGE_SPAN :: SLOT

// The table of the fixed ranges: a new range is a new member, and its
// address is its slot. A constant written by hand in the band, with no
// member, is not a fixed range, and the check of the tool refuses it.
//
// A starter maps a range in its child before the child runs. For the
// settings page, the glyph caches, the demand cache, the font outlines,
// the date page, the debug image, the disk process page and the fresh
// bytes page, it
// also sets the bit of the range in the value 20 of the context of the
// child (`range_mapped_add`). The child reads nothing at a range whose bit
// is clear (`ranges_mapped`): an address that is not mapped faults at the
// first read, and the bit tells the child before it reads. The other
// ranges come with their size in a value of the context.
Fixed_Range :: enum u8 {
	Module_Files, // The files of a module and of its imports, in the process that runs the module (modus:contract/isolated).
	// A call host finds there, read-only, the module that it runs, its
	// imports and the replacement records, as one list in the form of the
	// boot image. The console or the root service maps them before the
	// call host starts, and states their size in the values of its
	// context: a call host has no handle to the boot image, so it cannot
	// look for them.
	Pointer_Themes, // The pointer themes of the compositor, one after the other (src/modules/system/root).
	// The root service maps the theme files of the boot image there,
	// read-only, in the compositor, and gives the address and the size of
	// each one in the values of its context.
	Settings_Page, // The settings page (modus:contract/settings).
	// One page, read-only, that the process `settings` writes and every
	// process with a surface or a terminal reads: the value of each setting
	// of the machine. The root service maps it. A process reads a change at
	// its next read of the page, with no message.
	Glyph_Cache, // The glyph caches of the text of the system (modus:contract/settings).
	// The glyphs of the default font of the text, fitted to the grid of
	// the pixels, drawn once at build time. The root service maps it,
	// read-only, beside the settings page; each process draws text from it
	// and draws no glyph itself.
	Glyph_Cache_Without_Grid_Fit,
	// The glyphs of the default font with no fit to the grid of the
	// pixels, for the setting that chooses them. Mapped as the cache
	// above.
	Glyph_Cache_Bold,
	// The glyphs of the emphasis weight of the default font. Mapped as the
	// cache above.
	Date_Page, // The date page (modus:contract/date).
	// One page, read-only, that the process `date` writes from the
	// real-time clock: each process reads the date of the day there with
	// no call. The root service maps it.
	Storage_File, // The file of the storage service (src/library/support/storage).
	// The file of the process of the storage service, read-only, in a
	// process that the root service connects to the storage service at its
	// start: the process reads the descriptions of the exports there. The
	// root service maps it, and gives its size at the value 3 of the
	// context.
	Module_Tables, // The tables of the parameters of one export, in the process that receives the call (modus:contract/isolated).
	// A receiver maps the memory object of each table parameter there for
	// the time of one call: the parameter n at `TABLE_ADDRESS` plus n
	// times 16 GiB. The same addresses at each call cost no new page
	// tables, where an address that the kernel chooses would.
	Interface_Glyph_Cache, // The glyph cache of the interface font, regular weight (modus:contract/settings).
	// The glyphs of the proportional font of the windows. Mapped as the
	// glyph caches above.
	Interface_Glyph_Cache_Bold, // The glyph cache of the interface font, bold weight.
	// Mapped as the glyph caches above.
	Debug_Image, // The debug image, read-only: the debug objects of the modules, by the hash of each module (modus:contract/debug_object).
	// The root service maps it in a process that prints stop reports, as
	// the console, and gives its size at the value 21 of the context. The
	// report then names the procedure and the line of each frame.
	Disk_Process_Page, // The disk process page (modus:contract/disk_process_page).
	// One page, read-only, that the root service writes: the nickname and
	// the hash of each disk process that runs, by its process slot. The
	// root service maps it in each process that it starts with the right
	// Inspect of the machine, as the monitor.
	Demand_Cache, // The demand cache, read-only (modus:contract/demand_cache).
	// The glyphs of the fixed subsets past the glyph caches, which the
	// font service drew at its start. The root service maps it beside the
	// glyph caches; the font service is its one writer.
	Font_Outlines, // The font outlines, read-only (modus:contract/font_outlines).
	// The font files of the system, one resource of the boot image: each
	// process draws from them the glyphs past the glyph caches into its
	// private glyph cache. The root service maps it beside the glyph
	// caches, and in the font service.
	Fresh_Bytes_Page, // The fresh bytes page of the process, read-only (modus:contract/fresh_bytes).
	// The root service writes there, now and then, 32 bytes of its stream
	// for this process alone, after a read of the entropy device; the
	// random generator of the process mixes them into its key.
}
#assert(int(max(Fixed_Range)) < SLOT_COUNT)

// Fixed_Ranges: a set of ranges, one bit for each member. The value
// op.CONTEXT_VALUE_FIXED_RANGES_MAPPED of the context of a process is the
// set that its starter mapped. A bit past the last member has no meaning.
Fixed_Ranges :: bit_set[Fixed_Range;u64]
#assert(size_of(Fixed_Ranges) == size_of(u64))

// ranges_mapped gives the ranges that the starter of a process mapped for it.
ranges_mapped :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> Fixed_Ranges {
	return transmute(Fixed_Ranges)values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED]
}

// range_mapped_add is for a starter: it states in the values of its child
// that it maps a range.
range_mapped_add :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, range: Fixed_Range) {
	values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] = transmute(u64)(ranges_mapped(values) + {range})
}

// The band is after the addresses that the kernel chooses and the modules,
// and inside the addresses of a process.
#assert(BAND_START >= op.MODULE_BASE + SLOT)
#assert(BAND_END <= op.USER_END)

// The address of each range: the first byte of its slot.
MODULE_FILES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Module_Files)
POINTER_THEMES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Pointer_Themes)
SETTINGS_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Settings_Page)
GLYPH_CACHE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache)
GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache_Without_Grid_Fit)
GLYPH_CACHE_BOLD_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache_Bold)
DATE_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Date_Page)
STORAGE_FILE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Storage_File)
MODULE_TABLES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Module_Tables)
DEBUG_IMAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Debug_Image)
DISK_PROCESS_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Disk_Process_Page)
DEMAND_CACHE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Demand_Cache)
FONT_OUTLINES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Font_Outlines)
FRESH_BYTES_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Fresh_Bytes_Page)

// The addresses of one range.
Address_Range :: struct {
	address: u64, // The first byte of the range.
	span:    u64, // The bytes of addresses of the range: RANGE_SPAN.
}

// range_of gives the address and the span of a range.
range_of :: proc "contextless" (range: Fixed_Range) -> Address_Range {
	return {address = BAND_START + SLOT * u64(range), span = RANGE_SPAN}
}
