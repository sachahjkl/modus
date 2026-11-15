// The TPM service: the device service of the TPM of the machine. It seals
// 32 secret bytes to the values of PCR 7 and PCR 11, and unseals them only
// while those PCRs hold the same values (src/md/features/tpm_sealed_machine_key.md).
//
// **What it is for.** The boot program measures the system description into
// PCR 11 before the kernel starts, and the firmware measures the state of
// Secure Boot into PCR 7. A key that this service sealed opens again only
// on the same system, with the same state of Secure Boot: an older system,
// a changed system, or a copy of the disk on another machine opens nothing.
// The program `unlock` seals the machine key with it (docs/PRINCIPALS.md,
// "The machine key sealed by the TPM").
//
// **Start**: the root service starts it at boot, before `unlock`, only when
// the boot program measured the system into the TPM. No line of the console
// starts it.
//
// **Grants**, as the root service gives them: the page of the registers of
// the CRB interface of the TPM, the TPM ring and the TPM region
// (modus:contract/tpm_service). Nothing else: no store, no window, no ring
// to the root service.
//
// **The commands of the TPM.** The service builds each one itself
// (modus:support/tpm2): a client sends Seal or Unseal, never a raw command,
// so no client extends a PCR or clears the TPM. Each request makes the
// storage key from the owner hierarchy, uses it, and flushes it, with its
// session: the TPM keeps no object of the system between two requests.
//
// **What a reader sees.** No window. The log has "tpm: ok, the CRB
// interface at 0xFED40000, ...", then one line for each request: "tpm:
// sealed 32 bytes to PCR 7 and PCR 11 ...", "tpm: unsealed 32 bytes ...",
// or "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the
// values of the seal ...".
//
// **What it does not protect.** The secret crosses the interface of the TPM
// in clear: no session encrypts the parameters. A software TPM on the host
// sees each secret anyway.
package tpm_device_service

import "base:intrinsics"
import "modus:contract/ring"
import "modus:contract/tpm_service"
import "modus:support/system"
import "modus:support/tpm2"

// One thread serves the ring, one request at a time. Its working memory
// holds the ring, the region of its client and the buffers of one TPM
// command and its answer, each at most one page.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 16, programs = 1, threads = 1}

// The registers of locality 0 of the CRB interface, from the start of its
// page (TCG PC Client Platform TPM Profile, the CRB interface).
REGISTER_LOCALITY_CONTROL :: 0x08 // Bit 0: ask for the locality; bit 1: give it back.
REGISTER_LOCALITY_STATUS :: 0x0C // Bit 0: the locality is granted.
REGISTER_INTERFACE_IDENTIFIER :: 0x30 // Bits 0 to 3: the kind of the interface; 1 is CRB.
REGISTER_CONTROL_REQUEST :: 0x40 // Bit 0: become ready for a command; bit 1: become idle.
REGISTER_CONTROL_STATUS :: 0x44 // Bit 0: a fatal error; bit 1: the TPM is idle.
REGISTER_CONTROL_START :: 0x4C // Write 1 to start the command; the TPM clears it at the end.
REGISTER_COMMAND_SIZE :: 0x58
REGISTER_COMMAND_ADDRESS_LOW :: 0x5C
REGISTER_COMMAND_ADDRESS_HIGH :: 0x60
REGISTER_RESPONSE_SIZE :: 0x64
REGISTER_RESPONSE_ADDRESS :: 0x68 // 64 bits.
DATA_BUFFER :: 0x80 // The buffer of the command and of the answer, in the same page.
INTERFACE_KIND_CRB :: 1

// The bound of each step of a request. It only ends a wait for a TPM that
// does not answer: the creation of a key on a hardware TPM takes seconds,
// and a software TPM on a loaded host can take as long.
STEP_BOUND_MILLISECONDS :: 120_000
// The bound of one whole request, over all its commands. It only ends a
// request whose TPM does not answer, and it is below the bound of the
// client (unlock, TPM_ANSWER_LIMIT): the service never writes a secret
// after its client stopped waiting for it.
REQUEST_BOUND_MILLISECONDS :: 300_000
// The bound of one flush. It only ends a flush of a TPM that does not
// answer: a flush frees a slot and does no work of a key. The flushes of
// one request (three at most) stay far below the bound of the client.
FLUSH_BOUND_MILLISECONDS :: 10_000

// The bytes of a command and of an answer that this service handles: the
// largest is the answer of TPM2_Create with its creation data and ticket.
MESSAGE_LIMIT :: 1024

registers: uintptr
request_deadline: u64 // The time at which the request that runs ends: each wait of a step ends then too.
buffer_size: int // The bytes of the buffer of the interface, from its registers.
command_bytes: [MESSAGE_LIMIT]u8
answer_bytes: [MESSAGE_LIMIT]u8
region: []u8

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("devices", .Error, "tpm: ", text)
	system.stop(1)
}

register_read :: proc "contextless" (offset: uintptr) -> u32 {
	return intrinsics.volatile_load((^u32)(registers + offset))
}

register_write :: proc "contextless" (offset: uintptr, value: u32) {
	intrinsics.volatile_store((^u32)(registers + offset), value)
}

// erase writes 0 over a secret with volatile stores, which the compiler
// cannot remove.
erase :: proc "contextless" (bytes: []u8) {
	for &item in bytes {
		intrinsics.volatile_store(&item, 0)
	}
}

// buffer_erase writes 0 over the buffer of the interface: it held the
// secret of a seal or of an unseal.
buffer_erase :: proc "contextless" (count: int) {
	for index in 0 ..< min(count, buffer_size) {
		intrinsics.volatile_store((^u8)(registers + DATA_BUFFER + uintptr(index)), 0)
	}
}

// wait_for waits until the bits of a register hold a value, or the bound.
wait_for :: proc "contextless" (offset: uintptr, mask: u32, value: u32) -> bool {
	limit := min(system.time() + STEP_BOUND_MILLISECONDS, request_deadline)
	for register_read(offset) & mask != value {
		if system.time() >= limit {
			return false
		}
		system.sleep(system.time() + 1)
	}
	return true
}

// transact sends one command to the TPM and gives its answer. step is 0, or
// the step at which the interface failed (tpm_service.DEVICE_STEP_).
transact :: proc "contextless" (count: int) -> (answer: []u8, step: u64) {
	if count <= 0 || count > MESSAGE_LIMIT {
		return nil, tpm_service.DEVICE_STEP_ANSWER // A command that did not fit its buffer.
	}
	register_write(REGISTER_LOCALITY_CONTROL, 1)
	if !wait_for(REGISTER_LOCALITY_STATUS, 1, 1) {
		return nil, tpm_service.DEVICE_STEP_LOCALITY
	}
	defer register_write(REGISTER_LOCALITY_CONTROL, 2)
	register_write(REGISTER_CONTROL_REQUEST, 1)
	if !wait_for(REGISTER_CONTROL_REQUEST, 1, 0) || !wait_for(REGISTER_CONTROL_STATUS, 2, 0) {
		return nil, tpm_service.DEVICE_STEP_READY
	}
	defer register_write(REGISTER_CONTROL_REQUEST, 2)
	// The defers run in the reverse order: the buffer is erased while this
	// service still holds the locality, before the TPM becomes idle.
	defer buffer_erase(MESSAGE_LIMIT)
	for index in 0 ..< count {
		intrinsics.volatile_store((^u8)(registers + DATA_BUFFER + uintptr(index)), command_bytes[index])
	}
	register_write(REGISTER_CONTROL_START, 1)
	if !wait_for(REGISTER_CONTROL_START, 1, 0) {
		return nil, tpm_service.DEVICE_STEP_START
	}
	if register_read(REGISTER_CONTROL_STATUS) & 1 != 0 {
		return nil, tpm_service.DEVICE_STEP_ANSWER
	}
	// The size of the answer is in its header: bytes 2 to 5, big-endian.
	header: [6]u8
	for index in 0 ..< len(header) {
		header[index] = intrinsics.volatile_load((^u8)(registers + DATA_BUFFER + uintptr(index)))
	}
	size := int(u32(header[2]) << 24 | u32(header[3]) << 16 | u32(header[4]) << 8 | u32(header[5]))
	if size < 10 || size > min(buffer_size, MESSAGE_LIMIT) {
		return nil, tpm_service.DEVICE_STEP_ANSWER
	}
	for index in 0 ..< size {
		answer_bytes[index] = intrinsics.volatile_load((^u8)(registers + DATA_BUFFER + uintptr(index)))
	}
	return answer_bytes[:size], 0
}

// The outcome of one request, for its completion record.
Outcome :: struct {
	status: tpm_service.Status,
	values: [7]u64,
}

// outcome_of_problem gives the outcome of an answer that is not taken.
outcome_of_problem :: proc "contextless" (problem: tpm2.Answer_Problem, code: u32, command: u32) -> Outcome {
	if problem == .Refused {
		if tpm2.policy_fails(code) {
			return {status = .Policy_Fails, values = {0 = u64(code)}}
		}
		return {status = .Refused, values = {0 = u64(code), 1 = u64(command)}}
	}
	return {status = .Device_Error, values = {0 = tpm_service.DEVICE_STEP_ANSWER}}
}

// flush ends a session or a loaded object. Its answer is not read: a
// handle that the TPM ended already gives an error that changes nothing.
// It has a short bound of its own, apart from the deadline of the request:
// a flush after a request that reached its deadline still runs, else the
// sessions and the objects of that request would fill the few slots of the
// TPM until the next reset.
flush :: proc "contextless" (handle: u32) {
	if handle == 0 {
		return
	}
	deadline := request_deadline
	request_deadline = system.time() + FLUSH_BOUND_MILLISECONDS
	defer request_deadline = deadline
	count := tpm2.flush_command(command_bytes[:], handle)
	_, _ = transact(count)
}

// storage_key makes the storage key under the owner hierarchy: the same key
// at each command, from the fixed template.
storage_key :: proc "contextless" () -> (handle: u32, failed: Outcome, ok: bool) {
	count := tpm2.create_primary_command(command_bytes[:])
	answer, step := transact(count)
	if step != 0 {
		return 0, {status = .Device_Error, values = {0 = step}}, false
	}
	code: u32
	problem: tpm2.Answer_Problem
	handle, code, problem = tpm2.handle_answer(answer)
	if problem != .None {
		return 0, outcome_of_problem(problem, code, tpm2.COMMAND_CREATE_PRIMARY), false
	}
	return handle, {}, true
}

// policy_session starts a session of the kind given and runs TPM2_PolicyPCR
// in it.
policy_session :: proc "contextless" (kind: u8) -> (session: u32, failed: Outcome, ok: bool) {
	count := tpm2.start_session_command(command_bytes[:], kind)
	answer, step := transact(count)
	if step != 0 {
		return 0, {status = .Device_Error, values = {0 = step}}, false
	}
	code: u32
	problem: tpm2.Answer_Problem
	session, code, problem = tpm2.handle_answer(answer)
	if problem != .None {
		return 0, outcome_of_problem(problem, code, tpm2.COMMAND_START_AUTH_SESSION), false
	}
	count = tpm2.policy_pcr_command(command_bytes[:], session)
	answer, step = transact(count)
	if step != 0 {
		return session, {status = .Device_Error, values = {0 = step}}, false
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return session, outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_PCR), false
	}
	return session, {}, true
}

// seal seals the secret of the region to the values of PCR 7 and PCR 11 now.
seal :: proc "contextless" () -> Outcome {
	secret: [tpm2.SECRET_SIZE]u8
	defer erase(secret[:])
	copy(secret[:], region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	erase(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	defer erase(command_bytes[:])
	primary, primary_failed, primary_ok := storage_key()
	if !primary_ok {
		return primary_failed
	}
	defer flush(primary)
	// A trial session: the TPM computes the policy from the PCRs now.
	session, session_failed, session_ok := policy_session(tpm2.SESSION_TRIAL)
	defer flush(session)
	if !session_ok {
		return session_failed
	}
	count := tpm2.policy_get_digest_command(command_bytes[:], session)
	answer, step := transact(count)
	if step != 0 {
		return {status = .Device_Error, values = {0 = step}}
	}
	policy, code, problem := tpm2.digest_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_GET_DIGEST)
	}
	count = tpm2.create_sealed_command(command_bytes[:], primary, &secret, &policy)
	answer, step = transact(count)
	if step != 0 {
		return {status = .Device_Error, values = {0 = step}}
	}
	created: tpm2.Created_Object
	created, code, problem = tpm2.create_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_CREATE)
	}
	copy(region[tpm_service.REGION_PUBLIC_AREA:][:len(created.public_area)], created.public_area)
	copy(region[tpm_service.REGION_PRIVATE_AREA:][:len(created.private_area)], created.private_area)
	copy(region[tpm_service.REGION_CREATION_DATA:][:len(created.creation_data)], created.creation_data)
	copy(region[tpm_service.REGION_CREATION_TICKET:][:len(created.creation_ticket)], created.creation_ticket)
	system.log("tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of ", u64(len(created.public_area)), " bytes and a private area of ", u64(len(created.private_area)), " bytes, with its creation data and its ticket")
	return {status = .Ok, values = {0 = u64(len(created.public_area)), 1 = u64(len(created.private_area)), 2 = u64(tpm2.PCR_SET), 3 = u64(len(created.creation_data)), 4 = u64(len(created.creation_ticket))}}
}

// unseal gives the secret of a sealed object in the region, when this TPM
// made the object under the PCR values of its policy, and when PCR 7 and
// PCR 11 hold those values now.
unseal :: proc "contextless" (public_count, private_count, creation_count, ticket_count: u64) -> Outcome {
	// The counts come from the client: they are checked before any copy.
	if public_count > tpm2.PUBLIC_AREA_LIMIT || private_count > tpm2.PRIVATE_AREA_LIMIT || creation_count > tpm2.CREATION_DATA_LIMIT || ticket_count > tpm2.CREATION_TICKET_LIMIT {
		return {status = .Bad_Command}
	}
	public_bytes, private_bytes, creation_bytes, ticket_bytes := int(public_count), int(private_count), int(creation_count), int(ticket_count)
	public_area: [tpm2.PUBLIC_AREA_LIMIT]u8
	private_area: [tpm2.PRIVATE_AREA_LIMIT]u8
	creation_data: [tpm2.CREATION_DATA_LIMIT]u8
	creation_ticket: [tpm2.CREATION_TICKET_LIMIT]u8
	// One copy of each part: the client can change the region while this
	// service reads it, so the checks and the commands read the copy only.
	copy(public_area[:public_bytes], region[tpm_service.REGION_PUBLIC_AREA:][:public_bytes])
	copy(private_area[:private_bytes], region[tpm_service.REGION_PRIVATE_AREA:][:private_bytes])
	copy(creation_data[:creation_bytes], region[tpm_service.REGION_CREATION_DATA:][:creation_bytes])
	copy(creation_ticket[:ticket_bytes], region[tpm_service.REGION_CREATION_TICKET:][:ticket_bytes])
	if !tpm2.area_fits(public_area[:public_bytes], tpm2.PUBLIC_AREA_LIMIT) || !tpm2.area_fits(private_area[:private_bytes], tpm2.PRIVATE_AREA_LIMIT) || !tpm2.ticket_fits(creation_ticket[:ticket_bytes]) {
		return {status = .Bad_Command}
	}
	// The policy of the object must be the policy of the PCR values that
	// its creation data names, with the attributes of a sealed object. With
	// the ticket below, the object then opens only while the PCRs hold the
	// values that they held when this TPM made it: an object that another
	// system made with the policy of this system names the PCRs of that
	// system in its creation data.
	pcr_digest, creation_read := tpm2.creation_data_pcr_digest(creation_data[:creation_bytes])
	if !creation_read {
		system.log("tpm: refused the unseal: the creation data does not name PCR 7 and PCR 11 with a digest")
		return {status = .Not_Authentic}
	}
	policy := tpm2.policy_pcr_digest(&pcr_digest)
	if !tpm2.sealed_public_check(public_area[:public_bytes], &policy) {
		system.log("tpm: refused the unseal: the policy of the object is not the policy of the PCR values of its creation, or its attributes are not the attributes of a sealed object")
		return {status = .Not_Authentic}
	}
	defer erase(answer_bytes[:])
	primary, primary_failed, primary_ok := storage_key()
	if !primary_ok {
		return primary_failed
	}
	defer flush(primary)
	count := tpm2.load_command(command_bytes[:], primary, public_area[:public_bytes], private_area[:private_bytes])
	answer, step := transact(count)
	if step != 0 {
		return {status = .Device_Error, values = {0 = step}}
	}
	item, code, problem := tpm2.handle_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_LOAD)
	}
	defer flush(item)
	// The TPM checks the ticket: its own HMAC over the creation hash and the
	// name of the loaded object, which the public area gives.
	hash := tpm2.creation_hash(creation_data[:creation_bytes])
	count = tpm2.certify_creation_command(command_bytes[:], item, &hash, creation_ticket[:ticket_bytes])
	answer, step = transact(count)
	if step != 0 {
		return {status = .Device_Error, values = {0 = step}}
	}
	code, problem = tpm2.status_answer(answer)
	if problem == .Refused && tpm2.ticket_fails(code) {
		system.log("tpm: refused the unseal: the TPM refuses the creation ticket of the object (response code ", system.Hex(u64(code)), "): this TPM did not make it so")
		return {status = .Not_Authentic, values = {0 = u64(code)}}
	}
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_CERTIFY_CREATION)
	}
	session, session_failed, session_ok := policy_session(tpm2.SESSION_POLICY)
	defer flush(session)
	if !session_ok {
		return session_failed
	}
	count = tpm2.unseal_command(command_bytes[:], item, session)
	answer, step = transact(count)
	if step != 0 {
		return {status = .Device_Error, values = {0 = step}}
	}
	secret: []u8
	secret, code, problem = tpm2.unseal_answer(answer)
	if problem != .None {
		if problem == .Refused && tpm2.policy_fails(code) {
			system.log("tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal (response code ", system.Hex(u64(code)), ")")
		}
		return outcome_of_problem(problem, code, tpm2.COMMAND_UNSEAL)
	}
	copy(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE], secret)
	system.log("tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal")
	return {status = .Ok, values = {0 = tpm2.SECRET_SIZE}}
}

// The entry: it maps the registers and checks the interface, then serves
// the ring until the machine stops.
//
// **The stop**: with no ring, no region, no registers, an interface that is
// not CRB, or a buffer that is not in the page of the registers, it writes
// the reason at the level error and stops with the code 1. The client then
// receives no answer, and runs as on a machine with no TPM.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	clients, ring_status := system.ring_open(ctx.handles[tpm_service.SERVICE_RING])
	if ring_status != .Ok {
		fail("no TPM ring")
	}
	region_address, region_status := system.memory_map(ctx.handles[tpm_service.SERVICE_REGION], {.Write})
	if region_status != .Ok {
		fail("no TPM region")
	}
	region = ([^]u8)(region_address)[:tpm_service.REGION_SIZE]
	registers_address, registers_status := system.memory_map(ctx.handles[tpm_service.SERVICE_REGISTERS], {.Write})
	if registers_status != .Ok {
		fail("no registers of the TPM")
	}
	registers = uintptr(registers_address)
	if register_read(REGISTER_INTERFACE_IDENTIFIER) & 0xF != INTERFACE_KIND_CRB {
		fail("the interface of the TPM is not CRB")
	}
	// The buffer must be in the one page that this service maps: the
	// command and the answer share it, after the registers.
	buffer_address := u64(register_read(REGISTER_COMMAND_ADDRESS_HIGH)) << 32 | u64(register_read(REGISTER_COMMAND_ADDRESS_LOW))
	response_address := u64(register_read(REGISTER_RESPONSE_ADDRESS)) | u64(register_read(REGISTER_RESPONSE_ADDRESS + 4)) << 32
	buffer_size = int(min(register_read(REGISTER_COMMAND_SIZE), register_read(REGISTER_RESPONSE_SIZE)))
	if buffer_address != tpm_service.REGISTERS_ADDRESS + DATA_BUFFER || response_address != buffer_address || buffer_size < MESSAGE_LIMIT || buffer_size > system.PAGE_SIZE - DATA_BUFFER {
		fail("the buffer of the TPM is not in the page of its registers")
	}
	system.log("tpm: ok, the CRB interface at ", system.Hex(u64(tpm_service.REGISTERS_ADDRESS)), ", a buffer of ", u64(buffer_size), " bytes; it seals to PCR 7 and PCR 11")
	for {
		wait := system.wait_begin()
		for command in system.receive(&clients.commands) {
			outcome: Outcome
			request_deadline = system.time() + REQUEST_BOUND_MILLISECONDS
			#partial switch tpm_service.Command(command.kind) {
			case .Seal:
				outcome = seal()
			case .Unseal:
				outcome = unseal(command.values[0], command.values[1], command.values[2], command.values[3])
			case:
				outcome = {status = .Bad_Command}
			}
			if !system.send(&clients.completions, ring.Record{kind = u32(outcome.status), tag = command.tag, values = outcome.values}) {
				system.log_in("devices", .Warning, "tpm: the completion queue of the TPM ring is full: a completion is lost")
			}
		}
		system.wait_records(&wait, &clients.commands)
		system.wait_end(&wait)
	}
}
