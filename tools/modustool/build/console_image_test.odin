#+build !freestanding
package build

import "core:fmt"
import "core:testing"
import info "modus:contract/boot_info"
import "modus:contract/start_list"
import "modus:contract/system_description"
import "modustool:foundation"

// Builds a synthetic base boot image holding every boot-image module except
// `omit`, plus sample desktop resources (fonts, pointers).
@(private = "file")
qemu_console_test_base :: proc(omit := "", duplicate := "") -> []u8 {
	files := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		if !foundation.module_in_boot_image(row) || row.name == omit {
			continue
		}
		append(&files, Image_File{name = row.name, file = transmute([]u8)row.name})
		if duplicate != "" && row.name == duplicate {
			append(&files, Image_File{name = row.name, file = transmute([]u8)row.name})
		}
	}
	module_count := len(files)
	font_bytes: string = "font"
	pointer_bytes: string = "pointers"
	append(&files, Image_File{name = "font_outlines", file = transmute([]u8)font_bytes})
	append(&files, Image_File{name = "pointers_system", file = transmute([]u8)pointer_bytes})
	return boot_image_encode(files[:], module_count)
}

// The QEMU console image holds QEMU_CONSOLE_MODULES (with serial_terminal) and
// their imports only, refuses every desktop and alternate terminal module, and
// carries only its single-row start_list and rescue_list.
@(test)
qemu_console_image_holds_serial_terminal_and_no_desktop :: proc(t: ^testing.T) {
	base := qemu_console_test_base()
	files, module_count, problem := qemu_console_image_files(base)
	if !testing.expect_value(t, problem, "") {
		return
	}
	console_modules := QEMU_CONSOLE_MODULES
	refused := QEMU_CONSOLE_REFUSED_MODULES
	kept := make(map[string]bool, context.temp_allocator)
	for file in files[:module_count] {
		kept[file.name] = true
	}
	for name in console_modules {
		testing.expectf(t, kept[name], "the QEMU console image holds %s", name)
	}
	for name in refused {
		testing.expectf(t, !kept[name], "the QEMU console image refuses %s", name)
	}
	testing.expect(t, kept["serial_terminal"] && kept["console"] && kept["start_policy"])
	testing.expect(t, !kept["dom_terminal"] && !kept["grid_terminal"] && !kept["compositor"])

	// Every module in the image is listed or a transitive import of one.
	for name in kept {
		listed := false
		for listed_name in console_modules {
			listed ||= listed_name == name
		}
		imported := false
		for row in foundation.module_builds {
			if kept[row.name] {
				for import_name in row.imports {
					imported ||= import_name == name
				}
			}
		}
		testing.expectf(t, listed || imported, "module %s is listed or imported by QEMU_CONSOLE_MODULES", name)
	}

	// Only start_list and rescue_list resources (no fonts, no pointers).
	resources := files[module_count:]
	testing.expect_value(t, len(resources), 2)
	for resource, index in resources {
		testing.expect_value(t, resource.name, index == 0 ? start_list.START_LIST_RESOURCE : start_list.RESCUE_LIST_RESOURCE)
		list: start_list.List
		place := make([]start_list.Wiring_Row, start_list.list_wiring_count(resource.file), context.temp_allocator)
		read_problem, _, _ := start_list.list_read(resource.file, &list, place)
		testing.expect_value(t, read_problem, start_list.List_Problem.None)
		testing.expect_value(t, list.row_count, 1)
		row := list.rows[0]
		testing.expect_value(t, start_list.row_name(&row), "console")
		testing.expect_value(t, row.needs, start_list.Machine_Parts{})
		testing.expect_value(t, row.usable_mark, start_list.Usable_Mark.Needed)
	}

	// Encoded image parses back cleanly.
	image, encode_problem := qemu_console_boot_image_of(base)
	testing.expect_value(t, encode_problem, "")
	modules, image_resources, valid := info.image_tables(image)
	testing.expect(t, valid)
	testing.expect_value(t, len(modules), module_count)
	testing.expect_value(t, len(image_resources), 2)
	testing.expect_value(t, system_description.name_of(&image_resources[0].name), start_list.START_LIST_RESOURCE)
	testing.expect_value(t, system_description.name_of(&image_resources[1].name), start_list.RESCUE_LIST_RESOURCE)
}

// Bad images, missing required modules, and duplicate modules are refused.
@(test)
qemu_console_image_refuses_missing_modules_duplicates_and_bad_images :: proc(t: ^testing.T) {
	_, _, nil_problem := qemu_console_image_files(nil)
	testing.expect_value(t, nil_problem, "it is not a boot image")

	_, short_problem := qemu_console_boot_image_of([]u8{1, 2, 3, 4})
	testing.expect_value(t, short_problem, "it is not a boot image")

	for missing in ([?]string{"serial_terminal", "console", "root", "start_policy", "storage", "block"}) {
		_, _, problem := qemu_console_image_files(qemu_console_test_base(omit = missing))
		testing.expect_value(t, problem, fmt.tprintf("it holds no module %s", missing))
	}

	_, _, dup_problem := qemu_console_image_files(qemu_console_test_base(duplicate = "serial_terminal"))
	testing.expect_value(t, dup_problem, "the image holds the module serial_terminal twice")
}

// The start and rescue lists of the QEMU console image pass start_list_problems.
@(test)
qemu_console_lists_pass_start_list_checks :: proc(t: ^testing.T) {
	modules := QEMU_CONSOLE_MODULES
	rows := BROWSER_MACHINE_CONSOLE_START_LIST
	testing.expect_value(t, len(start_list_problems(rows[:], modules[:], false)), 0)
	testing.expect_value(t, len(start_list_problems(rows[:], modules[:], true)), 0)
}
