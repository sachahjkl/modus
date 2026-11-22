#+build !freestanding
package build

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"
import info "modus:contract/boot_info"
import "modus:contract/start_list"
import terminal_records "modus:terminal"
import "modustool:foundation"

// A module of the binary format with one import section and one export
// section, built byte by byte.
@(private = "file")
webassembly_module_bytes :: proc(sections: ..[]u8) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, ..transmute([]u8)string(WEBASSEMBLY_MAGIC))
	append(&bytes, ..transmute([]u8)string(WEBASSEMBLY_VERSION))
	for section in sections {
		append(&bytes, ..section)
	}
	return bytes[:]
}

@(private = "file")
webassembly_section :: proc(id: u8, content: []u8) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, id)
	// The length in LEB128: a section of the border passes 127 bytes.
	length := len(content)
	for {
		next := u8(length & 0x7F)
		length >>= 7
		if length == 0 {
			append(&bytes, next)
			break
		}
		append(&bytes, next | 0x80)
	}
	append(&bytes, ..content)
	return bytes[:]
}

@(private = "file")
webassembly_name :: proc(bytes: ^[dynamic]u8, name: string) {
	append(bytes, u8(len(name)))
	append(bytes, ..transmute([]u8)name)
}

// The border of the kernel as the page gives it: each import a function of
// modus_page, and each export.
@(private = "file")
webassembly_kernel_border :: proc() -> []u8 {
	imports := make([dynamic]u8, context.temp_allocator)
	names := BROWSER_MACHINE_IMPORT_NAMES
	append(&imports, u8(len(names)))
	for name in names {
		webassembly_name(&imports, BROWSER_MACHINE_IMPORT_MODULE)
		webassembly_name(&imports, name)
		append(&imports, u8(Webassembly_External_Kind.Function), 0)
	}
	exports := make([dynamic]u8, context.temp_allocator)
	expected := BROWSER_MACHINE_EXPORTS
	append(&exports, u8(len(expected)))
	for item in expected {
		webassembly_name(&exports, item.name)
		append(&exports, u8(item.kind), 0)
	}
	// A type section before them: a section that the reader skips.
	return webassembly_module_bytes(webassembly_section(1, {1, 0x60, 0, 0}), webassembly_section(WEBASSEMBLY_SECTION_IMPORT, imports[:]), webassembly_section(WEBASSEMBLY_SECTION_EXPORT, exports[:]))
}

@(test)
webassembly_border_read_refuses_what_is_not_a_module :: proc(t: ^testing.T) {
	for bytes in ([][]u8{{}, {0, 'a', 's'}, {0, 'a', 's', 'm', 2, 0, 0, 0}, {'a', 's', 'm', 0, 1, 0, 0, 0}}) {
		_, _, fault := webassembly_border_read(bytes, context.temp_allocator)
		testing.expect_value(t, fault, Webassembly_Read_Fault.Not_Webassembly)
	}
}

@(test)
webassembly_border_read_refuses_damaged_sections :: proc(t: ^testing.T) {
	// A section longer than the bytes that follow it.
	_, _, fault := webassembly_border_read(webassembly_module_bytes({WEBASSEMBLY_SECTION_IMPORT, 9, 1}), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
	// A length whose LEB128 never ends within 64 bits.
	_, _, fault = webassembly_border_read(webassembly_module_bytes({1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01}), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Number_Too_Long)
	// An export of the kind 5, which names no kind.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_EXPORT, {1, 1, 'x', 5, 0})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Unknown_Kind)
	// An imported memory whose limits have the flag 8.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {1, 1, 'm', 1, 'x', 2, 8, 1})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Unknown_Limits)
	// A count of two imports with the bytes of one.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {2, 1, 'm', 1, 'x', 0, 0})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
	// An import section with bytes after its last import.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {1, 1, 'm', 1, 'x', 0, 0, 7})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
}

@(test)
browser_machine_border_faults_name_each_difference :: proc(t: ^testing.T) {
	imports, exports, fault := webassembly_border_read(webassembly_kernel_border(), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.None)
	names := BROWSER_MACHINE_IMPORT_NAMES
	testing.expect_value(t, len(imports), len(names))
	testing.expect_value(t, len(exports), len(BROWSER_MACHINE_EXPORTS))

	// An import that the page does not give, and one that is missing.
	changed := make([dynamic]Webassembly_Import, context.temp_allocator)
	append(&changed, ..imports[1:])
	append(&changed, Webassembly_Import{module = "env", name = "memcpy", kind = .Function})
	testing.expect_value(t, len(browser_machine_border_faults(changed[:], exports[:], context.temp_allocator)), 2)
	// An import of the right name with the kind of a memory.
	changed[len(changed) - 1] = {module = BROWSER_MACHINE_IMPORT_MODULE, name = imports[0].name, kind = .Memory}
	testing.expect_value(t, len(browser_machine_border_faults(changed[:], exports[:], context.temp_allocator)), 1)
	// An import twice.
	twice := make([dynamic]Webassembly_Import, context.temp_allocator)
	append(&twice, ..imports[:])
	append(&twice, imports[0])
	testing.expect_value(t, len(browser_machine_border_faults(twice[:], exports[:], context.temp_allocator)), 1)
	// The memory exported as a function, and an export more.
	wrong_exports := make([dynamic]Webassembly_Export, context.temp_allocator)
	append(&wrong_exports, ..exports[:])
	wrong_exports[0].kind = .Function
	append(&wrong_exports, Webassembly_Export{name = "modus_vm_init", kind = .Function})
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], wrong_exports[:], context.temp_allocator)), 3)
	// No export at all.
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], {}, context.temp_allocator)), len(BROWSER_MACHINE_EXPORTS))

	// Last: the border of the kernel has no fault.
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], exports[:], context.temp_allocator)), 0)
}

// The text of the host of the page.
@(private = "file")
browser_machine_host_text :: proc() -> string {
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		if file.name == BROWSER_MACHINE_HOST_FILE {
			return file.text
		}
	}
	return ""
}

// The numbers of one object of the host, as "name: number," lines between
// "export const <name> = {" and the next "};" (or "}" on one line).
@(private = "file")
host_object_numbers :: proc(t: ^testing.T, constant: string) -> map[string]int {
	numbers := make(map[string]int, context.temp_allocator)
	text := browser_machine_host_text()
	start := strings.index(text, strings.concatenate({"export const ", constant, " = {"}, context.temp_allocator))
	if !testing.expectf(t, start >= 0, "the host names no %s", constant) {
		return numbers
	}
	body := text[start + strings.index_byte(text[start:], '{') + 1:]
	body = body[:strings.index_byte(body, '}')]
	for part in strings.split(body, ",", context.temp_allocator) {
		name, separator, number := strings.partition(part, ":")
		if len(separator) == 0 {
			continue
		}
		value, parsed := strconv.parse_int(strings.trim_space(number))
		testing.expectf(t, parsed, "%s.%s is not a number", constant, strings.trim_space(name))
		numbers[strings.trim_space(name)] = value
	}
	return numbers
}

@(private = "file")
expect_offsets :: proc(t: ^testing.T, constant: string, $T: typeid) {
	numbers := host_object_numbers(t, constant)
	fields := reflect.struct_fields_zipped(T)
	testing.expectf(t, len(numbers) == len(fields), "%s has %d fields, and %v has %d", constant, len(numbers), typeid_of(T), len(fields))
	for field in fields {
		offset, found := numbers[field.name]
		testing.expectf(t, found && offset == int(field.offset), "%s.%s is %d; offset_of is %d", constant, field.name, offset, field.offset)
	}
}

// The host writes the boot record at the offsets of the record that the
// kernel reads: a field moved in boot_info.odin fails here, not in a page.
@(test)
browser_machine_host_writes_the_boot_record_of_the_kernel :: proc(t: ^testing.T) {
	expect_offsets(t, "BOOT_INFO_OFFSETS", info.Boot_Info)
	expect_offsets(t, "FRAMEBUFFER_OFFSETS", info.Framebuffer)
	expect_offsets(t, "MEMORY_RANGE_OFFSETS", info.Memory_Range)
	text := browser_machine_host_text()
	testing.expect(t, strings.contains(text, strings.concatenate({"export const BOOT_INFO_SIZE = ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(size_of(info.Boot_Info)), 10), ";"}, context.temp_allocator)))
	testing.expect(t, strings.contains(text, strings.concatenate({"export const MEMORY_RANGE_SIZE = ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(size_of(info.Memory_Range)), 10), ";"}, context.temp_allocator)))
	for kind in info.Memory_Kind {
		testing.expectf(t, strings.contains(text, strings.concatenate({reflect.enum_string(kind), ": ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(kind), 10)}, context.temp_allocator)), "the host names no Memory_Kind %v", kind)
	}
	for format in info.Pixel_Format {
		testing.expectf(t, strings.contains(text, strings.concatenate({reflect.enum_string(format), ": ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(format), 10)}, context.temp_allocator)), "the host names no Pixel_Format %v", format)
	}
}

// The host gives each import that the tool checks in the kernel, and calls
// each export.
@(test)
browser_machine_host_names_the_border_of_the_tool :: proc(t: ^testing.T) {
	text := browser_machine_host_text()
	testing.expect(t, strings.contains(text, strings.concatenate({"export const PAGE_IMPORT_MODULE = \"", BROWSER_MACHINE_IMPORT_MODULE, "\";"}, context.temp_allocator)))
	names := BROWSER_MACHINE_IMPORT_NAMES
	for name in names {
		testing.expectf(t, strings.contains(text, strings.concatenate({"  \"", name, "\",\n"}, context.temp_allocator)), "PAGE_IMPORT_NAMES names no %s", name)
		testing.expectf(t, strings.contains(text, strings.concatenate({"        ", name, ": "}, context.temp_allocator)), "the imports of the machine give no %s", name)
	}
	exports := BROWSER_MACHINE_EXPORTS
	for item in exports {
		testing.expectf(t, strings.contains(text, strings.concatenate({"\"", item.name, "\""}, context.temp_allocator)), "KERNEL_EXPORT_NAMES names no %s", item.name)
	}
	// And each import of the host is an import of the tool: a name added
	// to the host and to the kernel alone fails here, not at the build.
	start := strings.index(text, "export const PAGE_IMPORT_NAMES = [")
	if !testing.expect(t, start >= 0, "the host names no PAGE_IMPORT_NAMES") {
		return
	}
	body := text[start + strings.index_byte(text[start:], '[') + 1:]
	body = body[:strings.index_byte(body, ']')]
	host_count := 0
	for part in strings.split(body, ",", context.temp_allocator) {
		name := strings.trim(strings.trim_space(part), "\"")
		if len(name) == 0 {
			continue
		}
		host_count += 1
		known := false
		for tool_name in names {
			known ||= tool_name == name
		}
		testing.expectf(t, known, "the host gives %s, which BROWSER_MACHINE_IMPORT_NAMES does not name", name)
	}
	testing.expect_value(t, host_count, len(names))
}

// The line of the framebuffer of the Node program: each form that is not
// "framebuffer: <lit> <pixels>" with lit at most pixels is refused.
@(test)
browser_machine_framebuffer_line_refuses_each_damaged_form :: proc(t: ^testing.T) {
	refused := []string {
		"",
		"framebuffer:",
		"framebuffer: ",
		"framebuffer: 12",
		"framebuffer: 12 ",
		"framebuffer:  12 100",
		"framebuffer: -1 100",
		"framebuffer: 12 x",
		"framebuffer: 101 100",
		"framebuffer: 0 0",
		"framebuffer: 1 18446744073709551616",
		"Framebuffer: 1 100",
		"serial: framebuffer: 1 100",
	}
	for line in refused {
		_, _, ok := browser_machine_framebuffer_line_parse(line)
		testing.expectf(t, !ok, "%q is read", line)
	}
	lit, pixels, ok := browser_machine_framebuffer_line_parse("framebuffer: 0 1024000")
	testing.expect(t, ok)
	testing.expect_value(t, lit, u64(0))
	testing.expect_value(t, pixels, u64(1024000))
	lit, pixels, ok = browser_machine_framebuffer_line_parse("framebuffer: 1024000 1024000")
	testing.expect(t, ok && lit == 1024000 && pixels == 1024000)
}

// The host raises the lines that the kernel delivers to the input service,
// and the import that gives them to the kernel is in the imports of the
// machine.
@(test)
browser_machine_host_raises_the_lines_of_the_input_service :: proc(t: ^testing.T) {
	text := browser_machine_host_text()
	lines := host_object_numbers(t, "InterruptLine")
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines["Keyboard"], 1)
	testing.expect_value(t, lines["Mouse"], 12)
	testing.expect(t, strings.contains(text, "page_interrupt_lines_take: () => machine.interruptLinesTake(),"))
	// The command that the boot types needs only keys of the layout.
	testing.expect(t, strings.contains(text, "[\"Digit9\", \"9\", \"(\"]"))
	testing.expect(t, strings.contains(text, "[\"Digit0\", \"0\", \")\"]"))
	for character in BROWSER_MACHINE_TYPED_COMMAND {
		testing.expectf(t, (character >= 'a' && character <= 'z') || character == '(' || character == ')', "the command has %q, which the test does not find in the layout", character)
	}
}

// Each file of the page that another file names is a file of the page.
@(test)
browser_machine_page_files_name_each_other :: proc(t: ^testing.T) {
	files := BROWSER_MACHINE_PAGE_FILES
	text_of :: proc(files: []Browser_Machine_Page_File, name: string) -> string {
		for file in files {
			if file.name == name {
				return file.text
			}
		}
		return ""
	}
	testing.expect(t, strings.has_prefix(text_of(files[:], "browser_machine.html"), "<!doctype html>"))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine.html"), "src=\"browser_machine_page.js\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "new Worker(\"browser_machine_worker.js\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "\"" + BROWSER_MACHINE_KERNEL_FILE + "\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "\"" + BROWSER_MACHINE_BOOT_IMAGE_FILE + "\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_worker.js"), "from \"./" + BROWSER_MACHINE_HOST_FILE + "\""))
	for file in files {
		testing.expectf(t, len(file.text) > 0, "%s is empty", file.name)
	}
}

// A base image of the test: one file for each name, a module or a
// resource, whose bytes are its name.
@(private = "file")
page_image_base :: proc(module_names: []string, resource_names: []string) -> []u8 {
	files := make([dynamic]Image_File, context.temp_allocator)
	for name in module_names {
		append(&files, Image_File{name = name, file = transmute([]u8)name})
	}
	for name in resource_names {
		append(&files, Image_File{name = name, file = transmute([]u8)name})
	}
	return boot_image_encode(files[:], len(module_names))
}

// The boot image of the page keeps the modules of the page and their
// imports, and each resource but the three that the signature makes again;
// it drops each other module. It refuses a base that is not an image, that
// lacks a module of the page or an import of one, or that holds a module
// twice.
@(test)
browser_machine_page_image_keeps_the_modules_of_the_page :: proc(t: ^testing.T) {
	page_modules := BROWSER_MACHINE_PAGE_MODULES
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..page_modules[:])
	// The import of unlock and of remote, which the list does not name.
	append(&all, "cryptography")
	tests := []string{"flood", "arena", "kernel_events", "shortage"}
	with_tests := make([dynamic]string, context.temp_allocator)
	append(&with_tests, "flood")
	append(&with_tests, ..all[:])
	append(&with_tests, ..tests[1:])
	resources := []string{"start_list", "rescue_list", "pointers", "replacement_list", "system_description", "system_description_signature"}

	files, module_count, problem := browser_machine_page_image_files(page_image_base(with_tests[:], resources))
	testing.expect_value(t, problem, "")
	testing.expect_value(t, module_count, len(all))
	for name, index in all {
		if index < len(files) {
			testing.expect_value(t, files[index].name, name)
			testing.expect_value(t, string(files[index].file), name)
		}
	}
	kept_resources := []string{"start_list", "rescue_list", "pointers"}
	testing.expect_value(t, len(files), len(all) + len(kept_resources))
	for name, index in kept_resources {
		if len(all) + index < len(files) {
			testing.expect_value(t, files[len(all) + index].name, name)
		}
	}

	// The refusals.
	_, _, problem = browser_machine_page_image_files(nil)
	testing.expect_value(t, problem, "it is not a boot image")
	_, _, problem = browser_machine_page_image_files(transmute([]u8)string("not an image of the system"))
	testing.expect_value(t, problem, "it is not a boot image")
	without_import := make([dynamic]string, context.temp_allocator)
	append(&without_import, ..page_modules[:])
	_, _, problem = browser_machine_page_image_files(page_image_base(without_import[:], resources))
	testing.expect_value(t, problem, "it holds no module cryptography")
	without_root := make([dynamic]string, context.temp_allocator)
	for name in all {
		if name != "root" {
			append(&without_root, name)
		}
	}
	_, _, problem = browser_machine_page_image_files(page_image_base(without_root[:], resources))
	testing.expect_value(t, problem, "it holds no module root")
	twice := make([dynamic]string, context.temp_allocator)
	append(&twice, ..all[:])
	append(&twice, "console")
	_, _, problem = browser_machine_page_image_files(page_image_base(twice[:], resources))
	testing.expect_value(t, problem, "the image holds the module console twice")
	// An entry that points past the end of the image.
	damaged := page_image_base(all[:], resources)
	modules, _, _ := info.image_tables(damaged)
	modules[0].size = u64(len(damaged))
	_, _, problem = browser_machine_page_image_files(damaged)
	testing.expect_value(t, problem, "the entry of the module root points outside the image")
}


// The console of the page is on COM2 and the log of the kernel on COM1: the
// host plays a UART at each, the data port of COM2 is the first port that
// the root service gives serial_terminal, and the console page reads COM2,
// types on COM2, and loads the console image.
@(test)
browser_machine_host_puts_the_console_on_com2 :: proc(t: ^testing.T) {
	text := browser_machine_host_text()
	testing.expect(t, strings.contains(text, "  SerialData: 0x3f8,\n"))
	testing.expect(t, strings.contains(text, fmt.tprintf("  ConsoleData: 0x%x,\n", terminal_records.SERIAL_PORT_FIRST)))
	testing.expect(t, strings.contains(text, fmt.tprintf("export const SERIAL_PORT_COUNT = %d;", terminal_records.SERIAL_PORT_COUNT)))
	testing.expect(t, strings.contains(text, "this.serial = new SerialPort(onSerialLine, Port.SerialData);"))
	testing.expect(t, strings.contains(text, "this.consolePort = new SerialPort(onConsoleLine, Port.ConsoleData, onConsoleBytes);"))
	// COM1 and COM2 never overlap.
	testing.expect(t, terminal_records.SERIAL_PORT_FIRST + terminal_records.SERIAL_PORT_COUNT <= 0x3F8 || terminal_records.SERIAL_PORT_FIRST >= 0x3F8 + terminal_records.SERIAL_PORT_COUNT)
	page := BROWSER_MACHINE_CONSOLE_PAGE_TEXT
	testing.expect(t, strings.has_prefix(page, "<!doctype html>"))
	testing.expect(t, strings.contains(page, "from \"./" + BROWSER_MACHINE_HOST_FILE + "\""))
	testing.expect(t, strings.contains(page, "fetch(\"./" + BROWSER_MACHINE_KERNEL_FILE + "\")"))
	testing.expect(t, strings.contains(page, "fetch(\"./" + BROWSER_MACHINE_CONSOLE_IMAGE_FILE + "\")"))
	testing.expect(t, strings.contains(page, "onConsoleBytes:"))
	testing.expect(t, strings.contains(page, "machine.consolePort.type(sequence)"))
	testing.expect(t, !strings.contains(page, "machine.serial.input"))
	// The site publishes the desktop page only: the console page needs its
	// own image, which the site does not write.
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		testing.expect(t, file.name != BROWSER_MACHINE_CONSOLE_PAGE_FILE)
	}
}

// A base image of the test with every module of the module table and the
// resources of a desktop image.
@(private = "file")
console_image_base :: proc(without: string = "") -> []u8 {
	names := make([dynamic]string, context.temp_allocator)
	for build in foundation.module_builds {
		if build.name != without {
			append(&names, build.name)
		}
	}
	resources := []string{"start_list", "rescue_list", "pointers", "font_outlines", "replacement_list", "system_description", "system_description_signature"}
	files := make([dynamic]Image_File, context.temp_allocator)
	for name in names {
		append(&files, Image_File{name = name, file = transmute([]u8)name})
	}
	for name in resources {
		append(&files, Image_File{name = name, file = transmute([]u8)name})
	}
	return boot_image_encode(files[:], len(names))
}

// The console image holds the modules of BROWSER_MACHINE_CONSOLE_MODULES and
// their imports only: serial_terminal and start_policy, and no compositor,
// no terminal of the desktop, no drawing module, no input service and no
// grid_terminal. Its resources are its own start list and rescue list,
// which name the console alone with no machine part: no font, no pointer
// theme, and none of the three resources that the signature makes again.
// The image that the files give reads back with its tables.
@(test)
browser_machine_console_image_holds_the_console_and_no_desktop :: proc(t: ^testing.T) {
	files, module_count, problem := browser_machine_page_image_files(console_image_base(), .Console)
	if !testing.expect_value(t, problem, "") {
		return
	}
	console_modules := BROWSER_MACHINE_CONSOLE_MODULES
	refused := BROWSER_MACHINE_CONSOLE_REFUSED_MODULES
	kept := make(map[string]bool, context.temp_allocator)
	for file in files[:module_count] {
		kept[file.name] = true
	}
	for name in console_modules {
		testing.expectf(t, kept[name], "the console image holds no %s", name)
	}
	for name in refused {
		testing.expectf(t, !kept[name], "the console image holds %s", name)
	}
	testing.expect(t, kept["serial_terminal"] && kept["start_policy"])
	// Each module is a module of the list or an import of a kept module.
	for name in kept {
		imported := false
		for build in foundation.module_builds {
			if kept[build.name] {
				for import_name in build.imports {
					imported ||= import_name == name
				}
			}
		}
		listed := false
		for listed_name in console_modules {
			listed ||= listed_name == name
		}
		testing.expectf(t, listed || imported, "the console image holds %s, which no module of the list imports", name)
	}
	resources := files[module_count:]
	testing.expect_value(t, len(resources), 2)
	for resource, index in resources {
		testing.expect_value(t, resource.name, index == 0 ? start_list.START_LIST_RESOURCE : start_list.RESCUE_LIST_RESOURCE)
		list: start_list.List
		read_problem, _, _ := start_list.list_read(resource.file, &list)
		testing.expect_value(t, read_problem, start_list.List_Problem.None)
		testing.expect_value(t, list.row_count, 1)
		row := list.rows[0]
		testing.expect_value(t, start_list.row_name(&row), "console")
		testing.expect_value(t, row.needs, start_list.Machine_Parts{})
		testing.expect_value(t, row.usable_mark, start_list.Usable_Mark.Needed)
	}
	image := boot_image_encode(files, module_count)
	modules, image_resources, valid := info.image_tables(image)
	testing.expect(t, valid)
	testing.expect_value(t, len(modules), module_count)
	testing.expect_value(t, len(image_resources), 2)

	// The desktop image of the same base keeps its fonts and its pointers.
	desktop, desktop_count, desktop_problem := browser_machine_page_image_files(console_image_base(), .Desktop)
	testing.expect_value(t, desktop_problem, "")
	testing.expect(t, desktop_count > module_count)
	testing.expect_value(t, len(desktop) - desktop_count, 4)
}

// A base with no serial_terminal, or with no console, gives no console
// image: the root service would find no terminal, or no shell, for the page.
// A base that is not an image is refused first.
@(test)
browser_machine_console_image_refuses_a_base_without_its_modules :: proc(t: ^testing.T) {
	for name in ([?]string{"serial_terminal", "console", "start_policy", "root"}) {
		_, _, problem := browser_machine_page_image_files(console_image_base(name), .Console)
		testing.expect_value(t, problem, fmt.tprintf("it holds no module %s", name))
	}
	_, _, problem := browser_machine_page_image_files(nil, .Console)
	testing.expect_value(t, problem, "it is not a boot image")
}

// The lists of the console image pass the check of the lists of each image
// of the build: a rescue list with a row that makes the machine usable, and
// rows that name modules of the image.
@(test)
browser_machine_console_lists_pass_the_check_of_the_build :: proc(t: ^testing.T) {
	modules := BROWSER_MACHINE_CONSOLE_MODULES
	rows := BROWSER_MACHINE_CONSOLE_START_LIST
	testing.expect_value(t, len(start_list_problems(rows[:], modules[:], false)), 0)
	testing.expect_value(t, len(start_list_problems(rows[:], modules[:], true)), 0)
	for row in rows {
		testing.expect_value(t, row.needs, start_list.Machine_Parts{})
		testing.expect(t, row.name != "display" && row.name != "input")
	}
	files, problem := browser_machine_console_list_files()
	testing.expect_value(t, problem, "")
	testing.expect(t, len(files[0].file) > 0 && len(files[1].file) > 0)
}
