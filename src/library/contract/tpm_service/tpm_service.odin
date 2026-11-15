// The contract of the TPM service: what the program `tpm` and its one
// client, `unlock`, agree on (src/md/features/tpm_sealed_machine_key.md).
//
// The TPM service is the device service of the TPM of the machine. It seals
// 32 secret bytes to the values of PCR 7 and PCR 11, and unseals them only
// while those PCRs hold the same values: the same system, measured by the
// boot program, with the same state of Secure Boot.
//
// The client and the service share two memory objects, which the root
// service makes and gives to both:
//
//   the TPM ring     a ring (package ring). One command record is one
//                    request: Seal or Unseal.
//   the TPM region   one page. The bytes of a request and of its answer:
//                    the secret, and the two areas of a sealed object.
//
// The client sends one command and waits for its completion before it
// sends the next one: the region holds the bytes of one request. The
// service builds each command of the TPM itself; a client sends no raw
// command, so no client extends a PCR or clears the TPM.
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

// The handles of the context of the service: the ring, the region, and the
// page of the registers of the CRB interface of the TPM.
SERVICE_RING :: 0
SERVICE_REGION :: 1
SERVICE_REGISTERS :: 2
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
AREA_LIMIT :: 512 // The bytes of the place of each part.

// A command of the client, as the kind of a command record of the ring.
Command :: enum u32 {
	None   = 0, // Not a command: Bad_Command.
	// The region holds the secret at REGION_SECRET. The completion:
	// values[0] the bytes of the public area at REGION_PUBLIC_AREA,
	// values[1] the bytes of the private area at REGION_PRIVATE_AREA,
	// values[2] the PCRs of the policy (bit n: PCR n), values[3] the bytes
	// of the creation data at REGION_CREATION_DATA, values[4] the bytes of
	// the creation ticket at REGION_CREATION_TICKET. The secret is erased
	// from the region before the parts are written there.
	Seal   = 1,
	// values[0] to values[3]: the bytes of the public area, of the private
	// area, of the creation data and of the creation ticket, at their
	// places. The service checks the parts, has the TPM check the ticket
	// (TPM2_CertifyCreation), and checks that the policy of the object is
	// the policy of the PCR values of its creation data; then it unseals.
	// The completion: the secret at REGION_SECRET, and values[0] its bytes.
	Unseal = 2,
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
}

// The steps of a request at which the interface failed, in values[0] of a
// completion Device_Error.
DEVICE_STEP_LOCALITY :: 1 // The TPM did not give locality 0.
DEVICE_STEP_READY :: 2 // The TPM did not become ready for a command.
DEVICE_STEP_START :: 3 // The TPM did not end the command.
DEVICE_STEP_ANSWER :: 4 // The answer does not fit its buffer, or the TPM reported a fatal error.
