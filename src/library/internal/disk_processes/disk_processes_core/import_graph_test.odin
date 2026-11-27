#+build !freestanding
package disk_processes_core

import "core:testing"
import "modus:contract/blake3"
import rd "modus:contract/root_delegation"

// Drives the disk_processes_core machine end-to-end with a diamond outside
// module DAG (root -> A, B -> C) and verifies rich_toolkit post-order
// resolution, then drives a cyclic import graph (root -> A -> B -> A) and
// verifies cycle refusal.

@(private = "file")
graph_test_image_holds :: proc "contextless" (hash: blake3.Hash) -> bool {
	_ = hash
	return false
}

@(private = "file")
Graph_Fake_Node :: struct {
	payload: [32]u8,
	hash:    blake3.Hash,
	deps:    [2]blake3.Hash,
	dep_n:   int,
}

@(private = "file")
graph_fake_nodes: [4]Graph_Fake_Node
@(private = "file")
graph_fake_count: int

@(private = "file")
graph_test_imports_walk :: proc "contextless" (file: []u8, machine: ^Machine) {
	if len(file) != 32 {
		return
	}
	for i in 0 ..< graph_fake_count {
		if string(file) == string(graph_fake_nodes[i].payload[:]) {
			for d in 0 ..< graph_fake_nodes[i].dep_n {
				want_import(machine, graph_fake_nodes[i].deps[d])
			}
			return
		}
	}
}

@(private = "file")
run_fake_module_load :: proc(
	t: ^testing.T,
	m: ^Machine,
	root_idx: int,
	store_names: []string,
	store_nodes: []int,
) -> (final_event: rd.Disk_Load_Event) {
	machine_init(m, {image_holds = graph_test_image_holds, imports_walk = graph_test_imports_walk})

	req := rd.Load_Request{
		kind                  = u8(rd.Load_Kind.Module),
		principal             = 1,
		module_hash           = graph_fake_nodes[root_idx].hash,
		storage_module_length = u8(len("storage")),
	}
	req.nickname_length = u8(copy(req.nickname[:], "app"))
	copy(req.storage_module[:], "storage")

	act := load_begin(m, &req)
	testing.expect_value(t, act.kind, Action_Kind.Ask_Size)

	lent_buf: [64]u8
	list_sent := false

	for _ in 0 ..< 128 {
		switch act.kind {
		case .Ask_Size:
			ans := Storage_Answer{kind = .Value, value = 32}
			act = storage_answered(m, &ans)
		case .Ask_Read:
			payload := graph_fake_nodes[root_idx].payload[:]
			for s_idx in 0 ..< len(store_names) {
				if act.name == store_names[s_idx] {
					payload = graph_fake_nodes[store_nodes[s_idx]].payload[:]
					break
				}
			}
			ans := Storage_Answer{kind = .Value, value = 32, text = payload}
			act = storage_answered(m, &ans)
		case .Ask_List:
			if list_sent {
				ans := Storage_Answer{kind = .Value, value = 0}
				act = storage_answered(m, &ans)
			} else {
				list_sent = true
				rows: [LIST_PAGE_ROWS]List_Row
				names_buf: [LIST_NAME_BYTES]u8
				pos := 0
				for name, idx in store_names {
					copy(names_buf[pos:], name)
					rows[idx] = {name_offset = i64(pos), name_count = i64(len(name)), class = .Object, size = 32}
					pos += len(name)
				}
				ans := Storage_Answer{kind = .Value, value = i64(len(store_names)), rows = rows[:len(store_names)], names = names_buf[:]}
				act = storage_answered(m, &ans)
			}
		case .Send_Event:
			switch act.event {
			case .Memory_Wanted:
				act = memory_lent(m, lent_buf[:])
			case .Module_Filled, .Scan_Started, .Import_Found, .Candidate_Dropped:
				act = continue_given(m)
			case .Ready, .Refused, .Command_Refused, .None, .Cancelled:
				return act.event
			}
		case .Wait_Command, .Ask_Cache_Frame, .Ask_Store_Set_Size, .Ask_Store_Write_Range, .Ask_Store_Commit:
			return act.event
		}
	}
	return act.event
}

@(test)
disk_processes_resolves_outside_import_dag_and_refuses_cycles :: proc(t: ^testing.T) {
	// Construct payloads for root (0), dep A (1), dep B (2), shared leaf C (3).
	for i in 0 ..< 4 {
		graph_fake_nodes[i] = {}
		graph_fake_nodes[i].payload[0] = u8('A' + i)
		graph_fake_nodes[i].hash = blake3.hash(graph_fake_nodes[i].payload[:])
	}
	graph_fake_count = 4

	// Diamond DAG: root -> A, B; A -> C; B -> C; C -> (none).
	graph_fake_nodes[0].deps = {graph_fake_nodes[1].hash, graph_fake_nodes[2].hash}
	graph_fake_nodes[0].dep_n = 2
	graph_fake_nodes[1].deps = {graph_fake_nodes[3].hash, {}}
	graph_fake_nodes[1].dep_n = 1
	graph_fake_nodes[2].deps = {graph_fake_nodes[3].hash, {}}
	graph_fake_nodes[2].dep_n = 1
	graph_fake_nodes[3].dep_n = 0

	names := [3]string{"dep_a", "dep_b", "dep_c"}
	indices := [3]int{1, 2, 3}
	m := new(Machine)
	defer free(m)
	event := run_fake_module_load(t, m, 0, names[:], indices[:])
	testing.expect_value(t, event, rd.Disk_Load_Event.Ready)
	testing.expect_value(t, m.resolved_count, 4)
	// Post-order resolution places leaf C first and root last.
	testing.expect_value(t, m.import_graph.modules[m.resolved_order[0]].hash, graph_fake_nodes[3].hash)
	testing.expect_value(t, m.import_graph.modules[m.resolved_order[3]].hash, graph_fake_nodes[0].hash)

	// Cyclic import graph: root -> A -> B -> A is refused with Import_Bounds.
	graph_fake_nodes[0].deps = {graph_fake_nodes[1].hash, {}}
	graph_fake_nodes[0].dep_n = 1
	graph_fake_nodes[1].deps = {graph_fake_nodes[2].hash, {}}
	graph_fake_nodes[1].dep_n = 1
	graph_fake_nodes[2].deps = {graph_fake_nodes[1].hash, {}}
	graph_fake_nodes[2].dep_n = 1

	cyc_names := [2]string{"dep_a", "dep_b"}
	cyc_indices := [2]int{1, 2}
	cyc_event := run_fake_module_load(t, m, 0, cyc_names[:], cyc_indices[:])
	testing.expect_value(t, cyc_event, rd.Disk_Load_Event.Refused)
	testing.expect_value(t, m.report.refusal, u32(rd.Disk_Load_Refusal.Import_Bounds))

	// Import graph overflow fails closed with Import_Bounds instead of skipping cycle checks.
	graph_fake_nodes[0].deps = {graph_fake_nodes[1].hash, {}}
	graph_fake_nodes[0].dep_n = 1
	graph_fake_nodes[1].dep_n = 0
	machine_init(m, {image_holds = graph_test_image_holds, imports_walk = graph_test_imports_walk})
	req := rd.Load_Request{
		kind                  = u8(rd.Load_Kind.Module),
		principal             = 1,
		module_hash           = graph_fake_nodes[0].hash,
		storage_module_length = u8(len("storage")),
	}
	req.nickname_length = u8(copy(req.nickname[:], "app"))
	copy(req.storage_module[:], "storage")
	act := load_begin(m, &req)
	testing.expect_value(t, act.kind, Action_Kind.Ask_Size)
	// Saturate import_graph so the root walk triggers graph_add(.Graph_Full) -> import_graph_overflow.
	m.import_graph.count = len(m.import_graph.modules)
	lent_buf: [64]u8
	list_sent := false
	ovf_event: rd.Disk_Load_Event
	for _ in 0 ..< 64 {
		switch act.kind {
		case .Ask_Size:
			ans := Storage_Answer{kind = .Value, value = 32}
			act = storage_answered(m, &ans)
		case .Ask_Read:
			payload := act.name == "dep_a" ? graph_fake_nodes[1].payload[:] : graph_fake_nodes[0].payload[:]
			ans := Storage_Answer{kind = .Value, value = 32, text = payload}
			act = storage_answered(m, &ans)
		case .Ask_List:
			if list_sent {
				ans := Storage_Answer{kind = .Value, value = 0}
				act = storage_answered(m, &ans)
			} else {
				list_sent = true
				rows := [1]List_Row{{name_offset = 0, name_count = 5, class = .Object, size = 32}}
				ans := Storage_Answer{kind = .Value, value = 1, rows = rows[:], names = transmute([]u8)string("dep_a")}
				act = storage_answered(m, &ans)
			}
		case .Send_Event:
			switch act.event {
			case .Memory_Wanted:
				act = memory_lent(m, lent_buf[:])
			case .Module_Filled, .Scan_Started, .Import_Found, .Candidate_Dropped:
				act = continue_given(m)
			case .Ready, .Refused, .Command_Refused, .None, .Cancelled:
				ovf_event = act.event
			}
		case .Wait_Command, .Ask_Cache_Frame, .Ask_Store_Set_Size, .Ask_Store_Write_Range, .Ask_Store_Commit:
			ovf_event = act.event
		}
		if ovf_event != .None {
			break
		}
	}
	testing.expect(t, m.import_graph_overflow)
	testing.expect_value(t, ovf_event, rd.Disk_Load_Event.Refused)
	testing.expect_value(t, m.report.refusal, u32(rd.Disk_Load_Refusal.Import_Bounds))
}
