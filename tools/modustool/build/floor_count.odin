package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "core:fmt"
import "core:math/bits"
import "modustool:foundation"

// The parts of the floor of a module that the tool counts, and the sum that
// the table Floor holds (src/md/features/module_budget_request.md, "The
// floor is counted whole"). The source states what the tool cannot count:
// its working memory while it leaves, its processes, its threads, the size
// of its window and its screen pictures, and its start objects by the
// names of their constants. Each counted part is a fact of the files of the
// build, priced by the cost functions of the contract.

// The pages that the starter and the kernel pay for the process and its
// first thread: its stack, the page of the context of the process, its
// thread area, and the own log ring that the kernel takes from the budget
// at Process_Create. The guard page of a thread area has no memory.
FLOOR_FIRST_THREAD_PAGES :: op.STACK_PAGES + 1 + (op.THREAD_AREA_PAGES - 1) + op.OWN_LOG_PAGES

// The pages of each other thread: the stack that system.thread_start makes
// when its caller gives no count, and its thread area.
FLOOR_OTHER_THREAD_PAGES :: op.THREAD_STACK_PAGES + (op.THREAD_AREA_PAGES - 1)

// A window has two pictures of 4 bytes for each pixel, as display.open
// makes them (src/library/modus/display, display.odin).
FLOOR_WINDOW_PICTURES :: 2
FLOOR_WINDOW_PIXEL_BYTES :: 4

// One module of the load of a process, from its file: its memory pages,
// and the pages of each segment. A starter with a table of prepared
// modules copies each writable segment for each process; the count prices
// each segment so, which is never below the writable ones alone, and the
// flags of a segment before and after the relocations change no count.
Module_Cost :: struct {
	pages:         u64,
	segment_pages: []u64,
}

// What the count of a floor reads: the parts that the source states, the
// modules of the load (the module itself first, then each module that it
// imports, at each level, each one time), the pages of each start object
// of the module and of each package compiled into its load, and the floors
// of the children that the module table names.
Floor_Inputs :: struct {
	stated:        Stated_Budget,
	modules:       []Module_Cost,
	start_objects: []u64,
	children:      []module.Floor,
}

// The floor of a module, and the parts that it is the sum of:
// floor.pages = working_memory_pages + module_pages + load_pages +
// thread_pages + window_pages + start_object_pages + children_pages.
Floor_Count :: struct {
	floor:                module.Floor,
	working_memory_pages: u64,
	module_pages:         u64, // The module and each module that it imports, each one time.
	load_pages:           u64, // The frame lists and the page tables of the load, of the stacks and of the pictures.
	thread_pages:         u64,
	window_pages:         u64,
	start_object_pages:   u64, // Each start object with its frame list and the tables of its mapping.
	children_pages:       u64, // The floor of each child that the module starts before its first state of work.
}

// floor_count gives the floor that the table Floor of a module holds. ok is
// false when a sum passes the end of 64 bits, for a window part past
// BUDGET_WINDOW_PART_LIMIT or with a least size above it, and for screen
// pictures past module.SCREEN_PICTURES_LIMIT: such a source asks for more
// than any machine, or is refused by the describe step first.
//
// Example: the stated parts {working_memory_pages = 100, threads = 3,
// window_width = 512, window_height = 256} and one module of 5 pages give
// 100 + 5 + (72 + 2 * 19) + 1024, and the load: the top table, the tables
// of the time page, the tables of the module, of the stacks and of the
// pictures, and the frame lists of the stacks and of the pictures.
floor_count :: proc(inputs: Floor_Inputs) -> (counted: Floor_Count, ok: bool) {
	add :: proc(sum: ^u64, value: u64) -> bool {
		total, carry := bits.add_u64(sum^, value, 0)
		sum^ = total
		return carry == 0
	}
	multiply :: proc(left, right: u64) -> (product: u64, fits: bool) {
		high, low := bits.mul_u64(left, right)
		return low, high == 0
	}
	// What an object of pages costs past its pages: its frame list and the
	// tables of its mapping.
	object_load :: proc(pages: u64) -> u64 {
		return op.memory_list_pages(pages) + op.mapping_table_pages_most(pages)
	}
	stated := inputs.stated

	// The address space: its top table, which Process_Create pays, and the
	// tables of the time page, which it maps in each process. The ready
	// ring, which the budget of the process pays at its start and which it
	// maps once, to say its first state of work (system.ready).
	add(&counted.load_pages, 1 + op.mapping_table_pages_most(1)) or_return
	add(&counted.load_pages, floor_ready_ring_pages()) or_return
	for item in inputs.modules {
		add(&counted.module_pages, item.pages) or_return
		// The starter with no table of prepared modules copies the whole
		// module in one object; with one, each writable segment: the larger
		// count of frame list pages of the two.
		segment_lists: u64 = 0
		for pages in item.segment_pages {
			add(&segment_lists, op.memory_list_pages(pages)) or_return
		}
		add(&counted.load_pages, max(op.memory_list_pages(item.pages), segment_lists)) or_return
		add(&counted.load_pages, op.mapping_table_pages_most(item.pages)) or_return
	}

	// Every process has its first thread, also when the source leaves the
	// part out.
	thread_count := max(stated.threads, 1)
	other_pages := multiply(thread_count - 1, FLOOR_OTHER_THREAD_PAGES) or_return
	counted.thread_pages = FLOOR_FIRST_THREAD_PAGES
	add(&counted.thread_pages, other_pages) or_return
	// The stack of the first thread and the context page are mapped; each
	// other stack is an object of its own, mapped.
	add(&counted.load_pages, object_load(op.STACK_PAGES) + op.mapping_table_pages_most(1)) or_return
	other_load := multiply(thread_count - 1, object_load(op.THREAD_STACK_PAGES)) or_return
	add(&counted.load_pages, other_load) or_return

	// The parts of a window are at most BUDGET_WINDOW_PART_LIMIT, so the
	// product cannot pass the end of 64 bits; it is checked all the same.
	// The parts are logical pixels: the pictures are their pixels of the
	// screen at the largest scale, 2, so a window pays its pictures at each
	// scale that a principal sets. A resizable window whose least size fits
	// the logical screen at that scale has each axis cut to the reference
	// screen: the compositor fits it into the work area before a scale
	// applies, so its surface is not larger; another window is not cut
	// (src/md/features/desktop_to_browser.md, "The budgets").
	if stated.window_width > BUDGET_WINDOW_PART_LIMIT || stated.window_height > BUDGET_WINDOW_PART_LIMIT || stated.window_least_width > stated.window_width || stated.window_least_height > stated.window_height {
		return {}, false
	}
	bound_width, bound_height := scale_factor.window_surface_largest(i32(stated.window_width), i32(stated.window_height), i32(stated.window_least_width), i32(stated.window_least_height))
	pixels := multiply(u64(bound_width), u64(bound_height)) or_return
	picture_bytes := multiply(pixels, FLOOR_WINDOW_PIXEL_BYTES) or_return
	picture_pages := module_pages_of_size(picture_bytes)
	if picture_pages != 0 {
		counted.window_pages = picture_pages * FLOOR_WINDOW_PICTURES
		add(&counted.load_pages, object_load(picture_pages) * FLOOR_WINDOW_PICTURES) or_return
	}

	for pages in inputs.start_objects {
		add(&counted.start_object_pages, op.memory_cost(pages)) or_return
		add(&counted.start_object_pages, op.mapping_table_pages_most(pages)) or_return
	}

	processes := max(stated.processes, 1)
	threads := thread_count
	child_processes, child_threads: u64 = 1, 1
	for child in inputs.children {
		add(&counted.children_pages, child.pages) or_return
		add(&child_processes, child.processes) or_return
		add(&child_threads, child.threads) or_return
	}

	if stated.screen_pictures > module.SCREEN_PICTURES_LIMIT {
		return {}, false
	}
	counted.working_memory_pages = stated.working_memory_pages
	pages := counted.working_memory_pages
	parts := [?]u64{counted.module_pages, counted.load_pages, counted.thread_pages, counted.window_pages, counted.start_object_pages, counted.children_pages, stated.wiring_pages}
	for part in parts {
		add(&pages, part) or_return
	}
	// The screen pictures are a part of their own: the build cannot know the
	// screen, so the starter adds their pages. The processes and the threads
	// hold the children at least: the process itself, and each child.
	counted.floor = {pages = pages, processes = max(processes, child_processes), threads = max(threads, child_threads), screen_pictures = stated.screen_pictures, wiring_pages = stated.wiring_pages}
	return counted, true
}

// floor_ready_ring_pages gives what the ready ring of a process costs its
// budget: the pages of a ring of the smallest capacity
// (system.READY_RING_CAPACITY) with its frame list, and the tables of its
// mapping in the process.
floor_ready_ring_pages :: proc() -> u64 {
	pages := ring.pages(ring.CAPACITY)
	return op.memory_cost(pages) + op.mapping_table_pages_most(pages)
}

// module_pages_of_size gives the pages of a size in bytes, the last one
// whole.
module_pages_of_size :: proc(size: u64) -> u64 {
	return size / module.PAGE_SIZE + u64(size % module.PAGE_SIZE != 0)
}

// module_cost_of_file gives the load of one module from its file: its
// memory pages and the pages of each segment. ok is false for a file that
// is not a module.
module_cost_of_file :: proc(file: []u8) -> (cost: Module_Cost, ok: bool) {
	head, header_error := module.header(file)
	if header_error != .None {
		return {}, false
	}
	segments := make([dynamic]u64, context.temp_allocator)
	for index in 1 ..< module.count(file, .Segments) {
		if segment, found := module.record(file, .Segments, index, module.Segment); found {
			append(&segments, module_pages_of_size(segment.memory_size))
		}
	}
	return {pages = module_pages_of_size(head.memory_size), segment_pages = segments[:]}, true
}

// floor_import_costs gives the load of each module that a module of the
// table imports, at each level, each module one time, from the files of
// the build. The conversion of a module runs after the conversion of each
// import, so each file is there.
floor_import_costs :: proc(build: foundation.Module_Build) -> (costs: []Module_Cost, ok: bool) {
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
	list := make([]Module_Cost, len(names), context.temp_allocator)
	for name, index in names {
		file := foundation.read_file(foundation.module_import_path(name)) or_return
		cost, cost_ok := module_cost_of_file(file)
		if !cost_ok {
			fmt.eprintfln("modustool: the file of the import %s of %s is not a module", name, build.name)
			return nil, false
		}
		list[index] = cost
	}
	return list, true
}

// floor_children_of gives the floor of each child that the module table
// names for a module: the modules that its process starts before its first
// state of work. The table lists each child before the module, so each
// file is there. ok is false for a child with no file or no table Floor.
floor_children_of :: proc(build: foundation.Module_Build) -> (floors: []module.Floor, ok: bool) {
	list := make([]module.Floor, len(build.children), context.temp_allocator)
	for name, index in build.children {
		file := foundation.read_file(foundation.module_import_path(name)) or_return
		floor, found := module.floor_read(file)
		if module.validate(file) != .None || !found {
			fmt.eprintfln("modustool: the child %s of %s has no table Floor: a child is a module with an entry, built before the module that starts it", name, build.name)
			return nil, false
		}
		list[index] = floor
	}
	return list, true
}

// floor_count_line gives the parts of a floor in words, for a line of the
// tests and of the measure of a build.
floor_count_line :: proc(counted: Floor_Count) -> string {
	return fmt.tprintf("%d pages (%d of working memory, %d of the module and its imports, %d of their load, %d of its threads, %d of the pictures of its window, %d of its start objects, %d of its children), %d processes, %d threads, %d pictures of the screen", counted.floor.pages, counted.working_memory_pages, counted.module_pages, counted.load_pages, counted.thread_pages, counted.window_pages, counted.start_object_pages, counted.children_pages, counted.floor.processes, counted.floor.threads, counted.floor.screen_pictures)
}
