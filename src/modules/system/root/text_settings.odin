package root

import "modus:contract/font_outlines"
import "modus:contract/settings"
import "modus:system"

// The text of the system and the settings of the system (docs/FONTS.md):
// this service creates the settings page, checks the hash and the format
// of the font outlines of the boot image once, and maps the page and the
// outlines read-only into each process with a surface, into each terminal
// and into the compositor. Each process draws each glyph of its text from
// the outlines, into its private glyph cache. The process `settings`
// receives the page with Write. The boot display that this service draws
// reads no font file: its text is Spleen at the size of its scale
// (src/md/features/boot_display_scale.md).
//
// At the end of the boot this service starts `settings` for its boot pass:
// it reads the settings kept in its private store and writes the page; the
// compositor sees the change and each window draws again.

settings_memory: system.Handle
// The font outlines of the boot image: page_count 0 when the image has
// none, or none that font_outlines.validate accepts.
font_outlines_mapping: system.Mapping
// The boot pass of `settings` is the next start of that name: start() gives
// it the value VALUE_BOOT_PASS.
settings_boot_pass: bool

// text_settings_create makes the settings page and finds the font
// outlines. It writes the initial defaults before any process starts and
// immediately unmaps its writable mapping so `settings` is the sole writer
// of the settings page. Font outlines are given only when their hash is
// right (resource_mapping) and their format is valid: a resource shorter
// than its header, or whose header states another size than the resource,
// is not given, so a process that reads the size in the header reads only
// mapped bytes. With no outlines, each process draws with Spleen 8x16, and
// the log says why.
text_settings_create :: proc "contextless" () {
	status: system.Status
	settings_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(settings_memory)
	}
	if status != .Ok {
		fail("cannot create the settings page", status)
	}
	// The defaults before any process maps the page: the word 0 names no
	// scale, so an all-zero page would be refused by each reader until the
	// boot pass of `settings` writes it. Unmap right away so this service
	// never writes the page again.
	settings.page_defaults_write((^settings.Page)(address))
	system.memory_unmap(address)
	if mapping, _, given := resource_mapping(font_outlines.RESOURCE_NAME, font_outlines.ADDRESS, "each process with a surface"); given {
		entry := system.image_resource_find(image, font_outlines.RESOURCE_NAME)
		if _, problem := font_outlines.validate(image[entry.offset:][:entry.size]); problem.kind == .None {
			font_outlines_mapping = mapping
		} else {
			system.log_fact(.Warning, Font_Outlines_Refused{problem_value = problem.value, problem = text_field(font_outlines.problem_sentences[problem.kind], 80)})
		}
	}
	if font_outlines_mapping.page_count == 0 {
		system.log_fact(.Warning, Font_Outlines_Absent{})
	}
}

// text_settings_give adds the settings page and the font outlines,
// read-only, to the mappings of a process that has a surface or a
// terminal, and sets the bit of each range in its values. The mapping of
// the outlines has no flag: the right Read only, for every process, the
// process `settings` included. Its pages come from the boot image, whose
// one handle (of this service) has no right Write.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if settings_memory == 0 {
		return
	}
	// The page and the outlines.
	if count^ + 2 > len(mappings) {
		mapping_dropped_log("the settings page and the font outlines", len(mappings))
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	system.range_mapped_put(values, .Settings_Page)
	if font_outlines_mapping.page_count != 0 {
		mappings[count^] = font_outlines_mapping
		mappings[count^].flags = {}
		count^ += 1
		system.range_mapped_put(values, .Font_Outlines)
	}
}

// settings_boot_pass_start starts `settings` for its boot pass: it reads
// the settings kept in its private store, writes the page, and stops. The
// storage service starts first, with the block service of the data disk.
// A machine with no data disk keeps the defaults. A start policy asks for
// it, as the row settings of its list, and gets the status.
settings_boot_pass_start :: proc "contextless" () -> system.Status {
	settings_boot_pass = true
	status := start("settings")
	settings_boot_pass = false
	if status != .Ok {
		system.log_fact(.Warning, Settings_Boot_Pass_Failed{status = status})
	}
	return status
}
