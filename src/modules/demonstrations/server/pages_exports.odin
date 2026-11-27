#+build freestanding
package server

// Freestanding-only module exports for the server service. Kept in a separate
// freestanding file so the exported symbol `remove` does not collide with host
// libc `remove` during host unit tests.

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:system"
import "modus:web"

// index_write writes the names of the pages in the store.
@(private = "file")
index_write :: proc "contextless" () -> bool {
	index: [PAGE_CAPACITY * web.PAGE_INDEX_ENTRY_SIZE]u8
	for &item, place in pages {
		if item.used {
			copy(index[place * web.PAGE_INDEX_ENTRY_SIZE:][:web.PAGE_INDEX_ENTRY_SIZE - 1], page_name(place))
		}
	}
	_, status := storage.write(&store_client, storage.ROOT, PAGE_INDEX_NAME, ([^]u8)(&index)[:size_of(index)])
	return status == .Ok
}

// acts_for_principal says if the caller of the export that runs acts for the principal:
// only such a caller changes the pages that the network sees.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// put writes a page in the private store of the server, and serves it at /name from now on.
//
// It is the one way to change what the network sees: HTTP itself refuses PUT and DELETE (405), because the
// network is not authenticated. The order is the store first, then the memory of the server: the page that is
// served is always the page that the store keeps, and a refused write leaves the old page in place. A page that
// changes keeps its count of answers.
//
// - **name**: 1 to 64 bytes of letters, digits, ".", "-" and "_". Its end gives the content type: .html, .txt,
//   .css, .js, .json or .svg.
// - **text**: the bytes of the page, 60 KiB at most (the call region of a connection has 64 KiB).
//
// The caller must act for the principal (**Acts_For_Principal**). The result is the bytes of the page, or an
// outcome with an error record:
//
// - `Grant_Or_Right_Missing`, `No_Grant`: the caller does not act for the principal.
// - `Argument_Refused`, `Empty`, `Too_Long` or `Bad_Byte`: the name; for `Bad_Byte`, the record holds the place of
//   the byte.
// - `Argument_Refused`, `Too_Long`: the text has more than 60 KiB.
// - `Budget_Or_Capacity_Exhausted`, `Full`: 16 pages exist, and the name is new.
// - `Callee_Unavailable`, `Refused`: the server has no store, or the storage service refused the page or the index
//   of the pages. The page that is served did not change.
//
// Example: `server.put("hello.html", "<h1>hello</h1>")`, then the host reads `http://<the address>/hello.html`.
@(export, link_name = "put")
put :: proc "c" (name: ^string, text: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	// The call region stays writable by the caller during the call: copy
	// the name one time before the checks, then check and use the copy only.
	name_copy: [PAGE_NAME_LIMIT + 1]u8
	name_length := min(len(name^), len(name_copy))
	copy(name_copy[:], name^)
	if len(name^) == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1, 0, PAGE_NAME_LIMIT)
	}
	if len(name^) > PAGE_NAME_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(name^)), PAGE_NAME_LIMIT)
	}
	if ok, bad := web.page_name_valid(string(name_copy[:name_length])); !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Byte, .Bytes, 1, i64(max(bad, 0)), 0, bad >= 0 ? i64(name_copy[bad]) : 0)
	}
	if len(text^) > PAGE_SIZE_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(text^)), PAGE_SIZE_LIMIT)
	}
	if !store_connected {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	key := string(name_copy[:name_length])
	place := page_find(key)
	if place < 0 {
		for &item, index in pages {
			if !item.used {
				place = index
				break
			}
		}
	}
	if place < 0 {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Records, 0, 0, PAGE_CAPACITY)
	}
	// The bytes go to the staging buffer first (the call region can
	// change), then to the store, then to the page memory: the page that is
	// served changes only when the store took it.
	length := copy(page_staging[:PAGE_SIZE_LIMIT], text^)
	if _, status := storage.write(&store_client, storage.ROOT, key, page_staging[:length]); status != .Ok {
		system.log_fact(.Info, Page_Refused{page = page_field(key)})
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store, 0, 0, 0, i64(status))
	}
	was_used := pages[place].used
	// A page that changes keeps its count of answers.
	served := was_used ? pages[place].served : 0
	copy(page_memory[place * PAGE_SIZE_LIMIT:][:PAGE_SIZE_LIMIT], page_staging[:length])
	pages[place] = {length = length, used = true, name_length = name_length, served = served, generation = page_generation_new()}
	copy(pages[place].name[:], key)
	if !was_used && !index_write() {
		// The index does not name the page: the page goes out again, so
		// that the store and what is served stay the same.
		pages[place] = {generation = page_generation_new()}
		arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name_copy[:name_length]}}
		storage.call(&store_client, "remove", arguments[:])
		system.log_fact(.Info, Index_Refused{page = page_field(key)})
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	system.log_fact(.Info, Page_Stored{page_size = value_kinds.Size_In_Bytes(length), page = page_field(key)})
	return .Succeeded, i64(length)
}

// remove takes a page out of the private store of the server: /name gives 404 from now on.
//
// The store first: when the storage service refuses, the page stays in the store and stays served, so what the
// network sees never differs from what the store keeps.
//
// - **name**: the name of a page, as [put](server.put) gave it.
//
// The caller must act for the principal (**Acts_For_Principal**). The result is 0, or an outcome with an error
// record:
//
// - `Grant_Or_Right_Missing`, `No_Grant`: the caller does not act for the principal.
// - `Nothing_Has_That_Name`, `Absent`: no page has this name.
// - `Callee_Unavailable`, `Refused`: the storage service refused the removal; the page is still served.
@(export, link_name = "remove")
remove :: proc "c" (name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [PAGE_NAME_LIMIT + 1]u8
	name_length := min(len(name^), len(name_copy))
	copy(name_copy[:], name^)
	place := page_find(string(name_copy[:name_length]))
	if place < 0 || len(name^) > PAGE_NAME_LIMIT {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Objects, 1)
	}
	// The store first: a page that the store keeps stays served. Else a
	// refused remove gives 404 until the next start of the server, and then
	// the page again.
	arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name_copy[:name_length]}}
	_, _, status, _ := storage.call(&store_client, "remove", arguments[:])
	if status != .Ok {
		system.log_fact(.Info, Removal_Refused{page = page_field(string(name_copy[:name_length]))})
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store, 0, 0, 0, i64(status))
	}
	pages[place] = {generation = page_generation_new()}
	if !index_write() {
		// The object is out of the store; the index still names it, and the
		// next start skips a name with no object.
		system.log_fact(.Info, Index_Refused_After_Removal{page = page_field(string(name_copy[:name_length]))})
	}
	system.log_fact(.Info, Page_Removed{page = page_field(string(name_copy[:name_length]))})
	return .Succeeded, 0
}

// pages gives one row for each page that the server serves: its name, its bytes, the answers of it since the start, its content type.
//
// Each caller gets the rows, with no grant: the pages are public on the network already.
//
// - **result**: a table of `Page_Row` rows; the call fills at most its length.
//
// The result is the count of pages, 16 at most. It never fails.
@(export, link_name = "pages")
pages_export :: proc "c" (result: ^[]Page_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	total := 0
	for &item, index in pages {
		if !item.used {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {bytes = i64(item.length), served = i64(item.served)}
			row.name = value_kinds.text_field(page_name(index), PAGE_ROW_NAME_BYTES)
			copy(row.type[:len(row.type) - 1], web.content_type_of_name(page_name(index)))
		}
		total += 1
	}
	return .Succeeded, i64(total)
}

// served gives the counts of the server: the requests that it answered, by class of status, its connections, its bytes and its pages.
//
// These are facts of the server itself: each caller sees them. The bytes in count the data of connections that
// ended; `calls` counts the calls of the exports.
//
// - **result**: one `Served` record.
//
// It never fails.
@(export, link_name = "served")
served :: proc "c" (result: ^Served) {
	page_count := 0
	for &item in pages {
		if item.used {
			page_count += 1
		}
	}
	result^ = {
		requests             = i64(requests_answered),
		answers_2xx          = i64(status_classes[2]),
		answers_4xx          = i64(status_classes[4]),
		answers_5xx          = i64(status_classes[5]),
		connections_accepted = i64(accepted),
		connections_open     = i64(tcp_open_count()),
		bytes_in             = i64(bytes_in),
		bytes_out            = i64(bytes_out),
		pages                = i64(page_count),
		calls                = i64(service.calls),
	}
}
