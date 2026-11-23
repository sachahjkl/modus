#+build !freestanding
package storage_mount

import "base:runtime"
import "core:testing"
import format "modus:contract/store"

// A budget of pages for the memory of the state, which holds the memory of
// the binding before until the new one is bound, as the service does.
@(private = "file")
Budget_Binder :: struct {
	using binder: Memory_Binder,
	state:        ^State,
	budget_pages: u64,
	held_pages:   u64, // The pages of the binding now.
	held:         []u64,
	most_held:    u64, // The most pages held at once.
	binds:        [dynamic]Count_Form,
}

@(private = "file")
budget_bind :: proc "contextless" (binder: ^Memory_Binder, blocks: u64, form: Count_Form, cache_pages: u64) -> bool {
	budget := (^Budget_Binder)(binder)
	layout, ok := state_layout(blocks, TEST_STATE_HASH_ROOTS, form, cache_pages)
	pages := (layout.bytes + BLOCK_SIZE - 1) / BLOCK_SIZE
	if !ok || budget.held_pages + pages > budget.budget_pages {
		return false
	}
	context = runtime.default_context()
	memory := make([]u64, (layout.bytes + 7) / 8)
	if !state_bind(budget.state, ([^]u8)(raw_data(memory))[:layout.bytes], blocks, TEST_STATE_HASH_ROOTS, form, cache_pages) {
		delete(memory)
		return false
	}
	budget.most_held = max(budget.most_held, budget.held_pages + pages)
	budget_release(binder)
	budget.held, budget.held_pages = memory, pages
	append(&budget.binds, form)
	return true
}

@(private = "file")
budget_release :: proc "contextless" (binder: ^Memory_Binder) {
	budget := (^Budget_Binder)(binder)
	context = runtime.default_context()
	delete(budget.held)
	budget.held, budget.held_pages = nil, 0
}

@(private = "file")
pages_of :: proc(blocks: u64, form: Count_Form, cache_pages: u64) -> u64 {
	layout, _ := state_layout(blocks, TEST_STATE_HASH_ROOTS, form, cache_pages)
	return (layout.bytes + BLOCK_SIZE - 1) / BLOCK_SIZE
}

@(private = "file")
binder_make :: proc(budget_pages: u64) -> Budget_Binder {
	return {binder = {bind = budget_bind, release = budget_release}, state = new(State), budget_pages = budget_pages}
}

@(private = "file")
binder_free :: proc(binder: ^Budget_Binder) {
	budget_release(binder)
	delete(binder.binds)
	free(binder.state)
}

// A disk of 8192 blocks whose root has a complete count tree, in a test
// disk of 8192 blocks.
@(private = "file")
disk_with_tree :: proc(t: ^testing.T) -> Test_Disk {
	disk := disk_make(8192)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	tables := test_state_make(8192)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 8192)
	counts := count_tree_write(t, tables, &disk)
	root := (^format.Root)(raw_data(disk.bytes))
	root.counts = counts
	root.counts_complete = 1
	root.check = format.root_check(root)
	return disk
}

// A budget that holds the tables of the disk opens it with them. A budget
// between the two forms (it pays the tables of half the disk and the
// cache, not both at once) opens from the count tree, never with both
// held past the budget. A budget that pays neither is refused whole, with
// no memory of use left.
@(test)
the_open_takes_the_form_that_its_budget_pays :: proc(t: ^testing.T) {
	disk := disk_with_tree(t)
	defer delete(disk.bytes)
	whole := pages_of(8192, .Tables, COUNT_CACHE_PAGES_OF_TABLES)
	tree := pages_of(8192, .Count_Tree, format.COUNT_LEVEL_LIMIT + 2)

	rich := binder_make(whole)
	defer binder_free(&rich)
	open := open_with_forms(rich.state, &disk, 8192, &rich)
	testing.expect(t, !open.result.failed && !open.from_tree && open.table_blocks == 8192)

	// The tables of 4096 blocks fit; the least cache fits alone, not with
	// them: the tables end first.
	half := pages_of(4096, .Tables, COUNT_CACHE_PAGES_OF_TABLES)
	testing.expect(t, whole > max(half, tree), "the tables of the whole disk pass the budget between the forms")
	between := binder_make(max(half, tree))
	defer binder_free(&between)
	open = open_with_forms(between.state, &disk, 8192, &between)
	testing.expect(t, !open.result.failed && open.from_tree)
	testing.expect_value(t, open.table_blocks, u64(4096))
	testing.expect(t, between.most_held <= between.budget_pages, "no binding past the budget")
	testing.expect_value(t, between.state.form, Count_Form.Count_Tree)
	testing.expect_value(t, block_count(between.state, 2), rich.state.references[2])

	// Neither form: refused whole, and the binder holds nothing.
	poor := binder_make(tree - 1)
	defer binder_free(&poor)
	open = open_with_forms(poor.state, &disk, 8192, &poor)
	testing.expect(t, open.result.failed)
	testing.expect_value(t, poor.held_pages, u64(0))
}
