// The TPM service: the device service of the TPM of the machine. It seals
// 32 secret bytes to the values of PCR 7 and PCR 11, and unseals them only
// while those PCRs hold the same values (src/md/features/tpm_sealed_machine_key.md).
//
// **What it is for.** The boot program measures the system description into
// PCR 11 before the kernel starts, and the firmware measures the state of
// Secure Boot into PCR 7. A key that this service sealed opens again only
// on the same system, with the same state of Secure Boot: an older system,
// a changed system, or a copy of the disk on another machine opens nothing.
// The process `unlock` seals the machine key with it (docs/PRINCIPALS.md,
// "The machine key sealed by the TPM"), and the keys of a named principal
// and the machine key under a machine passphrase, with an authorization
// value from the passphrase whose wrong tries the TPM counts
// (docs/PRINCIPALS.md, "The keys sealed by the TPM";
// docs/PRINCIPALS.md, "The machine passphrase with the TPM").
//
// **Start**: the root service starts it at boot, before `unlock`, only when
// the boot program measured the system into the TPM. No line of the console
// starts it.
//
// **Grants**, as the root service gives them: the page of the registers of
// the CRB interface of the TPM, the TPM ring and the TPM region
// (modus:contract/tpm_service), and the measure ring, which only the root
// service writes. Nothing else: no store, no window, no ring to the root
// service.
//
// **The commands of the TPM.** The service builds each one itself
// (modus:support/tpm2): a client sends Seal or Unseal, never a raw command,
// so no client extends a PCR or clears the TPM. On the measure ring the
// root service sends Measure_Start_Policy before each start policy runs:
// the service extends PCR 12, twice at most in one start
// (src/md/features/start_policy.md, "The measure of the start policy"). Each request makes the
// storage key from the owner hierarchy, uses it, and flushes it, with its
// session: the TPM keeps no object of the system between two requests.
//
// **The lockout hierarchy.** At its start it writes the count limits of the
// TPM on the log. Before the first request with an authorization value, it
// sets a random lockout authorization value, which nobody keeps, when the
// TPM has an empty one: then no system resets the count of the wrong
// passphrases of a named principal or of the machine
// (src/md/features/tpm_sealed_principal_keys.md).
//
// **What a reader sees.** No window. The log has "tpm: ok, the CRB
// interface at 0xFED40000, ...", the count limits, a line on the lockout
// authorization value at the first use of a passphrase, then one line for
// each request: "tpm:
// sealed 32 bytes to PCR 7 and PCR 11 ...", "tpm: unsealed 32 bytes ...",
// or "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the
// values of the seal ...".
//
// **What it does not protect.** The secret crosses the interface of the TPM
// in clear: no session encrypts the parameters. A software TPM on the host
// sees each secret anyway.
package tpm_device_service

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/tpm_service"
import "modus:support/random"
import "modus:support/system"
import "modus:support/tpm2"

// One thread serves the ring, one request at a time. Its working memory
// holds the ring, the region of its client and the buffers of one TPM
// command and its answer, each at most one page.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 16, processes = 1, threads = 1}

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
// The bound of the read of the count limits at the start, and of the check
// of the lockout hierarchy before the first request with an authorization
// value, each over its own commands. It only ends a wait for a TPM that
// does not answer: neither makes a key. The request that follows has its
// own bound after it, so the check and that request stay below the bound of
// the client.
LOCKOUT_CHECK_BOUND_MILLISECONDS :: 30_000

// The sends of one TPM2_Unseal when the TPM asks for it again
// (TPM_RC_RETRY): the TPM asks it at most once after its start, so a third
// answer of that kind is a fault of the TPM.
UNSEAL_TRIES :: 3

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

// transact sends one command to the TPM and gives its answer. step is
// .None, or the step at which the interface failed.
transact :: proc "contextless" (count: int) -> (answer: []u8, step: tpm_service.Device_Step) {
	if count <= 0 || count > MESSAGE_LIMIT {
		return nil, .Answer // A command that did not fit its buffer.
	}
	register_write(REGISTER_LOCALITY_CONTROL, 1)
	if !wait_for(REGISTER_LOCALITY_STATUS, 1, 1) {
		return nil, .Locality
	}
	defer register_write(REGISTER_LOCALITY_CONTROL, 2)
	register_write(REGISTER_CONTROL_REQUEST, 1)
	if !wait_for(REGISTER_CONTROL_REQUEST, 1, 0) || !wait_for(REGISTER_CONTROL_STATUS, 2, 0) {
		return nil, .Ready
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
		return nil, .Start
	}
	if register_read(REGISTER_CONTROL_STATUS) & 1 != 0 {
		return nil, .Answer
	}
	// The size of the answer is in its header: bytes 2 to 5, big-endian.
	header: [6]u8
	for index in 0 ..< len(header) {
		header[index] = intrinsics.volatile_load((^u8)(registers + DATA_BUFFER + uintptr(index)))
	}
	size := int(byte_order.read_u32_big_endian(header[:], 2))
	if size < 10 || size > min(buffer_size, MESSAGE_LIMIT) {
		return nil, .Answer
	}
	for index in 0 ..< size {
		answer_bytes[index] = intrinsics.volatile_load((^u8)(registers + DATA_BUFFER + uintptr(index)))
	}
	return answer_bytes[:size], .None
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
		if tpm2.authorization_fails(code) {
			return {status = .Authorization_Fails, values = {0 = u64(code)}}
		}
		if tpm2.locked_out(code) {
			return {status = .Locked_Out, values = {0 = u64(code)}}
		}
		return {status = .Refused, values = {0 = u64(code), 1 = u64(command)}}
	}
	return {status = .Device_Error, values = {0 = u64(tpm_service.Device_Step.Answer)}}
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
	if step != .None {
		return 0, {status = .Device_Error, values = {0 = u64(step)}}, false
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
// in it, then TPM2_PolicyPassword for an object with an authorization value.
policy_session :: proc "contextless" (kind: tpm2.Session_Kind, authorized: bool) -> (session: u32, failed: Outcome, ok: bool) {
	count := tpm2.start_session_command(command_bytes[:], kind)
	answer, step := transact(count)
	if step != .None {
		return 0, {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code: u32
	problem: tpm2.Answer_Problem
	session, code, problem = tpm2.handle_answer(answer)
	if problem != .None {
		return 0, outcome_of_problem(problem, code, tpm2.COMMAND_START_AUTH_SESSION), false
	}
	count = tpm2.policy_pcr_command(command_bytes[:], session)
	answer, step = transact(count)
	if step != .None {
		return session, {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return session, outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_PCR), false
	}
	if authorized {
		count = tpm2.policy_password_command(command_bytes[:], session)
		answer, step = transact(count)
		if step != .None {
			return session, {status = .Device_Error, values = {0 = u64(step)}}, false
		}
		code, problem = tpm2.status_answer(answer)
		if problem != .None {
			return session, outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_PASSWORD), false
		}
	}
	return session, {}, true
}

// authorization_take reads the authorization of a request: with .Value,
// it copies the value of the region and erases it there. The main loop
// refused a word that names no authorization before the request.
authorization_take :: proc "contextless" (authorization: tpm_service.Authorization, value: ^[tpm2.AUTHORIZATION_VALUE_SIZE]u8) -> (authorized: bool) {
	switch authorization {
	case .None:
		return false
	case .Value:
		copy(value^[:], region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
		erase(region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
		return true
	}
	return false
}

// The TPM was asked to check an authorization value in the request that
// runs: the TPM then marks that it used an object that it protects from a
// dictionary attack, and counts one failure at its next start unless it
// receives TPM2_Shutdown before.
authorization_used: bool

// orderly_state_restore sends TPM2_Shutdown(CLEAR) after a use of an
// authorization value that the TPM did not count as a failure. The system
// has no orderly stop: with no shutdown, each start that follows an unlock
// of a named principal would count one failure, and three starts would
// lock the TPM. After a counted failure it is not sent (see unseal). The
// TPM goes on to take commands after it.
orderly_state_restore :: proc "contextless" () {
	// A bound of its own, as a flush has: a request that reached its
	// deadline still ends with it.
	request_deadline = system.time() + FLUSH_BOUND_MILLISECONDS
	count := tpm2.shutdown_command(command_bytes[:])
	answer, step := transact(count)
	if step != .None {
		system.log("tpm: the interface failed at TPM2_Shutdown after a use of an authorization value: ", tpm_service.device_step_words[step], "; the next start of the TPM can count one failure")
		return
	}
	code, problem := tpm2.status_answer(answer)
	if problem != .None {
		system.log("tpm: the TPM refused TPM2_Shutdown after a use of an authorization value (response code ", system.Hex(u64(code)), "); the next start of the TPM can count one failure")
		return
	}
	system.log("tpm: TPM2_Shutdown after the use of an authorization value: a stop of the machine now makes the TPM count no failure")
}

// seal seals the secret of the region to the values of PCR 7 and PCR 11 now,
// with the authorization value of the region when the request has one.
seal :: proc "contextless" (authorization_kind: tpm_service.Authorization) -> Outcome {
	secret: [tpm2.SECRET_SIZE]u8
	authorization: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(secret[:])
	defer erase(authorization[:])
	copy(secret[:], region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	erase(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	authorized := authorization_take(authorization_kind, &authorization)
	authorization_bytes: []u8
	if authorized {
		authorization_bytes = authorization[:]
	}
	defer erase(command_bytes[:])
	primary, primary_failed, primary_ok := storage_key()
	if !primary_ok {
		return primary_failed
	}
	defer flush(primary)
	// A trial session: the TPM computes the policy from the PCRs now.
	session, session_failed, session_ok := policy_session(.Trial, authorized)
	defer flush(session)
	if !session_ok {
		return session_failed
	}
	count := tpm2.policy_get_digest_command(command_bytes[:], session)
	answer, step := transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}
	}
	policy, code, problem := tpm2.digest_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_GET_DIGEST)
	}
	count = tpm2.create_sealed_command(command_bytes[:], primary, &secret, &policy, authorization_bytes)
	answer, step = transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}
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
	if authorized {
		system.log("tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", u64(len(created.public_area)), " bytes and a private area of ", u64(len(created.private_area)), " bytes, with its creation data and its ticket")
	} else {
		system.log("tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of ", u64(len(created.public_area)), " bytes and a private area of ", u64(len(created.private_area)), " bytes, with its creation data and its ticket")
	}
	return {status = .Ok, values = {0 = u64(len(created.public_area)), 1 = u64(len(created.private_area)), 2 = u64(tpm2.PCR_SET), 3 = u64(len(created.creation_data)), 4 = u64(len(created.creation_ticket))}}
}

// unseal gives the secret of a sealed object in the region, when this TPM
// made the object under the PCR values of its policy, and when PCR 7 and
// PCR 11 hold those values now.
unseal :: proc "contextless" (public_count, private_count, creation_count, ticket_count: u64, authorization_kind: tpm_service.Authorization) -> Outcome {
	authorization: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(authorization[:])
	// The command of the unseal holds the authorization value: the buffer is
	// erased after the last command of the request, on each path.
	defer erase(command_bytes[:])
	authorized := authorization_take(authorization_kind, &authorization)
	// The counts come from the client: they are checked before any copy.
	if public_count > tpm2.PUBLIC_AREA_LIMIT || private_count > tpm2.PRIVATE_AREA_LIMIT || creation_count > tpm2.CREATION_DATA_LIMIT || ticket_count > tpm2.CREATION_TICKET_LIMIT {
		return {status = .Bad_Command}
	}
	authorization_bytes: []u8
	if authorized {
		authorization_bytes = authorization[:]
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
	// its creation data names, with the attributes of a sealed object of
	// its authorization: an object of a named principal with noDA set would
	// let a wrong passphrase go uncounted, and one with the policy of the
	// PCRs alone would open with no passphrase. With
	// the ticket below, the object then opens only while the PCRs hold the
	// values that they held when this TPM made it: an object that another
	// system made with the policy of this system names the PCRs of that
	// system in its creation data.
	pcr_digest, creation_read := tpm2.creation_data_pcr_digest(creation_data[:creation_bytes])
	if !creation_read {
		system.log("tpm: refused the unseal: the creation data does not name PCR 7 and PCR 11 with a digest")
		return {status = .Not_Authentic}
	}
	policy := tpm2.sealed_object_policy(&pcr_digest, authorized)
	if !tpm2.sealed_public_check(public_area[:public_bytes], &policy, tpm2.sealed_object_attributes(authorized)) {
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
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}
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
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}
	}
	code, problem = tpm2.status_answer(answer)
	if problem == .Refused && tpm2.ticket_fails(code) {
		system.log("tpm: refused the unseal: the TPM refuses the creation ticket of the object (response code ", system.Hex(u64(code)), "): this TPM did not make it so")
		return {status = .Not_Authentic, values = {0 = u64(code)}}
	}
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_CERTIFY_CREATION)
	}
	session, session_failed, session_ok := policy_session(.Policy, authorized)
	defer flush(session)
	if !session_ok {
		return session_failed
	}
	secret: []u8
	for attempt in 1 ..= UNSEAL_TRIES {
		count = tpm2.unseal_command(command_bytes[:], item, session, authorization_bytes)
		authorization_used = authorization_used || authorized
		answer, step = transact(count)
		if step != .None {
			return {status = .Device_Error, values = {0 = u64(step)}}
		}
		secret, code, problem = tpm2.unseal_answer(answer)
		// A TPM can ask for the command again at the first use of an object
		// that it protects from a dictionary attack after its start: the
		// check of the session did not run, and the session stays.
		if problem != .Refused || !tpm2.retry_asked(code) || attempt == UNSEAL_TRIES {
			break
		}
	}
	if problem != .None {
		if problem == .Refused && tpm2.policy_fails(code) {
			system.log("tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal (response code ", system.Hex(u64(code)), ")")
		}
		if problem == .Refused && tpm2.authorization_fails(code) {
			// No TPM2_Shutdown after a counted failure: a TPM can keep the
			// failure in its RAM and write it later, and a shutdown would
			// make its state orderly, so a stop of the power would lose the
			// failure. With no shutdown, the next start counts one failure
			// at most, and a right passphrase later in this run sends it.
			authorization_used = false
			system.log("tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code ", system.Hex(u64(code)), ")")
		}
		if problem == .Refused && tpm2.locked_out(code) {
			system.log("tpm: the TPM refuses the unseal: it counted too many wrong authorization values, and refuses each try for now (response code ", system.Hex(u64(code)), ")")
		}
		return outcome_of_problem(problem, code, tpm2.COMMAND_UNSEAL)
	}
	copy(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE], secret)
	if authorized {
		system.log("tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right")
	} else {
		system.log("tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal")
	}
	return {status = .Ok, values = {0 = tpm2.SECRET_SIZE}}
}

// The extends of PCR 12 that the TPM took in this start. The service runs
// once in a start: a stop of it is not followed by another run.
measure_count: int

// measure_start_policy extends PCR 12 with the event digest of a start
// policy, which the root service computed, then reads PCR 12 back for the
// line of the root service. Past MEASURE_LIMIT extends in this start, it
// sends no command to the TPM.
measure_start_policy :: proc "contextless" (values: [7]u64) -> Outcome {
	if refusal := tpm_service.measure_refusal(measure_count); refusal != .Ok {
		system.log_in("devices", .Warning, "tpm: refused an extend of PCR 12: ", u64(measure_count), " extends ran in this start, the most that it takes")
		return {status = refusal, values = {0 = u64(measure_count)}}
	}
	digest := transmute([tpm2.DIGEST_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
	count := tpm2.pcr_extend_command(command_bytes[:], &digest)
	answer, step := transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}
	}
	code, problem := tpm2.status_answer(answer)
	if problem != .None {
		system.log_in("devices", .Warning, "tpm: the TPM refused the extend of PCR 12 (response code ", system.Hex(u64(code)), ")")
		return outcome_of_problem(problem, code, tpm2.COMMAND_PCR_EXTEND)
	}
	measure_count += 1
	count = tpm2.pcr_read_command(command_bytes[:])
	answer, step = transact(count)
	if step != .None {
		system.log_in("devices", .Warning, "tpm: extended PCR 12, and the interface failed at its read back: ", tpm_service.device_step_words[step])
		return {status = .Device_Error, values = {0 = u64(step)}}
	}
	value: [tpm2.DIGEST_SIZE]u8
	value, code, problem = tpm2.pcr_read_answer(answer)
	if problem != .None {
		system.log_in("devices", .Warning, "tpm: extended PCR 12, and its read back gave no value of PCR 12 of SHA-256 (response code ", system.Hex(u64(code)), ")")
		return outcome_of_problem(problem, code, tpm2.COMMAND_PCR_READ)
	}
	system.log("tpm: extended PCR 12 with the digest of a start policy: extend ", u64(measure_count), " of ", u64(tpm_service.MEASURE_LIMIT), " in this start")
	words := transmute([4]u64)value
	return {status = .Ok, values = {0 = words[0], 1 = words[1], 2 = words[2], 3 = words[3], 4 = u64(measure_count)}}
}

// The generator of this process: it gives the lockout authorization value.
generator: random.Generator

// properties_read reads values of the properties of the TPM from the
// property first, one for each place of values. what names them in a line
// of the log when the TPM does not give them.
properties_read :: proc "contextless" (first: u32, values: []u32, what: string) -> bool {
	count := tpm2.properties_command(command_bytes[:], first, u32(len(values)))
	answer, step := transact(count)
	if step != .None {
		system.log_in("devices", .Warning, "tpm: the interface failed at TPM2_GetCapability of ", what, ": ", tpm_service.device_step_words[step])
		return false
	}
	code, problem := tpm2.properties_answer(answer, first, values)
	if problem == .Refused {
		system.log_in("devices", .Warning, "tpm: the TPM refused TPM2_GetCapability of ", what, " (response code ", system.Hex(u64(code)), ")")
		return false
	}
	if problem != .None {
		system.log_in("devices", .Warning, "tpm: the answer of the TPM to TPM2_GetCapability of ", what, " does not hold the properties asked, each in its place")
		return false
	}
	return true
}

// count_limits_log writes the count limits of the TPM on the log at the
// start. It reads only: it changes nothing in the TPM.
count_limits_log :: proc "contextless" () {
	request_deadline = system.time() + LOCKOUT_CHECK_BOUND_MILLISECONDS
	limits: [tpm2.COUNT_LIMIT_PROPERTIES]u32
	if properties_read(tpm2.PROPERTY_LOCKOUT_COUNTER, limits[:], "the count limits") {
		counted := limits[tpm2.PROPERTY_LOCKOUT_COUNTER - tpm2.PROPERTY_LOCKOUT_COUNTER]
		maximum := limits[tpm2.PROPERTY_MAXIMUM_AUTHORIZATION_FAILURES - tpm2.PROPERTY_LOCKOUT_COUNTER]
		interval := limits[tpm2.PROPERTY_LOCKOUT_INTERVAL - tpm2.PROPERTY_LOCKOUT_COUNTER]
		recovery := limits[tpm2.PROPERTY_LOCKOUT_RECOVERY - tpm2.PROPERTY_LOCKOUT_COUNTER]
		system.log("tpm: the count limits of the TPM: a lockout after ", u64(maximum), " wrong authorization values, one forgiven each ", u64(interval), " seconds; ", u64(counted), " counted now; the lockout hierarchy waits ", u64(recovery), " seconds after a wrong value of its own")
		if interval == 0 {
			system.log_in("devices", .Warning, "tpm: the TPM limits no rate of the wrong authorization values: its lockout interval is 0")
		}
	}
}

// The lockout hierarchy was checked in this run: the check runs once, at
// the first request that carries an authorization value.
lockout_checked: bool

// lockout_authorization_check sets a random lockout authorization value
// when the lockout hierarchy has an empty one. With an empty value, another
// system on the machine resets the count of the wrong passphrases of a
// named principal or of the machine, or changes its limits, with no PCR and
// no passphrase. It runs only before the first request with an
// authorization value: a boot that never seals or unseals a key with a
// passphrase leaves the
// TPM as it found it, as the change is undone only by a clear. The value is
// kept nowhere: nothing in the system may reset the count, and a kept copy
// gives that reset to whoever reads it
// (src/md/features/tpm_sealed_principal_keys.md, "The lockout authorization
// value").
lockout_authorization_check :: proc "contextless" (seeded: bool) {
	request_deadline = system.time() + LOCKOUT_CHECK_BOUND_MILLISECONDS
	permanent: [1]u32
	if !properties_read(tpm2.PROPERTY_PERMANENT, permanent[:], "the state of the hierarchies") {
		system.log_in("devices", .Warning, "tpm: the lockout hierarchy is not checked: another system can reset the count of the TPM while its value is empty")
		return
	}
	if tpm2.lockout_authorization_set(permanent[0]) {
		system.log("tpm: the lockout hierarchy has an authorization value: an earlier start of this system set it, or another system did; this service keeps no copy of it and leaves it")
		return
	}
	value: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(value[:])
	// The command holds the value: the buffer is erased on each path.
	defer erase(command_bytes[:])
	error: errors.Error_Record
	if !seeded {
		system.log_in("devices", .Warning, "tpm: the lockout hierarchy keeps its empty authorization value: this process has no seed, and another system can reset the count of the TPM")
		return
	}
	if !random.fill_for_a_key(&generator, value[:], .Processor, &error) {
		system.log_in("devices", .Warning, "tpm: the lockout hierarchy keeps its empty authorization value: the seed of this process is too weak for a key, and another system can reset the count of the TPM")
		return
	}
	count := tpm2.lockout_authorization_change_command(command_bytes[:], value[:])
	answer, step := transact(count)
	if step != .None {
		system.log_in("devices", .Warning, "tpm: the interface failed at TPM2_HierarchyChangeAuth of the lockout hierarchy: ", tpm_service.device_step_words[step], "; it can keep its empty authorization value until the next start")
		return
	}
	code, problem := tpm2.status_answer(answer)
	if problem == .Refused {
		system.log_in("devices", .Warning, "tpm: the TPM refused a lockout authorization value (response code ", system.Hex(u64(code)), "): the lockout hierarchy keeps its empty one until the next start, and another system can reset the count of the TPM")
		return
	}
	if problem != .None {
		system.log_in("devices", .Warning, "tpm: the answer of the TPM to TPM2_HierarchyChangeAuth of the lockout hierarchy does not have its form: the next start reads the state of the hierarchy again")
		return
	}
	system.log("tpm: the lockout hierarchy had an empty authorization value: this service set a random one and kept no copy, so no system resets the count of the TPM or changes its limits")
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
	// First: the call erases the seed in the context.
	seeded := random.generator_from_context(&generator, ctx)
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
	// The measure ring of the root service. With none, no start policy is
	// measured, and the root service says it at each start policy.
	measures, measure_ring_status := system.ring_open(ctx.handles[tpm_service.SERVICE_MEASURE_RING])
	measure_ring_open := measure_ring_status == .Ok
	if !measure_ring_open {
		system.log_in("devices", .Warning, "tpm: no measure ring: no start policy is measured into PCR 12")
	}
	// Before the ring: a request of unlock waits in the ring until then.
	count_limits_log()
	for {
		wait := system.wait_begin()
		requests_serve(&clients, .Client_Ring, seeded)
		system.wait_records(&wait, &clients.commands)
		if measure_ring_open {
			requests_serve(&measures, .Measure_Ring, seeded)
			system.wait_records(&wait, &measures.commands)
		}
		system.wait_end(&wait)
	}
}

// requests_serve answers each request of one ring. One thread serves both
// rings, one request at a time, so a request of the measure ring never runs
// in the middle of a request of a client.
requests_serve :: proc "contextless" (requests: ^ring.Ring, source: tpm_service.Request_Source, seeded: bool) {
	for command in system.receive(&requests.commands) {
		outcome: Outcome
		// The border of the ring: the kind and the authorization become
		// their members here, and a word that names no member, or a command
		// of the other ring, is answered with Bad_Command before any work.
		request, request_status := tpm_service.request_of_record(command.kind, command.values, source)
		if request_status != .Ok {
			// The secret and the value of a refused request of a client are
			// erased from the region all the same. A refusal on the measure
			// ring leaves the region alone: a client can have written its
			// secret there for its next request.
			if source == .Client_Ring {
				erase(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
				erase(region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
			}
			if !system.send(&requests.completions, ring.Record{kind = u32(request_status), tag = command.tag}) {
				system.log_in("devices", .Warning, "tpm: the completion queue of a ring of the TPM service is full: a completion is lost")
			}
			continue
		}
		// The first request whose keys the TPM counts: the lockout value
		// matters from this request on, and a boot with no such request
		// leaves the lockout hierarchy as it found it. The check has its
		// own bound, before the bound of the request, so both stay below
		// the bound of the client.
		if !lockout_checked && request.authorization == .Value {
			lockout_checked = true
			lockout_authorization_check(seeded)
		}
		request_deadline = system.time() + REQUEST_BOUND_MILLISECONDS
		authorization_used = false
		switch request.command {
		case .None:
			// Refused at the border above.
			outcome = {status = .Bad_Command}
		case .Seal:
			outcome = seal(request.authorization)
		case .Unseal:
			outcome = unseal(command.values[0], command.values[1], command.values[2], command.values[3], request.authorization)
		case .Measure_Start_Policy:
			outcome = measure_start_policy(command.values)
		}
		// After the flushes of the request, before its completion: the
		// client learns the outcome only once the TPM is orderly again.
		if authorization_used {
			orderly_state_restore()
		}
		if !system.send(&requests.completions, ring.Record{kind = u32(outcome.status), tag = command.tag, values = outcome.values}) {
			system.log_in("devices", .Warning, "tpm: the completion queue of a ring of the TPM service is full: a completion is lost")
		}
	}
}
