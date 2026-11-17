package root

import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/tpm_service"
import "modus:support/random"
import "modus:support/system"

// The TPM service (src/md/features/tpm_sealed_machine_key.md): the device
// service of the TPM. This service starts it at boot when the boot program
// measured the system into the TPM, and keeps its ring and its region to
// give them to each run of `unlock`, the one program with the start grant
// Tpm. With no measure, no key can be sealed to it: no TPM service runs,
// and `unlock` works as on a machine with no TPM.
tpm_ring: system.Handle
tpm_region: system.Handle
tpm_program: ^Started

// tpm_service_start starts the TPM service, once, before `unlock`.
tpm_service_start :: proc "contextless" () {
	if trust_boot_report.trust.measure != .Measured {
		system.log_in("devices", .Info, "root: no TPM service: the system is not measured into a TPM, so no key is sealed to its measure")
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
		system.log_in("devices", .Warning, "root: no TPM service: the table of the programs is full")
		return
	}
	// What this service creates here and does not keep: the program holds
	// its copy of the registers.
	registers, _, status := device_handle(.Memory, tpm_service.REGISTERS_ADDRESS, 1)
	if status != .Ok {
		system.log_in("devices", .Warning, "root: no TPM service: the registers of the TPM at ", system.Hex(u64(tpm_service.REGISTERS_ADDRESS)), " are refused: status ", status)
		return
	}
	defer system.close(registers)
	ring_memory, region_memory: system.Handle
	ring_memory, status = system.memory_create(ring.pages(ring.CAPACITY))
	if status == .Ok {
		region_memory, status = system.memory_create(1)
	}
	program: system.Handle
	role := role_of("tpm")
	if status == .Ok {
		context_grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role))
		system.grant_put(&context_grants, tpm_service.SERVICE_RING, {ring_memory, {.Read, .Write}})
		system.grant_put(&context_grants, tpm_service.SERVICE_REGION, {region_memory, {.Read, .Write}})
		system.grant_put(&context_grants, tpm_service.SERVICE_REGISTERS, {registers, {.Read, .Write}})
		if context_refused("tpm", &context_grants, &values) {
			status = .Bad_State
		} else {
			file := system.image_find(image, "tpm")
			program, status = system.program_start(file, "tpm", context_grants.grants, random.values_with_seed(&program_generator, values.values), budget_of(file, "tpm"))
		}
	}
	if status != .Ok {
		for handle in ([2]system.Handle{ring_memory, region_memory}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_in("devices", .Warning, "root: cannot start the TPM service: status ", status)
		return
	}
	slot^ = {}
	slot.program = program
	slot.role = role
	slot.granted = {.Log}
	copy(slot.name[:len(slot.name) - 1], "tpm")
	tpm_ring, tpm_region, tpm_program = ring_memory, region_memory, slot
	system.log_in("devices", .Info, "root: started tpm for the TPM at ", system.Hex(u64(tpm_service.REGISTERS_ADDRESS)), ": unlock seals keys to the measure of the system with it")
}

// tpm_service_end forgets the ring and the region of a TPM service that
// stopped: a later `unlock` gets none, and runs as on a machine with no TPM.
tpm_service_end :: proc "contextless" (item: ^Started) {
	if item != tpm_program {
		return
	}
	for handle in ([2]system.Handle{tpm_ring, tpm_region}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	tpm_ring, tpm_region, tpm_program = 0, 0, nil
	system.log_in("devices", .Warning, "root: the TPM service stopped: no key is sealed or unsealed until the machine starts again")
}

// tpm_grants_give gives a program with the start grant Tpm the ring and the
// region of the TPM service, when it runs, and the service with the right
// Read: its stop is then an event of the program, which ends a wait for an
// answer at once.
tpm_grants_give :: proc "contextless" (work: ^Start_Work) {
	if tpm_ring == 0 || tpm_program == nil {
		return
	}
	start_grant_put(work, .Tpm_Ring, {tpm_ring, {.Read, .Write}})
	start_grant_put(work, .Tpm_Region, {tpm_region, {.Read, .Write}})
	start_grant_put(work, .Tpm_Service, {tpm_program.program, {.Read}})
}

// tpm_seal_allowed says if a key may be sealed by the TPM: only when the
// firmware verified the boot program. With Secure Boot off, PCR 7 says
// "off", and a replaced boot program can extend PCR 11 with the hash of a
// correct description: a seal then trusts a boot program that nothing
// verified. An unseal stays allowed: it opens only a seal that was made.
tpm_seal_allowed :: proc "contextless" () -> bool {
	return trust_boot_report.trust.verifier == .Firmware_And_Boot_Program
}
