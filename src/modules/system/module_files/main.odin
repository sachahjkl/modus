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

import "modus:contract/blake3"
import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:support/disk_process"
import "modus:support/network"
import "modus:support/random"
import "modus:support/storage"
import "modus:support/system"
import "modus:support/tcp"
import "modus:support/web"

// The memory of one file of 4 MiB (1024 pages), the buffers of the 4
// connections (96 pages), and its tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1184, processes = 1, threads = 1}

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

// The file of one call: the limit of a module file of a disk process, so
// that the root service can load each file that this service stores.
FILE_PAGES :: disk_process.FILE_BYTES_LIMIT / system.PAGE_SIZE

// The bytes of the path of a request.
PATH_LIMIT :: 200

// The bytes of one write_range: the call region of a connection has 64 KiB,
// and holds the arguments too.
WRITE_PIECE :: 32 * 1024

// The pages of the listing of the store that one list reads at most. A
// storage service that never gives an empty page ends there.
LIST_PAGE_LIMIT :: 1024

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_NAME :: -2
ERROR_PATH :: -3
ERROR_NETWORK :: -4
ERROR_ANSWER :: -5
ERROR_STORE :: -6

// One row of module_files.list().
Module_File_Row :: struct {
	name:  [64]u8, // The name of the entry: the nickname of the file.
	bytes: i64, // The bytes of the object.
	hash:  [72]u8, // The 64 hexadecimal digits of the BLAKE3 hash of its bytes; empty when its bytes did not come or pass 4 MiB.
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
file: []u8 // FILE_PAGES pages of its own memory: the bytes of the call that runs.
service: system.Service
process_generator: random.Generator // The random generator of this process, from the seed of its starter.

fail :: proc "contextless" (text: string) -> ! {
	system.log(.Info, "module_files: ", text)
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
			if datagram.Status(record.kind) == .Ok && count < len(incoming) {
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
// result of the export.
network_failure :: proc "contextless" (error: ^errors.Error_Record, result: i64, kind: errors.Kind, unit: errors.Unit, path: string, why: string, found: i64 = 0) -> i64 {
	system.log(.Info, "module_files: GET ", path, ": ", why, ": nothing is stored")
	return errors.fail(error, result, kind, unit, 2, 0, 0, found)
}

// fetch sends GET path to the web server of the grant, and copies the
// body of the answer into `file`. The answer is input from the network:
// its head has a status 200 and a Content-Length of 1 to 4 MiB, and the
// body comes whole before the deadline, or nothing is kept. size is the
// bytes of the body; result is 0, or the result of a failed export.
fetch :: proc "contextless" (path: string, deadline: u64, error: ^errors.Error_Record) -> (size: int, result: i64) {
	index, connect_error := tcp.connect(&table, remote_address, remote_port, system.nanoseconds() / 1000)
	if connect_error.kind != 0 {
		return 0, network_failure(error, ERROR_NETWORK, .Full, .Connections, path, "the table of connections has no free record")
	}
	defer connection_end(index)
	for connections[index].state == .Syn_Sent && system.time() < deadline {
		pump()
	}
	if connections[index].state != .Established {
		return 0, network_failure(error, ERROR_NETWORK, .No_Answer, .Milliseconds, path, "the web server did not take the connection")
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
			return 0, network_failure(error, ERROR_NETWORK, .Refused, .Connection, path, "the connection ended before the request went")
		}
		written += count
		if system.time() >= deadline {
			return 0, network_failure(error, ERROR_NETWORK, .No_Answer, .Milliseconds, path, "the request did not go before the deadline")
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
			return 0, network_failure(error, ERROR_ANSWER, .Too_Long, .Bytes, path, "the head of the answer passes 2048 bytes")
		}
		if remote_ended(index) {
			return 0, network_failure(error, ERROR_ANSWER, .Malformed, .None, path, "the connection ended before the head of the answer")
		}
		if system.time() >= deadline {
			return 0, network_failure(error, ERROR_NETWORK, .No_Answer, .Milliseconds, path, "no answer before the deadline")
		}
		pump()
	}
	head, head_ok := web.head_read(head_bytes[:head_length])
	if !head_ok {
		return 0, network_failure(error, ERROR_ANSWER, .Malformed, .None, path, "the head of the answer is not HTTP/1.1")
	}
	if head.status != 200 {
		return 0, network_failure(error, ERROR_ANSWER, .Refused, .None, path, "the status of the answer is not 200", i64(head.status))
	}
	if head.content_length < 1 || head.content_length > disk_process.FILE_BYTES_LIMIT {
		return 0, network_failure(error, ERROR_ANSWER, .Too_Long, .Bytes, path, "the answer has no Content-Length of 1 to 4194304 bytes", i64(head.content_length))
	}
	// The length is read one time, here: no later byte changes it.
	size = head.content_length
	rest := head_bytes[head.size:head_length]
	if len(rest) > size {
		return 0, network_failure(error, ERROR_ANSWER, .Too_Long, .Bytes, path, "the answer has more bytes than its Content-Length")
	}
	received := copy(file[:size], rest)
	for received < size {
		count, _ := tcp.read(&table, index, file[received:size])
		received += count
		if received == size {
			break
		}
		if count == 0 && remote_ended(index) {
			return 0, network_failure(error, ERROR_ANSWER, .Too_Small, .Bytes, path, "the connection ended before the end of the body", i64(received))
		}
		if system.time() >= deadline {
			return 0, network_failure(error, ERROR_NETWORK, .No_Answer, .Milliseconds, path, "the body did not come whole before the deadline", i64(received))
		}
		if count == 0 {
			pump()
		}
	}
	return size, 0
}

// store_failure writes the line of a refusal of the storage service, and
// gives the result of the export. subject says what was refused.
store_failure :: proc "contextless" (error: ^errors.Error_Record, store_error: ^errors.Error_Record, status: storage.Status, subject: ..system.Part) -> i64 {
	subject_buffer: [96]u8
	sentence: [240]u8
	writer := system.Writer{buffer = sentence[:]}
	if status == .Failed {
		storage.error_text(&writer, &store_client, store_error)
	} else {
		system.write_bytes(&writer, transmute([]u8)string("the storage service gave no answer that its export allows"))
	}
	system.log(.Info, "module_files: the store module_files refused ", system.format(subject_buffer[:], ..subject), ": ", system.written(&writer))
	return errors.fail(error, ERROR_STORE, .Refused, .Store, 0, 0, 0, i64(status))
}

// receive fetches a module file from the web server of the grant, and stores it in the store module_files under a nickname.
//
// The service sends `GET path` to the web server, takes a body of 1 to 4 MiB with a Content-Length, writes it as the
// object `nickname` of the root tree of the store `module_files` of its principal in one commit, then gives the 64
// hexadecimal digits of the BLAKE3 hash of the bytes that came. The hash is the one to type in `start_from_disk`: the
// root service checks the bytes against it at the start, so a file with other bytes never runs under it. A file of the
// same nickname is replaced, and the store keeps the one before as a version.
//
// - **nickname**: the name of the entry, 1 to 23 bytes, with no zero byte and no `/`; not `module_files` and not
//   `grant_table`.
// - **path**: the path of the request, 1 to 200 bytes that start with `/`, with no space and no control byte.
// - **result**: the 64 hexadecimal digits of the hash.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The call ends 30 seconds after it
// starts, the deadline of a load. The result is 64, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long`, `Bad_Byte` or `Reserved` (-2): the nickname.
// - `Empty`, `Too_Long` or `Bad_Byte` (-3): the path; for `Bad_Byte`, the record holds the place of the byte.
// - `No_Answer`, `Full` or `Refused` (-4): the connection to the web server, or the deadline.
// - `Refused`, `Malformed`, `Too_Long` or `Too_Small` (-5): the answer: a status that is not 200 (the record holds
//   it), no Content-Length of 1 to 4 MiB, or a body that ends early.
// - `Refused` (-6): the service has no store, or the storage service refused the file.
//
// Example: `module_files.receive("visitor", "/visitor")`.
@(export, link_name = "receive")
receive :: proc "c" (nickname: ^string, path: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	if !caller_allowed() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	// The call region stays writable by the caller during the call: copy
	// each text one time, then check and use the copy only.
	nickname_text := nickname^
	name_copy: [disk_process.NAME_LIMIT]u8
	name_length := copy(name_copy[:], nickname_text)
	if len(nickname_text) > disk_process.NAME_LIMIT {
		return errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(len(nickname_text)), disk_process.NAME_LIMIT)
	}
	name := string(name_copy[:name_length])
	problem, offset := disk_process.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		return errors.fail(error, ERROR_NAME, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
	case .Too_Long:
		return errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(name_length), disk_process.NAME_LIMIT)
	case .Bad_Byte:
		return errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, 1, i64(offset), 0, i64(name_copy[offset]))
	case .Store_Name, .Table_Name:
		// The disk grant table of the principal is an object of this
		// store: no file is written over it.
		return errors.fail(error, ERROR_NAME, .Reserved, .None, 1)
	}
	path_text := path^
	path_copy: [PATH_LIMIT]u8
	path_length := copy(path_copy[:], path_text)
	if len(path_text) == 0 {
		return errors.fail(error, ERROR_PATH, .Empty, .Bytes, 2, 0, PATH_LIMIT)
	}
	if len(path_text) > PATH_LIMIT {
		return errors.fail(error, ERROR_PATH, .Too_Long, .Bytes, 2, i64(len(path_text)), PATH_LIMIT)
	}
	// One line of visible bytes: the request carries no second line that
	// the caller wrote.
	for byte, place in path_copy[:path_length] {
		if (place == 0 && byte != '/') || byte <= ' ' || byte > '~' {
			return errors.fail(error, ERROR_PATH, .Bad_Byte, .Bytes, 2, i64(place), 0, i64(byte))
		}
	}
	request_path := string(path_copy[:path_length])
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	deadline := system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS
	size, failed := fetch(request_path, deadline, error)
	if failed != 0 {
		return failed
	}
	hash := blake3.hash(file[:size])
	// The store first, then the answer: the hash goes back only when the
	// store holds the bytes.
	store_error: errors.Error_Record
	for piece_start := 0; piece_start < size; piece_start += WRITE_PIECE {
		piece := file[piece_start:min(piece_start + WRITE_PIECE, size)]
		if _, status := storage.write_range(&store_client, storage.ROOT, name, u64(piece_start), piece, &store_error); status != .Ok {
			return store_failure(error, &store_error, status, "the file ", system.Module_Name{name})
		}
	}
	// An older file of the nickname can be longer.
	if status := storage.set_size(&store_client, storage.ROOT, name, u64(size), &store_error); status != .Ok {
		return store_failure(error, &store_error, status, "the file ", system.Module_Name{name})
	}
	if _, status := storage.commit(&store_client, storage.ROOT, name, &store_error); status != .Ok {
		return store_failure(error, &store_error, status, "the file ", system.Module_Name{name})
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	system.log(.Info, "module_files: stored ", system.Module_Name{name}, " from ", request_path, ": ", u64(size), " bytes, the BLAKE3 hash of its bytes ", string(digits[:]))
	copy(result^, digits[:])
	return disk_process.HASH_DIGITS
}

// bytes_hash reads the bytes of an object of the store into `file`, and
// gives the BLAKE3 hash of those bytes. The hash of the entry is not read:
// it differs from the hash of the bytes when the object has a hole.
bytes_hash :: proc "contextless" (name: string, size: int) -> (hash: [disk_process.HASH_SIZE]u8, ok: bool) {
	if size <= 0 || size > disk_process.FILE_BYTES_LIMIT {
		return {}, false
	}
	received := 0
	for received < size {
		bytes, status := storage.read_range(&store_client, storage.ROOT, name, u64(received), file[received:size])
		// An answer with no byte before the end would come again for ever.
		if status != .Ok || len(bytes) == 0 {
			return {}, false
		}
		received += len(bytes)
	}
	return blake3.hash(file[:size]), true
}

// list gives one row for each module file of the store module_files: its name, its bytes, and the BLAKE3 hash of its bytes.
//
// The service reads the bytes of each object again and computes the hash: the hash that the storage service keeps for
// an entry differs from the hash of the bytes when the object has a hole. The object `grant_table`, the disk grant
// table of the principal, is no module file and has no row; nor has the debug object of a module file, an object named
// by the 64 hexadecimal digits of the hash of its module. An object over 4 MiB, the limit of a module file, or whose
// bytes did not come, has a row with no hash. The log has one line for each row.
//
// - **result**: a table of `Module_File_Row` rows; the call fills at most its length.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is the count of the rows, or
// a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal of the store.
// - `Refused` (-6): the service has no store, or the storage service refused the listing.
//
// Example: `module_files.list()`.
@(export, link_name = "list")
list :: proc "c" (result: ^[]Module_File_Row, error: ^errors.Error_Record) -> i64 {
	if !caller_allowed() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	rows: [16]storage.Listed
	names: [16 * 64]u8
	after: [64]u8
	after_length := 0
	total := 0
	for _ in 0 ..< LIST_PAGE_LIMIT {
		store_error: errors.Error_Record
		page, status := storage.list(&store_client, storage.ROOT, string(after[:after_length]), rows[:], names[:], &store_error)
		if status != .Ok {
			return store_failure(error, &store_error, status, "the listing of its root tree")
		}
		if len(page) == 0 {
			system.log(.Info, "module_files: listed ", u64(total), " module files of the store module_files, each hash computed on its bytes")
			return i64(total)
		}
		for item in page {
			// The offsets come from the storage service: each one is
			// checked before a use.
			if item.name_offset < 0 || item.name_count <= 0 || item.name_count > i64(len(after)) || item.name_offset > i64(len(names)) - item.name_count {
				return store_failure(error, &store_error, .Refused, "the listing of its root tree: an entry has a name out of its page")
			}
			entry_kind, entry_kind_ok := storage.entry_kind_of_word(item.kind)
			if !entry_kind_ok {
				return store_failure(error, &store_error, .Refused, "the listing of its root tree: an entry has a kind that names no kind")
			}
			entry_name := string(names[item.name_offset:][:item.name_count])
			after_length = copy(after[:], entry_name)
			// The disk grant table and the debug object of a module file
			// are objects of the store, and no module file.
			if entry_kind != .Object || entry_name == disk_process.TABLE_OBJECT_NAME || disk_process.debug_object_name_is(entry_name) {
				continue
			}
			digits: [disk_process.HASH_DIGITS]u8
			hash, hashed := bytes_hash(entry_name, int(min(item.size, i64(disk_process.FILE_BYTES_LIMIT) + 1)))
			if hashed {
				disk_process.hash_write(&digits, hash)
				system.log(.Info, "module_files: the file ", system.Module_Name{entry_name}, ", ", u64(max(item.size, 0)), " bytes, the BLAKE3 hash of its bytes ", string(digits[:]))
			} else {
				system.log(.Info, "module_files: the file ", system.Module_Name{entry_name}, ", ", u64(max(item.size, 0)), " bytes, has no hash: its bytes did not come, or pass the 4194304 bytes of a module file")
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
	system.log(.Info, "module_files: the listing of the store module_files did not end after ", u64(LIST_PAGE_LIMIT), " pages")
	return errors.fail(error, ERROR_STORE, .Refused, .Store)
}

// The entry of module_files: it opens its service, its store and its endpoint,
// then serves the calls of the console and the timers of TCP until the
// machine stops.
//
// 1. takes its random generator; with no seed it stops with `Failed`;
// 2. opens its service ring and its store, and makes the memory of one
//    file; a missing part stops it with a line of the log;
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
	file_memory, file_status := system.memory_create(FILE_PAGES)
	if file_status != .Ok {
		fail("no memory for the bytes of a file")
	}
	file_address, file_map_status := system.memory_map(file_memory, {.Write})
	if file_map_status != .Ok {
		fail("no memory for the bytes of a file")
	}
	file = ([^]u8)(file_address)[:disk_process.FILE_BYTES_LIMIT]
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
	system.log(.Info, "module_files: serves the store module_files of principal ", store_principal, ": a file from the web server ", system.written(&address_writer), " port ", u64(remote_port), ", and the list of the files with the hash of their bytes")
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
