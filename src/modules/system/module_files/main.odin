// The module file service: it stores a module file that a web server
// gives in the store `module_files` of its principal, and lists the files of
// that store with the hash of their bytes. A developer then adds a module
// to a machine that runs, with no disk from the tool
// (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// **What it is for.** The root service starts a disk process from the
// store `module_files` when the hash of its bytes is the hash that the
// principal names. This service puts a file in that store from the
// network, and gives the hash to type. It starts nothing: the root service
// checks the bytes at the start, so this service carries them as the
// storage service does, and does not choose what runs.
//
// **Start**: `connect("module_files")` in the console starts it, as the
// storage service starts. Then:
//
// ```
// module_files.receive("visitor", "/visitor")   the hash of the file that came
// module_files.list()                           the files, with their hashes
// start_from_disk("visitor", "<the hash>")
// ```
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store. The root service names a private store
//   by the name of its module, so the store of this module is the store
//   `module_files` of its principal.
// - **Network**: a client grant of TCP to one web server, 10.0.2.100 port
//   80: the address that QEMU gives to a server of the host.
// - **Serve**: the two exports for the console.
//
// The root service also gives the number of its principal in its context
// (disk_process.SERVICE_VALUE_PRINCIPAL): a caller of another principal
// is refused.
//
// **What a reader sees.** No window. The log has "module_files: serves the
// store module_files of principal 0, ...", one line for each file that it
// stores, and one line for each row of a list.
//
// The design: (src/md/features/processes_from_a_disk.md, "How the file
// reaches the disk").
package module_files

import "internal:module_files/module_files_core"
import "modus:contract/blake3"
import "modus:contract/storage_status"
import "modus:contract/datagram"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:network"
import "modus:random"
import "modus:storage"
import "modus:system"
import "modus:tcp"
import "modus:web"

// The buffers of the 4 connections (96 pages), and its tables. A file
// passes in pieces of WRITE_PIECE bytes, so its size costs no memory.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 160, processes = 1, threads = 1}

// The connections at one time: one for the call that runs, and the ones
// that wait in TIME-WAIT after earlier calls.
CAPACITY :: 4
SEND_SIZE :: 64 * 1024
RECEIVE_SIZE :: 32 * 1024
BUFFER_PAGES :: CAPACITY * (SEND_SIZE + RECEIVE_SIZE) / system.PAGE_SIZE

// The datagram region: 256 places of 2048 bytes. Places 0 to 95 receive
// segments; the others hold segments to send.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info.


// The bytes of the path of a request.
PATH_LIMIT :: 200

// The bytes of one piece of a file: one write_range of the stream
// (module_files_core, file_stream.odin).
WRITE_PIECE :: module_files_core.WRITE_PIECE

// The pages of the listing of the store that one list reads at most. A
// storage service that never gives an empty page ends there.
LIST_PAGE_LIMIT :: 1024

// One row of module_files.list().
Module_File_Row :: struct {
	name:  [64]u8, // The name of the entry: the nickname of the file.
	bytes: i64, // The bytes of the object.
	hash:  [72]u8, // The 64 hexadecimal digits of the BLAKE3 hash of its bytes; empty when its bytes did not come or pass 64 MiB.
}

table: tcp.Table
connections: [CAPACITY]tcp.Connection
endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
segments: [PLACE_COUNT - RECEIVE_PLACES]tcp.Outgoing
events: [CAPACITY]tcp.Event
// Commands that the ring did not take: they go at the next pass. Each
// command names one place, and a place is in one command at most, so the
// held commands never pass PLACE_COUNT.
held: [PLACE_COUNT]ring.Record
held_count: int

// The one remote of the grant.
remote_address: u32
remote_port: u16

store_client: storage.Client
store_principal: u64 // The principal of the store: the only principal whose callers this service serves.
piece: [WRITE_PIECE]u8 // The bytes of one piece of a file, in the memory of this service.
service: system.Service
process_generator: random.Generator // The random generator of this process, from the seed of its starter.

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Info, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

// command_push_or_hold puts a command in the ring; a full ring keeps it for
// the next pass, so that no Send and no Receive is lost with its place.
command_push_or_hold :: proc "contextless" (record: ring.Record) {
	if held_count == 0 && ring.push(&endpoint.commands, record) {
		return
	}
	if held_count == len(held) {
		fail("the held commands passed their proven bound")
	}
	held[held_count] = record
	held_count += 1
}

held_commands_push :: proc "contextless" () {
	done := 0
	for done < held_count && ring.push(&endpoint.commands, held[done]) {
		done += 1
	}
	copy(held[:], held[done:held_count])
	held_count -= done
}

post :: proc "contextless" (place: u32) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

// network_step reads the completions of the endpoint, runs one step of the
// table, and sends its segments. It never waits. deadline is the next
// timer of TCP, in microseconds; worked says if anything happened.
network_step :: proc "contextless" () -> (deadline: u64, worked: bool) {
	held_commands_push()
	incoming: [RECEIVE_PLACES]tcp.Incoming
	used: [RECEIVE_PLACES]u32
	count := 0
	for record in system.receive(&endpoint.completions) {
		switch {
		case record.tag < RECEIVE_PLACES:
			if record.kind == u32(call_outcome.Call_Outcome.Succeeded) && count < len(incoming) {
				incoming[count] = {remote_address = u32(record.values[2]), segment = place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)]}
				used[count] = record.tag
				count += 1
			} else {
				post(record.tag)
			}
		case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT && free_count < len(free_places):
			free_places[free_count] = record.tag - SEND_TAG
			free_count += 1
		}
	}
	now := system.nanoseconds() / 1000
	output := tcp.Output{memory = region, place_size = PLACE_SIZE, places = free_places[:free_count], segments = segments[:]}
	event_count: int
	deadline, event_count = tcp.step(&table, incoming[:count], now, &output, events[:])
	for item in segments[:output.count] {
		command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + item.place, values = {0 = u64(item.place) * PLACE_SIZE, 1 = u64(item.length), 2 = u64(item.remote_address), 3 = u64(item.remote_port)}})
	}
	// The places that the step used are not free until their Send completes.
	free_count -= output.count
	copy(free_places[:free_count], free_places[output.count:output.count + free_count])
	for place in used[:count] {
		post(place)
	}
	system.wake_reader(&endpoint.commands)
	return deadline, count > 0 || output.count > 0 || event_count > 0
}

// pump runs one step of the network inside a call, and waits until a
// segment comes, the next timer of TCP, or 50 ms.
pump :: proc "contextless" () {
	wait := system.wait_begin()
	deadline, worked := network_step()
	if worked || !ring.empty(&endpoint.completions) {
		return
	}
	system.wait_records(&wait, &endpoint.completions)
	limit := system.time() + 50
	if deadline != max(u64) {
		limit = min(limit, deadline / 1000 + 1)
	}
	system.wait_end(&wait, limit)
}

// caller_allowed says if the caller of the export that runs acts for the
// principal of the store: a service that writes the store of a principal
// for any caller is a confused deputy.
caller_allowed :: proc "contextless" () -> bool {
	caller := system.service_caller()
	if caller == nil {
		return false
	}
	acts := caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
	principal := (caller.grant & isolated.CALLER_PRINCIPAL_MASK) >> isolated.CALLER_PRINCIPAL_SHIFT
	return acts && principal == store_principal
}

// connection_end ends the connection of a call: a close when the data
// went both ways, else a reset. The loop of the process runs its timers
// after the call.
connection_end :: proc "contextless" (index: int) {
	switch connections[index].state {
	case .Established, .Close_Wait:
		tcp.close(&table, index)
	case .Closed, .Time_Wait, .Fin_Wait_1, .Fin_Wait_2, .Closing, .Last_Ack:
	case .Syn_Sent, .Syn_Received:
		tcp.abort(&table, index)
	}
}

// remote_ended says if no more byte can come on a connection: the remote
// closed or reset it, and the process read each byte that came.
remote_ended :: proc "contextless" (index: int) -> bool {
	connection := &connections[index]
	return (connection.state == .Closed || connection.closed_by_remote) && connection.receive_ready == 0
}

// network_failure writes the line of a failure of the fetch, and gives the
// outcome of the export. The web server is a party that the call needs: a
// server that did not answer, or that gave an answer that this service
// does not take, leaves the store as it was.
network_failure :: proc "contextless" (error: ^errors.Error_Record, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit, path: string, why: string, found: i64 = 0) -> call_outcome.Call_Outcome {
	system.log_fact(.Info, Get_Failed{problem = value_kinds.text_field(why, GET_PROBLEM_FIELD_BYTES)}, path)
	failed, _ := call_outcome.fail(error, outcome, kind, unit, 2, 0, 0, found)
	return failed
}

// fetch sends GET path to the web server of the grant, and writes the
// body of the answer into the staging object of the nickname name, by
// pieces, as it comes; at its end the nickname names the bytes. The answer
// is input from the network: its head has a status 200 and a
// Content-Length of 1 byte to disk_process.FILE_BYTES_LIMIT, each full
// piece of the body comes before the deadline after the piece before it,
// and the whole body before module_files_core.receive_total_deadline. size
// is the bytes of the body and hash the hash of the bytes written; outcome
// is Succeeded, or the outcome of the failed export. A body that ends early
// leaves the file before under the nickname.
fetch :: proc "contextless" (path: string, name: string, error: ^errors.Error_Record) -> (size: int, hash: blake3.Hash, outcome: call_outcome.Call_Outcome) {
	deadline := system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS
	index, connect_error := tcp.connect(&table, remote_address, remote_port, system.nanoseconds() / 1000)
	if connect_error.kind != 0 {
		return 0, {}, network_failure(error, .Callee_Busy, .Full, .Connections, path, "the table of connections has no free record")
	}
	defer connection_end(index)
	for connections[index].state == .Syn_Sent && system.time() < deadline {
		pump()
	}
	if connections[index].state != .Established {
		return 0, {}, network_failure(error, .Callee_Unavailable, .No_Answer, .Milliseconds, path, "the web server did not take the connection")
	}
	address_buffer: [16]u8
	address_writer := system.Writer{buffer = address_buffer[:]}
	network.address_write(&address_writer, remote_address)
	request_buffer: [PATH_LIMIT + 96]u8
	request := system.format(request_buffer[:], "GET ", path, " HTTP/1.1\r\nHost: ", system.written(&address_writer), "\r\nConnection: close\r\n\r\n")
	written := 0
	for written < len(request) {
		count, write_error := tcp.write(&table, index, transmute([]u8)request[written:])
		if write_error.kind != 0 {
			return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .Connection, path, "the connection ended before the request went")
		}
		written += count
		if system.time() >= deadline {
			return 0, {}, network_failure(error, .Callee_Unavailable, .No_Answer, .Milliseconds, path, "the request did not go before the deadline")
		}
		pump()
	}
	// The head of the answer.
	head_bytes: [web.HEAD_LIMIT]u8
	head_length := 0
	for {
		count, _ := tcp.read(&table, index, head_bytes[head_length:])
		head_length += count
		if web.head_end(head_bytes[:head_length]) != 0 {
			break
		}
		if head_length == len(head_bytes) {
			return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .Bytes, path, "the head of the answer passes 2048 bytes")
		}
		if remote_ended(index) {
			return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .None, path, "the connection ended before the head of the answer")
		}
		if system.time() >= deadline {
			return 0, {}, network_failure(error, .Callee_Unavailable, .No_Answer, .Milliseconds, path, "no answer before the deadline")
		}
		pump()
	}
	head, head_ok := web.head_read(head_bytes[:head_length])
	if !head_ok {
		return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .None, path, "the head of the answer is not HTTP/1.1")
	}
	if head.status != 200 {
		return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .None, path, "the status of the answer is not 200", i64(head.status))
	}
	if head.content_length < 1 || head.content_length > disk_process.FILE_BYTES_LIMIT {
		return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .Bytes, path, "the answer has no Content-Length of 1 byte to 64 MiB", i64(head.content_length))
	}
	// The length is read one time, here: no later byte changes it.
	size = head.content_length
	rest := head_bytes[head.size:head_length]
	if len(rest) > size {
		return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .Bytes, path, "the answer has more bytes than its Content-Length")
	}
	stream: module_files_core.File_Stream
	if status := module_files_core.file_stream_begin(&stream, &client_file_store, name); status != .Ok {
		return 0, {}, store_refused(error, &stream.store_error, status, .File, name)
	}
	// Each way out before the end leaves the file before under the nickname.
	defer file_stream_abandon_reported(&stream)
	if status := module_files_core.file_stream_piece(&stream, rest); status != .Ok {
		return 0, {}, store_refused(error, &stream.store_error, status, .File, name)
	}
	// Two deadlines end the body: no full piece in LOAD_DEADLINE_MILLISECONDS,
	// and the total of receive_total_deadline. Only a full piece moves the
	// first, so a link that gives a byte now and then cannot hold the call;
	// the second bounds a link that gives a piece just before each deadline.
	total_deadline := module_files_core.receive_total_deadline(system.time(), size)
	filled := 0
	for stream.written < size {
		wanted := min(len(piece), size - stream.written)
		count, _ := tcp.read(&table, index, piece[filled:wanted])
		filled += count
		if filled == wanted {
			if status := module_files_core.file_stream_piece(&stream, piece[:filled]); status != .Ok {
				return 0, {}, store_refused(error, &stream.store_error, status, .File, name)
			}
			filled = 0
			deadline = system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS
			continue
		}
		if count > 0 {
			continue
		}
		if remote_ended(index) {
			return 0, {}, network_failure(error, .Callee_Unavailable, .Refused, .Bytes, path, "the connection ended before the end of the body", i64(stream.written + filled))
		}
		now := system.time()
		if now >= deadline {
			return 0, {}, network_failure(error, .Callee_Unavailable, .No_Answer, .Milliseconds, path, "no piece of the body came before the deadline", i64(stream.written + filled))
		}
		if now >= total_deadline {
			return 0, {}, network_failure(error, .Callee_Unavailable, .No_Answer, .Milliseconds, path, "the body did not come before its total deadline", i64(stream.written + filled))
		}
		pump()
	}
	status: storage_status.Status
	if hash, status = module_files_core.file_stream_end(&stream); status != .Ok {
		return 0, {}, store_refused(error, &stream.store_error, status, .File, name)
	}
	return size, hash, .Succeeded
}

// The staging objects that one pass of staging_objects_remove removes at
// most, and the pages of the listing that it reads.
STAGING_REMOVE_BATCH :: 16

// staging_objects_remove removes each staging object of the store: a stop
// of this service between the clone and the remove of a write, or a remove
// that failed, leaves one, which no load reads and which holds blocks. The
// service runs it at its start, when no write of its own runs, and the
// listing runs it too. A staging object that the remove refuses stays, and
// the listing shows it. It gives the count of staging objects that stay.
staging_objects_remove :: proc "contextless" () -> (kept: int) {
	rows: [16]storage.Listed
	names: [16 * 64]u8
	after: [64]u8
	after_length := 0
	for _ in 0 ..< LIST_PAGE_LIMIT {
		page, status := storage.list(&store_client, storage.ROOT, string(after[:after_length]), rows[:], names[:])
		if status != .Ok || len(page) == 0 {
			return kept
		}
		found: [STAGING_REMOVE_BATCH][64]u8
		found_lengths: [STAGING_REMOVE_BATCH]int
		found_count := 0
		for item in page {
			if item.name_offset < 0 || item.name_count <= 0 || item.name_count > i64(len(after)) || item.name_offset > i64(len(names)) - item.name_count {
				return kept
			}
			entry_name := string(names[item.name_offset:][:item.name_count])
			after_length = copy(after[:], entry_name)
			if disk_process.staging_name_is(entry_name) && found_count < len(found) {
				found_lengths[found_count] = copy(found[found_count][:], entry_name)
				found_count += 1
			}
		}
		// The names are copied before the removes: a remove changes the
		// listing, and the next page starts after the last name read.
		for index in 0 ..< found_count {
			name := string(found[index][:found_lengths[index]])
			store_error: errors.Error_Record
			if generation, removed := storage.remove(&store_client, storage.ROOT, name, &store_error); removed != .Ok || generation < 0 {
				kept += 1
				continue
			}
			system.log_fact(.Info, Staging_Removed{file_name = value_kinds.text_field(name, FILE_NAME_FIELD_BYTES)})
		}
	}
	return kept
}

// file_stream_abandon_reported abandons a write that stops, and writes the
// fact of pending changes that the storage service did not drop: they stay
// held on this connection until the next write of the nickname drops them.
file_stream_abandon_reported :: proc "contextless" (stream: ^module_files_core.File_Stream) {
	module_files_core.file_stream_abandon(stream)
	if stream.pending_kept {
		system.log_fact(.Warning, Staging_Pending_Kept{nickname = value_kinds.module_name_field(stream.nickname)})
	}
}

// store_refused gives the outcome of store_failure alone, for a procedure
// that gives more than the outcome of the export.
store_refused :: proc "contextless" (error: ^errors.Error_Record, store_error: ^errors.Error_Record, status: storage_status.Status, subject: Store_Subject, nickname := "") -> call_outcome.Call_Outcome {
	outcome, _ := store_failure(error, store_error, status, subject, nickname)
	return outcome
}

// store_failure writes the fact of a refusal of the storage service, and
// gives the result of the export. subject says what was refused, and
// nickname names the file of the subject File. A status Failed has the
// error record of the export; each other status is an answer that the
// export does not allow. The subjects of an entry of a listing are checks
// of this service, whose status is always Refused.
store_failure :: proc "contextless" (error: ^errors.Error_Record, store_error: ^errors.Error_Record, status: storage_status.Status, subject: Store_Subject, nickname := "") -> (outcome: call_outcome.Call_Outcome, value: i64) {
	switch subject {
	case .File:
		if status == .Failed {
			fields := errors.error_record_fact_fields(store_error^)
			system.log_fact(.Info, File_Store_Refused{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, nickname = value_kinds.module_name_field(nickname)})
		} else {
			system.log_fact(.Info, File_Store_Answer_Refused{nickname = value_kinds.module_name_field(nickname)})
		}
	case .Listing:
		if status == .Failed {
			system.log_fact(.Info, Listing_Store_Refused(errors.error_record_fact_fields(store_error^)))
		} else {
			system.log_fact(.Info, Listing_Store_Answer_Refused{})
		}
	case .Listing_Entry_Name:
		system.log_fact(.Info, Listing_Entry_Name_Refused{})
	case .Listing_Entry_Kind:
		system.log_fact(.Info, Listing_Entry_Kind_Refused{})
	}
	return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store, 0, 0, 0, i64(status))
}

// receive fetches a module file from the web server of the grant, and stores it in the store module_files under a nickname.
//
// The service sends `GET path` to the web server, takes a body of 1 byte to 64 MiB with a Content-Length, writes it
// into the staging object of the nickname in the root tree of the store `module_files` of its principal by pieces as
// it comes, in commits of 1 MiB, then makes the object `nickname` name the bytes in one commit, removes the staging
// object, and gives the 64 hexadecimal digits of the BLAKE3 hash of the bytes that came. The hash is the one to type in
// `start_from_disk`: the root service checks the bytes against it at the start, so a file with other bytes never runs
// under it. A file of the same nickname is replaced whole, and the store keeps the one before as a version: one
// receive makes one version. A staging object has a name longer than a nickname, so it never runs.
//
// - **nickname**: the name of the entry, 1 to 23 bytes, with no zero byte and no `/`; not `module_files` and not
//   `grant_table`.
// - **path**: the path of the request, 1 to 200 bytes that start with `/`, with no space and no control byte.
// - **result**: the 64 hexadecimal digits of the hash.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The call ends when no piece of 32 KiB
// comes for 30 seconds, the deadline of a load, or when the body takes longer than 30 seconds and its bytes at 64 KiB
// each second: 1054 seconds for 64 MiB. The result is 64, or a failure with its call outcome and an error record:
//
// - `No_Grant` (Grant_Or_Right_Missing): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, argument 1): the nickname; `Exists` (Name_Already_Taken):
//   `module_files` or `grant_table`, which the store keeps.
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, argument 2): the path; for `Bad_Byte`, the record holds the
//   place of the byte.
// - `Full` (Callee_Busy): the table of connections has no free record.
// - `No_Answer` or `Refused` (Callee_Unavailable, argument 2): the web server did not answer before the deadline, or
//   its answer is not a module file: a status that is not 200 (the record holds it), no Content-Length of 1 byte to
//   64 MiB, or a body that ends early: the file before stays under the nickname, and the staging object goes. The
//   log says which.
// - `Refused` (Callee_Unavailable): the service has no store, or the storage service refused the file.
//
// Example: `module_files.receive("visitor", "/visitor")`.
@(export, link_name = "receive")
receive :: proc "c" (nickname: ^string, path: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !caller_allowed() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, .Make, error)
	if name_failure != .Succeeded {
		return name_failure, 0
	}
	path_text := path^
	path_copy: [PATH_LIMIT]u8
	path_length := copy(path_copy[:], path_text)
	if len(path_text) == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 2, 0, PATH_LIMIT)
	}
	if len(path_text) > PATH_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(path_text)), PATH_LIMIT)
	}
	// One line of visible bytes: the request carries no second line that
	// the caller wrote.
	for byte, place in path_copy[:path_length] {
		if (place == 0 && byte != '/') || byte <= ' ' || byte > '~' {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Byte, .Bytes, 2, i64(place), 0, i64(byte))
		}
	}
	request_path := string(path_copy[:path_length])
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	// The store first, then the answer: the hash goes back only when the
	// store holds the bytes.
	size, hash, fetched := fetch(request_path, name, error)
	if fetched != .Succeeded {
		return fetched, 0
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	system.log_fact(.Info, File_Stored{size = value_kinds.Size_In_Bytes(size), file_hash = value_kinds.Hash_Field(hash), nickname = value_kinds.module_name_field(name)}, request_path)
	copy(result^, digits[:])
	return .Succeeded, disk_process.HASH_DIGITS
}

// bytes_hash reads the bytes of an object of the store by pieces, and
// gives the BLAKE3 hash of those bytes. The hash of the entry is not read:
// it differs from the hash of the bytes when the object has a hole.
bytes_hash :: proc "contextless" (name: string, size: int) -> (hash: [disk_process.HASH_SIZE]u8, ok: bool) {
	if size <= 0 || size > disk_process.FILE_BYTES_LIMIT {
		return {}, false
	}
	hasher := blake3.hasher_make()
	received := 0
	for received < size {
		bytes, status := storage.read_range(&store_client, storage.ROOT, name, u64(received), piece[:min(len(piece), size - received)])
		// An answer with no byte before the end would come again for ever.
		if status != .Ok || len(bytes) == 0 {
			return {}, false
		}
		blake3.hasher_update(&hasher, bytes)
		received += len(bytes)
	}
	return blake3.hasher_finish(&hasher), true
}

// list gives one row for each module file of the store module_files: its name, its bytes, and the BLAKE3 hash of its bytes.
//
// The service reads the bytes of each object again and computes the hash: the hash that the storage service keeps for
// an entry differs from the hash of the bytes when the object has a hole. The object `grant_table`, the disk grant
// table of the principal, is no module file and has no row; nor has the debug object of a module file, an object named
// by the 64 hexadecimal digits of the hash of its module. An object over 64 MiB, the limit of a module file, or whose
// bytes did not come, has a row with no hash. The log has one line for each row.
//
// - **result**: a table of `Module_File_Row` rows; the call fills at most its length.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is the count of the rows, or a failure with its call outcome and an error record:
//
// - `No_Grant`: the caller does not act for the principal of the store.
// - `Refused`: the service has no store, or the storage service refused the listing.
//
// Example: `module_files.list()`.
@(export, link_name = "list")
list :: proc "c" (result: ^[]Module_File_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !caller_allowed() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	// A staging object that a stop left goes first; one that stays is a
	// row of the listing, so the listing hides nothing that holds blocks.
	staging_objects_remove()
	rows: [16]storage.Listed
	names: [16 * 64]u8
	after: [64]u8
	after_length := 0
	total := 0
	for _ in 0 ..< LIST_PAGE_LIMIT {
		store_error: errors.Error_Record
		page, status := storage.list(&store_client, storage.ROOT, string(after[:after_length]), rows[:], names[:], &store_error)
		if status != .Ok {
			return store_failure(error, &store_error, status, .Listing)
		}
		if len(page) == 0 {
			system.log_fact(.Info, Files_Listed{files = u64(total)})
			return .Succeeded, i64(total)
		}
		for item in page {
			// The offsets come from the storage service: each one is
			// checked before a use.
			if item.name_offset < 0 || item.name_count <= 0 || item.name_count > i64(len(after)) || item.name_offset > i64(len(names)) - item.name_count {
				return store_failure(error, &store_error, .Refused, .Listing_Entry_Name)
			}
			entry_kind, entry_kind_ok := storage.entry_kind_of_word(item.kind)
			if !entry_kind_ok {
				return store_failure(error, &store_error, .Refused, .Listing_Entry_Kind)
			}
			entry_name := string(names[item.name_offset:][:item.name_count])
			after_length = copy(after[:], entry_name)
			// The disk grant table and the debug object of a module file are
			// objects of the store, and no module file.
			if entry_kind != .Object || entry_name == disk_process.TABLE_OBJECT_NAME || disk_process.debug_object_name_is(entry_name) {
				continue
			}
			digits: [disk_process.HASH_DIGITS]u8
			hash, hashed := bytes_hash(entry_name, int(min(item.size, i64(disk_process.FILE_BYTES_LIMIT) + 1)))
			if hashed {
				disk_process.hash_write(&digits, hash)
				system.log_fact(.Info, File_Hashed{size = value_kinds.Size_In_Bytes(max(item.size, 0)), file_hash = value_kinds.Hash_Field(hash), file_name = value_kinds.text_field(entry_name, FILE_NAME_FIELD_BYTES)})
			} else {
				system.log_fact(.Info, File_Not_Hashed{size = value_kinds.Size_In_Bytes(max(item.size, 0)), file_name = value_kinds.text_field(entry_name, FILE_NAME_FIELD_BYTES)})
			}
			if total < len(result^) {
				row := &result[total]
				row^ = {bytes = item.size}
				copy(row.name[:len(row.name) - 1], entry_name)
				if hashed {
					copy(row.hash[:], digits[:])
				}
			}
			total += 1
		}
	}
	system.log_fact(.Info, Listing_Not_Ended{listing_pages = u64(LIST_PAGE_LIMIT)})
	return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
}

// The entry of module_files: it opens its service, its store and its endpoint,
// then serves the calls of the console and the timers of TCP until the
// machine stops.
//
// 1. takes its random generator; with no seed it stops with `Failed`;
// 2. opens its service ring and its store; a missing part stops it with a
//    line of the log;
// 3. asks the network service for its grant; a grant that is not a client
//    grant of TCP stops it;
// 4. writes "module_files: serves the store module_files of principal N: ...".
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		fail("no random seed in the context")
	}
	store_principal = ctx.values[disk_process.SERVICE_VALUE_PRINCIPAL]
	opened: bool
	if service, opened = system.service_open(ctx); !opened {
		fail("no service ring")
	}
	if store_client, opened = storage.open(ctx); !opened {
		fail("no store: the root service gave no connection to the store module_files")
	}
	staging_objects_remove()
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		fail("no endpoint: the process has no grant of the network")
	}
	region_address, region_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	if region_status != .Ok {
		fail("no datagram region")
	}
	region = ([^]u8)(region_address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	// The grant: the one remote, and the local address and ports.
	system.send(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Info), tag = CALL_TAG})
	info: ring.Record
	for {
		record, has := system.receive(&endpoint.completions)
		if has && record.tag == CALL_TAG {
			info = record
			break
		}
		wait: system.Wait
		system.wait_records(&wait, &endpoint.completions)
		system.wait_end(&wait, system.time() + 2000)
	}
	grant, grant_known := datagram.grant_unpack(info.values[6])
	if !grant_known || !grant.tcp || grant.listen || grant.address == 0 {
		fail("the grant is not a client grant of TCP")
	}
	remote_address, remote_port = grant.address, grant.port
	// The buffers of the connections: memory of this process, which gives
	// the library all the memory that it uses.
	buffer_memory, buffer_status := system.memory_create(BUFFER_PAGES)
	if buffer_status != .Ok {
		fail("no memory for the buffers of the connections")
	}
	buffers, buffers_status := system.memory_map(buffer_memory, {.Write})
	if buffers_status != .Ok {
		fail("no memory for the buffers of the connections")
	}
	// The secret of the initial sequence numbers (RFC 6528): 32 bytes of
	// the generator of this process (docs/RANDOMNESS.md).
	secret: [32]u8
	random.fill(&process_generator, secret[:])
	if table_error := tcp.table_init(&table, connections[:], ([^]u8)(buffers)[:BUFFER_PAGES * system.PAGE_SIZE], SEND_SIZE, RECEIVE_SIZE, u32(info.values[0]), secret); table_error.kind != 0 {
		fail("the connection table refused its memory")
	}
	secret = {}
	table.port_first = u16(info.values[1])
	table.port_count = datagram.PORT_BLOCK
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	address_buffer: [16]u8
	address_writer := system.Writer{buffer = address_buffer[:]}
	network.address_write(&address_writer, remote_address)
	system.log_fact(.Info, Serving{principal = store_principal, remote_port = u64(remote_port), remote_address = value_kinds.text_field(system.written(&address_writer), ADDRESS_FIELD_BYTES)})
	for {
		wait := system.wait_begin()
		deadline, _ := network_step()
		system.service_run(&service)
		if !ring.empty(&endpoint.completions) {
			continue
		}
		system.wait_records(&wait, &endpoint.completions)
		system.service_wait(&wait, &service)
		limit: u64 = system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = deadline / 1000 + 1
		}
		system.wait_end(&wait, limit)
	}
}
