// The client of the storage service: what a module compiles in to keep its
// data in its private store: a tree of entries, each an object or a tree
// (docs/STORAGE.md).
//
// The root service makes the connection when it starts the process, and
// gives it in the context (GRANT_ roles below): a call ring, a call region,
// a handle that reads the state of the storage service, and the file of the
// storage service, mapped read-only at FILE_ADDRESS. The calls are isolated
// calls (src/library/modus/contract/isolated): this package finds each export by its name in
// that file, and encodes the arguments with its description.
//
//   client, ok := storage.open(ctx)
//   storage.write(&client, storage.ROOT, "note", bytes)   // One commit, on the disk at the return.
//   storage.read(&client, storage.ROOT, "note", buffer[:])
//   drafts, _ := storage.open_tree(&client, storage.ROOT, "drafts")
//   storage.write(&client, drafts, "first", bytes)
//
// A place is a number of this connection that names a tree of the store:
// ROOT is the root of the connection; open_tree gives the place of a tree
// under a place. A name is one step under a place.
//
// When the root service revokes the grant, the handles of the connection
// end: a call gives Gone, and the process continues.
//
// Who uses it: each process with the grant `Store` (the console, the notes,
// the settings, the tests of the storage service). The parts:
//
// - `Client`, `open`, `connected`, `call`: the connection.
// - `call_send`, `call_answer`: one call in two parts, for a process that
//   does not wait for the storage service.
// - `read`, `write`, `remove` and the pending changes (`write_range`,
//   `set_size`, `commit`): the objects.
// - `open_tree`, `close_tree`, `add`, `list`, `rename`: the trees and the
//   places.
// - `versions`, `version`, `compare`, `restore`, `erase_versions`: the
//   versions.
// - `share`, `unshare`, `open_handles`, `open_store`: the shares and the
//   other stores.
// - `usage`, `error_text`: the counts of the store and the sentence of an
//   error record.
//
// See [storage service](term:storage-service), [place](term:place) and
// [private store](term:private-store).
package storage

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/storage_status"
import store_contract "modus:contract/store"
import "modus:system"

// The slots of the context of a process with a private store, in the one
// table of the context slots (src/library/modus/system/grants.odin).
GRANT_RING :: system.GRANT_STORAGE_RING // Memory: the call ring.
GRANT_REGION :: system.GRANT_STORAGE_REGION // Memory: the call region.
GRANT_SERVICE :: system.GRANT_STORAGE_SERVICE // The storage service, with the right Read: its state.
VALUE_FILE_SIZE :: system.GRANT_VALUE_STORAGE_FILE_SIZE // The size of the file of the storage service.

// A place of the connection (docs/STORAGE.md, "Places"). It is distinct:
// a generation, a size or a count is not a place.
Place :: distinct i64
ROOT :: Place(0) // The root of the connection: the tree of the store, or the tree of a share.
FILE_ADDRESS :: fixed_addresses.STORAGE_FILE_ADDRESS // Where the root service maps that file.

// One connection to the storage service, in the memory of the process. One
// thread uses it at a time: a call uses the call region whole.
Client :: struct {
	ring_memory:   system.Handle, // The memory of the call ring.
	region_memory: system.Handle, // The memory of the call region.
	service:       system.Handle, // The process of the storage service, with Read: its state.
	calls:         ring.Ring, // The call ring, mapped.
	region:        []u8, // The call region, mapped.
	file:          []u8, // The file of the storage service: the descriptions of its exports.
	tag:           u32, // The tag of the last call.
	gone:          bool, // The connection ended: each call gives Gone.
	// A call past its bound whose answer has not come: the service can still
	// write the call region, so the next call waits for that answer first.
	// 0: none.
	late_tag:      u32,
	// Caller runs with Process_Flag.No_Clock: never read system.time() or
	// sleep on wall-clock deadlines.
	no_clock:      bool,
}

// open opens the connection that the root service gave in the context of
// this process. ok is false for a process with no grant of a store, or a
// file of the service that is not a valid module.
open :: proc "contextless" (ctx: ^system.Context) -> (client: Client, ok: bool) {
	return open_of_handles(ctx.handles[GRANT_RING], ctx.handles[GRANT_REGION], ctx.handles[GRANT_SERVICE], ctx.values[VALUE_FILE_SIZE])
}

// open_of_handles opens a private store from the three handles and the size
// of the file of the storage service that its starter gave in other places
// of the context than the usual ones: the holder of the display, whose first
// values are its screen, gets its role store this way.
open_of_handles :: proc "contextless" (ring_memory, region_memory, service: system.Handle, file_size: u64) -> (client: Client, ok: bool) {
	client.ring_memory = ring_memory
	client.region_memory = region_memory
	client.service = service
	if client.ring_memory == 0 || client.region_memory == 0 {
		return {}, false
	}
	region_pages, size_status := system.memory_size(client.region_memory)
	if size_status != .Succeeded {
		return {}, false
	}
	status: call_outcome.Call_Outcome
	if client.calls, status = system.ring_open(client.ring_memory, receive_handles = true); status != .Succeeded {
		return {}, false
	}
	address, map_status := system.memory_map(client.region_memory)
	if map_status != .Succeeded {
		system.ring_close(&client.calls)
		return {}, false
	}
	client.region = ([^]u8)(address)[:region_pages * system.PAGE_SIZE]
	file_address := uintptr(FILE_ADDRESS)
	client.file = ([^]u8)(file_address)[:file_size]
	if module.validate(client.file) != .None {
		system.ring_close(&client.calls)
		system.memory_unmap(raw_data(client.region))
		return {}, false
	}
	// The root service made this connection: no call before the storage
	// service maps its ring (src/md/api/call_ring_ready.md).
	if system.connection_ready_wait(&client.calls, client.service) != .Ready {
		system.ring_close(&client.calls)
		system.memory_unmap(raw_data(client.region))
		return {}, false
	}
	return client, true
}

// connected says if the connection is still there. The kernel ends the
// handles of the connection at a revocation: the process learns it here,
// before it uses the memory.
connected :: proc "contextless" (client: ^Client) -> bool {
	if client.gone {
		return false
	}
	kind, _, _ := system.handle_state(client.ring_memory)
	region_kind, _, _ := system.handle_state(client.region_memory)
	state, _, _ := system.process_state(client.service)
	if kind != .Memory || region_kind != .Memory || state == .Stopped || state == .None {
		client.gone = true
	}
	return !client.gone
}

// The most milliseconds that a call waits while the storage service
// repairs the counts of the blocks of its disk, and the time between two
// tries. Past the bound the caller gets the refusal Busy, unit Count_Repair
// or Count_Recount, whose sentence names the repair or the recount and gives
// its progress.
REPAIR_WAIT_BOUND_MILLISECONDS :: 60_000
REPAIR_RETRY_MILLISECONDS :: 100

// repair_retry says if a call that the storage service answered is made
// again: a refusal Busy with the unit Count_Repair or Count_Recount (the
// service makes no change while it repairs or recounts its counts) before
// the bound. wait is the time
// to the next try.
repair_retry :: proc "contextless" (status: storage_status.Status, outcome: call_outcome.Call_Outcome, record: ^errors.Error_Record, waited_milliseconds: u64) -> (retry: bool, wait_milliseconds: u64) {
	if status != .Failed || outcome != .Callee_Busy {
		return false, 0
	}
	if record.kind != i64(errors.Kind.Busy) || record.unit != i64(errors.Unit.Count_Repair) && record.unit != i64(errors.Unit.Count_Recount) {
		return false, 0
	}
	if waited_milliseconds >= REPAIR_WAIT_BOUND_MILLISECONDS {
		return false, 0
	}
	return true, min(REPAIR_RETRY_MILLISECONDS, REPAIR_WAIT_BOUND_MILLISECONDS - waited_milliseconds)
}

// call makes one isolated call of the export with a name. For a Text result,
// text has the bytes in the call region: copy them before the next call.
// When the export fails, the status is Failed, outcome says how it ended,
// and error has its error record, as the storage service wrote it. A change
// that the service refuses while it repairs the counts of its disk is made
// again, up to REPAIR_WAIT_BOUND_MILLISECONDS (repair_retry). With no answer
// before storage_status.ANSWER_BOUND_MILLISECONDS, the status is No_Answer:
// the service can still write the answer into the call region, so the next
// call waits for that answer first (late_answer_wait), and runs when it
// came. The connection stays: a service that was slow once serves again.
call :: proc "contextless" (client: ^Client, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (value: i64, text: []u8, status: storage_status.Status, outcome: call_outcome.Call_Outcome) {
	local: errors.Error_Record
	record := error != nil ? error : &local
	if client.no_clock {
		attempts := u64(0)
		for {
			value, text, status, outcome = call_once(client, name, arguments, record)
			retry, _ := repair_retry(status, outcome, record, attempts * REPAIR_RETRY_MILLISECONDS)
			if !retry {
				return value, text, status, outcome
			}
			attempts += 1
			system.enter(0)
		}
	}
	start := system.time()
	for {
		value, text, status, outcome = call_once(client, name, arguments, record)
		retry, wait := repair_retry(status, outcome, record, system.time() - start)
		if !retry {
			return value, text, status, outcome
		}
		system.sleep(system.time() + wait)
	}
}

// call_once makes one isolated call and waits for its answer.
@(private)
call_once :: proc "contextless" (client: ^Client, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record) -> (value: i64, text: []u8, status: storage_status.Status, outcome: call_outcome.Call_Outcome) {
	if client.late_tag != 0 {
		if status = late_answer_wait(client); status != .Ok {
			return 0, nil, status, .Succeeded
		}
	}
	sent: Sent_Call
	if sent, status = call_send(client, name, arguments); status != .Ok {
		return 0, nil, status, .Succeeded
	}
	deadline := client.no_clock ? system.WAIT_FOREVER : call_deadline(system.time())
	for {
		// A revocation and the stop of the service are events.
		wait := system.wait_begin()
		answered: bool
		if value, text, status, outcome, answered = call_answer(client, &sent, arguments, error); answered {
			return value, text, status, outcome
		}
		if !connected(client) {
			return 0, nil, .Gone, .Succeeded
		}
		system.wait_records(&wait, &client.calls.completions)
		if returned := system.wait_end(&wait, deadline); !client.no_clock && returned >= deadline {
			// One last read: the answer can come with the deadline.
			if value, text, status, outcome, answered = call_answer(client, &sent, arguments, error); answered {
				return value, text, status, outcome
			}
			client.late_tag = sent.tag
			return 0, nil, .No_Answer, .Succeeded
		}
	}
}

// late_answer_wait waits, up to the bound of a call, for the answer of the
// call that passed its bound, and drops it: the call region is then the
// region of this client again. No_Answer when it does not come, Gone when
// the connection ended.
@(private = "file")
late_answer_wait :: proc "contextless" (client: ^Client) -> storage_status.Status {
	deadline := client.no_clock ? system.WAIT_FOREVER : call_deadline(system.time())
	for {
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has := system.receive(&client.calls.completions)
			if !has {
				break
			}
			if late_answer_is(client, completion.tag) {
				return .Ok
			}
		}
		if !connected(client) {
			return .Gone
		}
		system.wait_records(&wait, &client.calls.completions)
		if returned := system.wait_end(&wait, deadline); !client.no_clock && returned >= deadline {
			return .No_Answer
		}
	}
}

// late_answer_is says if a completion is the answer of the late call, and
// clears the late call when it is: an answer of another tag is an answer
// that no call waits for any more.
late_answer_is :: proc "contextless" (client: ^Client, tag: u32) -> bool {
	if client.late_tag == 0 || tag != client.late_tag {
		return false
	}
	client.late_tag = 0
	return true
}

// call_deadline gives the deadline of a call sent at the time now. A time
// so large that the sum passes the largest time gives the largest time:
// never a deadline in the past.
call_deadline :: proc "contextless" (now: u64) -> u64 {
	if now > system.WAIT_FOREVER - storage_status.ANSWER_BOUND_MILLISECONDS {
		return system.WAIT_FOREVER
	}
	return now + storage_status.ANSWER_BOUND_MILLISECONDS
}

// A call that was sent and whose answer did not come yet: what call_answer
// needs to read the answer. The root service keeps one while it reads a
// file, because it never waits for the storage service
// (docs/MODULE_CONTRACT.md, "A module from a disk").
Sent_Call :: struct {
	function:    module.Function, // The description of the export.
	offset:      u64, // The argument record in the call region.
	buffer:      isolated.Slice, // Where the export writes a Text or a Table result.
	tag:         u32, // The tag of the command: its completion has it.
}

// call_send sends one isolated call of the export with a name, and does
// not wait: call_answer reads its answer. One call is in flight at a time:
// a call uses the call region whole.
call_send :: proc "contextless" (client: ^Client, name: string, arguments: []isolated.Argument) -> (sent: Sent_Call, status: storage_status.Status) {
	if !connected(client) {
		return {}, .Gone
	}
	head, _ := module.header(client.file)
	export: u32
	function: module.Function
	for index in 1 ..< module.count(client.file, .Exports) {
		candidate, described := module.function(client.file, index)
		if described && index != head.entry_export && module.string_at(client.file, candidate.name_offset, candidate.name_count) == name {
			export, function = index, candidate
			break
		}
	}
	if export == 0 {
		return {}, .Refused
	}
	offset, size, buffer, ok := isolated.encode(client.file, function, arguments, client.region)
	if !ok {
		return {}, .Refused
	}
	client.tag += 1
	if !system.send(&client.calls.commands, ring.Record{kind = export, tag = client.tag, values = {0 = offset, 1 = size}}) {
		return {}, .Refused
	}
	return {function = function, offset = offset, buffer = buffer, tag = client.tag}, .Ok
}

// call_answer reads the answer of a call that call_send sent, if it came:
// answered is false when it did not, and the caller waits on the
// completions of the call ring, or does other work. arguments are the
// arguments of call_send. The results are those of call.
call_answer :: proc "contextless" (client: ^Client, sent: ^Sent_Call, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (value: i64, text: []u8, status: storage_status.Status, outcome: call_outcome.Call_Outcome, answered: bool) {
	for _ in 0 ..< ring.CAPACITY {
		completion, has := system.receive(&client.calls.completions)
		if !has {
			break
		}
		if completion.tag != sent.tag {
			continue
		}
		// The completion crosses its one border: the outcome and the record
		// of the service, or Answer_Unreadable for a word that names none.
		answer, ended, record := isolated.answer_of_completion(completion)
		if ended != .Succeeded {
			if error != nil {
				error^ = record
			}
			return 0, nil, .Failed, ended, true
		}
		if sent.function.result == u8(module.Type.Text) {
			result, complete := isolated.result_text(client.region, sent.buffer, u64(answer))
			if !complete {
				return answer, nil, .Refused, .Succeeded, true
			}
			return answer, result, .Ok, .Succeeded, true
		}
		if sent.function.result == u8(module.Type.Table) {
			// The records as bytes: the caller reads them with the record of
			// the export. A table that did not fit gives the rows that did.
			described, described_ok := module.record_type(client.file, sent.function.result_detail)
			if !described_ok {
				return 0, nil, .Refused, .Succeeded, true
			}
			records, _ := isolated.result_table(client.region, sent.buffer, u64(answer), u64(described.size))
			return answer, records, .Ok, .Succeeded, true
		}
		if problem, _ := isolated.tables_return(client.file, sent.function, arguments, client.region, sent.offset); problem != .None {
			return answer, nil, .Refused, .Succeeded, true
		}
		return answer, nil, .Ok, .Succeeded, true
	}
	return 0, nil, .Ok, .Succeeded, false
}

// write makes the object `name` under a place the bytes of data, in one
// commit. The result is the generation of the commit, or the status Failed
// and the error record (see the export write of the storage service).
write :: proc "contextless" (client: ^Client, place: Place, name: string, data: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: storage_status.Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {text = data}}
	generation, _, status, _ = call(client, "write", arguments[:], error)
	return generation, status
}

// remove removes the entry `name` under a place, in one commit: an object
// and its versions, or a tree and all under it. The result is the
// generation of the commit, or the status Failed and the error record; the
// status Absent when the tree has no entry with this name.
remove :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (generation: i64, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	outcome: call_outcome.Call_Outcome
	generation, _, status, outcome = call(client, "remove", arguments[:], error)
	if outcome == .Nothing_Has_That_Name {
		return 0, .Absent
	}
	return generation, status
}

// read copies the bytes of the object `name` under a place into result.
// found is false when the tree has no such object. The status Damaged says
// that the store has the object and that its bytes did not come: the
// caller must not take it for an empty object.
read :: proc "contextless" (client: ^Client, place: Place, name: string, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, found: bool, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	size: i64
	outcome: call_outcome.Call_Outcome
	size, _, status, outcome = call(client, "size", arguments[:], error)
	if outcome == .Data_Damaged {
		return nil, false, .Damaged
	}
	if outcome == .Nothing_Has_That_Name {
		return nil, false, .Ok // No such object: found is false.
	}
	if status != .Ok {
		return nil, false, status
	}
	text: []u8
	_, text, status, outcome = call(client, "read", arguments[:], error)
	if outcome == .Data_Damaged {
		return nil, false, .Damaged
	}
	if status != .Ok {
		return nil, false, status
	}
	if i64(len(text)) != size {
		return nil, false, .Damaged
	}
	count := copy(result, text)
	return result[:count], true, .Ok
}

// size gives the count of bytes of the object `name` under a place, with
// the pending changes of this connection. The status is Absent when the tree
// has no such object.
size :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (bytes: i64, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	outcome: call_outcome.Call_Outcome
	bytes, _, status, outcome = call(client, "size", arguments[:], error)
	#partial switch outcome {
	case .Nothing_Has_That_Name:
		return 0, .Absent
	case .Data_Damaged:
		return 0, .Damaged
	}
	return bytes, status
}

// read_range copies the bytes of an object from `offset` into result, up
// to its end, as this connection sees it: with its pending changes. A hole
// reads as zero bytes. bytes is empty at the end.
read_range :: proc "contextless" (client: ^Client, place: Place, name: string, offset: u64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: storage_status.Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}}
	count: i64
	text: []u8
	outcome: call_outcome.Call_Outcome
	count, text, status, outcome = call(client, "read_range", arguments[:], error)
	if outcome == .Data_Damaged {
		return nil, .Damaged
	}
	if status != .Ok {
		return nil, status
	}
	if i64(len(text)) != count {
		return nil, .Damaged
	}
	copied := copy(result, text)
	return result[:copied], .Ok
}

// write_range writes data at `offset` of an object as a pending change of
// this connection: no commit, no hash. The result is the size of the object
// with the pending changes. commit makes the pending changes one commit.
write_range :: proc "contextless" (client: ^Client, place: Place, name: string, offset: u64, data: []u8, error: ^errors.Error_Record = nil) -> (size: i64, status: storage_status.Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}, {text = data}}
	size, _, status, _ = call(client, "write_range", arguments[:], error)
	return size, status
}

// set_size makes the size of an object `size` bytes, as a pending change of
// this connection: a cut, or an extension with zero bytes.
set_size :: proc "contextless" (client: ^Client, place: Place, name: string, size: u64, error: ^errors.Error_Record = nil) -> storage_status.Status {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = size}}
	_, _, status, _ := call(client, "set_size", arguments[:], error)
	return status
}

// What one commit of pending changes did: the row of the export commit.
Commit_Measure :: struct {
	generation:     i64,
	object_blocks:  i64, // The blocks of the object, holes included.
	held_blocks:    i64, // The blocks that the object holds: its object nodes and its blocks of data.
	changed:        i64, // The blocks of data that the commit changed.
	hashed_blocks:  i64, // The blocks of data whose bytes the commit hashed.
	hashed_nodes:   i64, // The object nodes whose value the commit computed.
	object_written: i64, // The blocks of the block tree that the commit wrote.
	written:        i64, // Each block that the commit wrote.
	milliseconds:   i64,
}

// commit makes the pending changes of this connection on an object one
// commit, on the disk at the return. The measure says what it hashed and
// wrote.
commit :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (measure: Commit_Measure, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	bytes: []u8
	_, bytes, status, _ = call(client, "commit", arguments[:], error)
	if status == .Ok && len(bytes) >= size_of(Commit_Measure) {
		measure = (^Commit_Measure)(raw_data(bytes))^
	}
	return measure, status
}

// drop_pending drops the pending changes of this connection on one object:
// a read of this connection then sees the last commit. The other pending
// objects of the connection stay. Failed with Pending: the object has no
// pending change.
drop_pending :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> storage_status.Status {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	_, _, status, _ := call(client, "drop_pending", arguments[:], error)
	return status
}

// open_tree gives the place of the tree `name` under a place.
open_tree :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (opened: Place, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	result: i64
	result, _, status, _ = call(client, "open", arguments[:], error)
	return Place(result), status
}

// open_store gives a place on the root of another store, for a caller
// that can name it (the export open_store): a caller that acts for the
// principal. Another caller gets Failed with the error kind No_Grant.
open_store :: proc "contextless" (client: ^Client, store: string, error: ^errors.Error_Record = nil) -> (opened: Place, status: storage_status.Status) {
	arguments := [1]isolated.Argument{{text = transmute([]u8)store}}
	result: i64
	result, _, status, _ = call(client, "open_store", arguments[:], error)
	return Place(result), status
}

// close_tree frees a place.
close_tree :: proc "contextless" (client: ^Client, place: Place, error: ^errors.Error_Record = nil) -> storage_status.Status {
	arguments := [1]isolated.Argument{{integer = u64(place)}}
	_, _, status, _ := call(client, "close", arguments[:], error)
	return status
}

// The kind of an entry, in the field `kind` of Add_Row and of Listed: the
// word of a store_contract.Entry_Kind. The field stays a word of 64 bits, as the
// records are the layout of the export.
Entry_Kind :: store_contract.Entry_Kind

// entry_kind_of_word reads the kind of a Listed row from the storage
// service. A word that names no entry, None included, is refused: a reader
// never counts it as an object or as a tree.
entry_kind_of_word :: proc "contextless" (word: i64) -> (kind: Entry_Kind, ok: bool) {
	for member in Entry_Kind {
		if member != .None && i64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// One entry that add makes: its name, at an offset of the bytes of the
// names, and its kind (i64(Entry_Kind.Object): an empty object;
// i64(Entry_Kind.Tree): an empty tree). The layout of the record of the
// export add.
Add_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}

// add makes up to 256 entries under a place in one commit: all or none.
//
// ```odin
// names := "draftsnotes"
// rows := [2]storage.Add_Row{{0, 6, i64(storage.Entry_Kind.Tree)}, {6, 5, i64(storage.Entry_Kind.Object)}}
// generation, status := storage.add(&client, storage.ROOT, rows[:], transmute([]u8)names)
// ```
add :: proc "contextless" (client: ^Client, place: Place, rows: []Add_Row, names: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: storage_status.Status) {
	arguments: [3]isolated.Argument
	arguments[0].integer = u64(place)
	arguments[1].table = {records = ([^]u8)(raw_data(rows))[:len(rows) * size_of(Add_Row)], count = u64(len(rows))}
	arguments[2].table = {records = names, count = u64(len(names))}
	generation, _, status, _ = call(client, "add", arguments[:], error)
	return generation, status
}

// One entry of a page of list. Its name is names[name_offset:][:name_count].
Listed :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64, // The word of an Entry_Kind: read it with entry_kind_of_word.
	size:        i64, // The bytes of an object, the entries of a tree.
	generation:  i64, // The commit of the last change of the entry.
}

// list gives a page of the entries of the tree of a place, after the name
// `after` ("" from the start), as many as `rows` and `names` hold. An
// empty page: no more entries.
list :: proc "contextless" (client: ^Client, place: Place, after: string, rows: []Listed, names: []u8, error: ^errors.Error_Record = nil) -> (page: []Listed, status: storage_status.Status) {
	arguments: [4]isolated.Argument
	arguments[0].integer = u64(place)
	arguments[1].text = transmute([]u8)after
	arguments[2].table = {records = ([^]u8)(raw_data(rows))[:len(rows) * size_of(Listed)], count = 0}
	arguments[3].table = {records = names, count = 0}
	count: i64
	count, _, status, _ = call(client, "list", arguments[:], error)
	if status != .Ok {
		return nil, status
	}
	return rows[:clamp(int(count), 0, len(rows))], .Ok
}

// rename moves the entry `name` under a place to `to_name` under
// `to_place`, in one commit.
rename :: proc "contextless" (client: ^Client, place: Place, name: string, to_place: Place, to_name: string, error: ^errors.Error_Record = nil) -> (generation: i64, status: storage_status.Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(to_place)}, {text = transmute([]u8)to_name}}
	generation, _, status, _ = call(client, "rename", arguments[:], error)
	return generation, status
}

// The answer of the export share: the number of the share and its two
// handles, as this process names them.
Shared :: struct {
	share:  i64, // The number of the share, for `unshare`.
	ring:   i64, // The handle of the call ring of the new connection.
	region: i64, // The handle of its call region.
}

// share makes a new connection whose root is the tree of a place, and
// gives a Client of it. number is for unshare.
share :: proc "contextless" (client: ^Client, place: Place, read_only: bool, error: ^errors.Error_Record = nil) -> (shared: Client, number: i64, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {integer = read_only ? 1 : 0}}
	bytes: []u8
	_, bytes, status, _ = call(client, "share", arguments[:], error)
	if status != .Ok {
		return {}, 0, status
	}
	if len(bytes) < size_of(Shared) {
		return {}, 0, .Refused
	}
	row := (^Shared)(raw_data(bytes))^
	ok: bool
	shared, ok = open_mapped(system.Handle(row.ring), system.Handle(row.region), client.service, client.file)
	if !ok {
		return {}, row.share, .Refused
	}
	return shared, row.share, .Ok
}

// open_handles opens a connection that the root service made, from its
// call ring and its call region, with the file of the storage service that
// describes its exports. It waits for the ready completion of the storage
// service (src/md/api/call_ring_ready.md).
open_handles :: proc "contextless" (ring_memory, region_memory: system.Handle, service: system.Handle, file: []u8, no_clock := false) -> (client: Client, ok: bool) {
	client = open_mapped(ring_memory, region_memory, service, file) or_return
	client.no_clock = no_clock
	if system.connection_ready_wait(&client.calls, service, no_clock = no_clock) != .Ready {
		system.ring_close(&client.calls)
		system.memory_unmap(raw_data(client.region))
		return {}, false
	}
	return client, true
}

// open_mapped maps a call ring and a call region of a connection. A share
// is ready when the storage service gives it: the service maps its ring
// before it gives the handles (system.connection_make), and sends no ready
// completion. The process that made the share opens it.
@(private = "file")
open_mapped :: proc "contextless" (ring_memory, region_memory: system.Handle, service: system.Handle, file: []u8) -> (client: Client, ok: bool) {
	client.ring_memory = ring_memory
	client.region_memory = region_memory
	client.service = service
	client.file = file
	region_pages, size_status := system.memory_size(region_memory)
	if size_status != .Succeeded {
		return {}, false
	}
	status: call_outcome.Call_Outcome
	if client.calls, status = system.ring_open(ring_memory, receive_handles = true); status != .Succeeded {
		return {}, false
	}
	address, map_status := system.memory_map(region_memory)
	if map_status != .Succeeded {
		system.ring_close(&client.calls)
		return {}, false
	}
	client.region = ([^]u8)(address)[:region_pages * system.PAGE_SIZE]
	return client, true
}

// unshare ends a share that this connection made.
unshare :: proc "contextless" (client: ^Client, number: i64, error: ^errors.Error_Record = nil) -> storage_status.Status {
	arguments := [1]isolated.Argument{{integer = u64(number)}}
	_, _, status, _ := call(client, "unshare", arguments[:], error)
	return status
}

// The counts of the store of a connection: the row of the export usage.
// Through a share of a tree, the counts of that tree only: a share never
// sees a count of the whole store (docs/STORAGE.md, "4.3 Read only, and
// revocation").
Usage :: struct {
	objects:  i64, // The objects of the store, or under the tree of a share.
	trees:    i64, // The trees inside the tree of the store, or under the tree of a share.
	versions: i64, // The versions of all the objects.
	blocks:   i64, // The blocks that the store holds. A share of a tree: the blocks of its tree, a block that two objects share counted once for each.
	limit:    i64, // The most blocks of the store, as its grant gives it.
	removing: i64, // The trees that wait in the removal queue. A share of a tree: 0.
}

// USAGE_NOT_COUNTED is the value of objects, trees, versions and blocks
// when the tree of a share needs more reads to count than one call makes,
// or a block of it is wrong.
USAGE_NOT_COUNTED :: -1

// recount asks the storage service for a recount of the names of the
// blocks of its disk, which frees the blocks that only names of no state
// hold. It gives the leaves of the count tree that wait for it: 0 when none
// waits, and nothing starts. Only a process with the start grant Recount
// may ask (Failed with No_Grant, unit Count_Recount).
recount :: proc "contextless" (client: ^Client, error: ^errors.Error_Record = nil) -> (leaves: i64, status: storage_status.Status) {
	leaves, _, status, _ = call(client, "recount", nil, error)
	return leaves, status
}

// usage gives the counts of the store of the connection.
usage :: proc "contextless" (client: ^Client) -> (counts: Usage, status: storage_status.Status) {
	bytes: []u8
	_, bytes, status, _ = call(client, "usage", nil)
	if status == .Ok && len(bytes) >= size_of(Usage) {
		counts = (^Usage)(raw_data(bytes))^
	}
	return counts, status
}

// error_text writes the sentence of an error record that the storage service
// gave: the names come from the description of the export in its file.
error_text :: proc "contextless" (writer: ^system.Writer, client: ^Client, error: ^errors.Error_Record) {
	system.export_error_text(writer, client.file, u32(clamp(error.operation, 0, i64(max(u32)))), "storage", error)
}

// One state of an object, as the export versions gives it: its row.
Version :: struct {
	generation: i64, // The commit of the state: the name of the version.
	time:       i64, // Milliseconds since the format of the disk.
	date:       i64, // Seconds since 1970 (UTC). 0: not known.
	bytes:      i64, // The size of the object in that state.
	own_blocks: i64, // The blocks that only this state holds.
	current:    i64, // 1: the current version.
}

// versions copies the states of an object of the store of the process into
// `into`, the oldest first, the current version last. total is the count of
// all the states: more than len(rows) when they did not fit.
versions :: proc "contextless" (client: ^Client, place: Place, name: string, into: []Version, error: ^errors.Error_Record = nil) -> (rows: []Version, total: i64, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	bytes: []u8
	total, bytes, status, _ = call(client, "versions", arguments[:], error)
	if status != .Ok {
		return nil, total, status
	}
	count := min(len(bytes) / size_of(Version), len(into))
	for index in 0 ..< count {
		into[index] = (^Version)(raw_data(bytes[index * size_of(Version):]))^
	}
	return into[:count], total, .Ok
}

// version copies the bytes of an object at a generation (a version, or the
// current version) into result, one piece of the call region at a time, so
// a version larger than the call region reads whole. Too_Small: result is
// smaller than the bytes. A generation names one state that no commit
// changes, so the pieces are of one state.
version :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: storage_status.Status) {
	filled := 0
	for {
		piece: []u8
		piece, status = version_range(client, place, name, generation, u64(filled), result[filled:], error)
		if status != .Ok {
			return nil, status
		}
		if len(piece) == 0 {
			return result[:filled], .Ok
		}
		filled += len(piece)
		if filled == len(result) {
			// The result is full: one more byte past it means that the
			// version does not fit.
			probe: [1]u8
			more: []u8
			more, status = version_range(client, place, name, generation, u64(filled), probe[:], error)
			if status != .Ok {
				return nil, status
			}
			if len(more) != 0 {
				return nil, .Too_Small
			}
			return result[:filled], .Ok
		}
	}
}

// version_range copies the bytes of an object at a generation from
// `offset` into result, up to the end of the state or of the call region.
// bytes is empty at the end of the state.
version_range :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, offset: u64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: storage_status.Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(generation)}, {integer = offset}}
	count: i64
	text: []u8
	outcome: call_outcome.Call_Outcome
	count, text, status, outcome = call(client, "version", arguments[:], error)
	if status == .Failed && outcome == .Data_Damaged {
		return nil, .Damaged
	}
	if status != .Ok {
		return nil, status
	}
	if i64(len(text)) != count {
		return nil, .Damaged
	}
	copied := copy(result, text)
	return result[:copied], .Ok
}

// One range of bytes that differ between two states: the row of the export
// compare.
Byte_Range :: struct {
	first: i64, // The first byte that differs.
	count: i64, // The bytes of the range.
}

// compare copies into `into` the ranges of bytes that differ between two
// states of an object (two generations). The ranges that do not fit in
// `into` are not given.
compare :: proc "contextless" (client: ^Client, place: Place, name: string, first: i64, second: i64, into: []Byte_Range, error: ^errors.Error_Record = nil) -> (rows: []Byte_Range, status: storage_status.Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(first)}, {integer = u64(second)}}
	bytes: []u8
	_, bytes, status, _ = call(client, "compare", arguments[:], error)
	if status != .Ok {
		return nil, status
	}
	count := min(len(bytes) / size_of(Byte_Range), len(into))
	for index in 0 ..< count {
		into[index] = (^Byte_Range)(raw_data(bytes[index * size_of(Byte_Range):]))^
	}
	return into[:count], .Ok
}

// What one erase of versions did: the row of the export erase_versions.
Erase_Measure :: struct {
	generation: i64, // The generation of the root that the erase wrote last; 0 when the object had no version.
	versions:   i64, // The versions that the erase ended.
	zeroed:     i64, // The blocks written with zero bytes that read back as zero bytes.
	kept:       i64, // The blocks of the versions that another state still names: they keep their bytes.
	damaged:    i64, // The damaged version indexes, leaves and states that were ended with no zeros over them.
}

// erase_versions ends each version of an object of the store of this
// process, and writes zero bytes over each block that no other state names
// after that (src/md/features/version_erase.md). The current version stays.
// Only a process with the grant Versions_Erase may call it, on its own
// store: another process, and a share, get Failed with No_Grant. An object
// with no version gives a row of zeros, and the disk does not change.
erase_versions :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (measure: Erase_Measure, status: storage_status.Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	bytes: []u8
	_, bytes, status, _ = call(client, "erase_versions", arguments[:], error)
	if status == .Ok && len(bytes) >= size_of(Erase_Measure) {
		measure = (^Erase_Measure)(raw_data(bytes))^
	}
	return measure, status
}

// restore makes a version of an object its current version again, in one
// commit. The result is the generation of the commit.
restore :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, error: ^errors.Error_Record = nil) -> (commit: i64, status: storage_status.Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(generation)}}
	commit, _, status, _ = call(client, "restore", arguments[:], error)
	return commit, status
}

// clone makes the object `new_name` under a place a copy of the object
// `name` under the same place, in one commit: the two name the same blocks
// until one of them changes. The result is the generation of the commit.
clone :: proc "contextless" (client: ^Client, place: Place, name: string, new_name: string, error: ^errors.Error_Record = nil) -> (commit: i64, status: storage_status.Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {text = transmute([]u8)new_name}}
	commit, _, status, _ = call(client, "clone", arguments[:], error)
	return commit, status
}
