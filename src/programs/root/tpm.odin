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
	when SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST {
		system.log_in("devices", .Warning, TEST_BUILD_LINE_SEAL_WITHOUT_SECURE_BOOT)
	}
	if trust_boot_report.trust.measure != .Measured {
		system.log_in("devices", .Info, "root: no TPM service: the system is not measured into a TPM, so no key is sealed to its measure")
		return
	}
	slot: ^Started
	for &item in started {
		if item.program == 0 {
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
	if status == .Ok {
		grants: [op.CONTEXT_HANDLES]system.Grant
		grants[op.CONTEXT_LOG] = log_grant("tpm")
		grants[tpm_service.SERVICE_RING] = {ring_memory, {.Read, .Write}}
		grants[tpm_service.SERVICE_REGION] = {region_memory, {.Read, .Write}}
		grants[tpm_service.SERVICE_REGISTERS] = {registers, {.Read, .Write}}
		file := system.image_find(image, "tpm")
		program, status = system.program_start(file, "tpm", grants, random.values_with_seed(&program_generator, {}), budget_of(file, "tpm"))
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
	slot.role = {.System_Part}
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
tpm_grants_give :: proc "contextless" (grants: ^[op.CONTEXT_HANDLES]system.Grant) {
	if tpm_ring == 0 || tpm_program == nil {
		return
	}
	grants[tpm_service.GRANT_RING] = {tpm_ring, {.Read, .Write}}
	grants[tpm_service.GRANT_REGION] = {tpm_region, {.Read, .Write}}
	grants[tpm_service.GRANT_SERVICE] = {tpm_program.program, {.Read}}
}

// A setting of the build of the module root_seal_test of
// tools/modustool/modules.odin, which only the boot image of the test of
// the seal holds, under the name root. It lets a seal run when the boot
// program verified the system and the firmware did not verify the boot
// program: the test machines with Secure Boot have no TPM device
// (docs/TRUSTED_BOOT.md, "The machines of the TPM"), so the seal is tested
// with no Secure Boot. The module
// "root" has no define, so this is false in it; a root service with it
// writes TEST_BUILD_LINE_SEAL_WITHOUT_SECURE_BOOT at boot, and the tool
// fails each machine of another volume that prints that line.
SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST :: #config(SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST, false)
TEST_BUILD_LINE_SEAL_WITHOUT_SECURE_BOOT :: "root: this system seals with no Secure Boot: a test system, never a release"

// tpm_seal_allowed says if a key may be sealed by the TPM: only when the
// firmware verified the boot program. With Secure Boot off, PCR 7 says
// "off", and a replaced boot program can extend PCR 11 with the hash of a
// correct description: a seal then trusts a boot program that nothing
// verified. An unseal stays allowed: it opens only a seal that was made.
// The root service of the test of the seal also takes a boot program that
// only the boot program itself verified.
tpm_seal_allowed :: proc "contextless" () -> bool {
	verifier := trust_boot_report.trust.verifier
	when SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST {
		return verifier == .Firmware_And_Boot_Program || verifier == .Boot_Program
	} else {
		return verifier == .Firmware_And_Boot_Program
	}
}
