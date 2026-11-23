package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/scale_factor"
import "core:fmt"
import "core:math/bits"
import "modustool:foundation"

// The parts of the budget of a module that the tool counts, and the sum
// that the table Budget holds (docs/MODULE_CONTRACT.md, "The budget that a
// module asks for"; src/md/features/module_budget_request.md). The source
// states what the tool cannot count: its working memory, its processes, its
// threads and the size of its window. Each counted part is a fact of the
// files of the build.

// The pages that the starter and the kernel pay for the process and its
// first thread: its stack, the page of the context of the process, its
// thread area, and the own log ring that the kernel takes from the budget
// at Process_Create. The guard page of a thread area has no memory.
BUDGET_FIRST_THREAD_PAGES :: op.STACK_PAGES + 1 + (op.THREAD_AREA_PAGES - 1) + op.OWN_LOG_PAGES

// The pages of each other thread: the stack that system.thread_start makes
// when its caller gives no count, and its thread area.
BUDGET_OTHER_THREAD_PAGES :: op.THREAD_STACK_PAGES + (op.THREAD_AREA_PAGES - 1)

// A window has two pictures of 4 bytes for each pixel, as display.open
// makes them (src/library/modus/display, display.odin).
BUDGET_WINDOW_PICTURES :: 2
BUDGET_WINDOW_PIXEL_BYTES :: 4

// The request of a module, and the parts that it is the sum of:
// request.pages = working_memory_pages + module_pages + thread_pages +
// window_pages.
Budget_Count :: struct {
	request:              module.Budget_Request,
	working_memory_pages: u64,
	module_pages:         u64, // The module and each module that it imports, each one time.
	thread_pages:         u64,
	window_pages:         u64,
}

// budget_count gives the request that the table Budget of a module holds,
// from the stated budget of its source, the memory size of the module, and
// the memory size of each module that it imports. ok is false when a sum
// passes the end of 64 bits: such a source asks for more than any machine.
//
// Example: the stated budget {working_memory_pages = 100, threads = 3,
// window_width = 512, window_height = 256}, a module of 5 pages and one
// import of 3 pages give 100 + 8 + (72 + 2 * 19) + 1024 = 1242 pages (the
// window of 1024 x 512 pixels of the screen at 2, under the reference
// screen), the least processes and 3 threads.
budget_count :: proc(stated: Stated_Budget, module_memory_size: u64, import_memory_sizes: []u64) -> (counted: Budget_Count, ok: bool) {
	add :: proc(sum: ^u64, value: u64) -> bool {
		total, carry := bits.add_u64(sum^, value, 0)
		sum^ = total
		return carry == 0
	}
	multiply :: proc(left, right: u64) -> (product: u64, fits: bool) {
		high, low := bits.mul_u64(left, right)
		return low, high == 0
	}

	add(&counted.module_pages, module_pages_of_size(module_memory_size)) or_return
	for size in import_memory_sizes {
		add(&counted.module_pages, module_pages_of_size(size)) or_return
	}

	// Every process has its first thread, also when the source leaves the
	// part out and the starter gives the least.
	thread_count := max(stated.threads, 1)
	other_pages := multiply(thread_count - 1, BUDGET_OTHER_THREAD_PAGES) or_return
	counted.thread_pages = BUDGET_FIRST_THREAD_PAGES
	add(&counted.thread_pages, other_pages) or_return

	// The parts of a window are at most BUDGET_WINDOW_PART_LIMIT, so the
	// product cannot pass the end of 64 bits; it is checked all the same.
	// The parts are logical pixels: the pictures are their pixels of the
	// screen at the largest scale, 2, so a window pays its pictures at each
	// scale that a principal sets: a budget is fixed at the start of its
	// process, and no operation grows it. A resizable window whose least
	// size fits the logical screen at that scale has each axis cut to the
	// reference screen: the compositor fits it into the work area before a
	// scale applies, so its surface is not larger; another window is not
	// cut (src/md/features/desktop_to_browser.md, "The budgets").
	if stated.window_width > BUDGET_WINDOW_PART_LIMIT || stated.window_height > BUDGET_WINDOW_PART_LIMIT || stated.window_least_width > stated.window_width || stated.window_least_height > stated.window_height {
		return {}, false
	}
	bound_width, bound_height := scale_factor.window_surface_largest(i32(stated.window_width), i32(stated.window_height), i32(stated.window_least_width), i32(stated.window_least_height))
	screen_width, screen_height := u64(bound_width), u64(bound_height)
	pixels := multiply(screen_width, screen_height) or_return
	picture_bytes := multiply(pixels, BUDGET_WINDOW_PICTURES * BUDGET_WINDOW_PIXEL_BYTES) or_return
	counted.window_pages = module_pages_of_size(picture_bytes)

	counted.working_memory_pages = stated.working_memory_pages
	pages := counted.working_memory_pages
	add(&pages, counted.module_pages) or_return
	add(&pages, counted.thread_pages) or_return
	add(&pages, counted.window_pages) or_return
	// The screen pictures are a part of their own: the build cannot know the
	// screen, so the starter adds their pages.
	if stated.screen_pictures > module.SCREEN_PICTURES_LIMIT {
		return {}, false
	}
	counted.request = {pages = pages, processes = stated.processes, threads = stated.threads, screen_pictures = stated.screen_pictures}
	return counted, true
}

// module_pages_of_size gives the pages of a size in bytes, the last one
// whole.
module_pages_of_size :: proc(size: u64) -> u64 {
	return size / module.PAGE_SIZE + u64(size % module.PAGE_SIZE != 0)
}

// budget_import_memory_sizes gives the memory size of each module that a
// module of the table imports, at each level, each module one time, from
// the files of the build. The conversion of a module runs after the
// conversion of each import, so each file is there.
budget_import_memory_sizes :: proc(build: foundation.Module_Build) -> (sizes: []u64, ok: bool) {
	names := make([dynamic]string, context.temp_allocator)
	append(&names, ..build.imports)
	// The list is the queue of the walk: each name is read one time.
	for walked := 0; walked < len(names); walked += 1 {
		for item in foundation.module_builds {
			if item.name != names[walked] {
				continue
			}
			for inner in item.imports {
				known := inner == build.name
				for name in names {
					known ||= name == inner
				}
				if !known {
					append(&names, inner)
				}
			}
		}
	}
	list := make([]u64, len(names), context.temp_allocator)
	for name, index in names {
		file := foundation.read_file(foundation.module_import_path(name)) or_return
		head, header_error := module.header(file)
		if header_error != .None {
			fmt.eprintfln("modustool: the file of the import %s of %s is not a module", name, build.name)
			return nil, false
		}
		list[index] = head.memory_size
	}
	return list, true
}

// budget_count_line gives the parts of a request in words, for a line of
// the tests and of the measure of a build.
budget_count_line :: proc(counted: Budget_Count) -> string {
	return fmt.tprintf("%d pages (%d of working memory, %d of the module and its imports, %d of its threads, %d of the pictures of its window), %d processes, %d threads, %d pictures of the screen", counted.request.pages, counted.working_memory_pages, counted.module_pages, counted.thread_pages, counted.window_pages, counted.request.processes, counted.request.threads, counted.request.screen_pictures)
}
