package cache_server

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import info "modus:contract/boot_info"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"
import "modustool:foundation"

// A cache-serve on loopback, on its own thread.
@(private = "file")
Loopback_Server :: struct {
	server:   Cache_Server,
	listener: net.TCP_Socket,
	endpoint: string,
	worker:   ^thread.Thread,
}

@(private = "file")
loopback_server_start :: proc(t: ^testing.T, directory: string, authorized: [][object_cache.PUBLIC_KEY_SIZE]u8) -> ^Loopback_Server {
	running := new(Loopback_Server)
	open_ok: bool
	running.server, open_ok = cache_server_open(directory, authorized)
	testing.expect(t, open_ok)
	listen_error: net.Network_Error
	running.listener, listen_error = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_error, nil)
	bound, _ := net.bound_endpoint(running.listener)
	running.endpoint = strings.clone(net.endpoint_to_string(bound, context.temp_allocator))
	running.worker = thread.create_and_start_with_poly_data(running, proc(running: ^Loopback_Server) {
		cache_server_serve_listener(&running.server, running.listener)
	})
	return running
}

@(private = "file")
loopback_server_stop :: proc(running: ^Loopback_Server) {
	sync.atomic_store(&running.server.stop, true)
	_ = net.shutdown(running.listener, .Both)
	net.close(running.listener)
	thread.join(running.worker)
	thread.destroy(running.worker)
	cache_server_destroy(&running.server)
	delete(running.endpoint)
	free(running)
}

// A server that reads one request whole, answers fixed bytes, ends its side,
// and waits for the client to close: a hostile object cache.
@(private = "file")
Fake_Server :: struct {
	listener: net.TCP_Socket,
	endpoint: string,
	answer:   []u8,
	worker:   ^thread.Thread,
}

@(private = "file")
fake_server_start :: proc(t: ^testing.T, answer: []u8) -> ^Fake_Server {
	fake := new(Fake_Server)
	fake.answer = answer
	listen_error: net.Network_Error
	fake.listener, listen_error = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_error, nil)
	bound, _ := net.bound_endpoint(fake.listener)
	fake.endpoint = strings.clone(net.endpoint_to_string(bound, context.temp_allocator))
	fake.worker = thread.create_and_start_with_poly_data(fake, proc(fake: ^Fake_Server) {
		client, _, accept_error := net.accept_tcp(fake.listener)
		if accept_error != nil {
			return
		}
		defer net.close(client)
		_ = net.set_option(client, .Receive_Timeout, foundation.HANG_BOUND)
		header: [object_cache.FRAME_HEADER_SIZE]u8
		if ok, _ := tcp_read_exact(client, header[:], false); !ok {
			return
		}
		body := make([]u8, int(byte_order.read_u32_little_endian(header[:], 8)))
		defer delete(body)
		if len(body) > 0 {
			if ok, _ := tcp_read_exact(client, body, false); !ok {
				return
			}
		}
		_ = tcp_write_all(client, fake.answer)
		_ = net.shutdown(client, .Send)
		// Wait for the close of the client: a close with bytes unread would
		// send a reset, which can remove the answer before the client reads it.
		drain: [256]u8
		for {
			count, receive_error := net.recv_tcp(client, drain[:])
			if receive_error != nil || count == 0 {
				return
			}
		}
	})
	return fake
}

@(private = "file")
fake_server_stop :: proc(fake: ^Fake_Server) {
	thread.join(fake.worker)
	thread.destroy(fake.worker)
	net.close(fake.listener)
	delete(fake.endpoint)
	free(fake)
}

// fake_get_object asks a fake server for one blob and gives the outcome.
@(private = "file")
fake_get_object :: proc(t: ^testing.T, answer: []u8, asked: blake3.Hash) -> Cache_Client_Outcome {
	fake := fake_server_start(t, answer)
	defer fake_server_stop(fake)
	client, connect_outcome := cache_client_connect(fake.endpoint)
	testing.expect_value(t, connect_outcome, Cache_Client_Outcome.Done)
	defer cache_client_close(&client)
	payload, outcome := cache_client_get_object(&client, .Blob, asked)
	delete(payload)
	return outcome
}

@(private = "file")
answer_head :: proc(kind, status: u8, body_length: u32) -> (head: [object_cache.FRAME_HEADER_SIZE]u8) {
	head = {'M', 'O', 'C', 'R', object_cache.WIRE_VERSION, kind, status, 0, 0, 0, 0, 0}
	byte_order.write_u32_little_endian(head[:], 8, body_length)
	return head
}

@(private = "file")
encoded_answer :: proc(t: ^testing.T, response: ^object_cache.Cache_Response) -> []u8 {
	size, size_refusal := object_cache.encoded_response_size(response)
	testing.expect_value(t, size_refusal, object_cache.Wire_Refusal.None)
	frame := make([]u8, size, context.temp_allocator)
	_, refusal := object_cache.encode_response(response, frame)
	testing.expect_value(t, refusal, object_cache.Wire_Refusal.None)
	return frame
}

@(test)
a_cut_or_damaged_answer_is_refused_by_the_client :: proc(t: ^testing.T) {
	payload := transmute([]u8)string("the bytes of a blob")
	asked := blake3.hash(payload)

	// A head cut after 5 bytes, then the end of the connection.
	cut_head := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Ok), 0)
	testing.expect_value(t, fake_get_object(t, cut_head[:5], asked), Cache_Client_Outcome.Unreachable)

	// A wrong magic.
	bad_magic := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Not_Found), 0)
	bad_magic[0] = 'X'
	testing.expect_value(t, fake_get_object(t, bad_magic[:], asked), Cache_Client_Outcome.Damaged_Answer)

	// A version that is not 1.
	bad_version := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Not_Found), 0)
	bad_version[4] = 2
	testing.expect_value(t, fake_get_object(t, bad_version[:], asked), Cache_Client_Outcome.Damaged_Answer)

	// A kind and a status that name no member: 0, one past the last, the
	// largest byte.
	for word in ([3]u8{0, 6, 255}) {
		unknown_kind := answer_head(word, u8(object_cache.Cache_Response_Status.Not_Found), 0)
		testing.expect_value(t, fake_get_object(t, unknown_kind[:], asked), Cache_Client_Outcome.Damaged_Answer)
	}
	for word in ([3]u8{0, 8, 255}) {
		unknown_status := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), word, 0)
		testing.expect_value(t, fake_get_object(t, unknown_status[:], asked), Cache_Client_Outcome.Damaged_Answer)
	}

	// A body one byte past the bound, and the largest length: refused from
	// the head, before any allocation.
	for length in ([2]u32{u32(object_cache.MAX_RESPONSE_BODY_BYTES) + 1, max(u32)}) {
		oversize := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Ok), length)
		testing.expect_value(t, fake_get_object(t, oversize[:], asked), Cache_Client_Outcome.Damaged_Answer)
	}

	// A body cut short: the head says 8 + 19 bytes, 3 come.
	whole := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		payload      = payload,
	}
	whole_frame := encoded_answer(t, &whole)
	testing.expect_value(t, fake_get_object(t, whole_frame[:object_cache.FRAME_HEADER_SIZE + 3], asked), Cache_Client_Outcome.Unreachable)

	// An answer to another request.
	other_kind := object_cache.Cache_Response {
		request_kind = .Has,
		status       = .Ok,
	}
	testing.expect_value(t, fake_get_object(t, encoded_answer(t, &other_kind), asked), Cache_Client_Outcome.Damaged_Answer)

	// One bit of the payload changed: the server gives other bytes.
	changed := make([]u8, len(whole_frame), context.temp_allocator)
	copy(changed, whole_frame)
	changed[len(changed) - 1] ~= 0x01
	testing.expect_value(t, fake_get_object(t, changed, asked), Cache_Client_Outcome.Hash_Mismatch)

	// A tree for a blob.
	tree_buffer: [256]u8
	tree_bytes, tree_digest := make_test_tree(tree_buffer[:])
	as_tree := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Tree,
		payload      = tree_bytes,
	}
	testing.expect_value(t, fake_get_object(t, encoded_answer(t, &as_tree), tree_digest), Cache_Client_Outcome.Damaged_Answer)

	// Each refusal of the server is kept as its status.
	refused := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Bad_Hash), 0)
	testing.expect_value(t, fake_get_object(t, refused[:], asked), Cache_Client_Outcome.Server_Refused)
	absent := answer_head(u8(object_cache.Cache_Request_Kind.Get_Object), u8(object_cache.Cache_Response_Status.Not_Found), 0)
	testing.expect_value(t, fake_get_object(t, absent[:], asked), Cache_Client_Outcome.Not_Found)

	// Last: the whole answer.
	testing.expect_value(t, fake_get_object(t, whole_frame, asked), Cache_Client_Outcome.Done)
}

@(test)
a_has_answer_with_a_bit_past_the_question_is_refused :: proc(t: ^testing.T) {
	answer := object_cache.Cache_Response {
		request_kind   = .Has,
		status         = .Ok,
		present_bitset = 0b100,
	}
	fake := fake_server_start(t, encoded_answer(t, &answer))
	defer fake_server_stop(fake)
	client, _ := cache_client_connect(fake.endpoint)
	defer cache_client_close(&client)
	hashes := [2]blake3.Hash{blake3.hash(transmute([]u8)string("a")), blake3.hash(transmute([]u8)string("b"))}
	_, outcome := cache_client_has(&client, hashes[:])
	testing.expect_value(t, outcome, Cache_Client_Outcome.Damaged_Answer)
}

@(test)
a_realisation_is_kept_only_from_the_trusted_signer :: proc(t: ^testing.T) {
	trusted_key, trusted, _ := make_test_keypair(0x21)
	other_key, _, _ := make_test_keypair(0x42)
	recipe := blake3.hash(transmute([]u8)string("recipe"))
	output := blake3.hash(transmute([]u8)string("output"))

	// Another recipe than the one asked.
	elsewhere, _ := cache_client_realisation_sign(&trusted_key, blake3.hash(transmute([]u8)string("another recipe")), output, .Tree)
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &elsewhere), Cache_Client_Outcome.Damaged_Answer)

	// Another signer, whose signature verifies with its own key: the key of
	// the answer is never the trust.
	by_other, _ := cache_client_realisation_sign(&other_key, recipe, output, .Tree)
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &by_other), Cache_Client_Outcome.Untrusted_Signer)

	// The trusted key named, and the signature of another key.
	forged := by_other
	forged.signer_public_key = trusted
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &forged), Cache_Client_Outcome.Bad_Signature)

	// One bit of the output changed after the signature.
	changed, _ := cache_client_realisation_sign(&trusted_key, recipe, output, .Tree)
	changed.output_hash[31] ~= 0x01
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &changed), Cache_Client_Outcome.Bad_Signature)

	// The output kind changed after the signature.
	other_kind, _ := cache_client_realisation_sign(&trusted_key, recipe, output, .Tree)
	other_kind.output_kind = .Blob
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &other_kind), Cache_Client_Outcome.Bad_Signature)

	// Last: the realisation of the trusted signer.
	good, signed := cache_client_realisation_sign(&trusted_key, recipe, output, .Tree)
	testing.expect(t, signed)
	testing.expect_value(t, cache_client_realisation_check(recipe, trusted, &good), Cache_Client_Outcome.Done)
}

@(test)
the_client_refuses_a_request_before_it_leaves_the_host :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	key, public_key, _ := make_test_keypair(0x31)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	running := loopback_server_start(t, directory, authorized[:])
	defer loopback_server_stop(running)

	// An endpoint that is not host:port.
	for endpoint in ([5]string{"", "host:", ":5010", "a:05010", "-:1"}) {
		_, outcome := cache_client_connect(endpoint)
		testing.expect_value(t, outcome, Cache_Client_Outcome.Bad_Request)
	}
	client, connect_outcome := cache_client_connect(running.endpoint)
	testing.expect_value(t, connect_outcome, Cache_Client_Outcome.Done)
	defer cache_client_close(&client)

	// One byte past the bound of a blob, and bytes that are no tree.
	oversize := make([]u8, object_cache.MAX_OBJECT_PAYLOAD_BYTES + 1)
	defer delete(oversize)
	_, oversize_outcome := cache_client_put_object(&client, &key, .Blob, oversize)
	testing.expect_value(t, oversize_outcome, Cache_Client_Outcome.Too_Large)
	_, tree_outcome := cache_client_put_object(&client, &key, .Tree, transmute([]u8)string("no tree"))
	testing.expect_value(t, tree_outcome, Cache_Client_Outcome.Bad_Request)
	_, kind_outcome := cache_client_put_object(&client, &key, object_cache.Cache_Object_Kind(0), transmute([]u8)string("x"))
	testing.expect_value(t, kind_outcome, Cache_Client_Outcome.Bad_Request)

	// Has of no hash, and of one past 64.
	many: [object_cache.MAX_HAS_HASHES + 1]blake3.Hash
	_, none_outcome := cache_client_has(&client, many[:0])
	testing.expect_value(t, none_outcome, Cache_Client_Outcome.Bad_Request)
	_, past_outcome := cache_client_has(&client, many[:])
	testing.expect_value(t, past_outcome, Cache_Client_Outcome.Bad_Request)

	// The bound itself passes: a blob of exactly the bound.
	exact := make([]u8, object_cache.MAX_OBJECT_PAYLOAD_BYTES)
	defer delete(exact)
	_, exact_outcome := cache_client_put_object(&client, &key, .Blob, exact)
	testing.expect_value(t, exact_outcome, Cache_Client_Outcome.Done)
}

// A boot image of these files, in the layout of the loader: the header, the
// tables, then each file on a page boundary.
@(private = "file")
test_boot_image :: proc(names: []string, files: [][]u8, module_count: int) -> []u8 {
	image := make([dynamic]u8, context.temp_allocator)
	resize(&image, size_of(info.Image_Header) + len(files) * size_of(info.Image_Entry))
	entries := make([]info.Image_Entry, len(files), context.temp_allocator)
	for file, index in files {
		entries[index].hash = blake3.hash(file)
		entries[index].size = u64(len(file))
		copy(entries[index].name[:info.IMAGE_NAME_SIZE - 1], names[index])
		resize(&image, mem.align_forward_int(len(image), info.PAGE_SIZE))
		entries[index].offset = u64(len(image))
		append(&image, ..file)
	}
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(module_count), resource_count = u32(len(files) - module_count)}
	mem.copy(&image[0], &header, size_of(header))
	mem.copy(&image[size_of(header)], &entries[0], len(entries) * size_of(info.Image_Entry))
	return image[:]
}

@(private = "file")
TEST_IMAGE_NAMES :: [4]string{"kernel", "root", "console", "system_description"}

@(private = "file")
test_image_files :: proc() -> [4][]u8 {
	return {
		transmute([]u8)string("the kernel module of a test image"),
		transmute([]u8)string("the root service of a test image"),
		transmute([]u8)string("the root service of a test image"), // The same bytes twice: one object.
		transmute([]u8)string("a system description"),
	}
}

@(test)
the_cache_test_recipe_is_a_constant_that_each_reader_computes :: proc(t: ^testing.T) {
	first, first_ok := cache_test_recipe()
	second, second_ok := cache_test_recipe()
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.recipe_hash, second.recipe_hash)
	testing.expect_value(t, first.output_hash, second.output_hash)
	digest, refusal := tree_hash.tree_hash(first.output_bytes[:first.output_size])
	testing.expect_value(t, refusal, tree_hash.Tree_Refusal.None)
	testing.expect_value(t, digest, first.output_hash)
	recipe_digits := hash_to_hex(first.recipe_hash)
	output_digits := hash_to_hex(first.output_hash)
	fmt.printfln("the cache test recipe %s gives the tree %s", string(recipe_digits[:]), string(output_digits[:]))
}

@(test)
the_publication_of_a_release_on_loopback :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	publisher_key, publisher, _ := make_test_keypair(0x71)
	stranger_key, stranger, _ := make_test_keypair(0x13)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{publisher}
	running := loopback_server_start(t, directory, authorized[:])
	defer loopback_server_stop(running)
	// The server serves one connection at a time: the publisher closes its
	// connection before the reader opens one.
	client, connect_outcome := cache_client_connect(running.endpoint)
	testing.expect_value(t, connect_outcome, Cache_Client_Outcome.Done)

	names := TEST_IMAGE_NAMES
	files := test_image_files()
	image := test_boot_image(names[:], files[:], 3)

	// A key that the server does not authorise puts nothing.
	_, stranger_problem := cache_publish_release(&client, &stranger_key, image)
	testing.expect(t, strings.contains(stranger_problem, "does not authorise the key"))
	// A damaged image: one byte of a file changed after its entry.
	damaged := make([]u8, len(image), context.temp_allocator)
	copy(damaged, image)
	damaged[len(damaged) - 1] ~= 0x01
	_, damaged_problem := cache_publish_release(&client, &publisher_key, damaged)
	testing.expect(t, strings.contains(damaged_problem, "does not have the hash that its entry states"))
	// Bytes that are no boot image, and an entry outside the image.
	_, not_image_problem := cache_publish_release(&client, &publisher_key, transmute([]u8)string("not an image"))
	testing.expect(t, strings.contains(not_image_problem, "not a boot image"))
	outside := make([]u8, len(image), context.temp_allocator)
	copy(outside, image)
	entries := ([^]info.Image_Entry)(raw_data(outside[size_of(info.Image_Header):]))
	entries[0].offset = u64(len(outside))
	entries[0].size = 1
	_, outside_problem := cache_publish_release(&client, &publisher_key, outside)
	testing.expect(t, strings.contains(outside_problem, "points outside the image"))
	// Nothing of the refused publications is on the cache.
	refused_hashes := [3]blake3.Hash{blake3.hash(files[0]), blake3.hash(files[1]), blake3.hash(files[3])}
	present_before, _ := cache_client_has(&client, refused_hashes[:])
	testing.expect_value(t, present_before, u64(0))
	_, check_before := cache_verify_release(&client, publisher, image)
	testing.expect(t, strings.contains(check_before, "does not hold it"))

	// The publication: three distinct files, then the cache test recipe.
	report, problem := cache_publish_release(&client, &publisher_key, image)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, report.files, 3)
	testing.expect_value(t, report.put, 3)
	testing.expect_value(t, report.already_held, 0)

	// A second run puts nothing that the cache holds.
	again, again_problem := cache_publish_release(&client, &publisher_key, image)
	testing.expect_value(t, again_problem, "")
	testing.expect_value(t, again.put, 0)
	testing.expect_value(t, again.already_held, 3)

	// The check refuses another signer than the publisher.
	_, wrong_signer := cache_verify_release(&client, stranger, image)
	testing.expect(t, strings.contains(wrong_signer, "another key than the trusted signer"))
	cache_client_close(&client)

	// Each object and the realisation verify, from a second connection.
	reader, reader_outcome := cache_client_connect(running.endpoint)
	testing.expect_value(t, reader_outcome, Cache_Client_Outcome.Done)
	defer cache_client_close(&reader)
	checked, check_problem := cache_verify_release(&reader, publisher, image)
	testing.expect_value(t, check_problem, "")
	testing.expect_value(t, checked, 3)

	// A realisation of the recipe that a stranger signed, written on the
	// disk of the cache: the server serves it, its signature verifies with
	// its own key, and the client refuses it.
	recipe, _ := cache_test_recipe()
	planted, _ := cache_client_realisation_sign(&stranger_key, recipe.recipe_hash, recipe.output_hash, .Tree)
	planted_bytes: [object_cache.REALISATION_WIRE_SIZE]u8
	_, encode_refusal := object_cache.encode_realisation_record(&planted, planted_bytes[:])
	testing.expect_value(t, encode_refusal, object_cache.Wire_Refusal.None)
	recipe_digits := hash_to_hex(recipe.recipe_hash)
	planted_path, _ := store_path_for_hex(directory, .Realisations, string(recipe_digits[:]))
	testing.expect_value(t, os.write_entire_file(planted_path, planted_bytes[:]), nil)
	_, planted_problem := cache_verify_test_recipe(&reader, publisher)
	testing.expect(t, strings.contains(planted_problem, "another key than the trusted signer"))
}

@(test)
the_commands_cache_put_and_cache_get_on_loopback :: proc(t: ^testing.T) {
	directory := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	keys := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(keys)
		delete(keys)
	}
	_, publisher, seed := make_test_keypair(0x77)
	_, stranger, _ := make_test_keypair(0x19)
	seed_digits := hash_to_hex(seed)
	publisher_digits := hash_to_hex(publisher)
	stranger_digits := hash_to_hex(stranger)
	seed_path := fmt.aprintf("%s/cache_signing_key", keys)
	public_path := fmt.aprintf("%s/cache_signing_key.public", keys)
	stranger_path := fmt.aprintf("%s/stranger.public", keys)
	image_path := fmt.aprintf("%s/boot.image", keys)
	defer {
		delete(seed_path)
		delete(public_path)
		delete(stranger_path)
		delete(image_path)
	}
	testing.expect_value(t, os.write_entire_file(seed_path, transmute([]u8)fmt.tprintf("%s\n", string(seed_digits[:]))), nil)
	testing.expect_value(t, os.write_entire_file(public_path, transmute([]u8)fmt.tprintf("%s\n", string(publisher_digits[:]))), nil)
	testing.expect_value(t, os.write_entire_file(stranger_path, transmute([]u8)fmt.tprintf("%s\n", string(stranger_digits[:]))), nil)
	names := TEST_IMAGE_NAMES
	files := test_image_files()
	testing.expect_value(t, os.write_entire_file(image_path, test_boot_image(names[:], files[:], 3)), nil)

	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{publisher}
	running := loopback_server_start(t, directory, authorized[:])
	defer loopback_server_stop(running)
	endpoint := running.endpoint

	// The forms that the commands refuse.
	testing.expect_value(t, run_cache_put(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_put({endpoint, "--key", seed_path, "release"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_put({endpoint, "--key", seed_path, "tree", image_path}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_get({endpoint, "realisation", string(publisher_digits[:])}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_get({endpoint, "blob", "ABCD"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_get({endpoint, "test-recipe", "--signer", public_path, "--signer", public_path}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_cache_get({endpoint, "tree", string(publisher_digits[:])}), foundation.EXIT_USAGE)

	// A seed that other users can read is refused before any connection.
	testing.expect_value(t, os.chmod(seed_path, os.perm(0o644)), nil)
	testing.expect_value(t, run_cache_put({endpoint, "--key", seed_path, "release", image_path}), foundation.EXIT_FAILURE)
	testing.expect_value(t, os.chmod(seed_path, os.perm(0o600)), nil)

	// Nothing is on the cache yet.
	testing.expect_value(t, run_cache_get({endpoint, "test-recipe", "--signer", public_path}), foundation.EXIT_FAILURE)

	testing.expect_value(t, run_cache_put({endpoint, "--key", seed_path, "release", image_path}), 0)
	testing.expect_value(t, run_cache_get({endpoint, "release", image_path, "--signer", public_path}), 0)
	testing.expect_value(t, run_cache_get({endpoint, "test-recipe", "--signer", public_path}), 0)
	testing.expect_value(t, run_cache_get({endpoint, "test-recipe", "--signer", stranger_path}), foundation.EXIT_FAILURE)
	kernel_digits := hash_to_hex(blake3.hash(files[0]))
	testing.expect_value(t, run_cache_get({endpoint, "blob", string(kernel_digits[:])}), 0)
	recipe, _ := cache_test_recipe()
	recipe_digits := hash_to_hex(recipe.recipe_hash)
	testing.expect_value(t, run_cache_get({endpoint, "realisation", string(recipe_digits[:]), "--signer", public_path}), 0)
	testing.expect_value(t, run_cache_get({endpoint, "realisation", string(recipe_digits[:]), "--signer", stranger_path}), foundation.EXIT_FAILURE)
}
