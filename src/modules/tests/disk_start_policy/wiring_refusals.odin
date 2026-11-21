package disk_start_policy

import "modus:contract/errors"
import "modus:contract/root_ring"
import "modus:system"

// wiring_refusals asks the root service for the wiring that a start policy
// from the disk does not get (src/md/features/module_outputs.md, "The
// decisions of the wiring rows"). Its list page is refused: the root
// service keeps no budget handle of a disk process, so it pays no list for
// it, and this start policy can write no list that reads a stream of its
// children. Then each Start that names a list is refused before any
// start: for a part of the system, for the console that runs, and, with
// no list page, for a module that the image holds. Each refusal is checked
// whole, its status and its error record, and each Start is sent twice: a
// second refusal of the same kind, and not Exists, says that the first one
// started nothing. wrong is the count of the answers that differ, each
// with its line.
wiring_refusals :: proc "contextless" () -> (wrong: int) {
	wire := u32(root_ring.Root_Command.Wire)
	start := u32(root_ring.Root_Command.Start)
	status, values := call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	wrong += expect(1, status, values, .No_Budget, errors.ring_fail(wire, .Budget_Hidden, .Pages))
	cases := [3]struct {
		name:    string,
		status:  system.Status,
		refusal: [7]u64,
	} {
		{"input", .Bad_Operation, errors.ring_fail(start, .Unsupported, .Wiring_Rows, 2)},
		{"console", .Bad_State, errors.ring_fail(start, .Exists, .Processes, 1)},
		{"wired_reader", .Bad_State, errors.ring_fail(start, .Absent, .Wirings)},
	}
	for item, index in cases {
		for again in u32(0) ..< 2 {
			packed := system.name_pack(item.name)
			status, values = call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(root_ring.Start_Wiring_List.In_The_List_Page), 0, 0})
			wrong += expect(u32(2 + 2 * index) + again, status, values, item.status, item.refusal)
		}
	}
	return wrong
}

// expect checks one answer whole: its status and its error record.
@(private = "file")
expect :: proc "contextless" (case_number: u32, status: system.Status, values: [7]u64, wanted: system.Status, refusal: [7]u64) -> int {
	if status == wanted && values == refusal {
		return 0
	}
	system.log_fact(.Info, Wiring_Wrong{case_number = case_number, status = status})
	return 1
}
