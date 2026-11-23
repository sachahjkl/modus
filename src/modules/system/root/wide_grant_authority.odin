// The authority key of the wide grants, and the path of a grant through the
// root service (src/md/features/wide_grants.md, "The deliberate act: the
// proof of the principal" and "The path of a grant, end to end").
//
// At its start, right after it seeds its random generator, this service
// draws a fresh authority key, and refuses a seed weaker than Processor. It
// gives the key to each collector that it starts, in the values 5 to 8 of
// its context, with a ring and a region at the handles 10 and 11 for the
// grants. It then drives one grant at a time through the pure steps of
// wide_grant_flow: the ask of a console, the screen of the trusted display,
// the proof of `unlock`, Create_Grant in the collector, the wiring of the
// act records of `remote` and of the trusted display, the mark, and the end.
// It never waits: each answer comes in a later pass of its loop.
package root

import "base:intrinsics"
import "internal:root/wide_grant_flow"
import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/wide_grants"
import "modus:display"
import "modus:principals"
import "modus:random"
import "modus:system"

// The pages of the region of the ring of a collector: one grant request.
COLLECTOR_REGION_PAGES :: 1
#assert(size_of(wide_grants.Create_Grant_Request) <= COLLECTOR_REGION_PAGES * system.PAGE_SIZE)

// Authority key held exclusively by the unlock authority (this service) and
// delivered to the collector in its context at start.
wide_grant_authority: wide_grants.Wide_Grant_Authority

// The ring of the collector of one principal, which this service made at
// its start.
Collector_Link :: struct {
	owner:         ^Started, // nil until the start ends, and after the stop.
	ring_memory:   system.Handle,
	ring:          ring.Ring,
	region_memory: system.Handle,
	region:        []u8,
	next_tag:      u32,
	create_tag:    u32, // The tag of the Create_Grant in flight; 0: none.
}
collector_links: [principals.PRINCIPAL_CAPACITY]Collector_Link

// The one flow of the machine, and the writers whose acts it wires.
wide_grant_flow_state: wide_grant_flow.Flow
Act_Writer :: struct {
	producer: wide_grants.Act_Producer,
	writer:   ^Started,
}
wide_grant_writers: [2]Act_Writer
wide_grant_writer_count: u32
wide_grant_unwire_pending: ^Started // The collector whose audit wirings still end.

// wide_grant_authority_start generates a fresh authority key from
// process_generator, refusing weak entropy (below Processor) and refusing an
// all-zero key. Never logs key material.
wide_grant_authority_start :: proc "contextless" () {
	raw_key: wide_grants.Authority_Key
	defer intrinsics.mem_zero_volatile(&raw_key, size_of(raw_key))
	key_error: errors.Error_Record
	strength := random.seed_strength(&process_generator)
	if !random.fill_for_a_key(&process_generator, raw_key[:], wide_grants.AUTHORITY_KEY_LEAST_ENTROPY, &key_error) {
		_ = wide_grants.authority_init_from_bytes(&wide_grant_authority, {}, strength)
		system.log_fact(.Warning, Wide_Grant_Authority_Key_Refused{status_code = u64(wide_grant_authority.status)})
		return
	}
	if !wide_grants.authority_init_from_bytes(&wide_grant_authority, raw_key, strength) {
		system.log_fact(.Warning, Wide_Grant_Authority_Key_Refused{status_code = u64(wide_grant_authority.status)})
		return
	}
	system.log_fact(.Info, Wide_Grant_Authority_Key_Ready{})
}

// wide_grant_collector_context writes the principal, the authority key and
// the ring of the grants into the context of a collector that starts. With
// no key, the four key values stay zero and the collector refuses each wide
// grant; with no ring, it serves its spaces only.
wide_grant_collector_context :: proc "contextless" (work: ^Start_Work) {
	system.value_put(&work.values, system.GRANT_VALUE_SERVICE_PRINCIPAL, work.principal)
	key_words, ok := wide_grants.authority_context_words(&wide_grant_authority)
	defer intrinsics.mem_zero_volatile(&key_words, size_of(key_words))
	if ok {
		system.values_put(&work.values, system.GRANT_VALUE_WIDE_GRANT_AUTHORITY_KEY, key_words[:])
	}
	if work.principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	link := &collector_links[work.principal]
	collector_link_close(link)
	status: system.Status
	link.ring_memory, link.ring, status = system.ring_create()
	region_address: rawptr
	if status == .Ok {
		link.region_memory, status = system.memory_create(COLLECTOR_REGION_PAGES)
	}
	if status == .Ok {
		region_address, status = system.memory_map(link.region_memory, {.Write})
	}
	if status != .Ok {
		collector_link_close(link)
		system.log_fact(.Warning, Wide_Grant_Collector_Ring_Failed{status = status})
		return
	}
	link.region = ([^]u8)(region_address)[:COLLECTOR_REGION_PAGES * system.PAGE_SIZE]
	system.grant_put(&work.grants, wide_grants.SERVICE_RING_SLOT, {link.ring_memory, {.Read, .Write}})
	system.grant_put(&work.grants, wide_grants.SERVICE_REGION_SLOT, {link.region_memory, {.Read, .Write}})
}

// wide_grant_collector_started keeps the place of a collector that started
// with its ring.
wide_grant_collector_started :: proc "contextless" (work: ^Start_Work) {
	if work.principal < principals.PRINCIPAL_CAPACITY && collector_links[work.principal].ring_memory != 0 {
		collector_links[work.principal].owner = work.slot
	}
}

// wide_grant_collector_abandon ends the ring of a collector whose start
// failed.
wide_grant_collector_abandon :: proc "contextless" (work: ^Start_Work) {
	if work.principal < principals.PRINCIPAL_CAPACITY && collector_links[work.principal].owner == nil {
		collector_link_close(&collector_links[work.principal])
	}
}

@(private = "file")
collector_link_close :: proc "contextless" (link: ^Collector_Link) {
	if raw_data(link.region) != nil {
		system.memory_unmap(raw_data(link.region))
	}
	if link.ring.head != nil {
		system.ring_close(&link.ring)
	}
	for handle in ([2]system.Handle{link.ring_memory, link.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	link^ = {}
}

// wide_grant_process_released takes a process that stops out of the path:
// the collector of the grant, the trusted display and a writer end the grant
// (no grant holds without its reader, its mark or a writer of its acts); a
// run of `unlock` that proves ends the proof with no grant.
wide_grant_process_released :: proc "contextless" (item: ^Started) {
	flow := &wide_grant_flow_state
	for &link, principal in collector_links {
		if link.owner == item {
			// The grant lived in this collector: no Revoke_Grant reaches it.
			if flow.stage != .Idle && u64(principal) == flow.principal {
				wide_grant_end(.Principal_Revoked, false)
			}
			if wide_grant_unwire_pending == item {
				wide_grant_unwire_pending = nil
			}
			collector_link_close(&link)
		}
	}
	switch flow.stage {
	case .Idle:
	case .Proving:
		if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
			_ = wide_grant_flow.flow_proved(flow, flow.principal, false, system.time())
			system.log_fact(.Info, Wide_Grant_Proof_Not_Given{principal = flow.principal})
			wide_grant_mark_send({})
		}
	case .Screen_Shown, .Creating, .Wiring, .Active:
		if item.process != 0 && item.process == display_holder {
			wide_grant_end(.Principal_Revoked, true)
			return
		}
		for writer in wide_grant_writers[:wide_grant_writer_count] {
			if writer.writer == item {
				wide_grant_end(.Principal_Revoked, true)
				return
			}
		}
	}
}

// wide_grant_row_of gives the place of the row of a key of a principal in
// the client table, or -1. A row that is locked or contested holds no
// grant.
@(private = "file")
wide_grant_row_of :: proc "contextless" (principal: u64, key: [32]u8) -> int {
	place := remote.client_find(&client_table.clients, key)
	if place < 0 {
		return -1
	}
	row := client_table.clients[place]
	if row.principal != principal || row.session_locked != 0 || row.contested != 0 {
		return -1
	}
	return place
}

// wide_grant_row_set writes the grant serial in the row of the key of the
// flow: the one writer of the field.
@(private = "file")
wide_grant_row_set :: proc "contextless" (key: [32]u8, grant_serial: u64) {
	place := remote.client_find(&client_table.clients, key)
	if place < 0 {
		return
	}
	row := client_table.clients[place]
	row.wide_grant = grant_serial
	remote.client_table_write(client_table, place, row)
	system.word_wake(&client_table.version, system.WAKE_ALL)
}

@(private = "file")
wide_grant_mark_send :: proc "contextless" (mark: wide_grants.Mark) {
	if display_holder == 0 {
		return
	}
	if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Wide_Grant_Mark), values = wide_grants.mark_values(mark)}) {
		system.log_fact(.Warning, Wide_Grant_Control_Full{})
	}
}

// wide_grant_ask serves Wide_Grant_Ask: a console that acts for its
// principal asks a grant for a key of a row of that principal.
wide_grant_ask :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Wide_Grant_Ask)
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Wide_Grant_Ask, 7, record.values[6], 0)
		return .Bad_Operation
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	if wide_grant_row_of(caller.principal, key) < 0 {
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		return .Bad_Handle
	}
	if display_holder == 0 {
		values^ = errors.ring_fail(kind, .Absent, .Services)
		return .Bad_State
	}
	if wide_grant_authority.status != .Ready {
		values^ = errors.ring_fail(kind, .Refused, .None)
		return .Bad_State
	}
	now := system.time()
	serial, refusal := wide_grant_flow.flow_ask(&wide_grant_flow_state, caller.principal, key, record.values[4], record.values[5], now)
	switch refusal {
	case .None:
	case .Busy:
		values^ = errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1)
		return .No_Slot
	case .Bad_Scopes:
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(record.values[4], 1 << 62)), i64(wide_grants.WIDE_AUTHORITY_KNOWN_MASK))
		return .Bad_Operation
	case .Bad_Duration:
		values^ = errors.ring_fail(kind, .Out_Of_Range, .Milliseconds, 3, i64(min(record.values[5], 1 << 62)), i64(wide_grants.MAX_WIDE_GRANT_DURATION_MS))
		return .Bad_Operation
	case .Zero_Key:
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		return .Bad_Handle
	case .Paused, .Refused_For_Run:
		values^ = errors.ring_fail(kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
		return .Bad_State
	case .Not_Awaited, .Other_Flow, .Scope_Not_Proposed, .Duration_Past_Ask, .Bad_Answer, .Other_Principal, .Terms_Refused, .No_Grant, .Other_Key:
		values^ = errors.ring_fail(kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
		return .Bad_State
	}
	show := wide_grant_flow.flow_screen(&wide_grant_flow_state)
	if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Wide_Grant_Screen_Show), values = wide_grants.screen_show_values(show)}) {
		wide_grant_flow.flow_to_idle(&wide_grant_flow_state)
		values^ = errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1)
		return .No_Slot
	}
	system.log_fact(.Info, Wide_Grant_Screen_Asked{principal = caller.principal, flow = serial})
	values^ = {0 = serial}
	return .Ok
}

// wide_grant_end_command serves Wide_Grant_End: the principal of the grant
// ends it from a console.
wide_grant_end_command :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Wide_Grant_End)
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	for index in 4 ..< len(record.values) {
		if record.values[index] != 0 {
			values^ = root_ring.word_refusal(.Wide_Grant_End, i64(index) + 1, record.values[index], 0)
			return .Bad_Operation
		}
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	if wide_grant_flow.flow_end_key(&wide_grant_flow_state, key) != .None || wide_grant_flow_state.principal != caller.principal {
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		return .Bad_Handle
	}
	wide_grant_end(.Principal_Revoked, true)
	return .Ok
}

// wide_grant_proof serves Wide_Grant_Proof, which only the holder of
// Principals sends: the run of `unlock` that this flow started says how its
// proof ended.
wide_grant_proof :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Wide_Grant_Proof)
	outcome, outcome_status, outcome_refusal := root_ring.member_of_word(root_ring.Wide_Grant_Proof_Outcome, record.values[5], .Wide_Grant_Proof, 3)
	if outcome_status != .Ok || outcome == .None {
		values^ = outcome_status != .Ok ? outcome_refusal : root_ring.word_refusal(.Wide_Grant_Proof, 3, record.values[5], u64(max(root_ring.Wide_Grant_Proof_Outcome)))
		return .Bad_Operation
	}
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Wide_Grant_Proof, 7, record.values[6], 0)
		return .Bad_Operation
	}
	// Only the run of unlock that this service started for the proof.
	if unlock_run.mode != .Prove_Wide_Grant || (unlock_run.stage != .Running && unlock_run.stage != .Stop_Asked) || system.name_of(caller.name[:]) != "unlock" {
		values^ = errors.ring_fail(kind, .Refused, .Grants, 0, 0, 0, i64(wide_grant_flow.Flow_Refusal.Not_Awaited))
		return .Bad_State
	}
	principal := record.values[4]
	now := system.time()
	refusal := wide_grant_flow.flow_proved(&wide_grant_flow_state, principal, outcome == .Proved, now)
	if refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Proof_Refused{principal = principal, refusal_code = u64(refusal)})
		wide_grant_mark_send({})
		values^ = errors.ring_fail(kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
		return .Bad_State
	}
	if outcome != .Proved {
		system.log_fact(.Info, Wide_Grant_Proof_Not_Given{principal = principal})
		return .Ok
	}
	if !wide_grant_create_send(now) {
		wide_grant_flow.flow_to_idle(&wide_grant_flow_state)
		values^ = errors.ring_fail(kind, .Refused, .Grants, 0, 0, 0, i64(wide_grant_flow.Flow_Refusal.No_Grant))
		return .Bad_State
	}
	return .Ok
}

// wide_grant_create_send mints the proof of the terms that the screen
// fixed and sends Create_Grant to the collector of the principal, which it
// starts when none runs.
@(private = "file")
wide_grant_create_send :: proc "contextless" (now_ms: u64) -> bool {
	flow := &wide_grant_flow_state
	if flow.principal >= principals.PRINCIPAL_CAPACITY {
		return false
	}
	link := &collector_links[flow.principal]
	if link.owner == nil || link.owner.process == 0 {
		placed: ^Started
		if start("collector", flow.principal, place = &placed) != .Ok || link.owner == nil {
			system.log_fact(.Warning, Wide_Grant_Collector_Absent{principal = flow.principal})
			return false
		}
	}
	record := &principal_records[flow.principal]
	verifier := blake3.hash(record.public_key[:])
	if flow.principal == principals.MACHINE {
		verifier = blake3.hash(record.measure[:])
	}
	request: wide_grants.Create_Grant_Request
	request.terms = flow.terms
	proof, refusal := wide_grants.authority_mint_proof(&wide_grant_authority, &request.terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, now_ms)
	if refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Proof_Refused{principal = flow.principal, refusal_code = u64(refusal)})
		return false
	}
	request.proof = proof
	intrinsics.mem_copy_non_overlapping(raw_data(link.region), &request, size_of(request))
	intrinsics.mem_zero_volatile(&request, size_of(request))
	link.next_tag = link.next_tag == max(u32) ? 1 : link.next_tag + 1
	if !system.send(&link.ring.commands, ring.Record{kind = u32(wide_grants.Collector_Ring_Command.Create_Grant), tag = link.next_tag, values = {0 = 0}}) {
		return false
	}
	link.create_tag = link.next_tag
	return true
}

// wide_grant_screen_answered takes the answer of the trusted display: a
// grant to prove starts `unlock` for the principal.
wide_grant_screen_answered :: proc "contextless" (values: [7]u64) {
	flow := &wide_grant_flow_state
	decision, refusal := wide_grant_flow.flow_screen_answer(flow, values, system.time())
	if refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Screen_Refused{refusal_code = u64(refusal)})
		return
	}
	if decision != .Give {
		system.log_fact(.Info, Wide_Grant_Screen_Declined{principal = flow.principal})
		return
	}
	if status := unlock_start(.Prove_Wide_Grant, "", flow.principal); status != .Ok {
		wide_grant_flow.flow_to_idle(flow)
		wide_grant_mark_send({})
	}
}

// wide_grant_revoke_pressed takes a press on revoke of the mark.
wide_grant_revoke_pressed :: proc "contextless" (values: [7]u64) {
	flow := &wide_grant_flow_state
	if values[0] == 0 || values[0] != flow.grant_serial || flow.stage != .Active {
		return
	}
	wide_grant_end(.Principal_Revoked, true)
}

// wide_grant_wire_answered takes the answer of one Wire of the audit.
wide_grant_wire_answered :: proc "contextless" (status: system.Status) {
	flow := &wide_grant_flow_state
	if flow.stage != .Wiring {
		return
	}
	if status != .Ok {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{status = status})
		wide_grant_end(.Principal_Revoked, true)
		return
	}
	active, _ := wide_grant_flow.flow_wired(flow, wide_grant_writer_count, system.time())
	if !active {
		return
	}
	wide_grant_row_set(flow.client_key, flow.grant_serial)
	wide_grant_mark_send({grant_serial = flow.grant_serial, principal_id = flow.principal, authorities = flow.answer.authorities, ends_at_ms = flow.ends_at_ms, flow_serial = flow.serial})
	system.log_fact(.Info, Wide_Grant_Active{principal = flow.principal, grant_serial = flow.grant_serial, writers = u64(wide_grant_writer_count)})
}

// wide_grant_end ends the flow in any stage: the grant in the collector,
// the audit wirings, the row, the mark, a proof that runs. revoke: the
// collector still runs and takes Revoke_Grant.
wide_grant_end :: proc "contextless" (reason: wide_grants.Revocation_Reason, revoke: bool) {
	flow := &wide_grant_flow_state
	if flow.stage == .Idle {
		return
	}
	link: ^Collector_Link
	if flow.principal < principals.PRINCIPAL_CAPACITY {
		link = &collector_links[flow.principal]
	}
	if revoke && flow.grant_serial != 0 && link != nil && link.ring.head != nil {
		link.next_tag = link.next_tag == max(u32) ? 1 : link.next_tag + 1
		_ = system.send(&link.ring.commands, ring.Record{kind = u32(wide_grants.Collector_Ring_Command.Revoke_Grant), tag = link.next_tag, values = {0 = flow.grant_serial, 1 = u64(reason)}})
	}
	if link != nil && link.owner != nil && (flow.stage == .Wiring || flow.stage == .Active) {
		wide_grant_unwire_pending = link.owner
	}
	if flow.stage == .Proving {
		if running := find("unlock"); running != nil {
			unlock_stop_ask()
			started_process_stop(running)
		}
	}
	wide_grant_row_set(flow.client_key, 0)
	wide_grant_mark_send({})
	system.log_fact(.Info, Wide_Grant_Ended{principal = flow.principal, grant_serial = flow.grant_serial, reason_code = u64(reason)})
	wide_grant_flow.flow_to_idle(flow)
	wide_grant_writer_count = 0
	if link != nil {
		link.create_tag = 0
	}
}

// wide_grant_pass reads the answers of the collectors, wires the next ring
// of the audit, ends the wirings of an ended grant, checks the row of the
// key and the end time, and adds the rings to the wait. It gives the time of
// the end of the grant that holds, or WAIT_FOREVER.
wide_grant_pass :: proc "contextless" (wait: ^system.Wait) -> (deadline: u64) {
	flow := &wide_grant_flow_state
	now := system.time()
	for &link in collector_links {
		if link.ring.head == nil {
			continue
		}
		for record in system.receive(&link.ring.completions) {
			if record.tag == 0 || record.tag != link.create_tag {
				continue
			}
			link.create_tag = 0
			status, known := wide_grants_collector_status_of_word(record.kind)
			if !known || status != .Ok {
				system.log_fact(.Warning, Wide_Grant_Collector_Refused{status_word = u64(record.kind), refusal_code = record.values[0]})
				wide_grant_end(.Principal_Revoked, false)
				continue
			}
			if wide_grant_flow.flow_created(flow, record.values[1]) != .None {
				wide_grant_end(.Principal_Revoked, true)
				continue
			}
			wide_grant_writers_find()
			if wide_grant_writer_count == 0 {
				wide_grant_end(.Principal_Revoked, true)
			}
		}
		system.wait_records(wait, &link.ring.completions)
	}
	if wide_grant_unwire_pending != nil && audit_unwire_begin(wide_grant_unwire_pending) != .No_Slot {
		wide_grant_unwire_pending = nil
	}
	if flow.stage == .Wiring && flow.wired < wide_grant_writer_count && wiring_request.stage == .Idle {
		wide_grant_wire_next()
	}
	if flow.stage == .Active || flow.stage == .Wiring || flow.stage == .Creating {
		// A row that left, that a lock locked, or that two principals hold
		// ends the grant: the key no longer acts for its principal.
		if place := wide_grant_row_of(flow.principal, flow.client_key); place < 0 {
			row_place := remote.client_find(&client_table.clients, flow.client_key)
			reason := wide_grants.Revocation_Reason.Principal_Revoked
			if row_place >= 0 && client_table.clients[row_place].session_locked != 0 {
				reason = .Session_Locked
			}
			wide_grant_end(reason, true)
		}
	}
	if wide_grant_flow.flow_due(flow, now) {
		wide_grant_end(.Time_Bound, true)
	}
	if flow.stage == .Active {
		return flow.ends_at_ms
	}
	return system.WAIT_FOREVER
}

@(private = "file")
wide_grants_collector_status_of_word :: proc "contextless" (word: u32) -> (status: wide_grants.Collector_Ring_Status, ok: bool) {
	for member in wide_grants.Collector_Ring_Status {
		if u32(member) == word {
			return member, true
		}
	}
	return .Ok, false
}

// wide_grant_writers_find names the writers of the acts of the grant: the
// trusted display always, and `remote` when it runs.
@(private = "file")
wide_grant_writers_find :: proc "contextless" () {
	wide_grant_writer_count = 0
	display_name := role_holder_name(.Display)
	for &item in started {
		if item.process == 0 || item.is_terminal {
			continue
		}
		name := system.name_of(item.name[:])
		producer := wide_grants.Act_Producer.None
		switch {
		case item.process == display_holder || name == display_name:
			producer = .Trusted_Display
		case name == "remote":
			producer = .Remote_Service
		}
		if producer == .None || wide_grant_writer_count >= len(wide_grant_writers) {
			continue
		}
		wide_grant_writers[wide_grant_writer_count] = {producer = producer, writer = &item}
		wide_grant_writer_count += 1
	}
}

// wide_grant_wire_next asks the Wire of the next writer of the audit.
@(private = "file")
wide_grant_wire_next :: proc "contextless" () {
	flow := &wide_grant_flow_state
	link := &collector_links[flow.principal]
	if link.owner == nil {
		wide_grant_end(.Principal_Revoked, false)
		return
	}
	writer := wide_grant_writers[flow.wired]
	collector_file := image_file_checked("collector")
	writer_file := image_file_checked(system.name_of(writer.writer.name[:]))
	input_index := module_record_input_index(collector_file, "sources")
	output_index := module_record_output_index(writer_file, wide_grants.ACT_OUTPUT_NAME)
	if input_index == 0 || output_index == 0 {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{status = .Bad_Operation})
		wide_grant_end(.Principal_Revoked, true)
		return
	}
	// No_Slot: the wiring service serves another request; the next pass
	// asks again.
	if status := audit_wire_begin(link.owner, writer.writer, writer.producer, output_index, input_index); status != .Ok && status != .No_Slot {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{status = status})
		wide_grant_end(.Principal_Revoked, true)
	}
}

// module_record_output_index looks up the 1-based Record_Outputs index of
// stream_name in a verified module file, or 0 if absent.
@(private = "file")
module_record_output_index :: proc "contextless" (file: []u8, stream_name: string) -> u32 {
	total := module.count(file, .Record_Outputs)
	for index in u32(1) ..< total {
		row, _, _, ok := module.record_output(file, index)
		if ok && module.string_at(file, row.name_offset, row.name_count) == stream_name {
			return index
		}
	}
	return 0
}

// module_record_input_index looks up the 1-based Record_Inputs index of
// stream_name in a verified module file, or 0 if absent.
@(private = "file")
module_record_input_index :: proc "contextless" (file: []u8, stream_name: string) -> u32 {
	total := module.count(file, .Record_Inputs)
	for index in u32(1) ..< total {
		row, _, _, _, ok := module.record_input(file, index)
		if ok && module.string_at(file, row.name_offset, row.name_count) == stream_name {
			return index
		}
	}
	return 0
}
