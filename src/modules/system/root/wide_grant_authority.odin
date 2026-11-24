// The authority key of the wide grants, and the path of a grant through the
// root service (src/md/features/wide_grants.md, "The deliberate act: the
// proof of the principal"; src/md/features/wide_grants.md, "The path of a grant, end to end").
//
// At its start, right after it seeds its random generator, this service
// draws a fresh key of the run, and refuses a seed weaker than Processor.
// It makes from it the authority key of each principal, then erases it. It
// gives each collector that it starts the key of its principal only, in
// the values 5 to 8 of its context, with a ring and a region at the handles 10 and 11 for the
// grants. It then drives one grant at a time through the pure steps of
// wide_grant_flow: the ask of a console, the screen of the trusted display,
// the proof of `unlock`, Create_Grant in the collector, the wiring of the
// act records of `remote` and of the trusted display, the mark, and the end.
// It never waits: each answer comes in a later pass of its loop.
package root

import "base:intrinsics"
import "internal:root/wide_grant_flow"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
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

// The key of the run: it makes the key of each principal at the start,
// then this service erases it. It never leaves this service.
wide_grant_authority: wide_grants.Wide_Grant_Authority
// The key of each principal: this service signs the proofs of a principal
// with it, and gives it to the collector of that principal only, so a
// collector makes no proof that the collector of another principal
// accepts (src/md/features/wide_grants.md, "The deliberate act: the proof
// of the principal").
wide_grant_principal_authorities: [principals.PRINCIPAL_CAPACITY]wide_grants.Wide_Grant_Authority

// The ring of the collector of one principal, which this service made at
// its start.
Collector_Link :: struct {
	owner:         ^Started, // nil until the start ends, and after the stop.
	ring_memory:   system.Handle,
	ring:          ring.Ring,
	region_memory: system.Handle,
	region:        []u8,
	next_tag:      u32,
}
collector_links: [principals.PRINCIPAL_CAPACITY]Collector_Link

// The one flow of the machine.
wide_grant_flow_state: wide_grant_flow.Flow
#assert(wide_grant_flow.KEY_RECORDS_MOST >= remote.CLIENT_CAPACITY)
#assert(wide_grant_flow.PRINCIPALS_MOST >= principals.PRINCIPAL_CAPACITY)

// A writer of the act records of the grant: the trusted display, and
// `remote` when it runs, also when it starts after the grant.
Act_Writer :: struct {
	producer: wide_grants.Act_Producer,
	writer:   ^Started,
	wired:    bool,
}
WIDE_GRANT_WRITERS_MOST :: 2
wide_grant_writers: [WIDE_GRANT_WRITERS_MOST]Act_Writer
wide_grant_writer_count: u32
wide_grant_wiring_writer := -1 // The writer whose Wire the wiring service serves; -1: none.
wide_grant_mark_clear_due: bool // A clear of the mark that the control ring did not take yet.
// The collector of a principal whose session locked while its grant ends:
// it stops when the end settled, after its record of the end.
wide_grant_collector_stop_after_end: ^Started

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
	// Each slot gets its key now: a slot is never used again in a run, so
	// the key of the run is needed no more.
	for &authority, principal in wide_grant_principal_authorities {
		if !wide_grants.authority_init_for_principal(&authority, &wide_grant_authority, u64(principal)) {
			system.log_fact(.Warning, Wide_Grant_Authority_Key_Refused{status_code = u64(authority.status)})
		}
	}
	wide_grants.authority_erase(&wide_grant_authority)
	system.log_fact(.Info, Wide_Grant_Authority_Key_Ready{})
}

// wide_grant_collector_context writes the principal, the authority key and
// the ring of the grants into the context of a collector that starts. With
// no key, the four key values stay zero and the collector refuses each wide
// grant; with no ring, it serves its spaces only.
wide_grant_collector_context :: proc "contextless" (work: ^Start_Work) {
	system.value_put(&work.values, system.GRANT_VALUE_SERVICE_PRINCIPAL, work.principal)
	if work.principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	// The key of its principal only.
	key_words, ok := wide_grants.authority_context_words(&wide_grant_principal_authorities[work.principal])
	defer intrinsics.mem_zero_volatile(&key_words, size_of(key_words))
	if ok {
		system.values_put(&work.values, system.GRANT_VALUE_WIDE_GRANT_AUTHORITY_KEY, key_words[:])
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
	// The principal identifier of the collector, before its start: the name
	// of its principal in its store (wide_grants.COLLECTOR_REGION_IDENTIFIER_AT).
	identifier := principal_records[work.principal].identifier
	copy(link.region[wide_grants.COLLECTOR_REGION_IDENTIFIER_AT:][:wide_grants.COLLECTOR_IDENTIFIER_SIZE], identifier[:])
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
		if link.owner != item {
			continue
		}
		if u64(principal) == flow.principal {
			switch flow.stage {
			case .Creating, .Wiring, .Active:
				wide_grant_end(.Principal_Revoked, true)
			case .Idle, .Screen_Shown, .Proving, .Ending:
			}
			wide_grant_flow.flow_collector_gone(flow)
		}
		if wide_grant_collector_stop_after_end == item {
			wide_grant_collector_stop_after_end = nil
		}
		collector_link_close(&link)
	}
	switch flow.stage {
	case .Idle, .Ending:
	case .Proving:
		if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
			_ = wide_grant_flow.flow_proved(flow, flow.principal, false, system.time())
			system.log_fact(.Info, Wide_Grant_Proof_Not_Given{principal = flow.principal})
		}
	case .Screen_Shown, .Creating, .Wiring, .Active:
		if item.process != 0 && item.process == display_holder {
			wide_grant_end(.Principal_Revoked, false)
			return
		}
		for writer in wide_grant_writers[:wide_grant_writer_count] {
			if writer.writer == item {
				wide_grant_end(.Audit_Ring_Closed, false)
				return
			}
		}
	}
}

// wide_grant_process_started takes a process whose start ended: `remote`
// that starts while a grant holds is a writer of its acts, wired at the
// next pass. Until then its record of each call finds no reader, and it
// refuses the call (wide_grants.act_emit).
wide_grant_process_started :: proc "contextless" (item: ^Started) {
	flow := &wide_grant_flow_state
	if (flow.stage != .Wiring && flow.stage != .Active) || item == nil || item.is_terminal || system.name_of(item.name[:]) != "remote" {
		return
	}
	wide_grant_writer_add(.Remote_Service, item)
}

@(private = "file")
wide_grant_writer_add :: proc "contextless" (producer: wide_grants.Act_Producer, item: ^Started) {
	for writer in wide_grant_writers[:wide_grant_writer_count] {
		if writer.writer == item {
			return
		}
	}
	if wide_grant_writer_count >= WIDE_GRANT_WRITERS_MOST {
		return
	}
	wide_grant_writers[wide_grant_writer_count] = {producer = producer, writer = item}
	wide_grant_writer_count += 1
}

// wide_grant_principal_unlocked takes the unlock of a session: the proofs
// of the principal that were not given count from 0 again.
wide_grant_principal_unlocked :: proc "contextless" (principal: u64) {
	wide_grant_flow.flow_principal_unlocked(&wide_grant_flow_state, principal)
}

// wide_grant_principal_locked ends the grant of a principal whose session
// locks, with its reason, and keeps its collector until the end settled:
// the collector writes the record of the end before it stops. It says if
// item is that collector, which principal_lock must not stop now.
wide_grant_principal_locked :: proc "contextless" (principal: u64) {
	flow := &wide_grant_flow_state
	if flow.stage == .Idle || flow.principal != principal {
		return
	}
	wide_grant_end(.Session_Locked, false)
}

wide_grant_collector_held_at_lock :: proc "contextless" (item: ^Started) -> bool {
	flow := &wide_grant_flow_state
	if flow.stage != .Ending || flow.principal >= principals.PRINCIPAL_CAPACITY || collector_links[flow.principal].owner != item {
		return false
	}
	wide_grant_collector_stop_after_end = item
	return true
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

// wide_grant_row_set writes the grant serial in the row of the key: the one
// writer of the field. new_serial: the row held a grant that ends, and
// gets a new serial, so `remote` and `remote_display` end each connection
// of the key with Revoked (src/md/features/wide_grants.md, "What the agent
// sees").
@(private = "file")
wide_grant_row_set :: proc "contextless" (key: [32]u8, grant_serial: u64, new_serial: bool) {
	place := remote.client_find(&client_table.clients, key)
	if place < 0 {
		return
	}
	row := client_table.clients[place]
	row.wide_grant = grant_serial
	if new_serial {
		client_serial_last += 1
		row.serial = client_serial_last
	}
	remote.client_table_write(client_table, place, row)
	system.word_wake(&client_table.version, system.WAKE_ALL)
}

// wide_grant_mark_send gives the trusted display the mark of a grant, or
// its clear. false: the control ring did not take it. With no trusted
// display there is no mark to show or clear.
@(private = "file")
wide_grant_mark_send :: proc "contextless" (mark: wide_grants.Mark) -> bool {
	if display_holder == 0 {
		return mark.grant_serial == 0
	}
	if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Wide_Grant_Mark), values = wide_grants.mark_values(mark)}) {
		system.log_fact(.Warning, Wide_Grant_Control_Full{})
		return false
	}
	return true
}

// wide_grant_ask_open opens the flow of an ask, from a console or from an
// agent, for the key of a row of principal, and shows its screen.
@(private = "file")
wide_grant_ask_open :: proc "contextless" (command: root_ring.Root_Command, principal: u64, key: [32]u8, authorities_word: u64, duration_ms: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(command)
	if display_holder == 0 {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Services)
	}
	if principal >= principals.PRINCIPAL_CAPACITY || !wide_grants.authority_ready_for_principal(&wide_grant_principal_authorities[principal], principal) {
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .None)
	}
	serial, refusal := wide_grant_flow.flow_ask(&wide_grant_flow_state, principal, key, authorities_word, duration_ms, system.time())
	switch refusal {
	case .None:
	case .Busy:
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
	case .Bad_Scopes:
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2, i64(min(authorities_word, 1 << 62)), i64(wide_grants.wide_authorities_to_word(wide_grants.SCREEN_AUTHORITIES)))
	case .Bad_Duration:
		return root_ring.refuse(values, .Argument_Refused, kind, .Out_Of_Range, .Milliseconds, 3, i64(min(duration_ms, 1 << 62)), i64(wide_grants.MAX_WIDE_GRANT_DURATION_MS))
	case .Zero_Key:
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	case .Paused, .Refused_For_Run, .Proofs_Refused:
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
	case .Not_Awaited, .Other_Flow, .Scope_Not_Proposed, .Duration_Past_Ask, .Bad_Answer, .Other_Principal, .Terms_Refused, .No_Grant, .Other_Key, .Other_Tag:
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
	}
	show := wide_grant_flow.flow_screen(&wide_grant_flow_state)
	if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Wide_Grant_Screen_Show), values = wide_grants.screen_show_values(show)}) {
		wide_grant_flow.flow_to_idle(&wide_grant_flow_state)
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
	}
	system.log_fact(.Info, Wide_Grant_Screen_Asked{principal = principal, flow = serial})
	values^ = {0 = serial}
	return .Succeeded
}

// wide_grant_ask serves Wide_Grant_Ask: a console that acts for its
// principal asks a grant for a key of a row of that principal.
wide_grant_ask :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Wide_Grant_Ask)
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Wide_Grant_Ask, 7, record.values[6], 0)
		return .Argument_Refused
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	if wide_grant_row_of(caller.principal, key) < 0 {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	return wide_grant_ask_open(.Wide_Grant_Ask, caller.principal, key, record.values[4], record.values[5], values)
}

// wide_grant_agent_ask serves Wide_Grant_Agent_Ask: `remote` passes the
// ask of an agent for the key that its client proved. The principal is the
// one of the row of the key, whose grant to call still holds: the agent
// names no principal.
wide_grant_agent_ask :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Wide_Grant_Agent_Ask)
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Wide_Grant_Agent_Ask, 7, record.values[6], 0)
		return .Argument_Refused
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	place := remote.client_find(&client_table.clients, key)
	if place < 0 || !remote.client_grant_holds(&client_table.clients, place, client_table.clients[place].serial, .Calls) {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	return wide_grant_ask_open(.Wide_Grant_Agent_Ask, client_table.clients[place].principal, key, record.values[4], record.values[5], values)
}

// wide_grant_second_connection serves Wide_Grant_Second_Connection: a
// second connection of a key whose row holds a grant ends that grant.
wide_grant_second_connection :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Wide_Grant_Second_Connection)
	for index in 4 ..< len(record.values) {
		if record.values[index] != 0 {
			values^ = root_ring.word_refusal(.Wide_Grant_Second_Connection, i64(index) + 1, record.values[index], 0)
			return .Argument_Refused
		}
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	if wide_grant_flow.flow_end_key(&wide_grant_flow_state, key) != .None {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	wide_grant_end(.Duplicate_Connection, false)
	return .Succeeded
}

// wide_grant_end_command serves Wide_Grant_End: the principal of the grant
// ends it from a console.
wide_grant_end_command :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Wide_Grant_End)
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	for index in 4 ..< len(record.values) {
		if record.values[index] != 0 {
			values^ = root_ring.word_refusal(.Wide_Grant_End, i64(index) + 1, record.values[index], 0)
			return .Argument_Refused
		}
	}
	key := transmute([32]u8)([4]u64{record.values[0], record.values[1], record.values[2], record.values[3]})
	if wide_grant_flow.flow_end_key(&wide_grant_flow_state, key) != .None || wide_grant_flow_state.principal != caller.principal {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	wide_grant_end(.Principal_Revoked, false)
	return .Succeeded
}

// wide_grant_proof serves Wide_Grant_Proof, which only the holder of
// Principals sends: the run of `unlock` that this flow started says how its
// proof ended.
wide_grant_proof :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Wide_Grant_Proof)
	outcome, outcome_status, outcome_refusal := root_ring.member_of_word(root_ring.Wide_Grant_Proof_Outcome, record.values[5], .Wide_Grant_Proof, 3)
	if outcome_status != .Succeeded || outcome == .None {
		values^ = outcome_status != .Succeeded ? outcome_refusal : root_ring.word_refusal(.Wide_Grant_Proof, 3, record.values[5], u64(max(root_ring.Wide_Grant_Proof_Outcome)))
		return .Argument_Refused
	}
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Wide_Grant_Proof, 7, record.values[6], 0)
		return .Argument_Refused
	}
	// Only the run of unlock that this service started for the proof.
	if unlock_run.mode != .Prove_Wide_Grant || (unlock_run.stage != .Running && unlock_run.stage != .Stop_Asked) || system.name_of(caller.name[:]) != "unlock" {
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .Grants, 0, 0, 0, i64(wide_grant_flow.Flow_Refusal.Not_Awaited))
	}
	principal := record.values[4]
	now := system.time()
	refusal := wide_grant_flow.flow_proved(&wide_grant_flow_state, principal, outcome == .Proved, now)
	if refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Proof_Refused{principal = principal, refusal_code = u64(refusal)})
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .Grants, 0, 0, 0, i64(refusal))
	}
	if outcome != .Proved {
		system.log_fact(.Info, Wide_Grant_Proof_Not_Given{principal = principal})
		return .Succeeded
	}
	if !wide_grant_create_send(now) {
		wide_grant_flow.flow_to_idle(&wide_grant_flow_state)
		return root_ring.refuse(values, .Wrong_State, kind, .Refused, .Grants, 0, 0, 0, i64(wide_grant_flow.Flow_Refusal.No_Grant))
	}
	return .Succeeded
}

@(private = "file")
collector_tag_next :: proc "contextless" (link: ^Collector_Link) -> u32 {
	link.next_tag = link.next_tag == max(u32) ? 1 : link.next_tag + 1
	return link.next_tag
}

// wide_grant_create_send mints the proof of the terms that the screen
// fixed and sends Create_Grant to the collector of the principal, which it
// starts when none runs, with the one end time of the grant.
@(private = "file")
wide_grant_create_send :: proc "contextless" (now_ms: u64) -> bool {
	flow := &wide_grant_flow_state
	if flow.principal >= principals.PRINCIPAL_CAPACITY {
		return false
	}
	link := &collector_links[flow.principal]
	if link.owner == nil || link.owner.process == 0 {
		placed: ^Started
		if start("collector", flow.principal, place = &placed) != .Succeeded || link.owner == nil {
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
	proof, refusal := wide_grants.authority_mint_proof(&wide_grant_principal_authorities[flow.principal], &request.terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, now_ms)
	if refusal != .None {
		system.log_fact(.Warning, Wide_Grant_Proof_Refused{principal = flow.principal, refusal_code = u64(refusal)})
		return false
	}
	request.proof = proof
	intrinsics.mem_copy_non_overlapping(raw_data(link.region), &request, size_of(request))
	intrinsics.mem_zero_volatile(&request, size_of(request))
	tag := collector_tag_next(link)
	if !system.send(&link.ring.commands, ring.Record{kind = u32(wide_grants.Collector_Ring_Command.Create_Grant), tag = tag, values = {0 = 0, 1 = flow.ends_at_ms}}) {
		return false
	}
	return wide_grant_flow.flow_create_sent(flow, tag) == .None
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
	if outcome := unlock_start(.Prove_Wide_Grant, "", flow.principal); outcome != .Succeeded {
		wide_grant_flow.flow_to_idle(flow)
	}
}

// wide_grant_revoke_pressed takes a press on revoke of the mark.
wide_grant_revoke_pressed :: proc "contextless" (values: [7]u64) {
	flow := &wide_grant_flow_state
	if values[0] == 0 || values[0] != flow.grant_serial || flow.stage != .Active {
		return
	}
	wide_grant_end(.Principal_Revoked, false)
}

// wide_grant_wire_answered takes the answer of the wiring service to a
// request of the path: a Wire of one writer, or the end of the wirings of
// the collector. An answer of another flow counts for nothing.
wide_grant_wire_answered :: proc "contextless" (request: Audit_Request, flow_serial: u64, outcome: call_outcome.Call_Outcome) {
	flow := &wide_grant_flow_state
	if flow_serial != flow.serial {
		return
	}
	switch request {
	case .None:
		return
	case .Unwire:
		if outcome != .Succeeded {
			system.log_fact(.Warning, Wide_Grant_Wiring_Refused{outcome = outcome})
		}
		_ = wide_grant_flow.flow_unwired(flow, outcome == .Succeeded)
		return
	case .Wire:
	}
	index := wide_grant_wiring_writer
	wide_grant_wiring_writer = -1
	if flow.stage != .Wiring && flow.stage != .Active {
		return
	}
	if outcome != .Succeeded || index < 0 || index >= int(wide_grant_writer_count) {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{outcome = outcome})
		wide_grant_end(.Audit_Ring_Closed, false)
		return
	}
	wide_grant_writers[index].wired = true
	if flow.stage == .Active {
		return
	}
	active, _ := wide_grant_flow.flow_wired(flow, flow_serial, wide_grant_writer_count)
	if !active {
		return
	}
	wide_grant_row_set(flow.client_key, flow.grant_serial, false)
	if !wide_grant_mark_send({grant_serial = flow.grant_serial, principal_id = flow.principal, authorities = flow.answer.authorities, ends_at_ms = flow.ends_at_ms, flow_serial = flow.serial}) {
		// No grant holds without its mark.
		wide_grant_end(.Mark_Not_Shown, false)
		return
	}
	system.log_fact(.Info, Wide_Grant_Active{principal = flow.principal, grant_serial = flow.grant_serial, writers = u64(wide_grant_writer_count)})
}

// wide_grant_end ends the flow in any stage but Idle and Ending: the row,
// the mark, a proof that runs, then the work that waits in Ending (the
// revocation in the collector, the end of the wirings), which
// wide_grant_end_work drives at each pass. collector_ended: the collector
// ended the grant itself, or stopped.
wide_grant_end :: proc "contextless" (reason: wide_grants.Revocation_Reason, collector_ended: bool) {
	flow := &wide_grant_flow_state
	if flow.stage == .Idle || flow.stage == .Ending {
		return
	}
	if flow.stage == .Proving {
		if running := find("unlock"); running != nil {
			unlock_stop_ask()
			started_process_stop(running)
		}
	}
	key := flow.client_key
	held := flow.stage == .Active
	principal, grant := flow.principal, flow.grant_serial
	if wide_grant_flow.flow_end(flow, reason, collector_ended, system.time()) != .None {
		return
	}
	if held {
		wide_grant_row_set(key, 0, true)
	}
	wide_grant_mark_clear_due = true
	wide_grant_writer_count = 0
	wide_grant_wiring_writer = -1
	system.log_fact(.Info, Wide_Grant_Ended{principal = principal, grant_serial = grant, reason_code = u64(reason)})
	wide_grant_end_work()
}

// wide_grant_end_work sends what the end waits for: the Revoke_Grant (again
// after a full ring), the end of the wirings of the collector (again after
// a refusal), the clear of the mark; then settles the end, and stops the
// collector that a lock kept for the record of the end.
@(private = "file")
wide_grant_end_work :: proc "contextless" () {
	flow := &wide_grant_flow_state
	if wide_grant_mark_clear_due && wide_grant_mark_send({}) {
		wide_grant_mark_clear_due = false
	}
	if flow.stage != .Ending {
		return
	}
	link: ^Collector_Link
	if flow.principal < principals.PRINCIPAL_CAPACITY {
		link = &collector_links[flow.principal]
	}
	if link == nil || link.owner == nil || link.ring.head == nil {
		wide_grant_flow.flow_collector_gone(flow)
	}
	if grant_serial, reason, due := wide_grant_flow.flow_revoke_due(flow); due {
		tag := collector_tag_next(link)
		if system.send(&link.ring.commands, ring.Record{kind = u32(wide_grants.Collector_Ring_Command.Revoke_Grant), tag = tag, values = {0 = grant_serial, 1 = u64(reason)}}) {
			_ = wide_grant_flow.flow_revoke_sent(flow, tag)
		}
	}
	if wide_grant_flow.flow_unwire_due(flow) && wiring_request.stage == .Idle {
		if outcome, done := audit_unwire_begin(link != nil ? link.owner : nil, flow.serial); outcome == .Succeeded {
			wide_grant_flow.flow_unwire_sent(flow)
			if done {
				wide_grant_wire_answered(.Unwire, flow.serial, .Succeeded) // wirings.odin
			}
		}
	}
	if settled, late := wide_grant_flow.flow_end_settle(flow, system.time()); settled {
		if late {
			system.log_fact(.Warning, Wide_Grant_End_Late{})
		}
		if wide_grant_collector_stop_after_end != nil {
			started_process_stop(wide_grant_collector_stop_after_end)
			wide_grant_collector_stop_after_end = nil
		}
	}
}

// wide_grant_pass reads the answers of the collectors, wires the next ring
// of the audit, drives the end, checks the row of the key and the end time,
// and adds the rings to the wait. It gives the next time that it must run
// at, or WAIT_FOREVER.
wide_grant_pass :: proc "contextless" (wait: ^system.Wait) -> (deadline: u64) {
	flow := &wide_grant_flow_state
	now := system.time()
	for &link in collector_links {
		if link.ring.head == nil {
			continue
		}
		for record in root_receive(&link.ring.completions, "the collector") {
			wide_grant_collector_answer(record)
		}
		system.wait_records(wait, &link.ring.completions)
	}
	wide_grant_wire_pass()
	switch flow.stage {
	case .Creating, .Wiring, .Active:
		// A row that left, that a lock locked, or that two principals hold
		// ends the grant: the key no longer acts for its principal.
		if wide_grant_row_of(flow.principal, flow.client_key) < 0 {
			row_place := remote.client_find(&client_table.clients, flow.client_key)
			reason := wide_grants.Revocation_Reason.Principal_Revoked
			if row_place >= 0 && client_table.clients[row_place].session_locked != 0 {
				reason = .Session_Locked
			}
			wide_grant_end(reason, false)
		}
	case .Idle, .Screen_Shown, .Proving, .Ending:
	}
	if wide_grant_flow.flow_due(flow, now) {
		wide_grant_end(.Time_Bound, false)
	}
	wide_grant_end_work()
	switch flow.stage {
	case .Active, .Wiring:
		return flow.ends_at_ms
	case .Ending:
		return min(flow.end.deadline_ms, now + WIDE_GRANT_RETRY_MILLISECONDS)
	case .Idle, .Screen_Shown, .Proving, .Creating:
	}
	if wide_grant_mark_clear_due {
		return now + WIDE_GRANT_RETRY_MILLISECONDS
	}
	return system.WAIT_FOREVER
}

// The time between two tries of a send that a full ring refused.
WIDE_GRANT_RETRY_MILLISECONDS :: u64(50)

// wide_grant_collector_answer takes one record of the ring of a collector:
// a Grant_Ended that it sent itself, or the answer to a Create_Grant or a
// Revoke_Grant of the flow, matched by its tag.
@(private = "file")
wide_grant_collector_answer :: proc "contextless" (record: ring.Record) {
	flow := &wide_grant_flow_state
	status, known := enum_word.member_of_word(wide_grants.Collector_Ring_Status, u64(record.kind))
	if !known {
		system.log_fact(.Warning, Wide_Grant_Collector_Refused{status_word = u64(record.kind), refusal_code = record.values[0]})
		return
	}
	if record.tag == 0 {
		if status != .Grant_Ended || record.values[0] == 0 || record.values[0] != flow.grant_serial {
			return
		}
		reason, reason_ok := wide_grants.revocation_reason_from_word(record.values[1])
		if !reason_ok {
			reason = .Audit_Ring_Closed
		}
		wide_grant_end(reason, true)
		return
	}
	granted := status == .Ok ? record.values[1] : 0
	if refusal := wide_grant_flow.flow_created(flow, record.tag, granted); refusal == .None || refusal == .No_Grant {
		if granted == 0 {
			system.log_fact(.Warning, Wide_Grant_Collector_Refused{status_word = u64(record.kind), refusal_code = record.values[0]})
			return
		}
		if flow.stage == .Wiring {
			wide_grant_writers_find()
			if wide_grant_writer_count == 0 {
				wide_grant_end(.Audit_Ring_Closed, false)
			}
		}
		return
	}
	if wide_grant_flow.flow_revoke_answered(flow, record.tag) == .None && status != .Ok {
		system.log_fact(.Warning, Wide_Grant_Collector_Refused{status_word = u64(record.kind), refusal_code = record.values[0]})
	}
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
		switch {
		case item.process == display_holder || name == display_name:
			wide_grant_writer_add(.Trusted_Display, &item)
		case name == "remote":
			wide_grant_writer_add(.Remote_Service, &item)
		}
	}
}

// wide_grant_wire_pass asks the Wire of the next writer that is not wired,
// while the grant is wired or holds: a writer that started late is wired
// too. One request at a time.
@(private = "file")
wide_grant_wire_pass :: proc "contextless" () {
	flow := &wide_grant_flow_state
	if (flow.stage != .Wiring && flow.stage != .Active) || wiring_request.stage != .Idle || wide_grant_wiring_writer >= 0 {
		return
	}
	index := -1
	for writer, place in wide_grant_writers[:wide_grant_writer_count] {
		if !writer.wired {
			index = place
			break
		}
	}
	if index < 0 {
		return
	}
	link := &collector_links[flow.principal]
	if link.owner == nil {
		wide_grant_end(.Principal_Revoked, true)
		return
	}
	writer := wide_grant_writers[index]
	collector_file := image_file_checked("collector")
	writer_file := image_file_checked(system.name_of(writer.writer.name[:]))
	input_index := module_record_input_index(collector_file, "sources")
	output_index := module_record_output_index(writer_file, wide_grants.ACT_OUTPUT_NAME)
	if input_index == 0 || output_index == 0 {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{outcome = .Argument_Refused})
		wide_grant_end(.Audit_Ring_Closed, false)
		return
	}
	// Callee_Busy: the wiring service serves another request; the next
	// pass asks again.
	if outcome := audit_wire_begin(link.owner, writer.writer, writer.producer, output_index, input_index, flow.serial); outcome == .Succeeded {
		wide_grant_wiring_writer = index
	} else if outcome != .Callee_Busy {
		system.log_fact(.Warning, Wide_Grant_Wiring_Refused{outcome = outcome})
		wide_grant_end(.Audit_Ring_Closed, false)
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
