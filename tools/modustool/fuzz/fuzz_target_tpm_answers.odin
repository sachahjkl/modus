package fuzz

import "core:slice"
import info "modus:contract/boot_info"
import "modus:support/tpm2"

// The fuzz target of the answers of the TPM (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the TPM service and the boot program
// read each answer of a device. Each reader checks each size against the
// bytes that came before it uses it.

// fuzz_inside says if a slice lies in the bytes of another one.
@(private = "file")
fuzz_inside :: proc(part, whole: []u8) -> bool {
	if len(part) == 0 {
		return true
	}
	start := uintptr(raw_data(part))
	first := uintptr(raw_data(whole))
	return start >= first && start + uintptr(len(part)) <= first + uintptr(len(whole))
}

// fuzz_tpm_answers_execute gives the input to each reader of an answer.
// Each one agrees with the check of the header: a refused header gives
// the problem of the header and no value; a refusal of a field gives no
// value; an accepted answer gives values of their sizes, and slices inside
// the answer. No reader writes the answer.
fuzz_tpm_answers_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	_, header_code, header_problem := tpm2.answer_begin(input)
	// A header that fits is a success exactly when its code says so.
	if header_problem > max(tpm2.Answer_Problem) || header_problem == .None && header_code != tpm2.RESPONSE_SUCCESS || header_problem == .Refused && header_code == tpm2.RESPONSE_SUCCESS {
		return fuzz_broken(.Contract, "answer_begin gives %v with the code %x", header_problem, header_code)
	}
	// The problem of an answer is the problem of its header, or Malformed
	// past an accepted header.
	agrees :: proc(problem, header_problem: tpm2.Answer_Problem) -> bool {
		return header_problem != .None ? problem == header_problem : problem != .Refused
	}
	status_code, status_problem := tpm2.status_answer(input)
	if status_code != header_code || status_problem != header_problem {
		return fuzz_broken(.Two_Readers, "status_answer gives %v and answer_begin %v", status_problem, header_problem)
	}
	handle, _, handle_problem := tpm2.handle_answer(input)
	if !agrees(handle_problem, header_problem) || handle_problem != .None && handle != 0 {
		return fuzz_broken(.Contract, "handle_answer gives %v and the handle %x", handle_problem, handle)
	}
	digest, _, digest_problem := tpm2.digest_answer(input)
	if !agrees(digest_problem, header_problem) || digest_problem != .None && digest != ([tpm2.DIGEST_SIZE]u8{}) {
		return fuzz_broken(.Contract, "digest_answer gives %v and a digest", digest_problem)
	}
	secret, _, secret_problem := tpm2.unseal_answer(input)
	if !agrees(secret_problem, header_problem) || secret_problem != .None && secret != nil || secret_problem == .None && (len(secret) != tpm2.SECRET_SIZE || !fuzz_inside(secret, input)) {
		return fuzz_broken(.Contract, "unseal_answer gives %v and a secret of %d bytes", secret_problem, len(secret))
	}
	bits, _, bits_problem := tpm2.nv_read_answer(input)
	if !agrees(bits_problem, header_problem) || bits_problem != .None && bits != 0 {
		return fuzz_broken(.Contract, "nv_read_answer gives %v and the bits %x", bits_problem, bits)
	}
	if verdict := fuzz_tpm_create_check(input, header_problem); verdict.oracle != .None {
		return verdict
	}
	if verdict := fuzz_tpm_floor_check(input, header_problem, bits_problem, bits); verdict.oracle != .None {
		return verdict
	}
	// The properties: each count that the service can ask, from two first
	// properties.
	for first in ([2]u32{tpm2.PROPERTY_PERMANENT, tpm2.PROPERTY_LOCKOUT_COUNTER}) {
		for count in 0 ..= tpm2.COUNT_LIMIT_PROPERTIES {
			values: [tpm2.COUNT_LIMIT_PROPERTIES]u32
			for &value in values {
				value = max(u32)
			}
			_, problem := tpm2.properties_answer(input, first, values[:count])
			if !agrees(problem, header_problem) {
				return fuzz_broken(.Contract, "properties_answer gives %v past a header of %v", problem, header_problem)
			}
			for value, index in values[:count] {
				if problem != .None && value != 0 {
					return fuzz_broken(.Contract, "properties_answer refuses with %v and keeps the value %d", problem, index)
				}
			}
			for value in values[count:] {
				if value != max(u32) {
					return fuzz_broken(.Contract, "properties_answer writes past its %d values", count)
				}
			}
		}
	}
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "a reader changed the bytes of the answer")
	}
	return FUZZ_PASSED
}

// fuzz_tpm_create_check: the answer of TPM2_Create gives areas within their
// limits, a ticket of its form and a creation data with the digest of the
// PCRs, each inside the answer; a refusal gives none.
@(private = "file")
fuzz_tpm_create_check :: proc(input: []u8, header_problem: tpm2.Answer_Problem) -> Fuzz_Verdict {
	created, _, problem := tpm2.create_answer(input)
	if header_problem != .None && problem != header_problem || header_problem == .None && problem == .Refused {
		return fuzz_broken(.Contract, "create_answer gives %v past a header of %v", problem, header_problem)
	}
	if problem != .None {
		if created.private_area != nil || created.public_area != nil || created.creation_data != nil || created.creation_ticket != nil {
			return fuzz_broken(.Contract, "create_answer refuses with %v and gives areas", problem)
		}
		return FUZZ_PASSED
	}
	for part in ([4][]u8{created.private_area, created.public_area, created.creation_data, created.creation_ticket}) {
		if !fuzz_inside(part, input) {
			return fuzz_broken(.Contract, "create_answer gives a part outside the answer")
		}
	}
	if !tpm2.area_fits(created.private_area, tpm2.PRIVATE_AREA_LIMIT) || len(created.public_area) > tpm2.PUBLIC_AREA_LIMIT || !tpm2.ticket_fits(created.creation_ticket) {
		return fuzz_broken(.Contract, "create_answer gives areas of %d and %d bytes and a ticket of %d", len(created.private_area), len(created.public_area), len(created.creation_ticket))
	}
	pcr_digest, digest_ok := tpm2.creation_data_pcr_digest(created.creation_data)
	if !digest_ok {
		return fuzz_broken(.Two_Readers, "create_answer accepts a creation data that creation_data_pcr_digest refuses")
	}
	_ = tpm2.creation_hash(created.creation_data)
	for authorized in ([2]bool{false, true}) {
		policy := tpm2.sealed_object_policy(&pcr_digest, authorized)
		_ = tpm2.sealed_public_check(created.public_area, &policy, tpm2.sealed_object_attributes(authorized))
	}
	return FUZZ_PASSED
}

// fuzz_tpm_floor_check: the public area of an index has a policy within its
// limit, and each state that the boot program decides from the answers
// names a member with its step.
@(private = "file")
fuzz_tpm_floor_check :: proc(input: []u8, header_problem: tpm2.Answer_Problem, bits_problem: tpm2.Answer_Problem, bits: u64) -> Fuzz_Verdict {
	public, code, problem := tpm2.nv_public_answer(input)
	if header_problem != .None && problem != header_problem || header_problem == .None && problem == .Refused {
		return fuzz_broken(.Contract, "nv_public_answer gives %v past a header of %v", problem, header_problem)
	}
	if problem != .None && public != (tpm2.Nv_Public{}) || public.policy_size < 0 || public.policy_size > tpm2.NV_POLICY_LIMIT {
		return fuzz_broken(.Contract, "nv_public_answer gives %v and a policy of %d bytes", problem, public.policy_size)
	}
	pcr_7_value: [tpm2.DIGEST_SIZE]u8
	policy := tpm2.floor_policy_digest(&pcr_7_value)
	index := public.index
	state := tpm2.floor_state_of_public(problem, code, &public, index, &policy)
	if state > max(info.Floor_State) || state == .Held && !tpm2.floor_public_check(&public, index, &policy) {
		return fuzz_broken(.Contract, "floor_state_of_public gives %v", state)
	}
	_ = tpm2.floor_step_of(state)
	read_state, floor := tpm2.floor_state_of_read(bits_problem, code, bits)
	if read_state > max(info.Floor_State) || read_state != .Held && floor != 0 || read_state == .Held && floor != tpm2.floor_of_bits(bits) || floor > 64 {
		return fuzz_broken(.Contract, "floor_state_of_read gives %v and the floor %d", read_state, floor)
	}
	_ = tpm2.floor_step_of(read_state)
	return FUZZ_PASSED
}

// The writer of the seeds: each number big-endian, as the TPM writes it.
@(private = "file")
Fuzz_Tpm_Writer :: struct {
	bytes: [dynamic]u8,
}

@(private = "file")
fuzz_tpm_put :: proc(writer: ^Fuzz_Tpm_Writer, size: int, value: u64) {
	for index in 0 ..< size {
		append(&writer.bytes, u8(value >> (8 * u64(size - 1 - index))))
	}
}

@(private = "file")
fuzz_tpm_put_sized :: proc(writer: ^Fuzz_Tpm_Writer, bytes: []u8) {
	fuzz_tpm_put(writer, 2, u64(len(bytes)))
	append(&writer.bytes, ..bytes)
}

// fuzz_tpm_answer_of gives an answer: its header with its size, then its
// fields.
@(private = "file")
fuzz_tpm_answer_of :: proc(tag: u16, code: u32, fields: []u8) -> []u8 {
	writer: Fuzz_Tpm_Writer
	fuzz_tpm_put(&writer, 2, u64(tag))
	fuzz_tpm_put(&writer, 4, u64(10 + len(fields)))
	fuzz_tpm_put(&writer, 4, u64(code))
	append(&writer.bytes, ..fields)
	return writer.bytes[:]
}

fuzz_tpm_answers_seeds :: proc(seeds: ^[dynamic][]u8) {
	digest: [tpm2.DIGEST_SIZE]u8
	for &value, index in digest {
		value = u8(index)
	}
	// A handle, with the size of no parameters.
	handle: Fuzz_Tpm_Writer
	fuzz_tpm_put(&handle, 4, 0x8000_0001)
	fuzz_tpm_put(&handle, 4, 0)
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_SESSIONS, tpm2.RESPONSE_SUCCESS, handle.bytes[:]))
	// A digest, a secret and the bits of a floor.
	sized: Fuzz_Tpm_Writer
	fuzz_tpm_put_sized(&sized, digest[:])
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_NO_SESSIONS, tpm2.RESPONSE_SUCCESS, sized.bytes[:]))
	unsealed: Fuzz_Tpm_Writer
	fuzz_tpm_put(&unsealed, 4, 2 + tpm2.SECRET_SIZE)
	fuzz_tpm_put_sized(&unsealed, digest[:tpm2.SECRET_SIZE])
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_SESSIONS, tpm2.RESPONSE_SUCCESS, unsealed.bytes[:]))
	floor: Fuzz_Tpm_Writer
	fuzz_tpm_put(&floor, 4, 2 + tpm2.FLOOR_DATA_SIZE)
	fuzz_tpm_put_sized(&floor, digest[:tpm2.FLOOR_DATA_SIZE])
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_SESSIONS, tpm2.RESPONSE_SUCCESS, floor.bytes[:]))
	// The four properties of the lockout.
	properties: Fuzz_Tpm_Writer
	append(&properties.bytes, 0)
	fuzz_tpm_put(&properties, 4, u64(tpm2.CAPABILITY_TPM_PROPERTIES))
	fuzz_tpm_put(&properties, 4, u64(tpm2.COUNT_LIMIT_PROPERTIES))
	for index in 0 ..< tpm2.COUNT_LIMIT_PROPERTIES {
		fuzz_tpm_put(&properties, 4, u64(tpm2.PROPERTY_LOCKOUT_COUNTER) + u64(index))
		fuzz_tpm_put(&properties, 4, u64(index * 10))
	}
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_NO_SESSIONS, tpm2.RESPONSE_SUCCESS, properties.bytes[:]))
	// The public area of a floor, then its name.
	area: Fuzz_Tpm_Writer
	fuzz_tpm_put(&area, 4, 0x0100_0001)
	fuzz_tpm_put(&area, 2, u64(tpm2.ALGORITHM_SHA256))
	fuzz_tpm_put(&area, 4, u64(tpm2.FLOOR_ATTRIBUTES | tpm2.NV_WRITTEN))
	pcr_7_value: [tpm2.DIGEST_SIZE]u8
	policy := tpm2.floor_policy_digest(&pcr_7_value)
	fuzz_tpm_put_sized(&area, policy[:])
	fuzz_tpm_put(&area, 2, tpm2.FLOOR_DATA_SIZE)
	public: Fuzz_Tpm_Writer
	fuzz_tpm_put_sized(&public, area.bytes[:])
	fuzz_tpm_put_sized(&public, digest[:])
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_NO_SESSIONS, tpm2.RESPONSE_SUCCESS, public.bytes[:]))
	append(seeds, fuzz_tpm_create_seed(&digest))
	// Refusals of the header: a code of a refusal, a size one byte long,
	// another tag, and one byte short of a header.
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_SESSIONS, tpm2.RESPONSE_FORMAT_ONE | tpm2.RESPONSE_HANDLE, nil))
	long := fuzz_tpm_answer_of(tpm2.TAG_NO_SESSIONS, tpm2.RESPONSE_SUCCESS, nil)
	long[5] += 1
	append(seeds, long)
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_CREATION, tpm2.RESPONSE_SUCCESS, nil))
	append(seeds, fuzz_tpm_answer_of(tpm2.TAG_NO_SESSIONS, tpm2.RESPONSE_SUCCESS, nil)[:9])
}

// fuzz_tpm_create_seed gives an answer of TPM2_Create whose public area has
// the policy of the PCRs of its creation data.
@(private = "file")
fuzz_tpm_create_seed :: proc(pcr_digest: ^[tpm2.DIGEST_SIZE]u8) -> []u8 {
	// A local copy: the seed slices its bytes.
	digest := pcr_digest^
	creation: Fuzz_Tpm_Writer
	fuzz_tpm_put(&creation, 4, 1)
	fuzz_tpm_put(&creation, 2, u64(tpm2.ALGORITHM_SHA256))
	selection := tpm2.PCR_SELECTION
	append(&creation.bytes, u8(len(selection)))
	append(&creation.bytes, ..selection[:])
	fuzz_tpm_put_sized(&creation, digest[:])
	append(&creation.bytes, 0) // The locality.
	fuzz_tpm_put(&creation, 2, u64(tpm2.ALGORITHM_SHA256))
	fuzz_tpm_put_sized(&creation, digest[:])
	fuzz_tpm_put_sized(&creation, digest[:])
	fuzz_tpm_put_sized(&creation, nil)
	policy := tpm2.sealed_object_policy(&digest, false)
	public: Fuzz_Tpm_Writer
	fuzz_tpm_put(&public, 2, u64(tpm2.ALGORITHM_KEYED_HASH))
	fuzz_tpm_put(&public, 2, u64(tpm2.ALGORITHM_SHA256))
	fuzz_tpm_put(&public, 4, u64(tpm2.SEALED_OBJECT_ATTRIBUTES))
	fuzz_tpm_put_sized(&public, policy[:])
	fuzz_tpm_put(&public, 2, u64(tpm2.ALGORITHM_NULL))
	fuzz_tpm_put_sized(&public, digest[:])
	parameters: Fuzz_Tpm_Writer
	fuzz_tpm_put_sized(&parameters, digest[:16]) // The private area.
	fuzz_tpm_put_sized(&parameters, public.bytes[:])
	fuzz_tpm_put_sized(&parameters, creation.bytes[:])
	fuzz_tpm_put_sized(&parameters, digest[:]) // The creation hash.
	fuzz_tpm_put(&parameters, 2, u64(tpm2.TAG_CREATION))
	fuzz_tpm_put(&parameters, 4, u64(tpm2.HANDLE_OWNER))
	fuzz_tpm_put_sized(&parameters, digest[:])
	fields: Fuzz_Tpm_Writer
	fuzz_tpm_put(&fields, 4, u64(len(parameters.bytes)))
	append(&fields.bytes, ..parameters.bytes[:])
	return fuzz_tpm_answer_of(tpm2.TAG_SESSIONS, tpm2.RESPONSE_SUCCESS, fields.bytes[:])
}
