package root

// The script font set of the machine (src/md/features/script_fonts.md):
// the fonts of Hebrew, Arabic, the ideographs, the emoji and the geometric
// shapes, which the boot image does not hold. The plan of principal 0
// names the set by its hash (the entry Script_Fonts); with no such entry,
// the resource script_fonts_name of the boot image names it. When the
// machine is usable, this service reads the set once, through the
// delegated service disk_processes, from the object script_fonts of the
// store script_fonts of the machine. It checks the hash of the bytes after
// the end of the loan, and their form, then maps the set read-only at the
// fixed range Script_Fonts in each process that gets the font outlines and
// starts after that. A process that started before keeps the replacement
// glyph for those scripts until its next start: no process asks for a font,
// and no frame waits for one.

import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modus:contract/value_kinds"
import "modus:system"

// Where the set of this start stands.
Script_Fonts_Stage :: enum u8 {
	Unnamed, // Neither the plan nor the boot image names a set.
	Named, // A set is named; its read waits until the machine is usable.
	Reading, // The delegated service reads it.
	Mapped, // Checked: each process that starts maps it.
	Absent, // The machine does not hold it, or it was refused: the box stays until the next start.
}

script_fonts_stage: Script_Fonts_Stage
// The hash of the set of this start: the plan of principal 0, else the
// boot image.
script_fonts_named: blake3.Hash
// The memory of the set, which this service made, checked and keeps, and
// the mapping that each process receives.
script_fonts_memory: system.Handle
script_fonts_bytes: []u8
script_fonts_mapping: system.Mapping

// script_fonts_name_read reads the name of the set that the boot image
// gives: the 32 bytes of the resource script_fonts_name. The hash of the
// image was checked with the whole image (trust_check).
script_fonts_name_read :: proc "contextless" () {
	entry := system.image_resource_find(image, font_outlines.SCRIPT_FONTS_NAME_RESOURCE)
	if entry == nil {
		system.log_fact(.Info, Script_Fonts_Unnamed{})
		return
	}
	if entry.size != size_of(blake3.Hash) {
		system.log_fact(.Warning, Script_Fonts_Name_Refused{name_bytes = value_kinds.Size_In_Bytes(entry.size)})
		return
	}
	named: blake3.Hash
	copy(named[:], image[entry.offset:][:size_of(blake3.Hash)])
	if named == {} {
		system.log_fact(.Warning, Script_Fonts_Name_Refused{name_bytes = value_kinds.Size_In_Bytes(entry.size)})
		return
	}
	script_fonts_named = named
	script_fonts_stage = .Named
	system.log_fact(.Info, Script_Fonts_Named_By_Image{hash = value_kinds.Hash_Field(named)})
}

// script_fonts_planned takes the set that the plan of principal 0 names,
// with its roles: all zero for none, which keeps the set of the boot image.
// Before the read of this start, the plan names the set of this start;
// after it, the next start.
script_fonts_planned :: proc "contextless" (named: blake3.Hash) {
	if named == {} || named == script_fonts_named {
		return
	}
	switch script_fonts_stage {
	case .Unnamed, .Named:
		script_fonts_named = named
		script_fonts_stage = .Named
		system.log_fact(.Info, Script_Fonts_Named_By_Plan{hash = value_kinds.Hash_Field(named)})
	case .Reading, .Mapped, .Absent:
		system.log_fact(.Info, Script_Fonts_Next_Start{hash = value_kinds.Hash_Field(named)})
	}
}

// script_fonts_step starts the read of the named set once the machine is
// usable, the storage service can run, and no other load runs. The loop
// calls it after each reap.
script_fonts_step :: proc "contextless" () {
	if script_fonts_stage != .Named || start_policy_stage != .Usable || disk_load_running() {
		return
	}
	if .Data_Disk not_in machine_parts {
		script_fonts_stage = .Absent
		system.log_fact(.Info, Script_Fonts_Without_Data_Disk{})
		return
	}
	failure, status := disk_load_begin(nil, 0, font_outlines.SCRIPT_FONTS_OBJECT_NAME, script_fonts_named, 0, false, .Script_Fonts)
	if failure != .None {
		script_fonts_stage = .Absent
		system.log_fact(.Warning, Script_Fonts_Not_Read{status = status})
		return
	}
	script_fonts_stage = .Reading
	system.log_fact(.Info, Script_Fonts_Reading{hash = value_kinds.Hash_Field(script_fonts_named)})
}

// script_fonts_take keeps the bytes of a load whose hash this service
// checked on its own mapping, after the end of the loan: the set that the
// hash names. Its form is checked here, once; each process validates its
// header again at its open. The hash of each font against its record is
// checked where the set is written (modustool script_fonts): the hash of
// the whole object already says that these are the bytes of that set.
script_fonts_take :: proc "contextless" (file: ^Lent_File) {
	bytes := file.bytes[:file.size]
	outlines, problem := font_outlines.validate(bytes)
	if problem.kind != .None {
		script_fonts_stage = .Absent
		system.log_fact(.Warning, Script_Fonts_Refused_Form{problem_value = problem.value, problem = text_field(font_outlines.problem_sentences[problem.kind], 80)})
		return
	}
	script_fonts_memory, script_fonts_bytes = file.memory, file.bytes
	file^ = {}
	pages := u64(len(script_fonts_bytes)) / system.PAGE_SIZE
	script_fonts_mapping = {memory = script_fonts_memory, address = font_outlines.SCRIPT_FONTS_ADDRESS, first = 0, page_count = pages}
	script_fonts_stage = .Mapped
	system.log_fact(.Info, Script_Fonts_Mapped{hash = value_kinds.Hash_Field(script_fonts_named), set_size = value_kinds.Size_In_Bytes(len(bytes)), fonts = u64(outlines.count)})
}

// script_fonts_not_on_disk takes a data disk that holds no set: the box
// stays, and the line says why, once.
script_fonts_not_on_disk :: proc "contextless" () {
	if script_fonts_stage != .Reading {
		return
	}
	script_fonts_stage = .Absent
	system.log_fact(.Info, Script_Fonts_Not_On_Disk{hash = value_kinds.Hash_Field(script_fonts_named)})
}

// script_fonts_load_ended takes the end of a load of the set that did not
// map it: its cause has its own line before this one.
script_fonts_load_ended :: proc "contextless" (status: system.Status) {
	if script_fonts_stage != .Reading {
		return
	}
	script_fonts_stage = .Absent
	system.log_fact(.Warning, Script_Fonts_Not_Read{status = status})
}

// script_fonts_give adds the set, read-only, to the mappings of a process
// that gets the font outlines, and sets the bit of its range.
script_fonts_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if script_fonts_stage != .Mapped {
		return
	}
	if count^ + 1 > len(mappings) {
		mapping_dropped_log("the script font set", len(mappings))
		return
	}
	mappings[count^] = script_fonts_mapping
	mappings[count^].flags = {}
	count^ += 1
	system.range_mapped_put(values, .Script_Fonts)
}
