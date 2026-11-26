// The browser machine of the tool: the build of the kernel for
// WebAssembly, the check of its border with the page, the folder of the
// page, and its start in Node (src/md/features/browser_machine.md, "The
// page and its host").
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/image_tree"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/replacement_list"
import "modus:contract/start_list"
import "modus:contract/system_description"
import "modus:contract/value_kinds"
import "modustool:foundation"

BROWSER_MACHINE_FOLDER :: foundation.BUILD_FOLDER + "/browser_machine"
BROWSER_MACHINE_KERNEL_FILE :: "modulus_kernel.wasm"
BROWSER_MACHINE_BOOT_IMAGE_FILE :: "boot.image"
BROWSER_MACHINE_HOST_FILE :: "browser_machine_host.js"
BROWSER_MACHINE_KERNEL_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_KERNEL_FILE
// The features of WebAssembly past the base set that the kernel uses. Not
// atomics yet: its idle wait would wait on a memory that is not shared.
BROWSER_MACHINE_KERNEL_TARGET_FEATURES :: "bulk-memory"
BROWSER_MACHINE_BOOT_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_BOOT_IMAGE_FILE
BROWSER_MACHINE_HOST_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_HOST_FILE
// The boot image of the page before its signature: the input of the signed
// write of the system description.
BROWSER_MACHINE_UNSIGNED_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/boot_unsigned.image"
// The browser machine pages live at clean folder URLs (`/desktop/` and
// `/console/`), while their shared assets (CSS, JS, WebAssembly kernel, and
// boot images) stay at the root folder.
BROWSER_MACHINE_DESKTOP_PAGE_FILE :: "desktop/index.html"
BROWSER_MACHINE_CONSOLE_PAGE_FILE :: "console/index.html"
BROWSER_MACHINE_CONSOLE_IMAGE_FILE :: "console.image"
BROWSER_MACHINE_CONSOLE_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_CONSOLE_IMAGE_FILE
BROWSER_MACHINE_CONSOLE_UNSIGNED_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/console_unsigned.image"
// The suffix of the file beside a signed boot image of the page that holds
// the hash of its system description: the page has no BLAKE3, and its
// worker gives this hash to the trust of the boot record.
BROWSER_MACHINE_TRUST_SUFFIX :: ".trust"

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
	"files",
	"code",
	"browser",
	"inspect",
	"clock",
	"time_page",
	"life",
	"paint",
	"plasma",
	"heron",
	"manual",
	"disk",
	// The call host, demonstration pair of the default start list, and sample library.
	"host",
	"wired_reader",
	"wired_writer",
	"sample",
}

// The modules of the console image of the page
// (src/md/features/console_renderers.md, "The console image"): the core
// services of the root service, the console with its compilers and the
// sample demonstration module, and dom_terminal as its terminal on the second
// serial port, whose lines the page draws with its document. No compositor,
// no drawing module, no window and no font: the root service finds no
// compositor in the image and gives the role Terminal to dom_terminal. block
// is the device service of the data disk of the private store of the console;
// devices, principals and disk_processes are the delegated services that the
// root service starts at each boot.
@(rodata)
BROWSER_MACHINE_CONSOLE_MODULES := [?]string {
	"root",
	"start_policy",
	"log",
	"wiring",
	"dom_terminal",
	"console",
	"host",
	"sample",
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
// and the console must write the answer line. The answer line is the last
// line of the table of help(), "<count> rows of Command": the console shows
// only the first rows of a long table, so a row of one command, as the one
// of shutdown, leaves the answer when the commands grow; and the echo of
// the typed line does not hold it.
BROWSER_MACHINE_USABLE_LINE :: "[console] kernel console"
BROWSER_MACHINE_TYPED_COMMAND :: "help()"
BROWSER_MACHINE_ANSWER_PREFIX :: "[console] "
BROWSER_MACHINE_ANSWER_TEXT :: " rows of Command"

// The interactive part of a start of the console image in Node on COM2:
// once dom_terminal writes its first prompt edit record on COM2, the host
// types the Lex command on COM2 and verifies the exact answer line in the
// COM2 JSON updates (src/md/features/console_renderers.md, "The console image").
BROWSER_MACHINE_CONSOLE_TYPED_COMMAND :: "1 MiB + 512 KiB"
BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER :: "1536 KiB"

// Subcommands of "modustool browser-machine".
Browser_Machine_Command :: enum u8 {
	Build        = 0,
	Boot         = 1,
	Console      = 2,
	Console_Boot = 3,
}

// One file of the page of a browser machine. The site writes the same
// files (site_browser_machine.odin).
Browser_Machine_Page_File :: struct {
	name: string,
	text: string,
}

BROWSER_MACHINE_PAGE_FILES :: [?]Browser_Machine_Page_File {
	{BROWSER_MACHINE_DESKTOP_PAGE_FILE, #load("browser_machine/browser_machine.html", string)},
	{BROWSER_MACHINE_CONSOLE_PAGE_FILE, #load("browser_machine/browser_machine_console.html", string)},
	{"browser_machine.css", #load("browser_machine/browser_machine.css", string)},
	{"browser_machine_console_page.js", #load("browser_machine/browser_machine_console_page.js", string)},
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
	// bulk-memory makes each copy of the compiler one memory.copy. Without
	// it, a copy calls the memcpy of the runtime, a loop of one byte, and the
	// software processor copies its register file at each instruction
	// (src/md/features/browser_machine.md, "The size and the speed").
	if !foundation.run({"odin", "build", foundation.SOURCE_FOLDER_KERNEL, "-target:freestanding_wasm64p32", "-target-features:" + BROWSER_MACHINE_KERNEL_TARGET_FEATURES, "-o:speed", "-no-entry-point", "-default-to-nil-allocator", foundation.SOURCE_LIBRARY_FLAG, foundation.INTERNAL_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG, "-extra-linker-flags:--export=" + BROWSER_MACHINE_STACK_POINTER_EXPORT, "-out:" + BROWSER_MACHINE_KERNEL_PATH}) {
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
		if slash := strings.last_index_byte(path, '/'); slash > 0 {
			foundation.make_folder(path[:slash]) or_return
		}
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
		// One pointer theme: the first of the order of preference that the
		// base holds, the one that the compositor takes at its start. The
		// root service of a page hashes each resource that it gives, and a
		// second theme would cost its hash on the software processor with
		// no use (browser_machine.md, "The boot image of the page").
		theme_kept := ""
		preference := pointer_pictures.RESOURCE_PREFERENCE
		for theme in preference {
			for &entry in resources {
				if theme_kept == "" && system_description.name_of(&entry.name) == theme {
					theme_kept = theme
				}
			}
		}
		for &entry in resources {
			name := system_description.name_of(&entry.name)
			if name == system_description.RESOURCE_DESCRIPTION || name == system_description.RESOURCE_SIGNATURE || name == replacement_list.RESOURCE_NAME || name == image_tree.RESOURCE_NAME {
				continue
			}
			is_theme := false
			for theme in preference {
				is_theme ||= name == theme
			}
			if is_theme && name != theme_kept {
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
	if tree_problem := image_tree_append_to_files(&list, module_count, allocator); tree_problem != "" {
		return nil, 0, tree_problem
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
	if !browser_machine_trust_write(signed_path) {
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
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		foundation.make_folder(path[:slash]) or_return
	}
	if error := os.write_entire_file(path, transmute([]u8)BROWSER_MACHINE_CONSOLE_PAGE_TEXT); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return false
	}
	return browser_machine_page_image_write(BOOT_IMAGE, .Console)
}

// The tests of the stage tracker of the host, which modustool check and
// browser-machine boot run in Node.
BROWSER_MACHINE_HOST_TEST_TEXT :: #load("browser_machine/browser_machine_host_test.js", string)

// The folder where browser_machine_host_tests_run writes the host that the
// tests import: a check of the flake has no folder of the page.
BROWSER_MACHINE_HOST_TEST_FOLDER :: foundation.BUILD_FOLDER + "/browser_machine_host_test"

// browser_machine_host_tests_run runs the tests of the stage tracker in
// Node on the host as the tool holds it, and says whether they passed. A
// host with no node fails: the development shell and the checks of the
// flake give it.
browser_machine_host_tests_run :: proc() -> bool {
	if error := os.make_directory_all(BROWSER_MACHINE_HOST_TEST_FOLDER); error != nil && error != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", BROWSER_MACHINE_HOST_TEST_FOLDER, error)
		return false
	}
	host_path := strings.concatenate({BROWSER_MACHINE_HOST_TEST_FOLDER, "/", BROWSER_MACHINE_HOST_FILE}, context.temp_allocator)
	host_text := ""
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		if file.name == BROWSER_MACHINE_HOST_FILE {
			host_text = file.text
		}
	}
	if error := os.write_entire_file(host_path, transmute([]u8)host_text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", host_path, error)
		return false
	}
	state, output, error_output, error := os.process_exec({command = {"node", "--input-type=module", "--eval", BROWSER_MACHINE_HOST_TEST_TEXT, host_path}}, context.temp_allocator)
	if error != nil || !state.success {
		fmt.eprintfln("modustool: the tests of the stage tracker of %s failed (code %d, %v): %s%s", BROWSER_MACHINE_HOST_FILE, state.exit_code, error, string(output), string(error_output))
		return false
	}
	foundation.test_passed_print("the stage tracker of the host: %s", strings.trim_space(string(output)))
	return true
}

// The console page: the host of the page with the second serial port as
// its terminal. The site publishes both the desktop and console pages.
BROWSER_MACHINE_CONSOLE_PAGE_TEXT :: #load("browser_machine/browser_machine_console.html", string)

// The Node boot test of the console image on COM2, run by
// "modustool browser-machine console-boot".
BROWSER_MACHINE_CONSOLE_BOOT_TEXT :: #load("browser_machine/browser_machine_console_boot.js", string)

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
	return browser_machine_trust_write(BROWSER_MACHINE_BOOT_IMAGE_PATH)
}

// browser_machine_trust_hash_hex gives the hash of the system description
// of a signed boot image, in 64 lowercase hexadecimal digits; found is
// false for an image with no description and its signature.
browser_machine_trust_hash_hex :: proc(image: []u8, allocator := context.temp_allocator) -> (hex: string, found: bool) {
	description, _, has_description := system_description.trust_resources(image)
	if !has_description {
		return "", false
	}
	hash := blake3.hash(description)
	digits := "0123456789abcdef"
	text := make([]u8, 2 * len(hash), allocator)
	for value, index in hash {
		text[2 * index] = digits[value >> 4]
		text[2 * index + 1] = digits[value & 0x0F]
	}
	return string(text), true
}

// browser_machine_trust_write writes the trust file beside the boot image
// at image_path, or removes an old one when the image holds no
// description: a trust of another image would stop the root service.
@(private = "file")
browser_machine_trust_write :: proc(image_path: string) -> bool {
	trust_path := strings.concatenate({image_path, BROWSER_MACHINE_TRUST_SUFFIX}, context.temp_allocator)
	image, read_error := os.read_entire_file(image_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", image_path, read_error)
		return false
	}
	hex, found := browser_machine_trust_hash_hex(image)
	if !found {
		if os.is_file(trust_path) {
			if error := os.remove(trust_path); error != nil {
				fmt.eprintfln("modustool: cannot remove %s: %v", trust_path, error)
				return false
			}
		}
		return true
	}
	text := strings.concatenate({hex, "\n"}, context.temp_allocator)
	if error := os.write_entire_file(trust_path, transmute([]u8)text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", trust_path, error)
		return false
	}
	return true
}

// The program that Node runs: it imports the host of the page, starts the
// kernel with a boot image or none, prints each line of the serial port,
// types the command and its Enter on the PS/2 keyboard after the usable
// line (with an empty command, it types nothing), and ends when the answer
// line comes, when the machine stops, or at the bound. Its arguments: the host module, the kernel, the boot image
// (empty: none), the bound in milliseconds, the usable line, the command,
// the prefix and the text of the answer line. After the answer it writes
// "framebuffer: <pixels that are not black> <pixels>". At each stage of the
// start (BootStageTracker of the host) it writes "stage: <stage> at <time>".
// Its last line is "machine: <state> <stop code> <trap>".
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
const tracker = new host.BootStageTracker({ desktop: true, onStage: (stage) => console.log("stage: " + stage + " at " + ((Date.now() - started) / 1000).toFixed(1) + " s") });
tracker.enter(host.BootStage.Kernel);
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
    tracker.serialLine(line);
    if (!usable && line.includes(usableLine)) usable = true;
    if ((typed || !command) && line.startsWith(answerPrefix) && line.includes(answerText)) answered = true;
  },
});
await machine.start();
while (machine.state === host.MachineState.Running && Date.now() < end && !answered) {
  if (usable && !typed && command) {
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
	// The stage tracker of the host first: the stages that the page shows
	// come from it.
	if !browser_machine_host_tests_run() {
		return false
	}
	trust_hash_hex := ""
	if boot_image != "" {
		image_bytes, read_error := os.read_entire_file(boot_image, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", boot_image, read_error)
			return false
		}
		trust_hash_hex, _ = browser_machine_trust_hash_hex(image_bytes)
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
		} else if strings.has_prefix(line, "stage: ") {
			fmt.printfln("modustool: measure: the browser machine in node: the stage %s", line[len("stage: "):])
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
	return browser_machine_damaged_module_boot(boot_image, trust_hash_hex, bound)
}

// The module whose file browser_machine_damaged_module_boot changes: the
// root service starts it at each start of the machine.
BROWSER_MACHINE_DAMAGED_MODULE :: "console"

// The copy of the boot image with one changed byte in that module.
BROWSER_MACHINE_DAMAGED_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/damaged_module.image"

// browser_machine_damaged_module_boot starts the machine again in Node on a
// copy of the boot image with one byte of a module changed, and the trust
// of the image as it is: its description is the same. The root service of
// a page hashes each file at its first use, so it must refuse that module
// at its load, with the fact root.Image_File_Hash_Wrong
// (docs/TRUSTED_BOOT.md, "Root_Service_At_Load").
browser_machine_damaged_module_boot :: proc(boot_image: string, trust_hash_hex: string, bound: string) -> bool {
	image, read_error := os.read_entire_file(boot_image, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", boot_image, read_error)
		return false
	}
	modules, _, valid := info.image_tables(image)
	if !valid {
		fmt.eprintfln("modustool: %s is not a boot image", boot_image)
		return false
	}
	changed, root_found := false, false
	root_tag: [FACT_LINE_MODULE_TAG_BYTES]u8
	for &entry in modules {
		if system_description.name_of(&entry.name) == "root" {
			root_tag = module_tag_of(entry.hash)
			root_found = true
		}
		if system_description.name_of(&entry.name) != BROWSER_MACHINE_DAMAGED_MODULE {
			continue
		}
		bytes, inside := info.image_entry_bytes(image, &entry)
		if !inside || len(bytes) == 0 {
			fmt.eprintfln("modustool: the entry of the module %s points outside %s", BROWSER_MACHINE_DAMAGED_MODULE, boot_image)
			return false
		}
		bytes[len(bytes) / 2] ~= 0xFF
		changed = true
	}
	if !changed || !root_found {
		fmt.eprintfln("modustool: %s holds no module %s to change, or no module root", boot_image, BROWSER_MACHINE_DAMAGED_MODULE)
		return false
	}
	if error := os.write_entire_file(BROWSER_MACHINE_DAMAGED_IMAGE_PATH, image); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BROWSER_MACHINE_DAMAGED_IMAGE_PATH, error)
		return false
	}
	// A fact writes "[<module>] #<module tag>:<key tag> <values>" on the
	// serial port. The Node program ends at the first line of the root
	// service with the key tag; the check below reads that line whole.
	refusal_key_tag := op.log_fact_key_tag(fact_key("root", "Image_File_Hash_Wrong"))
	refusal_tag := fmt.tprintf(":%06x", refusal_key_tag)
	refused_file := value_kinds.module_name_field(BROWSER_MACHINE_DAMAGED_MODULE)
	started := time.tick_now()
	state, output, error_output, error := os.process_exec({command = {"node", "--input-type=module", "--eval", BROWSER_MACHINE_NODE_PROGRAM, BROWSER_MACHINE_HOST_PATH, BROWSER_MACHINE_KERNEL_PATH, BROWSER_MACHINE_DAMAGED_IMAGE_PATH, bound, BROWSER_MACHINE_USABLE_LINE, "", "[root] ", refusal_tag, trust_hash_hex}}, context.temp_allocator)
	if error != nil || !state.success {
		fmt.eprintfln("modustool: node failed on the image with a changed module (code %d, %v): %s", state.exit_code, error, string(error_output))
		return false
	}
	refused, damaged_ran, machine_line := false, "", ""
	damaged_head := "[" + BROWSER_MACHINE_DAMAGED_MODULE + "] "
	lines := string(output)
	for line in strings.split_lines_iterator(&lines) {
		if strings.has_prefix(line, "serial: ") {
			serial := line[len("serial: "):]
			if strings.has_prefix(serial, damaged_head) && damaged_ran == "" {
				damaged_ran = serial
			}
			if strings.has_prefix(serial, "[root] ") {
				fact, is_fact := fact_line_parse(serial[len("[root] "):])
				refused ||= is_fact && fact.module_tag == root_tag && fact.key_tag == refusal_key_tag && fact.part_count == 1 && fact.value_count <= len(refused_file) && slice.equal(fact.values[:len(refused_file)], refused_file[:])
			}
		} else if strings.has_prefix(line, "machine: ") {
			machine_line = line
		}
	}
	fmt.printfln("modustool: measure: the browser machine in node with a changed module: %.1f s, %s", time.duration_seconds(time.tick_since(started)), machine_line)
	if strings.has_prefix(machine_line, "machine: trapped") {
		fmt.eprintln("modustool: the kernel in node ended with a trap of WebAssembly on the image with a changed module")
		return false
	}
	if damaged_ran != "" {
		fmt.eprintfln("modustool: the module %s with one changed byte ran in node: %q", BROWSER_MACHINE_DAMAGED_MODULE, damaged_ran)
		return false
	}
	if !refused {
		fmt.eprintfln("modustool: the root service in node wrote no fact root.Image_File_Hash_Wrong (%s) for the file %s with one changed byte", refusal_tag, BROWSER_MACHINE_DAMAGED_MODULE)
		return false
	}
	foundation.test_passed_print("the root service in node refuses the module %s with one changed byte at its first use", BROWSER_MACHINE_DAMAGED_MODULE)
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

// browser_machine_command_parse parses the arguments of
// "modustool browser-machine" into a closed Browser_Machine_Command enum.
browser_machine_command_parse :: proc(args: []string) -> (command: Browser_Machine_Command, image_arg: string, ok: bool) {
	if len(args) == 0 {
		return .Build, "", true
	}
	if len(args) > 2 {
		return .Build, "", false
	}
	switch args[0] {
	case "boot":
		if len(args) == 2 {
			if args[1] == "" {
				return .Build, "", false
			}
			return .Boot, args[1], true
		}
		return .Boot, "", true
	case "console":
		if len(args) != 1 {
			return .Build, "", false
		}
		return .Console, "", true
	case "console-boot":
		if len(args) == 2 {
			if args[1] == "" {
				return .Build, "", false
			}
			return .Console_Boot, args[1], true
		}
		return .Console_Boot, "", true
	}
	return .Build, "", false
}

// browser_machine_console_boot_output_check validates the structured stdout of
// browser_machine_console_boot.js: kernel mark, root service stage, no trap,
// dom_terminal ready stage on COM2, typed command, and exact expected answer.
browser_machine_console_boot_output_check :: proc(output: string, expected_command: string, expected_answer: string) -> (problem: string) {
	mark_seen, root_seen, ready_seen, typed_seen, answer_seen := false, false, false, false, false
	machine_line := ""
	typed_prefix := strings.concatenate({"typed: ", expected_command, " "}, context.temp_allocator)
	lines := output
	for line in strings.split_lines_iterator(&lines) {
		if strings.has_prefix(line, "serial: ") {
			serial := line[len("serial: "):]
			mark_seen ||= serial == BROWSER_MACHINE_KERNEL_MARK
			root_seen ||= strings.has_prefix(serial, BROWSER_MACHINE_ROOT_STAGE_LINE)
		} else if strings.has_prefix(line, "stage: ready ") {
			ready_seen = true
		} else if strings.has_prefix(line, typed_prefix) {
			typed_seen = true
		} else if strings.has_prefix(line, "answer: ") {
			answer_seen ||= strings.contains(line[len("answer: "):], expected_answer)
		} else if strings.has_prefix(line, "machine: ") {
			machine_line = line
		}
	}
	if strings.has_prefix(machine_line, "machine: trapped") {
		return "the console image in node ended with a trap of WebAssembly"
	}
	if !mark_seen {
		return fmt.tprintf("the console image in node wrote no line %q", BROWSER_MACHINE_KERNEL_MARK)
	}
	if !root_seen {
		return fmt.tprintf("the console image in node wrote no line starting with %q", BROWSER_MACHINE_ROOT_STAGE_LINE)
	}
	if !ready_seen {
		return "the console image in node never reached dom_terminal ready on COM2"
	}
	if !typed_seen {
		return fmt.tprintf("the console image in node never typed %q on COM2", expected_command)
	}
	if !answer_seen {
		return fmt.tprintf("the console image in node wrote no COM2 answer holding %q for %q", expected_answer, expected_command)
	}
	return ""
}

// browser_machine_console_boot starts console.image on modulus_kernel.wasm in
// Node with no framebuffer, waits for dom_terminal readiness on COM2 under
// HANG_BOUND, sends BROWSER_MACHINE_CONSOLE_TYPED_COMMAND on COM2, and checks
// BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER in the COM2 JSON updates.
browser_machine_console_boot :: proc(console_image: string) -> bool {
	if major := browser_machine_node_major(); major < BROWSER_MACHINE_NODE_MAJOR_VERSION {
		fmt.eprintfln("modustool: browser-machine console-boot needs node %d or later on the path; found %d (0: none)", BROWSER_MACHINE_NODE_MAJOR_VERSION, major)
		return false
	}
	if !browser_machine_host_tests_run() {
		return false
	}
	image_bytes, read_error := os.read_entire_file(console_image, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", console_image, read_error)
		return false
	}
	trust_hash_hex, _ := browser_machine_trust_hash_hex(image_bytes)
	bound := fmt.tprintf("%d", i64(foundation.HANG_BOUND / time.Millisecond))
	started := time.tick_now()
	state, output, error_output, error := os.process_exec({command = {
		"node",
		"--input-type=module",
		"--eval",
		BROWSER_MACHINE_CONSOLE_BOOT_TEXT,
		BROWSER_MACHINE_HOST_PATH,
		BROWSER_MACHINE_KERNEL_PATH,
		console_image,
		bound,
		BROWSER_MACHINE_CONSOLE_TYPED_COMMAND,
		BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER,
		trust_hash_hex,
	}}, context.temp_allocator)
	if error != nil {
		fmt.eprintfln("modustool: cannot start node: %v", error)
		return false
	}
	lines := string(output)
	machine_line, answered_line := "", ""
	for line in strings.split_lines_iterator(&lines) {
		if strings.has_prefix(line, "serial: ") {
			fmt.println(line[len("serial: "):])
		} else if strings.has_prefix(line, "stage: ") {
			fmt.printfln("modustool: measure: the console image in node: the stage %s", line[len("stage: "):])
		} else if strings.has_prefix(line, "typed: ") {
			fmt.printfln("modustool: the host typed %s on COM2", line[len("typed: "):])
		} else if strings.has_prefix(line, "answered: ") {
			answered_line = line
		} else if strings.has_prefix(line, "machine: ") {
			machine_line = line
		}
	}
	fmt.printfln("modustool: measure: the console image in node: %.1f s, %s", time.duration_seconds(time.tick_since(started)), machine_line)
	if answered_line != "" {
		fmt.printfln("modustool: measure: the console image in node: COM2 answered %s %s", BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, answered_line[len("answered: "):])
	}
	if !state.success {
		fmt.eprintfln("modustool: console-boot node failed (code %d): %s", state.exit_code, strings.trim_space(string(error_output)))
		return false
	}
	if problem := browser_machine_console_boot_output_check(string(output), BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	foundation.test_passed_print("the console image starts in node on COM2 and answers %s with %s", BROWSER_MACHINE_CONSOLE_TYPED_COMMAND, BROWSER_MACHINE_CONSOLE_EXPECTED_ANSWER)
	return true
}

// run_browser_machine is the command browser-machine.
run_browser_machine :: proc(args: []string) -> int {
	command, image_arg, ok := browser_machine_command_parse(args)
	if !ok {
		fmt.eprintln("modustool: browser-machine takes no argument, boot [<boot image>], console, or console-boot [<console image>]")
		return foundation.EXIT_USAGE
	}
	if !browser_machine_build() {
		return foundation.EXIT_FAILURE
	}
	switch command {
	case .Build:
		return 0
	case .Console:
		return browser_machine_console_write() ? 0 : foundation.EXIT_FAILURE
	case .Boot:
		// The boot image of the page: the one that the command names, else the
		// one of the build that browser_machine_build copied, else none.
		if image_arg != "" && !browser_machine_boot_image_copy(image_arg) {
			return foundation.EXIT_FAILURE
		}
		boot_image := os.is_file(BROWSER_MACHINE_BOOT_IMAGE_PATH) ? BROWSER_MACHINE_BOOT_IMAGE_PATH : ""
		return browser_machine_boot(boot_image) ? 0 : foundation.EXIT_FAILURE
	case .Console_Boot:
		console_image := image_arg
		if console_image == "" {
			if !browser_machine_console_write() {
				return foundation.EXIT_FAILURE
			}
			console_image = BROWSER_MACHINE_CONSOLE_IMAGE_PATH
		}
		return browser_machine_console_boot(console_image) ? 0 : foundation.EXIT_FAILURE
	}
	return foundation.EXIT_FAILURE
}
