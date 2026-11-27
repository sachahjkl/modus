package server

// The pages that the server serves by name: objects of its private store in
// the storage service, as each process has one. The server reads them into
// its memory when it starts, and serves them from there: a request never
// waits for the storage service. The principal changes them from the console
// through the exports of the server, functions with typed parameters,
// which write the store first:
//
//   server.put("hello.html", "a text")    a page, new or changed
//   server.remove("hello.html")
//   server.pages()                        the table of the pages
//   server.served()                       the counts of the server
//
// The store holds each page under its name, and one object PAGE_INDEX_NAME
// with the names of the pages.

import "modus:storage"
import "modus:system"
import "modus:web"

PAGE_CAPACITY :: 16
PAGE_SIZE_LIMIT :: 60 * 1024 // Bytes of one page: the call region of a connection has 64 KiB.
PAGE_NAME_LIMIT :: web.PAGE_NAME_LIMIT
// The name of a page in a row of server.pages(): a row has at most 256
// bytes, so a longer name is cut on a whole character, with the cut mark.
PAGE_ROW_NAME_BYTES :: 208
#assert(size_of(Page_Row{}.name) == PAGE_ROW_NAME_BYTES && size_of(Page_Row) <= 256)
PAGE_INDEX_NAME :: web.PAGE_INDEX_NAME
PAGE_MEMORY_PAGES :: PAGE_CAPACITY * PAGE_SIZE_LIMIT / system.PAGE_SIZE

Page_Entry :: struct {
	name:        [PAGE_NAME_LIMIT]u8,
	name_length: int,
	length:      int, // The bytes of the page.
	used:        bool, // false: the place is free.
	served:      u64,
	generation:  u64, // Changes at each put and remove of the place: an answer of an older generation ends, so that it never sends the bytes of another page.
}

// One row of server.pages().
Page_Row :: struct {
	name:   [208]u8, // PAGE_ROW_NAME_BYTES
	bytes:  i64,
	served: i64, // The answers of this page since the start of the server.
	type:   [32]u8,
}

// What server.served() gives.
Served :: struct {
	requests:             i64, // Requests answered.
	answers_2xx:          i64,
	answers_4xx:          i64,
	answers_5xx:          i64,
	connections_accepted: i64,
	connections_open:     i64,
	bytes_in:             i64, // Bytes of data that arrived on connections that ended.
	bytes_out:            i64,
	pages:                i64,
	calls:                i64, // The calls of its exports.
}

pages: [PAGE_CAPACITY]Page_Entry
page_memory: []u8
// The bytes of a put, and of a page that the start reads: the store takes
// them from here, and the page memory changes only when the store took
// them: what is served is always what the store keeps. One byte over the
// limit shows a page that is
// too large.
page_staging: [PAGE_SIZE_LIMIT + 1]u8
page_generation_last: u64 // The generation that the last put or remove gave.

// page_generation_new gives a generation that no place had: never 0.
page_generation_new :: proc "contextless" () -> u64 {
	page_generation_last += 1
	return page_generation_last
}

page_bytes :: proc "contextless" (index: int) -> []u8 {
	return page_memory[index * PAGE_SIZE_LIMIT:][:pages[index].length]
}

page_name :: proc "contextless" (index: int) -> string {
	return string(pages[index].name[:pages[index].name_length])
}

page_find :: proc "contextless" (name: string) -> int {
	for &item, index in pages {
		if item.used && string(item.name[:item.name_length]) == name {
			return index
		}
	}
	return -1
}

// pages_load opens the private store and reads the pages into memory.
pages_load :: proc "contextless" (ctx: ^system.Context) {
	memory, memory_status := system.memory_create(PAGE_MEMORY_PAGES)
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Succeeded || map_status != .Succeeded {
		fail("no memory for the pages")
	}
	page_memory = ([^]u8)(address)[:PAGE_MEMORY_PAGES * system.PAGE_SIZE]
	store_client, store_connected = storage.open(ctx)
	if !store_connected {
		system.log_fact(.Info, No_Private_Store{})
		return
	}
	index: [PAGE_CAPACITY * web.PAGE_INDEX_ENTRY_SIZE]u8
	bytes, found, status := storage.read(&store_client, storage.ROOT, PAGE_INDEX_NAME, index[:])
	if status != .Ok || !found || len(bytes) != size_of(index) {
		system.log_fact(.Info, New_Store{})
		return
	}
	// The store is hostile input too: each name
	// must follow the rules and come once, each page must fit.
	loaded, refused := 0, 0
	for place in 0 ..< PAGE_CAPACITY {
		name, name_ok := web.page_index_entry(index[:], place)
		if !name_ok {
			refused += 1
			continue
		}
		if len(name) == 0 {
			continue
		}
		text, page_found, page_status := storage.read(&store_client, storage.ROOT, name, page_staging[:])
		if page_status != .Ok || !page_found {
			continue
		}
		if len(text) > PAGE_SIZE_LIMIT {
			refused += 1
			continue
		}
		copy(page_memory[place * PAGE_SIZE_LIMIT:][:PAGE_SIZE_LIMIT], text)
		pages[place] = {name_length = copy(pages[place].name[:], name), length = len(text), used = true, generation = page_generation_new()}
		loaded += 1
	}
	system.log_fact(.Info, Pages_Read{loaded = u64(loaded), refused = u64(refused)})
}

// counts_html writes the page / : the counts of the server as HTML, and
// the links to its pages.
counts_html :: proc "contextless" (buffer: []u8) -> string {
	writer := system.Writer{buffer = buffer}
	text :: proc "contextless" (writer: ^system.Writer, parts: ..system.Part) {
		for part in parts {
			system.write_part(writer, part)
		}
	}
	row :: proc "contextless" (writer: ^system.Writer, name: string, value: u64) {
		text(writer, "<tr><td>", name, "</td><td>", value, "</td></tr>\n")
	}
	text(&writer, "<!doctype html>\n<html><head><title>server</title></head><body>\n<h1>server</h1>\n<p>An HTTP/1.1 server of this system: TCP in the process, one thread, one table of ", u64(CAPACITY), " connections.</p>\n<table>\n")
	row(&writer, "connections open", u64(tcp_open_count()))
	row(&writer, "connections accepted", accepted)
	row(&writer, "requests answered", requests_answered)
	row(&writer, "answers 2xx", status_classes[2])
	row(&writer, "answers 4xx", status_classes[4])
	row(&writer, "answers 5xx", status_classes[5])
	row(&writer, "bytes in", bytes_in)
	row(&writer, "bytes out", bytes_out)
	row(&writer, "retransmitted segments", retransmissions)
	row(&writer, "milliseconds since the start", system.time() - start_time)
	row(&writer, "kernel entries of this process", system.kernel_entries())
	text(&writer, "</table>\n<p>pages:")
	for &item, index in pages {
		if item.used {
			// The names follow the rules of web.page_name_valid; they are
			// escaped anyway: the store is hostile input too.
			escaped: [6 * PAGE_NAME_LIMIT]u8
			name := string(escaped[:web.html_text_escape(escaped[:], page_name(index))])
			text(&writer, " <a href=\"/", name, "\">", name, "</a>")
		}
	}
	text(&writer, "</p>\n</body></html>\n")
	return system.written(&writer)
}

// counts_json writes the page /counts.json: the same counts as one JSON object.
counts_json :: proc "contextless" (buffer: []u8) -> string {
	return system.format(buffer, "{\"connections_open\":", u64(tcp_open_count()), ",\"connections_accepted\":", accepted, ",\"requests\":", requests_answered, ",\"answers_2xx\":", status_classes[2], ",\"answers_4xx\":", status_classes[4], ",\"answers_5xx\":", status_classes[5], ",\"bytes_in\":", bytes_in, ",\"bytes_out\":", bytes_out, ",\"retransmissions\":", retransmissions, ",\"uptime_ms\":", system.time() - start_time, ",\"kernel_entries\":", system.kernel_entries(), "}\n")
}

tcp_open_count :: proc "contextless" () -> int {
	count := 0
	for &item in connections {
		if item.state != .Closed && item.state != .Time_Wait {
			count += 1
		}
	}
	return count
}
