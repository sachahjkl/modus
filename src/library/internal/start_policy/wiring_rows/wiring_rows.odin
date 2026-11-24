// How the default start policy applies the wiring rows of its start list
// (src/md/features/module_outputs.md, "The wiring rows of a start list"):
// for the start of one row, which readers to lend, the wiring list in the
// list page, and the way back of the numbers lent when a lend or the list
// fails. A part with no call of the kernel, which the host tests: the
// start policy gives it the lend through its root ring as a procedure, and
// keeps only the calls (src/md/features/start_policy.md, "The rescue
// start policy").
package wiring_rows

import "modus:contract/call_outcome"
import "modus:contract/output"
import "modus:contract/start_list"

// The bytes of the list page in which the start policy writes the wiring
// list of one start.
PAGE_BYTES :: output.WIRING_LIST_BYTES_MOST

// How the start of one row goes after its wiring rows.
Outcome :: enum u8 {
	No_List            = 0, // The row writes into no wiring row: its Start names no list.
	Listed             = 1, // The list of the row is in the page: its Start names it.
	Reader_Not_Running = 2, // A reader row does not run: the row does not start.
	Lend_Refused       = 3, // A lend failed: the row does not start.
	List_Not_Written   = 4, // The list does not fit the page: the row does not start.
}

// What the start of one row needs, after row_list_prepare.
Prepared :: struct {
	outcome:    Outcome,
	reader_row: u32, // Reader_Not_Running and Lend_Refused: the reader row, from 1. Else 0.
	status:     call_outcome.Call_Outcome, // Lend_Refused: the outcome of the lend. List_Not_Written: Argument_Refused. Else Succeeded.
	// The page holds a list of no row with the numbers lent before the
	// failure: sent with Wire, the root service refuses it and closes each
	// one (src/md/features/module_outputs.md, "A lent handle with no
	// command").
	give_back:  bool,
}

// A lend of the process of the start row reader_row (from 0) to the root
// service, through the root ring: the number that the root service holds,
// or the outcome of the refusal.
Lend :: #type proc "contextless" (reader_row: int) -> (number: u32, status: call_outcome.Call_Outcome)

// row_has_wirings says if the start row writer (from 0) writes into a
// wiring row: its start needs the list page.
row_has_wirings :: proc "contextless" (list: ^start_list.List, writer: int) -> bool {
	for &wiring_row in list.wirings[:list.wiring_count] {
		if wiring_row.writer_row == writer {
			return true
		}
	}
	return false
}

// readers_of_row gives the reader rows of the wiring rows of the writer
// row, each once, in the order of their first wiring row: the start policy
// lends readers[n] at the place n + 1. absent is the first reader row that
// does not run, and then count is 0. With no wiring row, count is 0 and
// absent is -1.
readers_of_row :: proc "contextless" (list: ^start_list.List, writer: int, running: []bool, readers: ^[output.WIRING_LIST_ROW_LIMIT]int) -> (count: int, absent: int) {
	for &wiring_row in list.wirings[:list.wiring_count] {
		if wiring_row.writer_row != writer {
			continue
		}
		reader := wiring_row.reader_row
		if reader < 0 || reader >= len(running) || !running[reader] {
			readers^ = {}
			return 0, reader
		}
		known := false
		for earlier in readers[:count] {
			known ||= earlier == reader
		}
		// The rows of one writer are the list of its start, one command:
		// a reader past the room of a list stays out, and list_of_row then
		// writes no list for the row.
		if !known && count < len(readers) {
			readers[count] = reader
			count += 1
		}
	}
	return count, -1
}

// list_of_row writes in page the wiring list of the start of the writer
// row: its wiring rows in their order, each reader named by its place in
// handles, which holds the number lent for each row of readers, in that
// order, then the terms of the rows that have terms, after the handles,
// each row with its place there. ok is false when the page is too small,
// when handles and readers differ in count, or when a reader of a row is
// not in readers.
list_of_row :: proc "contextless" (list: ^start_list.List, writer: int, readers: []int, handles: []u32, page: []u8) -> (rows: int, ok: bool) {
	if len(handles) != len(readers) {
		return 0, false
	}
	written: [output.WIRING_LIST_ROW_LIMIT]output.Wiring
	terms_of: [output.WIRING_LIST_ROW_LIMIT]int // The wiring row of each written row.
	for &wiring_row, row_index in list.wirings[:list.wiring_count] {
		if wiring_row.writer_row != writer {
			continue
		}
		place := -1
		for reader, index in readers {
			if reader == wiring_row.reader_row {
				place = index
				break
			}
		}
		if place < 0 || rows >= len(written) {
			return 0, false
		}
		written[rows] = wiring_row.wiring
		written[rows].reader_handle = u32(place + 1)
		terms_of[rows] = row_index
		rows += 1
	}
	if rows == 0 {
		return 0, false
	}
	terms_at := output.wiring_terms_start(rows, len(handles))
	for index in 0 ..< rows {
		if written[index].terms_count == 0 {
			continue
		}
		written[index].terms_offset = u32(terms_at)
		terms_at += start_list.START_LIST_TERMS_BYTES
	}
	if terms_at > len(page) || !output.wiring_list_write(page, written[:rows], handles) {
		return 0, false
	}
	for index in 0 ..< rows {
		if written[index].terms_count != 0 {
			terms := list.wirings[terms_of[index]].terms
			copy(page[written[index].terms_offset:][:start_list.START_LIST_TERMS_BYTES], terms[:])
		}
	}
	return rows, true
}

// row_list_prepare decides the start of the writer row (from 0): no list
// for a row with no wiring row; no start when a reader row does not run
// (running says it for each start row); else it lends the process of each
// reader through lend and writes the list in page. A lend that fails, and
// a list that does not fit, leave in page the way back of the numbers
// already lent. The page is cleared before each list.
row_list_prepare :: proc "contextless" (list: ^start_list.List, writer: int, running: []bool, page: []u8, lend: Lend) -> Prepared {
	readers: [output.WIRING_LIST_ROW_LIMIT]int
	count, absent := readers_of_row(list, writer, running, &readers)
	if absent >= 0 {
		return {outcome = .Reader_Not_Running, reader_row = u32(absent + 1), status = .Succeeded}
	}
	if count == 0 {
		return {outcome = .No_List, status = .Succeeded}
	}
	handles: [output.WIRING_LIST_ROW_LIMIT]u32
	prepared := Prepared{outcome = .Listed, status = .Succeeded}
	lent := 0
	for reader in readers[:count] {
		number, status := lend(reader)
		if status != .Succeeded {
			prepared = {outcome = .Lend_Refused, reader_row = u32(reader + 1), status = status}
			break
		}
		handles[lent] = number
		lent += 1
	}
	page_clear(page)
	if prepared.outcome == .Listed {
		if _, written := list_of_row(list, writer, readers[:count], handles[:lent], page); written {
			return prepared
		}
		prepared = {outcome = .List_Not_Written, status = .Argument_Refused}
		page_clear(page)
	}
	prepared.give_back = lent > 0 && output.wiring_list_write(page, nil, handles[:lent])
	return prepared
}

@(private = "file")
page_clear :: proc "contextless" (page: []u8) {
	for &value in page {
		value = 0
	}
}
