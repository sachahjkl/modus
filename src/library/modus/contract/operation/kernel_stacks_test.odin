#+build !freestanding
#+build !modus
package operation

import "core:testing"

// Each interrupt stack of the slot of a processor starts one guard page
// after the stack before it, the first after the stack of the double
// fault, and a guard page follows the last one inside the slot. A stack of
// the index one past the last would pass the slot: the slot holds no
// fourth one.
@(test)
each_interrupt_stack_is_between_guard_pages_inside_its_slot :: proc(t: ^testing.T) {
	kernel_stack_first_page :: 1
	fault_stack_first_page :: kernel_stack_first_page + KERNEL_STACK_PAGES + 1
	previous_end := u64(fault_stack_first_page + KERNEL_FAULT_STACK_PAGES)
	stack_pages := u64(KERNEL_STACK_PAGES + KERNEL_FAULT_STACK_PAGES)
	for index in 0 ..< u64(KERNEL_INTERRUPT_STACK_COUNT) {
		first := kernel_interrupt_stack_first_page(index)
		testing.expectf(t, first == previous_end + 1, "the interrupt stack %v starts at page %v, one guard page after page %v", index, first, previous_end)
		previous_end = first + KERNEL_INTERRUPT_STACK_PAGES
		testing.expectf(t, previous_end < KERNEL_STACK_SLOT_PAGES, "a guard page follows the interrupt stack %v inside the slot", index)
		stack_pages += KERNEL_INTERRUPT_STACK_PAGES
	}
	testing.expect_value(t, stack_pages, KERNEL_STACK_SLOT_STACK_PAGES)
	past := kernel_interrupt_stack_first_page(KERNEL_INTERRUPT_STACK_COUNT)
	testing.expectf(t, past + KERNEL_INTERRUPT_STACK_PAGES > KERNEL_STACK_SLOT_PAGES, "a stack one past the last, at page %v, would pass the slot", past)
}
