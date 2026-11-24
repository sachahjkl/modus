#+build !freestanding
package budget_peak

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"
import "core:testing"

// The pages that a budget paid at one time: its pages at the creation less
// its least count, as the root service computes it.
@(private = "file")
peak_of :: proc(pages_at_creation, least: u64) -> u64 {
	return pages_at_creation - min(pages_at_creation, least)
}

// A model of the paths of the kernel that take and give pages of a budget,
// in the order of one start: the top table and the own log ring at
// Process_Create, an object at Memory_Create, a commit of pages, a page
// table that a map pays, a child budget that the parent carves, the end of
// the object, and the end of the child, whose pages return to the parent.
// The least count holds the peak of the takes; the returns never raise it.
@(test)
the_least_count_holds_the_peak_of_each_spend_path :: proc(t: ^testing.T) {
	free, least: u64
	created(&free, &least, 1000)
	testing.expect(t, free == 1000 && least == 1000)
	testing.expect(t, spend(&free, &least, 1 + 4)) // The top table and the own log ring.
	testing.expect(t, spend(&free, &least, 17)) // An object of 16 pages and its list page.
	testing.expect(t, spend(&free, &least, 32)) // A commit of 32 pages.
	testing.expect(t, spend(&free, &least, 1)) // A page table of a map.
	testing.expect_value(t, peak_of(1000, least), 55)
	// A child budget carved from this one: its pages leave the parent.
	child_free, child_least: u64
	testing.expect(t, spend(&free, &least, 400))
	created(&child_free, &child_least, 400)
	testing.expect_value(t, peak_of(1000, least), 455)
	// The child spends: its own least count moves, never the parent's.
	testing.expect(t, spend(&child_free, &child_least, 300))
	testing.expect_value(t, peak_of(400, child_least), 300)
	testing.expect_value(t, peak_of(1000, least), 455)
	// The object ends, then the child ends: its pages return to the parent.
	give_back(&free, 17)
	give_back(&child_free, 300)
	give_back(&free, child_free)
	testing.expect_value(t, free, 1000 - 5 - 32 - 1)
	testing.expect_value(t, peak_of(1000, least), 455)
	// A second rise below the first peak changes nothing; one above it does.
	testing.expect(t, spend(&free, &least, 100))
	testing.expect_value(t, peak_of(1000, least), 455)
	testing.expect(t, spend(&free, &least, 500))
	testing.expect_value(t, peak_of(1000, least), 638)
}

// The edges: a spend of 0, a spend of every free page, a spend of one page
// more (refused, nothing changes), a budget of no page, and a budget of the
// largest count.
@(test)
a_spend_past_the_free_pages_changes_nothing :: proc(t: ^testing.T) {
	free, least: u64
	created(&free, &least, 10)
	testing.expect(t, spend(&free, &least, 0))
	testing.expect(t, free == 10 && least == 10)
	testing.expect(t, !spend(&free, &least, 11))
	testing.expect(t, free == 10 && least == 10)
	testing.expect(t, spend(&free, &least, 10))
	testing.expect(t, free == 0 && least == 0)
	testing.expect(t, !spend(&free, &least, 1))
	created(&free, &least, 0)
	testing.expect(t, !spend(&free, &least, 1))
	created(&free, &least, max(u64))
	testing.expect(t, spend(&free, &least, max(u64)))
	testing.expect_value(t, peak_of(max(u64), least), max(u64))
	testing.expect_value(t, peak_of(5, 9), 0)
}

// The assignments of the sources of the kernel to the pages of a budget,
// each form: =, +=, -=, and any other operator, on a field pages of a field
// amounts of anything (budgets[x].amounts.pages, budget.amounts.pages).
@(private = "file")
Page_Assignments :: struct {
	found: [dynamic]string,
	src:   string,
	path:  string,
}

@(private = "file")
page_assignments_of :: proc(path, source: string, found: ^[dynamic]string) -> bool {
	file := ast.new_from_positions(ast.File, {}, {})
	file.src = source
	file.fullpath = path
	reader := parser.default_parser()
	if !parser.parse_file(&reader, file) {
		return false
	}
	state := Page_Assignments{src = source, path = path}
	visitor := ast.Visitor {
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			state := (^Page_Assignments)(visitor.data)
			if assign, is_assign := node.derived.(^ast.Assign_Stmt); is_assign {
				for target in assign.lhs {
					pages, is_pages := target.derived.(^ast.Selector_Expr)
					if !is_pages || pages.field == nil || pages.field.name != "pages" {
						continue
					}
					amounts, is_amounts := pages.expr.derived.(^ast.Selector_Expr)
					if is_amounts && amounts.field != nil && amounts.field.name == "amounts" {
						append(&state.found, strings.concatenate({state.path, ": ", state.src[assign.pos.offset:assign.end.offset]}, context.temp_allocator))
					}
				}
			}
			return visitor
		},
	}
	visitor.data = &state
	for declaration in file.decls {
		ast.walk(&visitor, declaration)
	}
	append(found, ..state.found[:])
	return true
}

// Each place of the kernel that changes the pages of a budget goes through
// this package: a path that changed them by itself would leave the least
// count behind, and the peak would be false. The parse finds each
// assignment, whatever its operator; the model of a source of each form
// first shows that the parse finds them.
@(test)
the_kernel_changes_budget_pages_at_this_package_alone :: proc(t: ^testing.T) {
	model: [dynamic]string
	model.allocator = context.temp_allocator
	forms := "package k\nf :: proc() {\n\tbudgets[1].amounts.pages -= 1\n\tbudget.amounts.pages += 2\n\tb.amounts.pages = 3\n\tb.amounts.pages *= 4\n\tamounts.pages = 5\n\tif true {\n\t\tx.amounts.pages |= 6\n\t}\n}\n"
	testing.expect(t, page_assignments_of("model.odin", forms, &model))
	testing.expect_value(t, len(model), 5)
	folder := "src/modulus"
	entries, read_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if !testing.expect(t, read_error == nil, "the sources of the kernel are readable") {
		return
	}
	found: [dynamic]string
	found.allocator = context.temp_allocator
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") {
			continue
		}
		bytes, file_error := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if !testing.expect(t, file_error == nil) {
			continue
		}
		testing.expectf(t, page_assignments_of(entry.fullpath, string(bytes), &found), "%s parses", entry.name)
	}
	for item in found {
		testing.expectf(t, false, "the pages of a budget change outside budget_peak: %s", item)
	}
}
