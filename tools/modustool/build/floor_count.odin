package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "core:fmt"
import "core:math/bits"
import "core:odin/ast"
import "core:strings"
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
	// The pages of each budget that the process makes for a child before
	// its first state of work, at a fixed amount (MODULE_START_BUDGETS):
	// counted at their pages, as the parent carves them.
	start_budgets: []u64,
	// The module can send Wire from its root ring and states no wiring
	// pages: the root service carves its wiring budget from its floor at its
	// first wiring, half of its pages, so the floor counts that carve
	// (floor_wiring_derived).
	wiring_derived: bool,
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
	children_pages:       u64, // The floor of each child that the module table names, and each fixed budget of a child that the source lists.
	wiring_pages:         u64, // The wiring budget that the root service carves: stated, or derived.
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
	for pages in inputs.start_budgets {
		add(&counted.children_pages, pages) or_return
	}

	if stated.screen_pictures > module.SCREEN_PICTURES_LIMIT {
		return {}, false
	}
	counted.working_memory_pages = stated.working_memory_pages
	pages := counted.working_memory_pages
	parts := [?]u64{counted.module_pages, counted.load_pages, counted.thread_pages, counted.window_pages, counted.start_object_pages, counted.children_pages}
	for part in parts {
		add(&pages, part) or_return
	}
	// The wiring budget: the pages that the source states, or for a module
	// that wires from its root ring and states none, the carve of the root
	// service, half of the floor: as many pages as the rest of the floor.
	// The table holds it, so the root service carves this amount.
	counted.wiring_pages = stated.wiring_pages
	if counted.wiring_pages == 0 && inputs.wiring_derived {
		counted.wiring_pages = pages
	}
	add(&pages, counted.wiring_pages) or_return
	// The screen pictures are a part of their own: the build cannot know the
	// screen, so the starter adds their pages. The processes and the threads
	// hold the children at least: the process itself, and each child.
	counted.floor = {pages = pages, processes = max(processes, child_processes), threads = max(threads, child_threads), screen_pictures = stated.screen_pictures, wiring_pages = counted.wiring_pages}
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

// The start grant sets of the root service, read once for the floors.
@(private = "file")
floor_grant_rows: []foundation.Start_Grant_Set_Row
@(private = "file")
floor_grant_rows_read: bool

// The import path of the root ring contract, whose Root_Command.Wire and
// Wire_Step members identify a module that sends Wire from its root ring.
@(private = "file")
ROOT_RING_IMPORT_PATH :: "modus:contract/root_ring"

// One parameter of a package procedure whose type is root_ring.Root_Command:
// a call passing .Wire at index (or by name) sends Wire.
@(private = "file")
Root_Command_Param :: struct {
	proc_name:  string,
	param_name: string,
	index:      int,
}

// One parsed source of a module's own package, paired with its local import
// name for ROOT_RING_IMPORT_PATH ("" when the file does not import it).
@(private = "file")
Wiring_Parsed_File :: struct {
	file:           ^ast.File,
	root_ring_name: string,
}

// root_ring_import_name gives the local package identifier for
// ROOT_RING_IMPORT_PATH in file, or "" when file does not import it.
@(private = "file")
root_ring_import_name :: proc(file: ^ast.File) -> string {
	for item in file.imports {
		if strings.trim(item.fullpath, "\"") != ROOT_RING_IMPORT_PATH {
			continue
		}
		if item.name.text != "" {
			return item.name.text
		}
		return "root_ring"
	}
	return ""
}

// selector_is_type says if expr is `<pkg>.<type_name>`.
@(private = "file")
selector_is_type :: proc(expr: ^ast.Expr, pkg: string, type_name: string) -> bool {
	if expr == nil || pkg == "" {
		return false
	}
	selector, is_selector := expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.expr == nil || selector.field == nil {
		return false
	}
	ident, is_ident := selector.expr.derived.(^ast.Ident)
	return is_ident && ident.name == pkg && selector.field.name == type_name
}

// root_command_params_collect appends every parameter of type
// `<pkg>.Root_Command` declared on a top-level procedure in file.
@(private = "file")
root_command_params_collect :: proc(file: ^ast.File, pkg: string, out: ^[dynamic]Root_Command_Param) {
	if pkg == "" {
		return
	}
	for decl in file.decls {
		value_decl, is_value := decl.derived.(^ast.Value_Decl)
		if !is_value || value_decl.is_mutable || len(value_decl.names) != 1 || len(value_decl.values) != 1 {
			continue
		}
		proc_ident, has_name := value_decl.names[0].derived.(^ast.Ident)
		proc_lit, is_proc := value_decl.values[0].derived.(^ast.Proc_Lit)
		if !has_name || !is_proc || proc_lit.type == nil || proc_lit.type.params == nil {
			continue
		}
		param_index := 0
		for field in proc_lit.type.params.list {
			is_root_command := selector_is_type(field.type, pkg, "Root_Command")
			count := max(len(field.names), 1)
			if is_root_command {
				if len(field.names) == 0 {
					append(out, Root_Command_Param{proc_name = proc_ident.name, index = param_index})
				} else {
					for name_expr, offset in field.names {
						param_name := ""
						if ident, ok := name_expr.derived.(^ast.Ident); ok {
							param_name = ident.name
						}
						append(out, Root_Command_Param{proc_name = proc_ident.name, param_name = param_name, index = param_index + offset})
					}
				}
			}
			param_index += count
		}
	}
}

// expr_is_implicit_wire says if expr is the implicit enum member `.Wire`.
@(private = "file")
expr_is_implicit_wire :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	implicit, is_implicit := expr.derived.(^ast.Implicit_Selector_Expr)
	return is_implicit && implicit.field != nil && implicit.field.name == "Wire"
}

// call_sends_wire says if call invokes a package procedure taking
// root_ring.Root_Command with the implicit argument `.Wire`.
@(private = "file")
call_sends_wire :: proc(call: ^ast.Call_Expr, params: []Root_Command_Param) -> bool {
	if call == nil || call.expr == nil {
		return false
	}
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident {
		return false
	}
	for param in params {
		if param.proc_name != callee.name {
			continue
		}
		positional := 0
		for arg in call.args {
			if named, is_named := arg.derived.(^ast.Field_Value); is_named {
				if field, ok := named.field.derived.(^ast.Ident); ok && param.param_name != "" && field.name == param.param_name {
					if expr_is_implicit_wire(named.value) {
						return true
					}
				}
				continue
			}
			if positional == param.index && expr_is_implicit_wire(arg) {
				return true
			}
			positional += 1
		}
	}
	return false
}

// floor_wiring_derived says if the module of name sends Wire from its root
// ring: it holds the start grant Root_Ring, is not a start policy, whose
// wiring pages its list prices, and the parsed syntax tree of its own
// package names root_ring.Root_Command.Wire, a step of root_ring.Wire_Step
// (List_Page or Apply), or passes .Wire to a package procedure whose
// parameter has type root_ring.Root_Command. The root service then carves
// its wiring budget from its floor. A holder of the grant that never wires
// gets no wiring part. ok is false when the grant table or an own source
// file cannot be read.
floor_wiring_derived :: proc(name: string, module_folder: string, sources: []Fact_Source) -> (derived: bool, ok: bool) {
	if !floor_grant_rows_read {
		text := foundation.read_text_file(foundation.ROOT_START_GRANT_SETS_FILE) or_return
		rows, _, problem := start_grant_sets_read(text)
		if problem != "" {
			fmt.eprintfln("modustool: the start grant sets cannot be read for the floors: %s", problem)
			return false, false
		}
		floor_grant_rows, floor_grant_rows_read = rows, true
	}
	can_wire := false
	for row in floor_grant_rows {
		if row.name != name {
			continue
		}
		root_ring, start_policy := false, false
		for grant in row.grants {
			root_ring ||= grant == "Root_Ring"
			start_policy ||= grant == "Start_Policy"
		}
		can_wire = root_ring && !start_policy
		break
	}
	if !can_wire {
		return false, true
	}

	module_package := strings.trim_right(module_folder, "/")
	state: Describe_State
	parsed := make([dynamic]Wiring_Parsed_File, context.temp_allocator)
	command_params := make([dynamic]Root_Command_Param, context.temp_allocator)
	for source in sources {
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		own := folder == module_package || strings.has_suffix(folder, strings.concatenate({"/", module_package}, context.temp_allocator))
		if !own || strings.has_suffix(source.path, "_test.odin") {
			continue
		}
		file := parse_source(source.path, source.source, &state) or_return
		if file.syntax_error_count != 0 {
			fmt.eprintfln("modustool: %s: the parser found syntax errors", source.path)
			return false, false
		}
		pkg := root_ring_import_name(file)
		append(&parsed, Wiring_Parsed_File{file = file, root_ring_name = pkg})
		root_command_params_collect(file, pkg, &command_params)
	}

	Walk :: struct {
		pkg:    string,
		params: []Root_Command_Param,
		wires:  bool,
	}
	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		walk := (^Walk)(visitor.data)
		if node == nil || walk.wires {
			return nil
		}
		#partial switch item in node.derived {
		case ^ast.Selector_Expr:
			if walk.pkg != "" && item.field != nil {
				if selector_is_type(item.expr, walk.pkg, "Root_Command") && item.field.name == "Wire" {
					walk.wires = true
					return nil
				}
				if selector_is_type(item.expr, walk.pkg, "Wire_Step") && (item.field.name == "List_Page" || item.field.name == "Apply") {
					walk.wires = true
					return nil
				}
			}
		case ^ast.Call_Expr:
			if call_sends_wire(item, walk.params) {
				walk.wires = true
				return nil
			}
		}
		return visitor
	}
	for item in parsed {
		walk := Walk{pkg = item.root_ring_name, params = command_params[:]}
		visitor := ast.Visitor{visit = visit, data = &walk}
		for decl in item.file.decls {
			ast.walk(&visitor, decl)
			if walk.wires {
				return true, true
			}
		}
	}
	return false, true
}

// floor_count_line gives the parts of a floor in words, for a line of the
// tests and of the measure of a build.
floor_count_line :: proc(counted: Floor_Count) -> string {
	return fmt.tprintf("%d pages (%d of working memory, %d of the module and its imports, %d of their load, %d of its threads, %d of the pictures of its window, %d of its start objects, %d of its children, %d of its wirings), %d processes, %d threads, %d pictures of the screen", counted.floor.pages, counted.working_memory_pages, counted.module_pages, counted.load_pages, counted.thread_pages, counted.window_pages, counted.start_object_pages, counted.children_pages, counted.wiring_pages, counted.floor.processes, counted.floor.threads, counted.floor.screen_pictures)
}
