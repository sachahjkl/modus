#+build !freestanding
// The windows of the spaces on the heap of a host, for the host tests of the
// collector: a machine commits them from the budget of the collector
// (src/modules/system/collector). No build of the system reads this file.
package wide_grants

import "base:runtime"

// The windows of one store on the heap, by place.
@(private = "file")
Heap_Windows :: struct {
	windows: [SPACE_CAPACITY]^Space_Window,
}

// space_window_heap_port gives a port of windows on the heap, for one
// store. Each window is zeroed when it is taken, and freed when it is given
// back. The table of the port lives as long as the test that made it.
space_window_heap_port :: proc "contextless" () -> Space_Window_Port {
	table := (^Heap_Windows)(runtime.heap_alloc(size_of(Heap_Windows)))
	take :: proc "contextless" (user: rawptr, place: u32) -> ^Space_Window {
		table := (^Heap_Windows)(user)
		if place >= SPACE_CAPACITY || table.windows[place] != nil {
			return nil
		}
		table.windows[place] = (^Space_Window)(runtime.heap_alloc(size_of(Space_Window)))
		return table.windows[place]
	}
	give :: proc "contextless" (user: rawptr, place: u32) {
		table := (^Heap_Windows)(user)
		if place < SPACE_CAPACITY && table.windows[place] != nil {
			runtime.heap_free(table.windows[place])
			table.windows[place] = nil
		}
	}
	return {user = table, take = take, give = give}
}
