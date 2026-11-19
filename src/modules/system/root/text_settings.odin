package root

import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "modus:contract/settings"
import "modus:support/system"

// The text of the system and the settings of the system (docs/FONTS.md):
// this service creates the settings page, checks the hashes and the format
// of the glyph caches of the boot image once, and maps the page and the
// caches read-only into each process with a surface, into each terminal and
// into the compositor. The process `settings` receives the page with Write.
// The boot display that this service draws reads no glyph cache: its text
// is Spleen at the size of its scale (src/md/features/boot_display_scale.md).
//
// At the end of the boot this service starts `settings` for its boot pass:
// it reads the settings kept in its private store and writes the page; the
// compositor sees the change and each window draws again.

// The resource of the boot image of each glyph cache.
glyph_cache_resources := [settings.Glyph_Cache]string {
	.With_Grid_Fit    = "glyph_cache",
	.Without_Grid_Fit = "glyph_cache_no_grid_fit",
	.Bold             = "glyph_cache_bold",
	.Interface        = "interface_glyph_cache",
	.Interface_Bold   = "interface_glyph_cache_bold",
}

settings_memory: system.Handle
settings_page: ^settings.Page
glyph_cache_mappings: [settings.Glyph_Cache]system.Mapping // page_count 0: no such glyph cache.
// The font outlines of the boot image: page_count 0 when the image has
// none, or none that font_outlines.validate accepts.
font_outlines_mapping: system.Mapping
// The boot pass of `settings` is the next start of that name: start() gives
// it the value VALUE_BOOT_PASS.
settings_boot_pass: bool

// text_settings_create makes the settings page and finds the glyph caches.
// Each cache is given only when its hash is right (resource_mapping) and
// its format is valid: a resource shorter than the header of a cache, or
// whose header states another size than the resource, is not given, so a
// process that reads the size in the header reads only mapped bytes. With
// no cache of the text of cells, each process draws with Spleen 8x16, and
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
	settings_page = (^settings.Page)(address)
	caches: [settings.Glyph_Cache]glyph_cache.Cache
	for name, cache in glyph_cache_resources {
		place := fixed_addresses.range_of(settings.glyph_cache_ranges[cache])
		mapping, _, given := resource_mapping(name, place.address, "each process with a surface")
		if !given {
			continue
		}
		entry := system.image_resource_find(image, name)
		problem: glyph_cache.Problem
		caches[cache], problem = glyph_cache.validate(image[entry.offset:][:entry.size])
		if problem.kind != .None {
			system.log_in("processes", .Warning, "root: the glyph cache ", name, " is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value, ": it is not given")
			continue
		}
		glyph_cache_mappings[cache] = mapping
	}
	// The font outlines, given only when their hash is right and their
	// format valid, as a glyph cache.
	if mapping, _, given := resource_mapping(font_outlines.RESOURCE_NAME, font_outlines.ADDRESS, "each process with a surface"); given {
		entry := system.image_resource_find(image, font_outlines.RESOURCE_NAME)
		if _, problem := font_outlines.validate(image[entry.offset:][:entry.size]); problem.kind == .None {
			font_outlines_mapping = mapping
		} else {
			system.log_in("processes", .Warning, "root: the font outlines are refused: ", font_outlines.problem_sentences[problem.kind], ", value ", problem.value, ": they are not given")
		}
	}
	if glyph_cache_mappings[.With_Grid_Fit].page_count == 0 {
		system.log_in("processes", .Warning, "root: the boot image has no valid glyph cache: the text of the system is Spleen 8x16")
	}
}

// text_settings_give adds the settings page, the glyph caches and the font
// outlines, read-only, to the mappings of a process that has a surface or
// a terminal, and sets the bit of each range in its values. A cache
// mapping has no flag: the right Read only, for every process, the process
// `settings` included. The pages of the caches and of the outlines come
// from the boot image, whose one handle (of this service) has no right
// Write. The process draws each glyph past the glyph caches itself, from
// the outlines, into its private glyph cache.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if settings_page == nil {
		return
	}
	// The page, the caches and the outlines.
	if count^ + 1 + len(glyph_cache_mappings) + 1 > len(mappings) {
		mapping_dropped_log("the settings page, the glyph caches and the font outlines", len(mappings))
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	system.range_mapped_put(values, .Settings_Page)
	for mapping, cache in glyph_cache_mappings {
		if mapping.page_count != 0 {
			mappings[count^] = mapping
			mappings[count^].flags = {}
			count^ += 1
			system.range_mapped_put(values, settings.glyph_cache_ranges[cache])
		}
	}
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
		system.log_in("processes", .Warning, "root: the boot pass of settings did not start (status ", status, "): the settings are the defaults")
	}
	return status
}
