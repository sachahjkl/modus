// The console boot image for QEMU (src/md/features/console_renderers.md,
// "The console image on QEMU"): derived from the main boot image with
// serial_terminal on COM2 and no desktop, compositor, drawing module, input
// service, font, or pointer theme.
package build

import "core:fmt"
import "core:os"
import "core:strings"
import info "modus:contract/boot_info"
import "modus:contract/system_description"
import "modustool:foundation"

// The boot image of the QEMU console boot volume.
BOOT_IMAGE_CONSOLE :: foundation.BUILD_FOLDER + "/boot_console.image"

// The modules of the QEMU console image: the core services of the root
// service, the console with its compilers, and serial_terminal as the holder
// of Terminal on COM2. No compositor, no drawing module, no input service,
// no font, and no pointer theme.
@(rodata)
QEMU_CONSOLE_MODULES := [?]string {
	"root",
	"start_policy",
	"log",
	"wiring",
	"serial_terminal",
	"console",
	"c_compiler",
	"assemble",
	"storage",
	"block",
	"devices",
	"principals",
	"disk_processes",
}

// The modules that the QEMU console image never holds: any module that draws
// or holds the screen, or another terminal renderer.
@(rodata)
QEMU_CONSOLE_REFUSED_MODULES := [?]string{"compositor", "terminal", "drawing", "interface_module", "grid_terminal", "dom_terminal", "input"}

// qemu_console_image_files selects the modules of QEMU_CONSOLE_MODULES and
// their transitive imports from a base boot image, plus the single-row
// console start list and rescue list. It refuses a base that is not a boot
// image, lacks any required module, holds a duplicate module, or pulls in any
// module of QEMU_CONSOLE_REFUSED_MODULES.
qemu_console_image_files :: proc(base: []u8, allocator := context.temp_allocator) -> (files: []Image_File, module_count: int, problem: string) {
	modules, _, valid := info.image_tables(base)
	if !valid {
		return nil, 0, "it is not a boot image"
	}
	wanted := make(map[string]bool, allocator)
	defer delete(wanted)
	console_modules := QEMU_CONSOLE_MODULES
	for name in console_modules {
		wanted[name] = false
	}
	for added := true; added; {
		added = false
		for row in foundation.module_builds {
			if row.name not_in wanted {
				continue
			}
			for import_name in row.imports {
				if import_name not_in wanted {
					wanted[import_name] = false
					added = true
				}
			}
		}
	}
	refused := QEMU_CONSOLE_REFUSED_MODULES
	for name in refused {
		if name in wanted {
			return nil, 0, fmt.tprintf("the QEMU console image would hold the module %s", name)
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
	for name, found in wanted {
		if !found {
			return nil, 0, fmt.tprintf("it holds no module %s", name)
		}
	}
	lists, list_problem := browser_machine_console_list_files(allocator)
	if list_problem != "" {
		return nil, 0, list_problem
	}
	append(&list, ..lists[:])
	return list[:], module_count, ""
}

// qemu_console_boot_image_of encodes the unsigned QEMU console boot image
// from the main boot image of the build.
qemu_console_boot_image_of :: proc(base: []u8) -> (image: []u8, problem: string) {
	files, module_count, files_problem := qemu_console_image_files(base)
	if files_problem != "" {
		return nil, files_problem
	}
	return boot_image_encode(files, module_count), ""
}

// qemu_console_wanted_modules computes the closed set of module names needed by
// the QEMU console image (QEMU_CONSOLE_MODULES plus transitive imports) and
// rejects any module in QEMU_CONSOLE_REFUSED_MODULES.
qemu_console_wanted_modules :: proc(allocator := context.temp_allocator) -> (wanted: map[string]bool, problem: string) {
	wanted = make(map[string]bool, allocator)
	console_modules := QEMU_CONSOLE_MODULES
	for name in console_modules {
		wanted[name] = false
	}
	for added := true; added; {
		added = false
		for row in foundation.module_builds {
			if row.name not_in wanted {
				continue
			}
			for import_name in row.imports {
				if import_name not_in wanted {
					wanted[import_name] = false
					added = true
				}
			}
		}
	}
	refused := QEMU_CONSOLE_REFUSED_MODULES
	for name in refused {
		if name in wanted {
			delete(wanted)
			return nil, fmt.tprintf("the QEMU console image would hold the module %s", name)
		}
	}
	return wanted, ""
}

// qemu_console_boot_image_write_direct encodes build/boot_console.image
// directly from the built module files of QEMU_CONSOLE_MODULES and their
// transitive imports without requiring build/boot.image. The encoded bytes are
// identical to qemu_console_boot_image_of(boot.image).
qemu_console_boot_image_write_direct :: proc() -> bool {
	wanted, wanted_problem := qemu_console_wanted_modules(context.temp_allocator)
	if wanted_problem != "" {
		fmt.eprintfln("modustool: console image: %s", wanted_problem)
		return false
	}
	list := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		if !foundation.module_in_boot_image(row) || row.name not_in wanted {
			continue
		}
		bytes := foundation.read_file(foundation.module_path(row.name)) or_return
		wanted[row.name] = true
		append(&list, Image_File{name = row.name, file = bytes})
	}
	module_count := len(list)
	for name, found in wanted {
		if !found {
			fmt.eprintfln("modustool: console image: it holds no module %s", name)
			return false
		}
	}
	lists, list_problem := browser_machine_console_list_files(context.temp_allocator)
	if list_problem != "" {
		fmt.eprintfln("modustool: console image: %s", list_problem)
		return false
	}
	append(&list, ..lists[:])
	image := boot_image_encode(list[:], module_count)
	if err := os.write_entire_file(BOOT_IMAGE_CONSOLE, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BOOT_IMAGE_CONSOLE, err)
		return false
	}
	return true
}

// qemu_console_boot_image_write writes build/boot_console.image from
// build/boot.image.
qemu_console_boot_image_write :: proc() -> bool {
	base := foundation.read_file(BOOT_IMAGE) or_return
	image, problem := qemu_console_boot_image_of(base)
	if problem != "" {
		fmt.eprintfln("modustool: console image: %s", problem)
		return false
	}
	if err := os.write_entire_file(BOOT_IMAGE_CONSOLE, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BOOT_IMAGE_CONSOLE, err)
		return false
	}
	return true
}
