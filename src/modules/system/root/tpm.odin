package root

import info "modus:contract/boot_info"
import op "modus:contract/operation"
import "modus:contract/call_outcome"
import "modus:contract/ring"
import "modus:contract/tpm_service"
import "modus:contract/value_kinds"
import "modus:random"
import "modus:system"
import "modus:tpm2"

// The TPM service (src/md/features/tpm_sealed_machine_key.md): the device
// service of the TPM. This service starts it at boot when the boot program
// measured the system into the TPM, and keeps its ring and its region to
// give them to each run of `unlock`, the one process with the start grant
// Tpm. With no measure, no key can be sealed to it: no TPM service runs,
// and `unlock` works as on a machine with no TPM.
tpm_ring: system.Handle
tpm_region: system.Handle
tpm_process: ^Started
// The measure ring: this service writes it, and no other process holds it
// (src/md/features/start_policy.md, "The measure of the start policy").
tpm_measure_memory: system.Handle
tpm_measure_ring: ring.Ring
tpm_measure_tag: u32
// The TPM service ran in this run and stopped: the line of a start policy
// that is not measured names that cause, and not an absent TPM.
tpm_service_stopped: bool

// The bound of the wait for the answer of one measure. It only ends a wait
// for a TPM service that does not answer: an extend and a read take
// milliseconds, after a request of unlock that the service may run first.
// The start policy then starts unmeasured, with its line.
TPM_MEASURE_BOUND_MILLISECONDS :: 30_000

// tpm_service_start starts the TPM service, once, before `unlock`.
tpm_service_start :: proc "contextless" () {
	if measure, ok := info.measure_state_of_word(trust_boot_report.trust.measure); !ok || measure != .Measured {
		system.log_fact(.Info, Tpm_Service_Absent_Unmeasured{})
		return
	}
	slot: ^Started
	for &item in started {
		if place_is_free(&item) {
			slot = &item
			break
		}
	}
	if slot == nil {
		system.log_fact(.Warning, Tpm_Service_Absent_Table_Full{})
		return
	}
	// What this service creates here and does not keep: the process holds
	// its copy of the registers.
	registers, _, status := device_handle(.Memory, tpm_service.REGISTERS_ADDRESS, 1)
	if status != .Ok {
		system.log_fact(.Warning, Tpm_Registers_Refused{registers = value_kinds.Hexadecimal_Sixteen_Digits(tpm_service.REGISTERS_ADDRESS), status = op.Status_Word(status)})
		return
	}
	defer system.close(registers)
	ring_memory, region_memory, measure_memory: system.Handle
	measure_ring: ring.Ring
	ring_memory, status = system.memory_create(ring.pages(ring.CAPACITY))
	if status == .Ok {
		region_memory, status = system.memory_create(1)
	}
	if status == .Ok {
		measure_memory, measure_ring, status = system.ring_create()
	}
	process: system.Handle
	tpm_budget: Start_Budget
	// The place is cleared after the start: the ready ring waits here.
	tpm_ready: system.Ready_Ring
	start_grant_set := start_grant_set_of("tpm")
	if status == .Ok {
		context_grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set))
		system.grant_put(&context_grants, tpm_service.SERVICE_RING, {ring_memory, {.Read, .Write}})
		system.grant_put(&context_grants, tpm_service.SERVICE_REGION, {region_memory, {.Read, .Write}})
		system.grant_put(&context_grants, tpm_service.SERVICE_REGISTERS, {registers, {.Read, .Write}})
		system.grant_put(&context_grants, tpm_service.SERVICE_MEASURE_RING, {measure_memory, {.Read, .Write}})
		tpm_name := role_holder_name(.Tpm)
		tpm_mappings: [1]system.Mapping
		tpm_mapping_count := 0
		fresh_bytes_page_give(slot, tpm_mappings[:], &tpm_mapping_count, &values)
		budget_ok: bool
		if context_refused(tpm_name, &context_grants, &values) {
			status = .Bad_State
		} else if tpm_budget, budget_ok = budget_of(image_file_checked(tpm_name), tpm_name); !budget_ok {
			status = .No_Budget
		} else {
			process, status = system.process_start(image_file_checked(tpm_name), tpm_name, context_grants.grants, random.values_with_seed(&process_generator, values.values), tpm_budget.amounts, tpm_mappings[:tpm_mapping_count], nil, load_source(), ready = &tpm_ready)
		}
	}
	if status != .Ok {
		fresh_bytes_forget(slot)
		if measure_ring.head != nil {
			system.ring_close(&measure_ring)
		}
		for handle in ([3]system.Handle{ring_memory, region_memory, measure_memory}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_fact(.Warning, Tpm_Service_Start_Failed{status = status})
		return
	}
	slot^ = {}
	slot.process = process
	slot.process_slot, slot.process_serial, _ = system.process_place(process)
	start_budget_note(slot, tpm_budget)
	slot.ready = tpm_ready
	slot.start_grant_set = start_grant_set
	slot.granted = {.Log}
	copy(slot.name[:len(slot.name) - 1], "tpm")
	tpm_ring, tpm_region, tpm_process = ring_memory, region_memory, slot
	tpm_measure_memory, tpm_measure_ring = measure_memory, measure_ring
	system.log_fact(.Info, Tpm_Service_Started{registers = value_kinds.Hexadecimal_Sixteen_Digits(tpm_service.REGISTERS_ADDRESS)})
}

// tpm_service_end forgets the ring and the region of a TPM service that
// stopped: a later `unlock` gets none, and runs as on a machine with no TPM.
tpm_service_end :: proc "contextless" (item: ^Started) {
	if item != tpm_process {
		return
	}
	if tpm_measure_ring.head != nil {
		system.ring_close(&tpm_measure_ring)
	}
	for handle in ([3]system.Handle{tpm_ring, tpm_region, tpm_measure_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	tpm_ring, tpm_region, tpm_process = 0, 0, nil
	tpm_measure_memory, tpm_measure_ring = 0, {}
	tpm_service_stopped = true
	system.log_fact(.Warning, Tpm_Service_Stopped{})
}

// tpm_grants_give gives a process with the start grant Tpm the ring and the
// region of the TPM service, when it runs, and the service with the right
// Read: its stop is then an event of the process, which ends a wait for an
// answer at once.
tpm_grants_give :: proc "contextless" (work: ^Start_Work) {
	if tpm_ring == 0 || tpm_process == nil {
		return
	}
	start_grant_put(work, .Tpm_Ring, {tpm_ring, {.Read, .Write}})
	start_grant_put(work, .Tpm_Region, {tpm_region, {.Read, .Write}})
	start_grant_put(work, .Tpm_Service, {tpm_process.process, {.Read}})
}

// start_policy_measure has the TPM service extend PCR 12 with the event
// digest of a start policy, before its Process_Start, and writes the line
// with the value of PCR 12 that the TPM gives back. what names the start
// policy after its hash: its nickname, or its list. measured: the TPM took
// the extend. A start policy of the boot image starts unmeasured, with the
// line of the cause; a chosen start policy does not start unmeasured
// (start_policy_chosen_run).
//
// The wait is not a stage of the loop of this service: the bytes of the
// chosen module file are held by the load until Process_Start, the rescue
// starts inside the reap of the failed policy, and each would need a state
// of its own across passes. The wait is short in practice (an extend and a
// read), and its bound only ends a TPM service that does not answer.
start_policy_measure :: proc "contextless" (module_hash: [32]u8, list_hash: [32]u8, what: string) -> (measured: bool) {
	head := value_kinds.Hash_Head_Field(module_hash)
	policy_words := text_field(what, 40)
	if tpm_service_stopped {
		system.log_fact(.Warning, Start_Policy_Unmeasured_Tpm_Stopped_Earlier{start_policy_hash = head, start_policy_words = policy_words})
		return false
	}
	if tpm_ring == 0 || tpm_process == nil {
		system.log_fact(.Info, Start_Policy_Unmeasured_No_Tpm{start_policy_hash = head, start_policy_words = policy_words})
		return false
	}
	if tpm_measure_ring.head == nil {
		system.log_fact(.Warning, Start_Policy_Unmeasured_No_Measure_Ring{start_policy_hash = head, start_policy_words = policy_words})
		return false
	}
	module_copy, list_copy := module_hash, list_hash
	digest := tpm2.start_policy_event_digest(&module_copy, &list_copy)
	words := transmute([4]u64)digest
	tpm_measure_tag += 1
	tag := tpm_measure_tag
	if !system.send(&tpm_measure_ring.commands, ring.Record{kind = u32(tpm_service.Command.Measure_Start_Policy), tag = tag, values = {0 = words[0], 1 = words[1], 2 = words[2], 3 = words[3]}}) {
		system.log_fact(.Warning, Start_Policy_Unmeasured_Measure_Ring_Full{start_policy_hash = head, start_policy_words = policy_words})
		return false
	}
	limit := system.time() + TPM_MEASURE_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		for record in root_receive(&tpm_measure_ring.completions, "the TPM service") {
			if record.tag != tag {
				// A completion of a measure whose wait ended at the bound.
				continue
			}
			// The one border of the completion of the TPM service.
			outcome, failure := call_outcome.completion_outcome(record.kind, record.values)
			if outcome == .Answer_Unreadable {
				system.log_fact(.Warning, Start_Policy_Unmeasured_Unknown_Status{outcome_word = u64(record.kind), start_policy_hash = head, start_policy_words = policy_words})
				return false
			}
			if outcome != .Succeeded {
				system.log_fact(.Warning, Start_Policy_Measure_Failed{answer_value = cast(u64)failure.found, start_policy_hash = head, start_policy_words = policy_words, tpm_status = text_field(call_outcome.CALL_OUTCOME_NAMES[outcome], 64)})
				return false
			}
			value := transmute([32]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
			system.log_fact(.Info, Start_Policy_Measured{start_policy_hash = head, measure_value = value_kinds.Hash_Field(value), start_policy_words = policy_words})
			return true
		}
		if state, _, _ := system.process_state(tpm_process.process); state == .Stopped {
			system.log_fact(.Warning, Start_Policy_Unmeasured_Tpm_Stopped_During{start_policy_hash = head, start_policy_words = policy_words})
			return false
		}
		system.wait_records(&wait, &tpm_measure_ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			system.log_fact(.Warning, Start_Policy_Unmeasured_No_Answer{bound = TPM_MEASURE_BOUND_MILLISECONDS, start_policy_hash = head, start_policy_words = policy_words})
			return false
		}
	}
}

// tpm_seal_allowed says if a key may be sealed by the TPM: only when the
// firmware verified the boot program. With Secure Boot off, PCR 7 says
// "off", and a replaced boot program can extend PCR 11 with the hash of a
// correct description: a seal then trusts a boot program that nothing
// verified. An unseal stays allowed: it opens only a seal that was made.
tpm_seal_allowed :: proc "contextless" () -> bool {
	verifier, ok := info.verifier_of_word(trust_boot_report.trust.verifier)
	return ok && verifier == .Firmware_And_Boot_Program
}
