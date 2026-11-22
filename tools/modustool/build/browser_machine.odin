// The browser machine of the tool: the build of the kernel for
// WebAssembly, the check of its border with the page, the folder of the
// page, and its start in Node (src/md/features/browser_machine.md, "The
// page and its host").
package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/replacement_list"
import "modus:contract/start_list"
import "modus:contract/system_description"
import "modustool:foundation"

BROWSER_MACHINE_FOLDER :: foundation.BUILD_FOLDER + "/browser_machine"
BROWSER_MACHINE_KERNEL_FILE :: "modulus_kernel.wasm"
BROWSER_MACHINE_BOOT_IMAGE_FILE :: "boot.image"
BROWSER_MACHINE_HOST_FILE :: "browser_machine_host.js"
BROWSER_MACHINE_KERNEL_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_KERNEL_FILE
BROWSER_MACHINE_BOOT_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_BOOT_IMAGE_FILE
BROWSER_MACHINE_HOST_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_HOST_FILE
// The boot image of the page before its signature: the input of the signed
// write of the system description.
BROWSER_MACHINE_UNSIGNED_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/boot_unsigned.image"
// The console page and its boot image, beside the desktop page: the
// console image has its own name, so the two pages share the kernel and
// the host and never overwrite the image of the other.
BROWSER_MACHINE_CONSOLE_PAGE_FILE :: "browser_machine_console.html"
BROWSER_MACHINE_CONSOLE_IMAGE_FILE :: "console.image"
BROWSER_MACHINE_CONSOLE_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_CONSOLE_IMAGE_FILE
BROWSER_MACHINE_CONSOLE_UNSIGNED_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/console_unsigned.image"

// The modules of the boot image of the page: the desktop and its
// applications, the holder of each role of the root service
// (src/modules/system/root/role_holders.odin), and the module of each row
// of the start list and of the rescue list (start_lists.odin). The imports
// of each one join it from the module table. No module that only a test
// runs is in it: the root service hashes each file of the image at its
// start, and the software processor makes each byte of that work slow.
@(rodata)
BROWSER_MACHINE_PAGE_MODULES := [?]string {
	// The services of the start and the holders of the roles.
	"root",
	"log",
	"wiring",
	"start_policy",
	"input",
	"compositor",
	"console",
	"terminal",
	"settings",
	"date",
	"unlock",
	"storage",
	"module_files",
	"network",
	"block",
	"frame",
	"sound",
	"entropy",
	"tpm",
	"remote",
	"remote_display",
	"plans",
	"recipes",
	"projects",
	"powerbox",
	"collector",
	"disk_processes",
	"devices",
	"principals",
	// The libraries of the windows.
	"drawing",
	"interface_module",
	// The applications of the desktop.
	"monitor",
	"edit",
	"notes",
	"browser",
	"inspect",
	"clock",
	"life",
	"paint",
	"plasma",
	"heron",
	"manual",
	"disk",
	// The demonstration pair of the default start list.
	"wired_reader",
	"wired_writer",
}

// The modules of the console image of the page
// (src/md/features/console_renderers.md, "The console image"): the core
// services of the root service, the console with its compilers, and
// dom_terminal as its terminal on the second serial port, whose lines the
// page draws with its document. No compositor, no drawing module, no
// window and no font: the root service finds no compositor in the image
// and gives the role Terminal to dom_terminal. block is the device service of the data disk of the
// private store of the console; devices, principals and disk_processes
// are the delegated services that the root service starts at each boot.
@(rodata)
BROWSER_MACHINE_CONSOLE_MODULES := [?]string {
	"root",
	"start_policy",
	"log",
	"wiring",
	"dom_terminal",
	"console",
	"c_compiler",
	"assemble",
	"storage",
	"block",
	"devices",
	"principals",
	"disk_processes",
}

// The modules that a console image never holds: each one draws, or holds
// the screen, and the root service would run the desktop with it; or it
// is another renderer of the terminal, which the page does not read.
@(rodata)
BROWSER_MACHINE_CONSOLE_REFUSED_MODULES := [?]string{"compositor", "terminal", "drawing", "interface_module", "grid_terminal", "serial_terminal", "input"}

// The start list and the rescue list of the console image: the console
// alone, which needs no screen. Its terminal starts with it.
@(rodata)
BROWSER_MACHINE_CONSOLE_START_LIST := [?]Start_List_Row{{name = "console", absent_rule = .Not_Started, usable_mark = .Needed}}

// Which boot image of a page the tool writes.
Browser_Machine_Image :: enum u8 {
	Desktop = 0, // The desktop and its applications: BROWSER_MACHINE_PAGE_MODULES.
	Console = 1, // The console on the serial port: BROWSER_MACHINE_CONSOLE_MODULES.
}

// The lowest major version of Node that runs the host: the version that the
// development shell of the project was checked with.
BROWSER_MACHINE_NODE_MAJOR_VERSION :: 24

// The lines of the kernel that a start in Node must write: its mark, and,
// with a boot image, the line of the stage of the root service.
BROWSER_MACHINE_KERNEL_MARK :: "kernel: ok"
BROWSER_MACHINE_ROOT_STAGE_LINE :: "kernel: boot: kernel: root service: "

// The interactive part of a start with a boot image: once the root service
// writes its usable line, the host types the command on the PS/2 keyboard,
// and the console must write the answer line. The answer is the line of
// help() for shutdown: the echo of the typed line does not hold it.
BROWSER_MACHINE_USABLE_LINE :: "[console] kernel console"
BROWSER_MACHINE_TYPED_COMMAND :: "help()"
BROWSER_MACHINE_ANSWER_PREFIX :: "[console] shutdown "
BROWSER_MACHINE_ANSWER_TEXT :: "stop the machine"

// One file of the page of a browser machine. The site writes the same
// files (site_browser_machine.odin).
Browser_Machine_Page_File :: struct {
	name: string,
	text: string,
}

BROWSER_MACHINE_PAGE_FILES :: [?]Browser_Machine_Page_File {
	{"browser_machine.html", #load("browser_machine/browser_machine.html", string)},
	{"browser_machine_page.js", #load("browser_machine/browser_machine_page.js", string)},
	{"browser_machine_worker.js", #load("browser_machine/browser_machine_worker.js", string)},
	{BROWSER_MACHINE_HOST_FILE, #load("browser_machine/browser_machine_host.js", string)},
}

// The border of the kernel with the page: the module of the imports, the
// name of each import (each is a function), and each export. The host of
// the page names the same lists.
BROWSER_MACHINE_IMPORT_MODULE :: "modus_page"
BROWSER_MACHINE_IMPORT_NAMES :: [?]string {
	"page_clock_nanoseconds",
	"page_port_write_8",
	"page_port_read_8",
	"page_processor_loop_unwind",
	"page_processor_stop",
	"page_idle_wait",
	"page_interrupt_lines_take",
}
BROWSER_MACHINE_EXPORTS :: [?]Webassembly_Export {
	{name = "memory", kind = .Memory},
	{name = "entry", kind = .Function},
	{name = "modus_processor_loop_run", kind = .Function},
	// The pointer of the shadow stack, which the page sets back to the top
	// after each throw of the processor loop.
	{name = BROWSER_MACHINE_STACK_POINTER_EXPORT, kind = .Global},
}
BROWSER_MACHINE_STACK_POINTER_EXPORT :: "__stack_pointer"

// The kind of an import or an export of a WebAssembly module: the byte of
// its description in the binary format.
Webassembly_External_Kind :: enum u8 {
	Function = 0,
	Table    = 1,
	Memory   = 2,
	Global   = 3,
	Tag      = 4,
}

Webassembly_Import :: struct {
	module, name: string,
	kind:         Webassembly_External_Kind,
}

Webassembly_Export :: struct {
	name: string,
	kind: Webassembly_External_Kind,
}

// Why the read of a WebAssembly module stopped.
Webassembly_Read_Fault :: enum {
	None,
	Not_Webassembly, // The magic number or the version is not the one of the binary format 1.
	Truncated, // A section, a number or a name passes the end of its bytes.
	Number_Too_Long, // A number of LEB128 has more bytes than a number of 64 bits.
	Unknown_Kind, // The byte of a kind names no kind.
	Unknown_Limits, // The flags of the limits of a table or a memory name no form.
}

WEBASSEMBLY_MAGIC :: "\x00asm"
WEBASSEMBLY_VERSION :: "\x01\x00\x00\x00"
WEBASSEMBLY_SECTION_IMPORT :: 2
WEBASSEMBLY_SECTION_EXPORT :: 7
// The flags of limits: bit 0 a maximum, bit 1 shared, bit 2 addresses of 64 bits.
WEBASSEMBLY_LIMITS_FLAGS_ALL :: 0x07

@(private = "file")
Webassembly_Reader :: struct {
	bytes: []u8,
	at:    int,
	fault: Webassembly_Read_Fault,
}

@(private = "file")
reader_byte :: proc(reader: ^Webassembly_Reader) -> u8 {
	if reader.fault != .None {
		return 0
	}
	if reader.at >= len(reader.bytes) {
		reader.fault = .Truncated
		return 0
	}
	reader.at += 1
	return reader.bytes[reader.at - 1]
}

@(private = "file")
reader_number :: proc(reader: ^Webassembly_Reader) -> u64 {
	value: u64
	for shift: uint = 0; reader.fault == .None; shift += 7 {
		if shift >= 64 {
			reader.fault = .Number_Too_Long
			return 0
		}
		next := reader_byte(reader)
		value |= u64(next & 0x7F) << shift
		if next & 0x80 == 0 {
			return value
		}
	}
	return 0
}

@(private = "file")
reader_bytes :: proc(reader: ^Webassembly_Reader, count: u64) -> []u8 {
	if reader.fault != .None {
		return nil
	}
	if count > u64(len(reader.bytes) - reader.at) {
		reader.fault = .Truncated
		return nil
	}
	start := reader.at
	reader.at += int(count)
	return reader.bytes[start:reader.at]
}

@(private = "file")
reader_name :: proc(reader: ^Webassembly_Reader) -> string {
	return string(reader_bytes(reader, reader_number(reader)))
}

@(private = "file")
reader_kind :: proc(reader: ^Webassembly_Reader) -> Webassembly_External_Kind {
	word := reader_byte(reader)
	if reader.fault != .None {
		return .Function
	}
	switch word {
	case u8(Webassembly_External_Kind.Function):
		return .Function
	case u8(Webassembly_External_Kind.Table):
		return .Table
	case u8(Webassembly_External_Kind.Memory):
		return .Memory
	case u8(Webassembly_External_Kind.Global):
		return .Global
	case u8(Webassembly_External_Kind.Tag):
		return .Tag
	}
	reader.fault = .Unknown_Kind
	return .Function
}

@(private = "file")
reader_limits :: proc(reader: ^Webassembly_Reader) {
	flags := reader_byte(reader)
	if flags & ~u8(WEBASSEMBLY_LIMITS_FLAGS_ALL) != 0 {
		if reader.fault == .None {
			reader.fault = .Unknown_Limits
		}
		return
	}
	_ = reader_number(reader)
	if flags & 1 != 0 {
		_ = reader_number(reader)
	}
}

// webassembly_border_read reads the imports and the exports of a
// WebAssembly module. The names are slices of bytes.
webassembly_border_read :: proc(bytes: []u8, allocator := context.allocator) -> (imports: [dynamic]Webassembly_Import, exports: [dynamic]Webassembly_Export, fault: Webassembly_Read_Fault) {
	imports = make([dynamic]Webassembly_Import, allocator)
	exports = make([dynamic]Webassembly_Export, allocator)
	if len(bytes) < 8 || string(bytes[:4]) != WEBASSEMBLY_MAGIC || string(bytes[4:8]) != WEBASSEMBLY_VERSION {
		return imports, exports, .Not_Webassembly
	}
	reader := Webassembly_Reader{bytes = bytes, at = 8}
	for reader.fault == .None && reader.at < len(bytes) {
		section := reader_byte(&reader)
		content := reader_bytes(&reader, reader_number(&reader))
		if reader.fault != .None {
			break
		}
		if section != WEBASSEMBLY_SECTION_IMPORT && section != WEBASSEMBLY_SECTION_EXPORT {
			continue
		}
		inner := Webassembly_Reader{bytes = content}
		count := reader_number(&inner)
		for _ in 0 ..< count {
			if inner.fault != .None {
				break
			}
			if section == WEBASSEMBLY_SECTION_EXPORT {
				name := reader_name(&inner)
				kind := reader_kind(&inner)
				_ = reader_number(&inner)
				append(&exports, Webassembly_Export{name = name, kind = kind})
				continue
			}
			module := reader_name(&inner)
			name := reader_name(&inner)
			kind := reader_kind(&inner)
			switch kind {
			case .Function, .Tag:
				if kind == .Tag {
					_ = reader_byte(&inner)
				}
				_ = reader_number(&inner)
			case .Table:
				_ = reader_byte(&inner)
				reader_limits(&inner)
			case .Memory:
				reader_limits(&inner)
			case .Global:
				_ = reader_byte(&inner)
				_ = reader_byte(&inner)
			}
			append(&imports, Webassembly_Import{module = module, name = name, kind = kind})
		}
		if inner.fault != .None {
			reader.fault = inner.fault
		} else if inner.at != len(content) {
			reader.fault = .Truncated
		}
	}
	return imports, exports, reader.fault
}

// browser_machine_border_faults lists each difference between the border
// of a kernel and the border that the page gives: an import or an export
// that the page does not know, one that is missing, and one that comes
// twice. No fault: the kernel runs on the host of the page.
browser_machine_border_faults :: proc(imports: []Webassembly_Import, exports: []Webassembly_Export, allocator := context.allocator) -> []string {
	faults := make([dynamic]string, allocator)
	import_names := BROWSER_MACHINE_IMPORT_NAMES
	for item in imports {
		known := item.module == BROWSER_MACHINE_IMPORT_MODULE && item.kind == .Function
		if known {
			known = false
			for name in import_names {
				known ||= name == item.name
			}
		}
		if !known {
			append(&faults, fmt.aprintf("the import %s.%s (%v) is not an import that the page gives", item.module, item.name, item.kind, allocator = allocator))
		}
	}
	for name in import_names {
		count := 0
		for item in imports {
			count += int(item.module == BROWSER_MACHINE_IMPORT_MODULE && item.name == name)
		}
		if count != 1 {
			append(&faults, fmt.aprintf("the import %s.%s comes %d times, not once", BROWSER_MACHINE_IMPORT_MODULE, name, count, allocator = allocator))
		}
	}
	expected_exports := BROWSER_MACHINE_EXPORTS
	for item in exports {
		known := false
		for expected in expected_exports {
			known ||= expected == item
		}
		if !known {
			append(&faults, fmt.aprintf("the export %s (%v) is not an export that the page calls", item.name, item.kind, allocator = allocator))
		}
	}
	for expected in expected_exports {
		count := 0
		for item in exports {
			count += int(item == expected)
		}
		if count != 1 {
			append(&faults, fmt.aprintf("the export %s (%v) comes %d times, not once", expected.name, expected.kind, count, allocator = allocator))
		}
	}
	return faults[:]
}

// browser_machine_build compiles the kernel for WebAssembly into the folder
// of the page, checks its border, and writes the files of the page beside
// it, with a copy of the boot image of the build when there is one.
browser_machine_build :: proc() -> bool {
	if error := os.make_directory_all(BROWSER_MACHINE_FOLDER); error != nil && error != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", BROWSER_MACHINE_FOLDER, error)
		return false
	}
	kernel := BROWSER_MACHINE_KERNEL_PATH
	if !foundation.run({"odin", "build", foundation.SOURCE_FOLDER_KERNEL, "-target:freestanding_wasm64p32", "-o:speed", "-no-entry-point", "-default-to-nil-allocator", foundation.SOURCE_LIBRARY_FLAG, foundation.INTERNAL_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG, "-extra-linker-flags:--export=" + BROWSER_MACHINE_STACK_POINTER_EXPORT, "-out:" + BROWSER_MACHINE_KERNEL_PATH}) {
		return false
	}
	bytes, read_error := os.read_entire_file(kernel, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", kernel, read_error)
		return false
	}
	imports, exports, fault := webassembly_border_read(bytes, context.temp_allocator)
	if fault != .None {
		fmt.eprintfln("modustool: %s is not a WebAssembly module that the tool reads: %v", kernel, fault)
		return false
	}
	faults := browser_machine_border_faults(imports[:], exports[:], context.temp_allocator)
	for line in faults {
		fmt.eprintfln("modustool: %s: %s", kernel, line)
	}
	if len(faults) != 0 {
		return false
	}
	fmt.printfln("modustool: %s: %d bytes, %d imports of %s, the exports %d", kernel, len(bytes), len(imports), BROWSER_MACHINE_IMPORT_MODULE, len(exports))
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		path := strings.concatenate({BROWSER_MACHINE_FOLDER, "/", file.name}, context.temp_allocator)
		if error := os.write_entire_file(path, transmute([]u8)file.text); error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", path, error)
			return false
		}
	}
	if os.is_file(BOOT_IMAGE) {
		return browser_machine_page_image_write(BOOT_IMAGE)
	}
	return true
}

// browser_machine_console_list_files gives the start list and the rescue
// list of the console image, written through the contract and checked
// against the modules of that image, as the build checks the lists of each
// image (start_lists.odin).
browser_machine_console_list_files :: proc(allocator := context.temp_allocator) -> (files: [2]Image_File, problem: string) {
	modules := BROWSER_MACHINE_CONSOLE_MODULES
	rows := BROWSER_MACHINE_CONSOLE_START_LIST
	kinds := [2]struct {
		resource: string,
		rescue:   bool,
	}{{start_list.START_LIST_RESOURCE, false}, {start_list.RESCUE_LIST_RESOURCE, true}}
	for kind, index in kinds {
		if problems := start_list_problems(rows[:], modules[:], kind.rescue); len(problems) > 0 {
			return {}, fmt.tprintf("the list %s of the console image is refused: %s", kind.resource, problems[0])
		}
		bytes, _, list_problem := start_list_bytes(rows[:])
		if list_problem != "" {
			return {}, fmt.tprintf("the list %s of the console image is refused: %s", kind.resource, list_problem)
		}
		files[index] = {name = kind.resource, file = bytes}
	}
	return files, ""
}

// browser_machine_page_image_files gives the files of the boot image of a
// page from a boot image of the build, signed or not: each module of the
// modules of the image (BROWSER_MACHINE_PAGE_MODULES, or
// BROWSER_MACHINE_CONSOLE_MODULES) and of their imports, in the order of
// the base, then the resources. The desktop image keeps each resource of
// the base but the system description, its signature and the replacement
// list, which the signed write makes again for these modules. The console
// image keeps no resource of the base, fonts and pointers included, and
// holds its own start list and rescue list. A module of the list that the
// base does not hold is a problem: the page would start a machine with no
// holder for a role. A console image that would hold a module of
// BROWSER_MACHINE_CONSOLE_REFUSED_MODULES, through an import, is a problem
// too: the root service would run the desktop.
browser_machine_page_image_files :: proc(base: []u8, image := Browser_Machine_Image.Desktop, allocator := context.temp_allocator) -> (files: []Image_File, module_count: int, problem: string) {
	modules, resources, valid := info.image_tables(base)
	if !valid {
		return nil, 0, "it is not a boot image"
	}
	wanted := make(map[string]bool, allocator)
	defer delete(wanted)
	desktop_modules := BROWSER_MACHINE_PAGE_MODULES
	console_modules := BROWSER_MACHINE_CONSOLE_MODULES
	page_modules: []string
	switch image {
	case .Desktop:
		page_modules = desktop_modules[:]
	case .Console:
		page_modules = console_modules[:]
	}
	for name in page_modules {
		wanted[name] = false
	}
	// The imports of the table, until no row adds a name.
	for added := true; added; {
		added = false
		for build in foundation.module_builds {
			if build.name not_in wanted {
				continue
			}
			for name in build.imports {
				if name not_in wanted {
					wanted[name] = false
					added = true
				}
			}
		}
	}
	list := make([dynamic]Image_File, allocator)
	for &entry in modules {
		name := system_description.name_of(&entry.name)
		if name not_in wanted {
			continue
		}
		bytes, inside := info.image_entry_bytes(base, &entry)
		if !inside {
			return nil, 0, fmt.tprintf("the entry of the module %s points outside the image", name)
		}
		if wanted[name] {
			return nil, 0, fmt.tprintf("the image holds the module %s twice", name)
		}
		wanted[name] = true
		append(&list, Image_File{name = strings.clone(name, allocator), file = bytes})
	}
	module_count = len(list)
	switch image {
	case .Desktop:
		for &entry in resources {
			name := system_description.name_of(&entry.name)
			if name == system_description.RESOURCE_DESCRIPTION || name == system_description.RESOURCE_SIGNATURE || name == replacement_list.RESOURCE_NAME {
				continue
			}
			bytes, inside := info.image_entry_bytes(base, &entry)
			if !inside {
				return nil, 0, fmt.tprintf("the entry of the resource %s points outside the image", name)
			}
			append(&list, Image_File{name = strings.clone(name, allocator), file = bytes})
		}
	case .Console:
		refused := BROWSER_MACHINE_CONSOLE_REFUSED_MODULES
		for name in refused {
			if name in wanted {
				return nil, 0, fmt.tprintf("the console image would hold the module %s", name)
			}
		}
		lists, list_problem := browser_machine_console_list_files(allocator)
		if list_problem != "" {
			return nil, 0, list_problem
		}
		append(&list, ..lists[:])
	}
	for name, found in wanted {
		if !found {
			return nil, 0, fmt.tprintf("it holds no module %s", name)
		}
	}
	return list[:], module_count, ""
}

// browser_machine_page_image_write writes a boot image of a page from the
// boot image at base_path: the modules and the resources of the image
// (browser_machine_page_image_files), with a system description and its
// signature, as the image of a boot volume (system_description.odin).
@(private = "file")
browser_machine_page_image_write :: proc(base_path: string, image := Browser_Machine_Image.Desktop) -> bool {
	unsigned_path, signed_path: string
	switch image {
	case .Desktop:
		unsigned_path, signed_path = BROWSER_MACHINE_UNSIGNED_IMAGE_PATH, BROWSER_MACHINE_BOOT_IMAGE_PATH
	case .Console:
		unsigned_path, signed_path = BROWSER_MACHINE_CONSOLE_UNSIGNED_IMAGE_PATH, BROWSER_MACHINE_CONSOLE_IMAGE_PATH
	}
	base, read_error := os.read_entire_file(base_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", base_path, read_error)
		return false
	}
	files, module_count, problem := browser_machine_page_image_files(base, image)
	if problem != "" {
		fmt.eprintfln("modustool: the %v boot image of the page from %s: %s", image, base_path, problem)
		return false
	}
	unsigned := boot_image_encode(files, module_count)
	if error := os.write_entire_file(unsigned_path, unsigned); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", unsigned_path, error)
		return false
	}
	if _, signed := boot_image_signed_write(unsigned_path, "kernel", signed_path, {}); !signed {
		return false
	}
	base_modules, _, _ := info.image_tables(base)
	written, stat_error := os.stat(signed_path, context.temp_allocator)
	if stat_error != nil {
		fmt.eprintfln("modustool: cannot read the size of %s: %v", signed_path, stat_error)
		return false
	}
	fmt.printfln("modustool: measure: the %v boot image of the page: %d bytes, %d modules of the %d of %s (%d bytes)", image, written.size, module_count, len(base_modules), base_path, len(base))
	return true
}

// browser_machine_console_write writes the console page and its boot image
// beside the files of the page, from the boot image of the build. The
// console page reads the second serial port of the host; the first stays
// the log of the kernel.
browser_machine_console_write :: proc() -> bool {
	if !os.is_file(BOOT_IMAGE) {
		fmt.eprintfln("modustool: browser-machine console needs the boot image of the build, %s: run modustool build first", BOOT_IMAGE)
		return false
	}
	path := strings.concatenate({BROWSER_MACHINE_FOLDER, "/", BROWSER_MACHINE_CONSOLE_PAGE_FILE}, context.temp_allocator)
	if error := os.write_entire_file(path, transmute([]u8)BROWSER_MACHINE_CONSOLE_PAGE_TEXT); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return false
	}
	return browser_machine_page_image_write(BOOT_IMAGE, .Console)
}

// The console page: the host of the page with the second serial port as
// its terminal. The site publishes the desktop page only.
BROWSER_MACHINE_CONSOLE_PAGE_TEXT :: #load("browser_machine/browser_machine_console.html", string)

@(private = "file")
browser_machine_boot_image_copy :: proc(source: string) -> bool {
	bytes, read_error := os.read_entire_file(source, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", source, read_error)
		return false
	}
	if write_error := os.write_entire_file(BROWSER_MACHINE_BOOT_IMAGE_PATH, bytes); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BROWSER_MACHINE_BOOT_IMAGE_PATH, write_error)
		return false
	}
	return true
}

// The program that Node runs: it imports the host of the page, starts the
// kernel with a boot image or none, prints each line of the serial port,
// types the command and its Enter on the PS/2 keyboard after the usable
// line, and ends when the answer line comes, when the machine stops, or at
// the bound. Its arguments: the host module, the kernel, the boot image
// (empty: none), the bound in milliseconds, the usable line, the command,
// the prefix and the text of the answer line. After the answer it writes
// "framebuffer: <pixels that are not black> <pixels>". Its last line is
// "machine: <state> <stop code> <trap>".
BROWSER_MACHINE_NODE_PROGRAM :: `
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const [hostPath, kernelPath, imagePath, boundText, usableLine, command, answerPrefix, answerText, trustHashHex] = process.argv.slice(1);
const host = await import(pathToFileURL(resolve(hostPath)).href);
const kernelModule = await WebAssembly.compile(readFileSync(kernelPath));
const bootImage = imagePath ? new Uint8Array(readFileSync(imagePath)) : undefined;
const trustDescriptionHash = trustHashHex && trustHashHex.length === 64 ? Uint8Array.from(trustHashHex.match(/../g).map((b) => parseInt(b, 16))) : null;
const idleWord = new Int32Array(new SharedArrayBuffer(4));
let usable = false, typed = false, answered = false;
const started = Date.now();
const end = started + Number(boundText);
const machine = new host.BrowserMachine({
  kernelModule, bootImage, trustDescriptionHash, memoryMebibytes: 512, framebufferWidth: 1280, framebufferHeight: 800,
  clockNanoseconds: () => process.hrtime.bigint(),
  idleWait: (bound) => {
    const remaining = end - Date.now();
    if (remaining <= 0) throw new host.ProcessorStop();
    Atomics.wait(idleWord, 0, 0, Math.min(Number(bound) / 1e6, remaining, 5));
  },
  onSerialLine: (line) => {
    console.log("serial: " + line);
    if (!usable && line.includes(usableLine)) usable = true;
    if (typed && line.startsWith(answerPrefix) && line.includes(answerText)) answered = true;
  },
});
await machine.start();
while (machine.state === host.MachineState.Running && Date.now() < end && !answered) {
  if (usable && !typed) {
    typed = true;
    if (!machine.keyboard.typeText(command + "\n")) throw new Error("the layout has no key for a character of " + command);
    console.log("typed: " + command + " at " + ((Date.now() - started) / 1000).toFixed(1) + " s");
  }
  if (machine.runSlice(10000000) === host.LoopResult.Idle) Atomics.wait(idleWord, 0, 0, 1);
}
if (answered) {
  console.log("answered: at " + ((Date.now() - started) / 1000).toFixed(1) + " s");
  const pixels = machine.framebufferPixels();
  let lit = 0;
  for (let at = 0; at < pixels.length; at += 4) if (pixels[at] | pixels[at + 1] | pixels[at + 2]) lit += 1;
  console.log("framebuffer: " + lit + " " + pixels.length / 4);
}
const trap = machine.trap ? String(machine.trap).replace(/\s+/g, " ") : "";
console.log("machine: " + machine.state + " " + machine.stopCode + " " + trap);
`

// browser_machine_node_major gives the major version of the node of the
// host; 0 when there is none.
@(private = "file")
browser_machine_node_major :: proc() -> int {
	state, output, _, error := os.process_exec({command = {"node", "--version"}}, context.temp_allocator)
	if error != nil || !state.success {
		return 0
	}
	text := strings.trim_space(string(output))
	if !strings.has_prefix(text, "v") {
		return 0
	}
	major := 0
	for character in text[1:] {
		if character < '0' || character > '9' {
			break
		}
		major = major * 10 + int(character - '0')
	}
	return major
}

// browser_machine_boot starts the kernel of the folder in Node with the
// host of the page, prints each line of its serial port, and checks the
// mark of the kernel. With a boot image it also checks the start of the
// root service, the answer of the console to the command typed on the
// PS/2 keyboard, and a framebuffer that is not black.
browser_machine_boot :: proc(boot_image: string) -> bool {
	if major := browser_machine_node_major(); major < BROWSER_MACHINE_NODE_MAJOR_VERSION {
		fmt.eprintfln("modustool: browser-machine boot needs node %d or later on the path; found %d (0: none)", BROWSER_MACHINE_NODE_MAJOR_VERSION, major)
		return false
	}
	trust_hash_hex := ""
	if boot_image != "" {
		if image_bytes, read_err := os.read_entire_file(boot_image, context.temp_allocator); read_err == nil {
			if description, _, found := system_description.trust_resources(image_bytes); found {
				h := blake3.hash(description)
				trust_hash_hex = fmt.tprintf("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16], h[17], h[18], h[19], h[20], h[21], h[22], h[23], h[24], h[25], h[26], h[27], h[28], h[29], h[30], h[31])
			}
		}
	}
	bound := fmt.tprintf("%d", i64(foundation.HANG_BOUND / time.Millisecond))
	started := time.tick_now()
	state, output, error_output, error := os.process_exec({command = {"node", "--input-type=module", "--eval", BROWSER_MACHINE_NODE_PROGRAM, BROWSER_MACHINE_HOST_PATH, BROWSER_MACHINE_KERNEL_PATH, boot_image, bound, BROWSER_MACHINE_USABLE_LINE, BROWSER_MACHINE_TYPED_COMMAND, BROWSER_MACHINE_ANSWER_PREFIX, BROWSER_MACHINE_ANSWER_TEXT, trust_hash_hex}}, context.temp_allocator)
	if error != nil {
		fmt.eprintfln("modustool: cannot start node: %v", error)
		return false
	}
	if !state.success {
		fmt.eprintfln("modustool: node failed (code %d): %s", state.exit_code, string(error_output))
		return false
	}
	mark_seen, root_seen, answer_seen := false, false, false
	machine_line, typed_line, answered_line, framebuffer_line := "", "", "", ""
	lines := string(output)
	for line in strings.split_lines_iterator(&lines) {
		if strings.has_prefix(line, "serial: ") {
			serial := line[len("serial: "):]
			fmt.println(serial)
			mark_seen ||= serial == BROWSER_MACHINE_KERNEL_MARK
			root_seen ||= strings.has_prefix(serial, BROWSER_MACHINE_ROOT_STAGE_LINE)
			answer_seen ||= strings.has_prefix(serial, BROWSER_MACHINE_ANSWER_PREFIX) && strings.contains(serial, BROWSER_MACHINE_ANSWER_TEXT)
		} else if strings.has_prefix(line, "machine: ") {
			machine_line = line
		} else if strings.has_prefix(line, "typed: ") {
			typed_line = line
			fmt.printfln("modustool: the host typed %s on the PS/2 keyboard", line[len("typed: "):])
		} else if strings.has_prefix(line, "answered: ") {
			answered_line = line
		} else if strings.has_prefix(line, "framebuffer: ") {
			framebuffer_line = line
		}
	}
	fmt.printfln("modustool: measure: the browser machine in node: %.1f s, %s", time.duration_seconds(time.tick_since(started)), machine_line)
	if answered_line != "" {
		fmt.printfln("modustool: measure: the browser machine in node: the console answered %s %s", BROWSER_MACHINE_TYPED_COMMAND, answered_line[len("answered: "):])
	}
	if !mark_seen {
		fmt.eprintfln("modustool: the kernel in node wrote no line %q", BROWSER_MACHINE_KERNEL_MARK)
		return false
	}
	if boot_image != "" && !root_seen {
		fmt.eprintfln("modustool: the kernel in node wrote no line that starts with %q", BROWSER_MACHINE_ROOT_STAGE_LINE)
		return false
	}
	if strings.has_prefix(machine_line, "machine: trapped") {
		fmt.eprintln("modustool: the kernel in node ended with a trap of WebAssembly")
		return false
	}
	if boot_image == "" {
		foundation.test_passed_print("the kernel for WebAssembly starts in node to its mark, with no boot image")
		return true
	}
	if typed_line == "" {
		fmt.eprintfln("modustool: the kernel in node wrote no line that holds %q, so the host typed nothing", BROWSER_MACHINE_USABLE_LINE)
		return false
	}
	if !answer_seen {
		fmt.eprintfln("modustool: the console in node wrote no line that starts with %q and holds %q after %s on the PS/2 keyboard", BROWSER_MACHINE_ANSWER_PREFIX, BROWSER_MACHINE_ANSWER_TEXT, BROWSER_MACHINE_TYPED_COMMAND)
		return false
	}
	lit, pixels, framebuffer_read := browser_machine_framebuffer_line_parse(framebuffer_line)
	if !framebuffer_read || lit == 0 {
		fmt.eprintfln("modustool: the framebuffer of the machine in node is black, or its line is missing: %q", framebuffer_line)
		return false
	}
	fmt.printfln("modustool: the framebuffer in node: %d of %d pixels are not black", lit, pixels)
	foundation.test_passed_print("the kernel for WebAssembly starts in node to the root service, and the console answers %s typed on the PS/2 keyboard", BROWSER_MACHINE_TYPED_COMMAND)
	return true
}

// browser_machine_framebuffer_line_parse reads the line
// "framebuffer: <pixels that are not black> <pixels>" of the Node program.
// ok is false for another line, a number that does not parse, and more lit
// pixels than pixels.
browser_machine_framebuffer_line_parse :: proc(line: string) -> (lit: u64, pixels: u64, ok: bool) {
	PREFIX :: "framebuffer: "
	if !strings.has_prefix(line, PREFIX) {
		return 0, 0, false
	}
	lit_text, separator, pixels_text := strings.partition(line[len(PREFIX):], " ")
	if len(separator) == 0 {
		return 0, 0, false
	}
	lit_read, pixels_read: bool
	lit, lit_read = strconv.parse_u64_of_base(lit_text, 10)
	pixels, pixels_read = strconv.parse_u64_of_base(pixels_text, 10)
	if !lit_read || !pixels_read || pixels == 0 || lit > pixels {
		return 0, 0, false
	}
	return lit, pixels, true
}

// run_browser_machine is the command browser-machine.
run_browser_machine :: proc(args: []string) -> int {
	boot := len(args) >= 1 && args[0] == "boot"
	console := len(args) == 1 && args[0] == "console"
	if len(args) > 2 || (len(args) >= 1 && !boot && !console) {
		fmt.eprintln("modustool: browser-machine takes no argument, boot [<boot image>], or console")
		return foundation.EXIT_USAGE
	}
	if !browser_machine_build() {
		return foundation.EXIT_FAILURE
	}
	if console {
		return browser_machine_console_write() ? 0 : foundation.EXIT_FAILURE
	}
	if !boot {
		return 0
	}
	// The boot image of the page: the one that the command names, else the
	// one of the build that browser_machine_build copied, else none.
	if len(args) == 2 && !browser_machine_boot_image_copy(args[1]) {
		return foundation.EXIT_FAILURE
	}
	boot_image := os.is_file(BROWSER_MACHINE_BOOT_IMAGE_PATH) ? BROWSER_MACHINE_BOOT_IMAGE_PATH : ""
	return browser_machine_boot(boot_image) ? 0 : foundation.EXIT_FAILURE
}
