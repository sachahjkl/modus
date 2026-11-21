#+build !freestanding
package wiring_core

import "core:mem"
import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import ws "modus:contract/wiring_service"

@(private = "file")
Test_Record_Spec :: struct {
	name:       string,
	field_name: string,
	field_size: u32,
	unsigned:   bool,
}

@(private = "file")
Test_Stream_Spec :: struct {
	name:         string,
	record_index: u32, // 1-based into records, or 0 for generic.
	wirings:      module.Wiring_Count,
}

// build_test_module synthesizes a minimal valid module file in memory with
// the given record descriptions, record outputs, and record inputs.
@(private = "file")
build_test_module :: proc(records_spec: []Test_Record_Spec, outputs_spec: []Test_Stream_Spec, inputs_spec: []Test_Stream_Spec) -> []u8 {
	strings_buf := make([dynamic]u8, context.temp_allocator)
	append(&strings_buf, 0)
	add_str :: proc(buf: ^[dynamic]u8, s: string) -> (u32, u32) {
		off := u32(len(buf))
		for i in 0 ..< len(s) {
			append(buf, s[i])
		}
		return off, u32(len(s))
	}

	records := make([dynamic]module.Record, context.temp_allocator)
	append(&records, module.Record{})
	fields := make([dynamic]module.Field, context.temp_allocator)
	append(&fields, module.Field{})

	for spec in records_spec {
		name_off, name_cnt := add_str(&strings_buf, spec.name)
		f_off, f_cnt := add_str(&strings_buf, spec.field_name)
		first_field := u32(len(fields))
		append(&fields, module.Field{
			name_offset = f_off,
			name_count  = f_cnt,
			offset      = 0,
			type        = u8(module.Type.Integer),
			detail      = spec.field_size,
			unsigned    = spec.unsigned,
		})
		append(&records, module.Record{
			name_offset = name_off,
			name_count  = name_cnt,
			size        = spec.field_size,
			first_field = first_field,
			field_count = 1,
		})
	}

	outputs := make([dynamic]module.Record_Output, context.temp_allocator)
	append(&outputs, module.Record_Output{})
	for spec in outputs_spec {
		n_off, n_cnt := add_str(&strings_buf, spec.name)
		append(&outputs, module.Record_Output{
			name_offset = n_off,
			name_count  = n_cnt,
			record      = spec.record_index,
			pairing     = u8(module.Record_Output_Pairing.Unpaired),
		})
	}

	inputs := make([dynamic]module.Record_Input, context.temp_allocator)
	append(&inputs, module.Record_Input{})
	for spec in inputs_spec {
		n_off, n_cnt := add_str(&strings_buf, spec.name)
		append(&inputs, module.Record_Input{
			name_offset = n_off,
			name_count  = n_cnt,
			record      = spec.record_index,
			wirings     = u8(spec.wirings),
		})
	}

	dir_end := size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry)
	rec_off := dir_end
	fld_off := rec_off + len(records) * size_of(module.Record)
	out_off := fld_off + len(fields) * size_of(module.Field)
	in_off := out_off + len(outputs) * size_of(module.Record_Output)
	str_off := in_off + len(inputs) * size_of(module.Record_Input)
	total := str_off + len(strings_buf)

	buf := make([]u8, total, context.temp_allocator)
	hdr := module.Header{
		magic       = module.MAGIC,
		version     = module.VERSION,
		header_size = size_of(module.Header),
		machine     = .X86_64,
		table_count = module.TABLE_COUNT,
	}
	dir: [module.TABLE_COUNT]module.Table_Entry
	dir[module.Table_Kind.Records] = {offset = u64(rec_off), count = u32(len(records)), record_size = size_of(module.Record)}
	dir[module.Table_Kind.Fields] = {offset = u64(fld_off), count = u32(len(fields)), record_size = size_of(module.Field)}
	dir[module.Table_Kind.Record_Outputs] = {offset = u64(out_off), count = u32(len(outputs)), record_size = size_of(module.Record_Output)}
	dir[module.Table_Kind.Record_Inputs] = {offset = u64(in_off), count = u32(len(inputs)), record_size = size_of(module.Record_Input)}
	dir[module.Table_Kind.Strings] = {offset = u64(str_off), count = u32(len(strings_buf)), record_size = 1}

	mem.copy(&buf[0], &hdr, size_of(hdr))
	mem.copy(&buf[size_of(hdr)], &dir, size_of(dir))
	mem.copy(&buf[rec_off], raw_data(records), len(records) * size_of(module.Record))
	mem.copy(&buf[fld_off], raw_data(fields), len(fields) * size_of(module.Field))
	mem.copy(&buf[out_off], raw_data(outputs), len(outputs) * size_of(module.Record_Output))
	mem.copy(&buf[in_off], raw_data(inputs), len(inputs) * size_of(module.Record_Input))
	mem.copy(&buf[str_off], raw_data(strings_buf), len(strings_buf))
	return buf
}

// pack_image concatenates module slices into one fake boot image with non-zero
// starting offset (so offset 0 is never a valid module).
@(private = "file")
pack_image :: proc(mods: ..[]u8) -> (image: []u8, offsets: []u64, sizes: []u64) {
	buf := make([dynamic]u8, context.temp_allocator)
	resize(&buf, 64)
	offs := make([]u64, len(mods), context.temp_allocator)
	szs := make([]u64, len(mods), context.temp_allocator)
	for m, i in mods {
		offs[i] = u64(len(buf))
		szs[i] = u64(len(m))
		append(&buf, ..m)
	}
	return buf[:], offs, szs
}

@(private = "file")
make_wire_row :: proc(w_end: output.Wiring_End, w_h, w_idx: u32, r_end: output.Wiring_End, r_h, r_idx: u32, pace: output.Wiring_Pace = .Writer_Chooses) -> output.Wiring {
	return {
		writer_end    = u32(w_end),
		writer_handle = w_h,
		writer_stream = u32(output.Writer_Stream.Record_Output),
		writer_index  = w_idx,
		reader_end    = u32(r_end),
		reader_handle = r_h,
		reader_index  = r_idx,
		pace          = u32(pace),
	}
}

@(private = "file")
wire_once :: proc(s: ^State, image: []u8, asker_id: ws.Process_Identity, row: output.Wiring, lent: []ws.Resolved_Lent_End, connected: []ws.Resolved_Connected_End = nil, room_proc: Ring_Room_Proc = nil, room_data: rawptr = nil) -> (status: ws.Response_Status, refusal: errors.Error_Record, wiring_slot: int, wiring_num: u32) {
	list_bytes: [output.WIRING_LIST_BYTES_MOST]u8
	rows := [1]output.Wiring{row}
	handles: [output.WIRING_LIST_HANDLE_LIMIT]u32
	for i in 0 ..< len(lent) {
		handles[i] = u32(i + 1)
	}
	output.wiring_list_write(list_bytes[:], rows[:], handles[:len(lent)])
	req := ws.Resolved_Wiring_Request{
		form            = u32(output.Wiring_List_Form.Wire),
		list_bytes      = u32(output.wiring_terms_start(1, len(lent))),
		lent_count      = u32(len(lent)),
		connected_count = u32(len(connected)),
	}
	for l, i in lent {
		req.lent[i] = l
	}
	for c, i in connected {
		req.connected[i] = c
	}
	work: Plan_Work
	status, refusal = plan_resolve(s, image, list_bytes[:], &req, asker_id, 29, &work, room_proc, room_data)
	if status != .Ok {
		return status, refusal, -1, 0
	}
	slot, num, ok := wiring_slot_allocate(s, work.asker_index, &work.plans[0])
	if !ok {
		return .No_Slot, {}, -1, 0
	}
	wiring_mark_delivered(s, slot, &work.plans[0])
	return .Ok, {}, slot, num
}

// Type mismatch (different record name, size, or field signedness) is refused
// with zero state mutation.
@(test)
type_mismatch_is_refused_without_mutating_state :: proc(t: ^testing.T) {
	mod_a := build_test_module({{"Alpha", "v", 8, true}}, {{"out", 1, .One}}, {{"in_one", 1, .One}})
	mod_b_name := build_test_module({{"Beta", "v", 8, true}}, nil, {{"in_one", 1, .One}})
	mod_b_size := build_test_module({{"Alpha", "v", 4, true}}, nil, {{"in_one", 1, .One}})
	mod_b_sign := build_test_module({{"Alpha", "v", 8, false}}, nil, {{"in_one", 1, .One}})
	image, offs, szs := pack_image(mod_a, mod_b_name, mod_b_size, mod_b_sign)

	s: State
	state_init(&s)
	asker := ws.Process_Identity{1, 10}
	writer := ws.Process_Identity{2, 20}
	r_name := ws.Process_Identity{3, 30}
	r_size := ws.Process_Identity{4, 40}
	r_sign := ws.Process_Identity{5, 50}
	_, _ = process_register(&s, asker, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, writer, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_name, offs[1], szs[1], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_size, offs[2], szs[2], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_sign, offs[3], szs[3], {.Has_Wiring_Ring})

	cases := [?]struct {
		reader: ws.Process_Identity,
		diff:   output.Description_Difference,
	}{
		{r_name, .Name},
		{r_size, .Size},
		{r_sign, .Field},
	}
	for c in cases {
		lent := [2]ws.Resolved_Lent_End{
			{process_slot = writer.slot, process_serial = writer.serial, started_by_asker = 1, present = 1},
			{process_slot = c.reader.slot, process_serial = c.reader.serial, started_by_asker = 1, present = 1},
		}
		status, refusal, _, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), lent[:])
		testing.expect_value(t, status, ws.Response_Status.Bad_Command)
		testing.expect_value(t, errors.Unit(refusal.unit), errors.Unit.Record_Types)
		testing.expect_value(t, output.Description_Difference(refusal.value), c.diff)
		testing.expect_value(t, s.wirings_running, 0)
	}
}

// Duplicate wiring (both on Wiring_Count.One and exact duplicate on Many),
// self-wire, and multi-hop cycles (A -> B -> A) are refused cleanly.
@(test)
duplicate_self_and_cycle_wirings_are_refused :: proc(t: ^testing.T) {
	mod := build_test_module({{"Item", "x", 8, true}}, {{"out", 1, .One}}, {{"in_one", 1, .One}, {"in_many", 1, .Many}})
	image, offs, szs := pack_image(mod)

	s: State
	state_init(&s)
	asker := ws.Process_Identity{1, 1}
	p_a := ws.Process_Identity{2, 2}
	p_b := ws.Process_Identity{3, 3}
	p_c := ws.Process_Identity{4, 4}
	_, _ = process_register(&s, asker, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, p_a, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, p_b, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, p_c, offs[0], szs[0], {.Has_Wiring_Ring})

	// 1. Self-wire A -> A refused.
	self_lent := [2]ws.Resolved_Lent_End{
		{process_slot = p_a.slot, process_serial = p_a.serial, started_by_asker = 1, present = 1},
		{process_slot = p_a.slot, process_serial = p_a.serial, started_by_asker = 1, present = 1},
	}
	st, ref, _, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), self_lent[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Bad_Value)
	testing.expect_value(t, s.wirings_running, 0)

	// 2. Wire A -> B (in_one), then duplicate A -> B (in_one) and C -> B (in_one) both refused.
	ab := [2]ws.Resolved_Lent_End{
		{process_slot = p_a.slot, process_serial = p_a.serial, started_by_asker = 1, present = 1},
		{process_slot = p_b.slot, process_serial = p_b.serial, started_by_asker = 1, present = 1},
	}
	st, _, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), ab[:])
	testing.expect_value(t, st, ws.Response_Status.Ok)
	testing.expect_value(t, s.wirings_running, 1)

	st, ref, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), ab[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Exists)

	cb := [2]ws.Resolved_Lent_End{
		{process_slot = p_c.slot, process_serial = p_c.serial, started_by_asker = 1, present = 1},
		{process_slot = p_b.slot, process_serial = p_b.serial, started_by_asker = 1, present = 1},
	}
	st, ref, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), cb[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Exists)

	// 3. Wire A -> B (in_many) succeeds, then exact duplicate A -> B (in_many) refused!
	st, _, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 2), ab[:])
	testing.expect_value(t, st, ws.Response_Status.Ok)
	st, ref, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 2), ab[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Exists)

	// 4. Direct cycle B -> A refused; 3-hop cycle B -> C then C -> A refused!
	ba := [2]ws.Resolved_Lent_End{
		{process_slot = p_b.slot, process_serial = p_b.serial, started_by_asker = 1, present = 1},
		{process_slot = p_a.slot, process_serial = p_a.serial, started_by_asker = 1, present = 1},
	}
	st, ref, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), ba[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Bad_Value)

	bc := [2]ws.Resolved_Lent_End{
		{process_slot = p_b.slot, process_serial = p_b.serial, started_by_asker = 1, present = 1},
		{process_slot = p_c.slot, process_serial = p_c.serial, started_by_asker = 1, present = 1},
	}
	st, _, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), bc[:])
	testing.expect_value(t, st, ws.Response_Status.Ok)

	ca := [2]ws.Resolved_Lent_End{
		{process_slot = p_c.slot, process_serial = p_c.serial, started_by_asker = 1, present = 1},
		{process_slot = p_a.slot, process_serial = p_a.serial, started_by_asker = 1, present = 1},
	}
	st, ref, _, _ = wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), ca[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_State)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Bad_Value)
	testing.expect_value(t, s.wirings_running, 3)
}

// Capacity bounds and one past each bound are refused with exact error records:
// LIST_PAGE_ASKERS_MOST, WIRINGS_OF_AN_ASKER_MOST, WIRINGS_OF_THE_MACHINE_MOST,
// CONNECTED_ENDS_OF_AN_ASKER_MOST, and ring room exhaustion.
@(test)
capacity_bounds_and_one_past_bound_are_refused :: proc(t: ^testing.T) {
	mod := build_test_module({{"Tick", "n", 8, true}}, {{"ticks", 1, .One}}, nil)
	image, offs, szs := pack_image(mod)

	s: State
	state_init(&s)

	// Register 5 askers and 4 writers.
	askers: [5]ws.Process_Identity
	for i in 0 ..< 5 {
		askers[i] = {u64(i + 1), u64(100 + i)}
		_, reg_st := process_register(&s, askers[i], 0, 0, {.Can_Wire, .Has_Wiring_Ring})
		testing.expect_value(t, reg_st, ws.Response_Status.Ok)
	}
	writers: [4]ws.Process_Identity
	for i in 0 ..< 4 {
		writers[i] = {u64(10 + i), u64(200 + i)}
		_, reg_st := process_register(&s, writers[i], offs[0], szs[0], {.Is_Service, .Has_Wiring_Ring})
		testing.expect_value(t, reg_st, ws.Response_Status.Ok)
	}

	// LIST_PAGE_ASKERS_MOST: 4 succeed, 5th refused with Full.
	for i in 0 ..< LIST_PAGE_ASKERS_MOST {
		already, _, lp_st, _ := list_page_reserve(&s, askers[i], 29)
		testing.expect(t, !already && lp_st == .Ok)
	}
	_, _, lp_st, lp_ref := list_page_reserve(&s, askers[4], 29)
	testing.expect_value(t, lp_st, ws.Response_Status.No_Slot)
	testing.expect_value(t, errors.Kind(lp_ref.kind), errors.Kind.Full)
	testing.expect_value(t, lp_ref.limit, i64(LIST_PAGE_ASKERS_MOST))

	// CONNECTED_ENDS_OF_AN_ASKER_MOST: 4 connected ends succeed, 5th refused!
	conn := [1]ws.Resolved_Connected_End{{
		process_slot             = writers[0].slot,
		process_serial           = writers[0].serial,
		handle_number            = 7,
		asker_acts_for_principal = 1,
		process_is_a_service     = 1,
		asker_holds_a_connection = 1,
		present                  = 1,
	}}
	for _ in 0 ..< CONNECTED_ENDS_OF_AN_ASKER_MOST {
		st, _, _, _ := wire_once(&s, image, askers[0], make_wire_row(.Connected, 7, 1, .Asker, 0, 0), nil, conn[:])
		testing.expect_value(t, st, ws.Response_Status.Ok)
	}
	st, ref, _, _ := wire_once(&s, image, askers[0], make_wire_row(.Connected, 7, 1, .Asker, 0, 0), nil, conn[:])
	testing.expect_value(t, st, ws.Response_Status.No_Slot)
	testing.expect_value(t, ref.limit, i64(CONNECTED_ENDS_OF_AN_ASKER_MOST))

	// Fill askers[0] up to WIRINGS_OF_AN_ASKER_MOST (4 more via Started on writers[1]), then 9th refused!
	lent1 := [1]ws.Resolved_Lent_End{{process_slot = writers[1].slot, process_serial = writers[1].serial, started_by_asker = 1, present = 1}}
	for _ in CONNECTED_ENDS_OF_AN_ASKER_MOST ..< output.WIRINGS_OF_AN_ASKER_MOST {
		w_st, _, _, _ := wire_once(&s, image, askers[0], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent1[:])
		testing.expect_value(t, w_st, ws.Response_Status.Ok)
	}
	st, ref, _, _ = wire_once(&s, image, askers[0], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent1[:])
	testing.expect_value(t, st, ws.Response_Status.No_Slot)
	testing.expect_value(t, ref.limit, i64(output.WIRINGS_OF_AN_ASKER_MOST))

	// Fill askers[1] (8) and askers[2] (8) -> 24 = WIRINGS_OF_THE_MACHINE_MOST; askers[3]'s 1st is 25th -> refused!
	lent2 := [1]ws.Resolved_Lent_End{{process_slot = writers[2].slot, process_serial = writers[2].serial, started_by_asker = 1, present = 1}}
	lent3 := [1]ws.Resolved_Lent_End{{process_slot = writers[3].slot, process_serial = writers[3].serial, started_by_asker = 1, present = 1}}
	for _ in 0 ..< output.WIRINGS_OF_AN_ASKER_MOST {
		w_st, _, _, _ := wire_once(&s, image, askers[1], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent2[:])
		testing.expect_value(t, w_st, ws.Response_Status.Ok)
	}
	for _ in 0 ..< output.WIRINGS_OF_AN_ASKER_MOST {
		w_st, _, _, _ := wire_once(&s, image, askers[2], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent3[:])
		testing.expect_value(t, w_st, ws.Response_Status.Ok)
	}
	testing.expect_value(t, s.wirings_running, WIRINGS_OF_THE_MACHINE_MOST)
	st, ref, _, _ = wire_once(&s, image, askers[3], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent1[:])
	testing.expect_value(t, st, ws.Response_Status.No_Slot)
	testing.expect_value(t, ref.limit, i64(WIRINGS_OF_THE_MACHINE_MOST))

	// Ring room exhaustion refused with Busy when callback reports 0 room.
	zero_room :: proc "contextless" (data: rawptr, proc_index: int) -> (u32, bool) {
		return 0, true
	}
	actions: [WIRINGS_OF_THE_MACHINE_MOST]Stop_Action
	_, _ = revoke_asker_apply(&s, askers[2], actions[:])
	st, ref, _, _ = wire_once(&s, image, askers[3], make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent1[:], nil, zero_room, nil)
	testing.expect_value(t, st, ws.Response_Status.No_Slot)
	testing.expect_value(t, errors.Kind(ref.kind), errors.Kind.Busy)
}

// Stop of producer/consumer notifies the surviving peer, reclaims slots,
// ignores stale serials, and detaches sides that already closed.
@(test)
stop_cleanup_notifies_peers_reclaims_slots_and_ignores_stale_serials :: proc(t: ^testing.T) {
	mod := build_test_module({{"Msg", "k", 8, true}}, {{"out", 1, .One}}, {{"in", 1, .Many}})
	image, offs, szs := pack_image(mod)

	s: State
	state_init(&s)
	asker := ws.Process_Identity{1, 10}
	writer := ws.Process_Identity{2, 20}
	reader := ws.Process_Identity{3, 30}
	_, _ = process_register(&s, asker, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, writer, offs[0], szs[0], {.Has_Wiring_Ring})
	r_idx, _ := process_register(&s, reader, offs[0], szs[0], {.Has_Wiring_Ring})

	lent := [2]ws.Resolved_Lent_End{
		{process_slot = writer.slot, process_serial = writer.serial, started_by_asker = 1, present = 1},
		{process_slot = reader.slot, process_serial = reader.serial, started_by_asker = 1, present = 1},
	}
	st, _, _, num := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), lent[:])
	testing.expect_value(t, st, ws.Response_Status.Ok)
	testing.expect_value(t, s.wirings_running, 1)

	// Stale serial on writer's slot is completely ignored.
	actions: [WIRINGS_OF_THE_MACHINE_MOST]Stop_Action
	stale := ws.Process_Stop_Notice{process_slot = writer.slot, process_serial = writer.serial - 1, kind = .Process_Stopped, cause = .Fault}
	cnt, _, matched := process_stop_apply(&s, stale, actions[:])
	testing.expect(t, !matched && cnt == 0)
	testing.expect_value(t, s.wirings_running, 1)

	// Real stop of writer notifies reader with Writer_Stopped + (Fault, None) and reclaims slot.
	real_stop := ws.Process_Stop_Notice{process_slot = writer.slot, process_serial = writer.serial, kind = .Process_Stopped, cause = .Fault}
	cnt, _, matched = process_stop_apply(&s, real_stop, actions[:])
	testing.expect(t, matched)
	testing.expect_value(t, cnt, 1)
	testing.expect_value(t, actions[0].kind, Stop_Action_Kind.End_Wiring)
	testing.expect_value(t, actions[0].wiring_number, num)
	testing.expect_value(t, actions[0].end_word, output.End_Word.Writer_Stopped)
	testing.expect_value(t, actions[0].stop_cause, op.Stop_Cause.Fault)
	testing.expect_value(t, actions[0].stop_outcome, op.Stop_Outcome.None)
	testing.expect(t, actions[0].asker_empty)
	testing.expect_value(t, s.wirings_running, 0)
	testing.expect_value(t, s.processes[r_idx].ends_given, 0)

	// Reusing slot 2 with a new serial succeeds, and a stale stop for old serial 20 is ignored.
	writer2 := ws.Process_Identity{2, 21}
	w2_idx, reg_st := process_register(&s, writer2, offs[0], szs[0], {.Has_Wiring_Ring})
	testing.expect_value(t, reg_st, ws.Response_Status.Ok)
	// Conflicting serial on active slot 2 is refused.
	_, conflict_st := process_register(&s, {2, 22}, offs[0], szs[0], {})
	testing.expect_value(t, conflict_st, ws.Response_Status.Bad_State)

	// Wire writer2 -> reader, writer2 takes and closes its end -> Side_Closed, then writer2 stops -> Detach (wiring stays open for reader!).
	lent2 := [2]ws.Resolved_Lent_End{
		{process_slot = writer2.slot, process_serial = writer2.serial, started_by_asker = 1, present = 1},
		{process_slot = reader.slot, process_serial = reader.serial, started_by_asker = 1, present = 1},
	}
	st2, _, _, num2 := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1), lent2[:])
	testing.expect_value(t, st2, ws.Response_Status.Ok)

	act_taken := wiring_completion_apply(&s, w2_idx, output.wiring_completion(num2, .Ok))
	testing.expect_value(t, act_taken.effect, Completion_Effect.None)
	act_closed := wiring_completion_apply(&s, w2_idx, output.wiring_closed_completion(num2))
	testing.expect_value(t, act_closed.effect, Completion_Effect.Write_End_Word)
	testing.expect_value(t, act_closed.end_word, output.End_Word.Side_Closed)

	// Stale stop for serial 20 does nothing!
	cnt, _, matched = process_stop_apply(&s, real_stop, actions[:])
	testing.expect(t, !matched && cnt == 0)
	testing.expect_value(t, s.wirings_running, 1)

	// Real stop for writer2 (serial 21) detaches without ending wiring; reader still holds it!
	stop2 := ws.Process_Stop_Notice{process_slot = writer2.slot, process_serial = writer2.serial, kind = .Process_Stopped, cause = .Itself, outcome = .Done}
	cnt, _, matched = process_stop_apply(&s, stop2, actions[:])
	testing.expect(t, matched && cnt == 1)
	testing.expect_value(t, actions[0].kind, Stop_Action_Kind.Detach)
	testing.expect_value(t, s.wirings_running, 1)

	// Then reader stops -> wiring ends with no second end word (end_written already true) and slot is reclaimed!
	stop_r := ws.Process_Stop_Notice{process_slot = reader.slot, process_serial = reader.serial, kind = .Process_Stopped, cause = .Holder}
	cnt, _, matched = process_stop_apply(&s, stop_r, actions[:])
	testing.expect(t, matched && cnt == 1)
	testing.expect_value(t, actions[0].kind, Stop_Action_Kind.End_Wiring)
	testing.expect_value(t, actions[0].end_word, output.End_Word.None)
	testing.expect_value(t, s.wirings_running, 0)
}

// Unwire refuses non-owners and unknown numbers; owner unwire succeeds.
@(test)
unwire_enforces_asker_ownership :: proc(t: ^testing.T) {
	mod := build_test_module({{"Row", "a", 8, true}}, {{"out", 1, .One}}, nil)
	image, offs, szs := pack_image(mod)

	s: State
	state_init(&s)
	asker1 := ws.Process_Identity{1, 10}
	asker2 := ws.Process_Identity{2, 20}
	writer := ws.Process_Identity{3, 30}
	_, _ = process_register(&s, asker1, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, asker2, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, writer, offs[0], szs[0], {.Has_Wiring_Ring})

	lent := [1]ws.Resolved_Lent_End{{process_slot = writer.slot, process_serial = writer.serial, started_by_asker = 1, present = 1}}
	st, _, _, num := wire_once(&s, image, asker1, make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent[:])
	testing.expect_value(t, st, ws.Response_Status.Ok)

	// Another asker cannot unwire asker1's wiring.
	_, _, _, u_st, _ := unwire_apply(&s, asker2, num, .Revoked, 8)
	testing.expect_value(t, u_st, ws.Response_Status.No_Right)
	testing.expect_value(t, s.wirings_running, 1)

	// Unknown wiring number refused.
	_, _, _, u_st, _ = unwire_apply(&s, asker1, num + 99, .Revoked, 8)
	testing.expect_value(t, u_st, ws.Response_Status.Bad_Handle)

	// Owner unwires cleanly.
	_, written, empty, ok_st, _ := unwire_apply(&s, asker1, num, .Revoked, 8)
	testing.expect_value(t, ok_st, ws.Response_Status.Ok)
	testing.expect_value(t, written, output.End_Word.Revoked)
	testing.expect(t, empty)
	testing.expect_value(t, s.wirings_running, 0)
}

// Generic record output defers until its generic input is fixed in a Start list,
// and refuses when no wiring fixes its input type.
@(test)
generic_chain_resolves_and_unfixed_generic_output_is_refused :: proc(t: ^testing.T) {
	mod_src := build_test_module({{"Probe", "n", 8, true}}, {{"probes", 1, .One}}, nil)
	mod_relay := build_test_module(nil, {{"out", 0, .One}}, {{"in", 0, .Many}})
	image, offs, szs := pack_image(mod_src, mod_relay)

	s: State
	state_init(&s)
	asker := ws.Process_Identity{1, 10}
	src := ws.Process_Identity{2, 20}
	relay := ws.Process_Identity{3, 30}
	_, _ = process_register(&s, asker, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, src, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, relay, offs[1], szs[1], {.Has_Wiring_Ring})

	// Unfixed generic output refused with Not_Fixed.
	lent_relay := [1]ws.Resolved_Lent_End{{process_slot = relay.slot, process_serial = relay.serial, started_by_asker = 1, present = 1}}
	st, ref, _, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Asker, 0, 0), lent_relay[:])
	testing.expect_value(t, st, ws.Response_Status.Bad_Command)
	testing.expect_value(t, output.Description_Difference(ref.value), output.Description_Difference.Not_Fixed)

	// Start list: row 1 wires relay.out -> Asker (deferred), row 2 wires Child(src).probes -> relay.in (fixes relay.in).
	list_bytes: [output.WIRING_LIST_BYTES_MOST]u8
	rows := [2]output.Wiring{
		make_wire_row(.Started, 1, 1, .Asker, 0, 0),
		make_wire_row(.Child, 0, 1, .Started, 1, 1),
	}
	handles := [1]u32{1}
	output.wiring_list_write(list_bytes[:], rows[:], handles[:])
	req := ws.Resolved_Wiring_Request{
		form                = u32(output.Wiring_List_Form.Start),
		list_bytes          = u32(output.wiring_terms_start(2, 1)),
		lent_count          = 1,
		child_module_offset = offs[0],
		child_module_size   = szs[0],
	}
	req.lent[0] = {process_slot = relay.slot, process_serial = relay.serial, started_by_asker = 1, present = 1}
	work: Plan_Work
	st, ref = plan_resolve(&s, image, list_bytes[:], &req, asker, 1, &work)
	testing.expect_value(t, st, ws.Response_Status.Ok)
	testing.expect(t, work.plans[0].deferred && work.plans[0].resolved)
	testing.expect(t, work.plans[1].fixes && work.plans[1].keeps_type)
}

// Stall revocation edges: invalid slots, inactive slots, zero timestamp,
// clock below latch time, u64 max overflow safety, and bounded actions slice.
@(test)
stall_revocation_edges_and_bounds :: proc(t: ^testing.T) {
	mod_src := build_test_module({{"Event", "v", 8, true}}, {{"events", 1, .One}}, nil)
	mod_dst := build_test_module({{"Event", "v", 8, true}}, nil, {{"events", 1, .Many}})
	image, offs, szs := pack_image(mod_src, mod_dst)

	s: State
	state_init(&s)

	// Out-of-bounds and inactive slots are safe no-ops.
	wiring_stall_observe(&s, -1, true, 0, 100)
	wiring_stall_observe(&s, WIRINGS_OF_THE_MACHINE_MOST, true, 0, 100)
	wiring_stall_observe(&s, max(int), true, 0, 100)
	wiring_stall_observe(&s, 0, true, 0, 100)
	actions: [WIRINGS_OF_THE_MACHINE_MOST]Stop_Action
	testing.expect_value(t, wiring_stall_expire(&s, STALL_HANG_BOUND_MS, actions[:]), 0)
	_, watched_empty := wiring_stall_next_deadline(&s, 0, 1_000)
	testing.expect(t, !watched_empty)

	asker := ws.Process_Identity{1, 10}
	src := ws.Process_Identity{2, 20}
	r1 := ws.Process_Identity{3, 30}
	r2 := ws.Process_Identity{4, 40}
	_, _ = process_register(&s, asker, 0, 0, {.Can_Wire})
	_, _ = process_register(&s, src, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r1, offs[1], szs[1], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r2, offs[1], szs[1], {.Has_Wiring_Ring})

	lent1 := [2]ws.Resolved_Lent_End{
		{process_slot = src.slot, process_serial = src.serial, started_by_asker = 1, present = 1},
		{process_slot = r1.slot, process_serial = r1.serial, started_by_asker = 1, present = 1},
	}
	lent2 := [2]ws.Resolved_Lent_End{
		{process_slot = src.slot, process_serial = src.serial, started_by_asker = 1, present = 1},
		{process_slot = r2.slot, process_serial = r2.serial, started_by_asker = 1, present = 1},
	}
	st1, _, slot1, num1 := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Always_Holds_Writer), lent1[:])
	testing.expect_value(t, st1, ws.Response_Status.Ok)
	st2, _, slot2, num2 := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Always_Holds_Writer), lent2[:])
	testing.expect_value(t, st2, ws.Response_Status.Ok)

	// Latching at timestamp 0 must be distinct from unstalled.
	wiring_stall_observe(&s, slot1, true, 0, 0)
	testing.expect(t, s.wirings[slot1].stall_active)
	testing.expect_value(t, s.wirings[slot1].stalled_since_ms, u64(0))
	// 1 ms before bound: must NOT expire.
	testing.expect_value(t, wiring_stall_expire(&s, STALL_HANG_BOUND_MS - 1, actions[:]), 0)
	testing.expect(t, s.wirings[slot1].active)

	// Unstall slot1 while testing slot2 at max(u64) - 5 for overflow safety.
	wiring_stall_observe(&s, slot1, false, 0, 0)
	wiring_stall_observe(&s, slot2, true, 42, max(u64) - 5)
	testing.expect_value(t, wiring_stall_expire(&s, max(u64) - 10, actions[:]), 0) // Clock < stalled_since_ms: no underflow.
	testing.expect_value(t, wiring_stall_expire(&s, max(u64), actions[:]), 0) // Elapsed 5 < bound: no overflow.
	dl_max, watched_max := wiring_stall_next_deadline(&s, max(u64) - 2, 1_000)
	testing.expect(t, watched_max)
	testing.expect_value(t, dl_max, max(u64)) // Clamped to max(u64) with no wraparound.

	// Latch both slot1 and slot2 at 0 so both expire at STALL_HANG_BOUND_MS.
	wiring_stall_observe(&s, slot1, true, 0, 0)
	wiring_stall_observe(&s, slot2, false, 42, 0)
	wiring_stall_observe(&s, slot2, true, 42, 0)

	// Empty actions buffer must NOT mutate or drop any wiring.
	testing.expect_value(t, wiring_stall_expire(&s, STALL_HANG_BOUND_MS, nil), 0)
	testing.expect_value(t, s.wirings_running, 2)

	// Buffer of length 1 revokes only 1 and leaves the 2nd active for the next pass.
	single: [1]Stop_Action
	testing.expect_value(t, wiring_stall_expire(&s, STALL_HANG_BOUND_MS, single[:]), 1)
	testing.expect_value(t, single[0].kind, Stop_Action_Kind.End_Wiring)
	testing.expect_value(t, single[0].wiring_number, num1)
	testing.expect_value(t, single[0].end_word, output.End_Word.Revoked)
	testing.expect(t, !single[0].asker_empty)
	testing.expect_value(t, s.wirings_running, 1)

	// Second pass revokes the remaining stalled wiring and marks asker_empty.
	testing.expect_value(t, wiring_stall_expire(&s, STALL_HANG_BOUND_MS, single[:]), 1)
	testing.expect_value(t, single[0].wiring_number, num2)
	testing.expect_value(t, single[0].end_word, output.End_Word.Revoked)
	testing.expect(t, single[0].asker_empty)
	testing.expect_value(t, s.wirings_running, 0)
}

// Reader progress resets stalled_since_ms to 0 immediately (including u32
// cursor wraparound), Never_Holds_Writer and Writer_Chooses are never
// revoked, and revoking a stalled wiring leaves all healthy siblings intact.
@(test)
stall_revocation_preserves_healthy_siblings_and_non_holding_paces :: proc(t: ^testing.T) {
	mod_src := build_test_module({{"Log", "x", 8, true}}, {{"out", 1, .One}}, nil)
	mod_dst := build_test_module({{"Log", "x", 8, true}}, nil, {{"in", 1, .Many}})
	image, offs, szs := pack_image(mod_src, mod_dst)

	s: State
	state_init(&s)
	asker := ws.Process_Identity{1, 10}
	src := ws.Process_Identity{2, 20}
	r_stalled := ws.Process_Identity{3, 30}
	r_healthy := ws.Process_Identity{4, 40}
	r_never := ws.Process_Identity{5, 50}
	r_choice := ws.Process_Identity{6, 60}
	asker_idx, _ := process_register(&s, asker, 0, 0, {.Can_Wire})
	src_idx, _ := process_register(&s, src, offs[0], szs[0], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_stalled, offs[1], szs[1], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_healthy, offs[1], szs[1], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_never, offs[1], szs[1], {.Has_Wiring_Ring})
	_, _ = process_register(&s, r_choice, offs[1], szs[1], {.Has_Wiring_Ring})

	make_lent :: proc(a, b: ws.Process_Identity) -> [2]ws.Resolved_Lent_End {
		return {
			{process_slot = a.slot, process_serial = a.serial, started_by_asker = 1, present = 1},
			{process_slot = b.slot, process_serial = b.serial, started_by_asker = 1, present = 1},
		}
	}
	l_stalled := make_lent(src, r_stalled)
	l_healthy := make_lent(src, r_healthy)
	l_never := make_lent(src, r_never)
	l_choice := make_lent(src, r_choice)

	st_s, _, slot_stalled, num_stalled := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Always_Holds_Writer), l_stalled[:])
	st_h, _, slot_healthy, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Always_Holds_Writer), l_healthy[:])
	st_n, _, slot_never, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Never_Holds_Writer), l_never[:])
	st_c, _, slot_choice, _ := wire_once(&s, image, asker, make_wire_row(.Started, 1, 1, .Started, 2, 1, .Writer_Chooses), l_choice[:])
	testing.expect_value(t, st_s, ws.Response_Status.Ok)
	testing.expect_value(t, st_h, ws.Response_Status.Ok)
	testing.expect_value(t, st_n, ws.Response_Status.Ok)
	testing.expect_value(t, st_c, ws.Response_Status.Ok)
	testing.expect_value(t, s.wirings_running, 4)

	// All four observed full at t = 1 000 ms.
	wiring_stall_observe(&s, slot_stalled, true, 100, 1_000)
	wiring_stall_observe(&s, slot_healthy, true, max(u32), 1_000)
	wiring_stall_observe(&s, slot_never, true, 0, 1_000)
	wiring_stall_observe(&s, slot_choice, true, 0, 1_000)

	// Non-Always_Holds_Writer paces never latch stalled_since_ms.
	testing.expect(t, !s.wirings[slot_never].stall_active && s.wirings[slot_never].stalled_since_ms == 0)
	testing.expect(t, !s.wirings[slot_choice].stall_active && s.wirings[slot_choice].stalled_since_ms == 0)
	testing.expect(t, s.wirings[slot_stalled].stall_active && s.wirings[slot_stalled].stalled_since_ms == 1_000)
	testing.expect(t, s.wirings[slot_healthy].stall_active && s.wirings[slot_healthy].stalled_since_ms == 1_000)

	// At t = 59 500 ms: healthy reader advances across u32 wraparound (max(u32) -> 0).
	// Stalled reader makes no progress.
	wiring_stall_observe(&s, slot_stalled, true, 100, 59_500)
	wiring_stall_observe(&s, slot_healthy, true, 0, 59_500)
	testing.expect_value(t, s.wirings[slot_stalled].stalled_since_ms, u64(1_000))
	testing.expect(t, !s.wirings[slot_healthy].stall_active)
	testing.expect_value(t, s.wirings[slot_healthy].stalled_since_ms, u64(0))

	// Next deadline at t = 60 600 ms must clamp to 61 000 ms (400 ms remaining < 1 000 ms poll).
	dl, watched := wiring_stall_next_deadline(&s, 60_600, 1_000)
	testing.expect(t, watched)
	testing.expect_value(t, dl, u64(1_000 + STALL_HANG_BOUND_MS))

	// At t = 61 000 ms (exact bound): ONLY slot_stalled is revoked!
	actions: [WIRINGS_OF_THE_MACHINE_MOST]Stop_Action
	revoked := wiring_stall_expire(&s, 1_000 + STALL_HANG_BOUND_MS, actions[:])
	testing.expect_value(t, revoked, 1)
	testing.expect_value(t, actions[0].kind, Stop_Action_Kind.End_Wiring)
	testing.expect_value(t, actions[0].wiring_slot, slot_stalled)
	testing.expect_value(t, actions[0].wiring_number, num_stalled)
	testing.expect_value(t, actions[0].end_word, output.End_Word.Revoked)
	testing.expect(t, !actions[0].asker_empty)

	// Counters updated cleanly; healthy, Never_Holds_Writer, and Writer_Chooses siblings intact.
	testing.expect_value(t, s.wirings_running, 3)
	testing.expect_value(t, s.processes[asker_idx].wirings_asked, 3)
	testing.expect_value(t, s.processes[src_idx].ends_given, 3)
	testing.expect(t, !s.wirings[slot_stalled].active)
	testing.expect(t, s.wirings[slot_healthy].active)
	testing.expect(t, s.wirings[slot_never].active)
	testing.expect(t, s.wirings[slot_choice].active)

	// Even 10x past the hang bound, Never_Holds_Writer and Writer_Chooses are NEVER revoked.
	wiring_stall_observe(&s, slot_never, true, 0, 10 * STALL_HANG_BOUND_MS)
	wiring_stall_observe(&s, slot_choice, true, 0, 10 * STALL_HANG_BOUND_MS)
	testing.expect_value(t, wiring_stall_expire(&s, 20 * STALL_HANG_BOUND_MS, actions[:]), 0)
	testing.expect(t, s.wirings[slot_never].active && s.wirings[slot_choice].active)
}
