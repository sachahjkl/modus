// The contract of the TPM service: what the process `tpm` and its one
// client, `unlock`, agree on (src/md/features/tpm_sealed_machine_key.md).
//
// The TPM service is the device service of the TPM of the machine. It seals
// 32 secret bytes to the values of PCR 7 and PCR 11, and unseals them only
// while those PCRs hold the same values: the same system, measured by the
// boot program, with the same state of Secure Boot. A sealed object can
// also need an authorization value: the TPM then counts each wrong value
// (src/md/features/tpm_sealed_principal_keys.md).
//
// The client and the service share two memory objects, which the root
// service makes and gives to both:
//
//   the TPM ring     a ring (package ring). One command record is one
//                    request: Seal, Unseal, Pin_Read or Pin_Write.
//   the TPM region   one page. The bytes of a request and of its answer:
//                    the secret, and the two areas of a sealed object.
//
// The client sends one command and waits for its completion before it
// sends the next one: the region holds the bytes of one request. The
// service builds each command of the TPM itself; a client sends no raw
// command, so no client extends a PCR or clears the TPM.
//
// The root service has a ring of its own, the measure ring, with no
// region: it sends Measure_Start_Policy there before each start policy
// runs, and the service extends PCR 12, at most MEASURE_LIMIT times in one
// start (src/md/features/start_policy.md, "The measure of the start policy").
//
// The region holds a secret while a request runs. The service writes zeros
// over its own copies and over the buffer of the interface of the TPM
// after each request; the client writes zeros over the region after it read
// the secret.
//
// This package allocates no memory and calls no kernel operation.
//
// See [TPM service](term:tpm-service).
package tpm_service

// The handles of the context of the service: the ring, the region, the
// page of the registers of the CRB interface of the TPM, and the measure
// ring, which only the root service holds: it sends Measure_Start_Policy
// there, and nowhere else (src/md/features/start_policy.md, "The measure
// of the start policy").
SERVICE_RING :: 0
SERVICE_REGION :: 1
SERVICE_REGISTERS :: 2
SERVICE_MEASURE_RING :: 3

// The extends of PCR 12 in one start: the start policy that starts, then
// the rescue after a failure. A third is refused before any command of the
// TPM, so no later process makes another start policy look measured.
MEASURE_LIMIT :: 2
// The handles of the context of the client: the ring, the region, and the
// TPM service with the right Read: its state, so that the client learns at
// once that the service stopped (its stop is an event of the client).
GRANT_RING :: 11
GRANT_SERVICE :: 12
GRANT_REGION :: 13

// The physical address of the registers of locality 0 of the CRB interface:
// the address of the TPM of the fixed machine (QEMU, tpm-crb). One page.
REGISTERS_ADDRESS :: 0xFED4_0000

REGION_SIZE :: 4096 // The bytes of the region: one page.
SECRET_SIZE :: 32 // The bytes of a sealed secret.
// The places of the region, in bytes. The four parts of a sealed object
// are the parts that the record keeps: the two areas that TPM2_Load takes,
// and the creation data and the creation ticket, which prove that this TPM
// made the object under the PCR values of its policy.
REGION_SECRET :: 0 // The secret: SECRET_SIZE bytes.
REGION_PUBLIC_AREA :: 0 // The public area of a sealed object, with its size field.
REGION_PRIVATE_AREA :: 512 // The private area, with its size field.
REGION_CREATION_DATA :: 1024 // The creation data, with its size field.
REGION_CREATION_TICKET :: 1536 // The creation ticket, whole.
// The authorization value of a request with Authorization.Value:
// AUTHORIZATION_SIZE bytes. The service erases it from the region when it
// takes the request.
REGION_AUTHORIZATION :: 2048
AUTHORIZATION_SIZE :: 32
// The payload of a pin of Pin_Read and Pin_Write: at most PIN_LIMIT bytes.
REGION_PIN :: 2560
PIN_LIMIT :: 128

// The authorization of a sealed object, in values[0] of Seal and values[4]
// of Unseal. Its word crosses the ring, so each value is explicit.
Authorization :: enum u64 {
	// The object opens to the policy of PCR 7 and PCR 11 alone: the machine
	// key with no machine passphrase.
	None  = 0,
	// The object also needs the authorization value at
	// REGION_AUTHORIZATION: the keys of a named principal, whose value comes
	// from its passphrase, and the machine key under a machine passphrase,
	// whose value comes from it. The TPM counts each wrong value, and
	// refuses each try for a time after too many.
	Value = 1,
}

// A command of the client, as the kind of a command record of the ring.
Command :: enum u32 {
	None   = 0, // Not a command: Bad_Command.
	// The region holds the secret at REGION_SECRET; values[0] is the
	// word of an Authorization (with Authorization.Value, the value is at
	// REGION_AUTHORIZATION); another word is refused with Bad_Command. The
	// completion:
	// values[0] the bytes of the public area at REGION_PUBLIC_AREA,
	// values[1] the bytes of the private area at REGION_PRIVATE_AREA,
	// values[2] the PCRs of the policy (bit n: PCR n), values[3] the bytes
	// of the creation data at REGION_CREATION_DATA, values[4] the bytes of
	// the creation ticket at REGION_CREATION_TICKET. The secret is erased
	// from the region before the parts are written there.
	Seal   = 1,
	// values[0] to values[3]: the bytes of the public area, of the private
	// area, of the creation data and of the creation ticket, at their
	// places; values[4] the authorization, as for Seal. The service checks
	// the parts, has the TPM check the ticket (TPM2_CertifyCreation), and
	// checks that the policy of the object is the policy of the PCR values
	// of its creation data, with the attributes of its authorization; then
	// it unseals. The completion: the secret at REGION_SECRET, and
	// values[0] its bytes. After an unseal with Authorization.Value that the
	// TPM answered with another answer than a counted failure
	// (Authorization_Fails), the service sends TPM2_Shutdown(CLEAR): the system has
	// no orderly stop, and a TPM counts a failure at a start that follows a
	// use of such an object with no TPM2_Shutdown.
	Unseal = 2,
	// Only on the measure ring, from the root service: values[0..3] the
	// event digest of the start policy that starts (tpm2.start_policy_event_digest).
	// The service extends PCR 12 of the SHA-256 bank with it, then reads
	// PCR 12. The completion: values[0..3] the value of PCR 12 after the
	// extend, values[4] the count of the extends of this start. On the TPM
	// ring of a client it is refused with Bad_Command; past MEASURE_LIMIT
	// extends, with Measure_Limit.
	Measure_Start_Policy = 3,
	// values[0] the word of a Pin_Kind, values[1] the principal: 0 for the
	// machine key, the number of a named principal for its file. The service
	// reads the index of the pin. The completion: values[0] the bytes of its
	// payload at REGION_PIN (0 unless the state is Held or
	// Held_Other_Policy), values[1] the word of its Pin_State.
	Pin_Read = 4,
	// As Pin_Read, with values[2] the bytes of the new payload at
	// REGION_PIN: the size of the payload of its kind. The service checks
	// the payload and its change against the index (pin_write_refusal),
	// defines the index when it must, and writes it in a policy session of
	// PCR 7 and PCR 11. The completion: Ok, or Bad_Command with values[0]
	// the word of the Pin_Refusal (modus:contract/tpm_attestation) when the
	// payload or its change is refused; a refusal at the border has the
	// word 0, Pin_Refusal.None.
	Pin_Write = 5,
}

// The ring on which a request came: the border takes Seal and Unseal on the
// TPM ring of a client, and Measure_Start_Policy on the measure ring only.
Request_Source :: enum u8 {
	Client_Ring,
	Measure_Ring,
}

// The status of a request: the kind of its completion record.
Status :: enum u32 {
	Ok           = 0, // The request is done: the values are its results.
	Bad_Command  = 1, // The command is not known, or a value is out of its range.
	Refused      = 2, // The TPM answered with a response code that is not a success: values[0] has it, values[1] the code of the command of the TPM.
	Policy_Fails = 3, // The PCRs do not hold the values of the seal: another system, or another state of Secure Boot. values[0] is the response code.
	Device_Error = 4, // The interface gave no answer within its bound, or an answer that is not whole: values[0] says which step.
	// Unseal: the object does not prove that this TPM made it under the PCR
	// values of its policy: the TPM refuses its ticket with TPM_RC_TICKET
	// (values[0] the response code; another refusal of the check of the
	// ticket, as a lack of memory, is Refused), or its policy is not the
	// policy of its creation data,
	// or its attributes are not the attributes of a sealed object (values[0]
	// 0). Nothing is unsealed: a record that another system wrote.
	Not_Authentic = 5,
	// Unseal with Authorization.Value: the value is wrong, and the TPM
	// counted the failure (TPM_RC_AUTH_FAIL). values[0] is the response code.
	Authorization_Fails = 6,
	// Unseal with Authorization.Value: the TPM refuses each try for now, as
	// it counted too many failures (TPM_RC_LOCKOUT). The PCRs and the value
	// were not checked. values[0] is the response code.
	Locked_Out = 7,
	// Measure_Start_Policy: MEASURE_LIMIT extends ran in this start, and
	// PCR 12 takes no more. values[0] is the count of the extends.
	Measure_Limit = 8,
}

// The step of a request at which the interface failed, in values[0] of a
// completion Device_Error. Its word crosses the ring, so each value is
// explicit.
Device_Step :: enum u64 {
	None     = 0, // The interface did not fail: no completion Device_Error has it.
	Locality = 1, // The TPM did not give locality 0.
	Ready    = 2, // The TPM did not become ready for a command.
	Start    = 3, // The TPM did not end the command.
	Answer   = 4, // The answer does not fit its buffer, or the TPM reported a fatal error.
}

// The words of each step, for the log of a client.
@(rodata)
device_step_words := [Device_Step]string {
	.None     = "no step",
	.Locality = "the request of locality 0",
	.Ready    = "the wait until the TPM is ready",
	.Start    = "the end of the command",
	.Answer   = "the read of the answer",
}

// The border of the ring: a word becomes its member here only, and a word
// that names no member is refused. The service answers a refused command
// or authorization with Bad_Command; a client logs a refused status or
// step with its number.

command_of_word :: proc "contextless" (word: u32) -> (command: Command, ok: bool) {
	for member in Command {
		if u32(member) == word {
			return member, true
		}
	}
	return {}, false
}

authorization_of_word :: proc "contextless" (word: u64) -> (authorization: Authorization, ok: bool) {
	for member in Authorization {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

status_of_word :: proc "contextless" (word: u32) -> (status: Status, ok: bool) {
	for member in Status {
		if u32(member) == word {
			return member, true
		}
	}
	return {}, false
}

// A request of the ring, past its border.
Request :: struct {
	command:       Command,
	authorization: Authorization, // .None for Measure_Start_Policy, Pin_Read and Pin_Write.
}

// request_of_record is the border of the service: the command of a record,
// the ring it came on, and its authorization (values[0] of Seal, values[4]
// of Unseal). A kind that names no command, the kind of None, a command of
// the other ring, or an authorization that names none gives Bad_Command;
// the service then does no work. It reads and changes no state.
request_of_record :: proc "contextless" (kind: u32, values: [7]u64, source: Request_Source) -> (request: Request, status: Status) {
	command, command_ok := command_of_word(kind)
	if !command_ok {
		return {}, .Bad_Command
	}
	authorization_word: u64
	switch command {
	case .None:
		return {}, .Bad_Command
	case .Pin_Read, .Pin_Write:
		// The pins are the work of unlock: the root service never asks.
		if source != .Client_Ring {
			return {}, .Bad_Command
		}
		if _, pin_ok := pin_request_of_values(command, values); !pin_ok {
			return {}, .Bad_Command
		}
		return {command = command, authorization = .None}, .Ok
	case .Seal, .Unseal:
		if source != .Client_Ring {
			return {}, .Bad_Command
		}
		authorization_word = command == .Seal ? values[0] : values[4]
	case .Measure_Start_Policy:
		// A client of the TPM ring never extends a PCR: only the root
		// service holds the measure ring.
		if source != .Measure_Ring {
			return {}, .Bad_Command
		}
		return {command = .Measure_Start_Policy, authorization = .None}, .Ok
	}
	authorization, authorization_ok := authorization_of_word(authorization_word)
	if !authorization_ok {
		return {}, .Bad_Command
	}
	return {command = command, authorization = authorization}, .Ok
}

// measure_refusal decides one Measure_Start_Policy from the count of the
// extends that ran in this start: Measure_Limit from MEASURE_LIMIT on, and
// for a count that no start can reach (a negative one); else Ok. The service
// counts each extend that it sends, before its answer: the TPM can take an
// extend whose answer the interface lost.
measure_refusal :: proc "contextless" (extends_done: int) -> Status {
	if extends_done < 0 || extends_done >= MEASURE_LIMIT {
		return .Measure_Limit
	}
	return .Ok
}

device_step_of_word :: proc "contextless" (word: u64) -> (step: Device_Step, ok: bool) {
	for member in Device_Step {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}
