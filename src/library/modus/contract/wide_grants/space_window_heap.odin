#+build !freestanding
// The memory of the spaces on the heap of a host, for the host tests of the
// collector: a machine commits it from the budget of the collector
// (src/modules/system/collector/space_window_memory.odin). No build of the
// system reads this file.
package wide_grants

import "base:runtime"

// The places that a table on the heap holds at most: a host test that
// passes it asks for a budget that a test does not reach.
SPACE_HEAP_PLACES_MOST :: 4096

// The memory of one store on the heap. windows_paid is the budget of the
// test, in windows; taken, the windows that the store holds.
Space_Heap_Memory :: struct {
	windows_paid: u32,
	taken:        u32,
	places:       ^[SPACE_HEAP_PLACES_MOST]Collector_Space,
	places_paid:  u32, // The places that the budget of the test pays.
	index:        []u8,
	refuse_take:  bool, // A test of a commit that the kernel refuses.
}

// space_memory_heap gives the memory of one store on the heap, with a budget
// of windows_paid windows and places_paid places. It lives as long as the
// test that made it: a host test does not free it.
space_memory_heap :: proc "contextless" (windows_paid: u32 = 64, places_paid: u32 = 256) -> (port: Space_Memory_Port, memory: ^Space_Heap_Memory) {
	memory = (^Space_Heap_Memory)(runtime.heap_alloc(size_of(Space_Heap_Memory)))
	memory.windows_paid = windows_paid
	memory.places_paid = min(places_paid, SPACE_HEAP_PLACES_MOST)
	memory.places = (^[SPACE_HEAP_PLACES_MOST]Collector_Space)(runtime.heap_alloc(size_of([SPACE_HEAP_PLACES_MOST]Collector_Space)))
	take :: proc "contextless" (user: rawptr) -> ^Space_Window {
		memory := (^Space_Heap_Memory)(user)
		if memory.refuse_take || memory.taken >= memory.windows_paid {
			return nil
		}
		memory.taken += 1
		return (^Space_Window)(runtime.heap_alloc(size_of(Space_Window)))
	}
	give :: proc "contextless" (user: rawptr, window: ^Space_Window) {
		memory := (^Space_Heap_Memory)(user)
		memory.taken -= 1
		runtime.heap_free(window)
	}
	left :: proc "contextless" (user: rawptr) -> u32 {
		memory := (^Space_Heap_Memory)(user)
		return memory.windows_paid - min(memory.taken, memory.windows_paid)
	}
	places :: proc "contextless" (user: rawptr, count: u32) -> []Collector_Space {
		memory := (^Space_Heap_Memory)(user)
		if count > memory.places_paid {
			return nil
		}
		return memory.places[:count]
	}
	index :: proc "contextless" (user: rawptr, bytes: int) -> []u8 {
		memory := (^Space_Heap_Memory)(user)
		grown := ([^]u8)(runtime.heap_alloc(bytes))[:bytes]
		copy(grown, memory.index)
		if memory.index != nil {
			runtime.heap_free(raw_data(memory.index))
		}
		memory.index = grown
		return grown
	}
	return {user = memory, window_take = take, window_give = give, windows_left = left, places_grow = places, index_grow = index}, memory
}

// space_window_heap_port gives the memory of one store on the heap with a
// budget that the test does not reach.
space_window_heap_port :: proc "contextless" () -> Space_Memory_Port {
	port, _ := space_memory_heap()
	return port
}
