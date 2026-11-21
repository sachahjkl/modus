package operation

import "modus:contract/enum_word"

// The two rules of a reader of the ring of the log (Log_Head, Log_Record).
//
// The kernel writes record W in the slot W % LOG_RECORD_CAPACITY, over the
// record W - LOG_RECORD_CAPACITY, and stores `written = W + 1` only after
// the whole record. While it writes, `written` is still W. So the record
// W - LOG_RECORD_CAPACITY, whose number is `written - LOG_RECORD_CAPACITY`,
// can be half written: a reader never takes it. A copy that holds the old
// head of a record and the new text would give one process the text of
// another one.
//
// A reader copies the record, puts an acquire fence, reads `written` again,
// and keeps the copy only when `log_copy_kept` holds. The fence keeps the
// compiler from moving a load of the copy after that second load; the
// processor does not reorder two loads.

// log_first_kept gives the first record from the number `after` on that a
// reader can still copy whole, and the count of the records from `after`
// that it cannot: the kernel wrote over them, or writes over the oldest one
// now.
//
// Example: with `written = LOG_RECORD_CAPACITY + 10` and `after = 0`, the
// first record that a reader can copy is 11, and 11 records are lost.
log_first_kept :: proc "contextless" (after: u64, written: u64) -> (next: u64, lost: u64) {
	next = min(after, written)
	if written - next >= LOG_RECORD_CAPACITY {
		lost = written - next - LOG_RECORD_CAPACITY + 1
		next += lost
	}
	return next, lost
}

// log_copy_kept says if the copy of the record `number` is whole: the
// kernel did not start to write over it before `written_after_copy`, the
// value of `written` that the reader loaded after the copy and the fence.
log_copy_kept :: proc "contextless" (number: u64, written_after_copy: u64) -> bool {
	return written_after_copy - number < LOG_RECORD_CAPACITY
}

// The rules of an own log ring (src/md/features/own_log_ring.md). The
// kernel copies it under the log lock, so a copy is never torn: the two
// rules above are for the whole log only.

// The distance below which an own number names a record before the count:
// the own number has 32 bits, and the ring holds far fewer records.
OWN_NUMBER_HALF :: u64(1) << 31

// own_log_window gives which records of an own log ring a reader receives
// when it asks from the own number `after` on, and the process wrote
// `written` records: the count of the first one, the own records from
// `after` that the ring no longer keeps, and the records from the first one
// to the last one. `after` is an own number, the low 32 bits of a count: it
// names the count below `written` with these low bits, up to 2^31 before
// it. An `after` past `written` gives no record.
//
// Example: with `written = OWN_LOG_RECORD_CAPACITY + 10` and `after = 0`,
// the first record is 10, 10 records are lost, and the ring gives
// OWN_LOG_RECORD_CAPACITY records.
own_log_window :: proc "contextless" (written: u64, after: u32) -> (first: u64, lost: u64, total: u64) {
	distance := u64(u32(written) - after)
	if distance >= OWN_NUMBER_HALF {
		return written, 0, 0
	}
	first = written - min(distance, written)
	oldest := written - min(written, OWN_LOG_RECORD_CAPACITY)
	if first < oldest {
		lost = oldest - first
		first = oldest
	}
	return first, lost, written - first
}

// own_log_place gives where the record with the count `number` of a
// process is in its own log ring: the page of the ring, and the offset in
// that page. A page holds whole records.
own_log_place :: proc "contextless" (number: u64) -> (page: u64, offset: u64) {
	RECORDS_OF_A_PAGE :: 4096 / size_of(Log_Record)
	place := number % OWN_LOG_RECORD_CAPACITY
	return place / RECORDS_OF_A_PAGE, place % RECORDS_OF_A_PAGE * size_of(Log_Record)
}

// The bytes of the head of a line of the serial port: "[", the name, "] ".
LOG_LINE_HEAD_CAPACITY :: 1 + LOG_NAME_BYTES + 2
// The bytes of the name of a process in a record (`Log_Record.name`).
LOG_NAME_BYTES :: 32
#assert(offset_of(Log_Record, runs) - offset_of(Log_Record, name) == LOG_NAME_BYTES)
// The bytes of the module hash that the line of a fact names: the module
// tag. The tool refuses a build where two module files share them.
LOG_FACT_LINE_MODULE_HASH_BYTES :: 4
// The bytes of the fact key that the line of a fact names, its high bytes:
// the key tag. The tool refuses a module where two fact types share them.
LOG_FACT_LINE_KEY_BYTES :: 3
// The letter of a run of one zero value byte in the line of a fact; the
// letters after it, up to "z", are the runs of 2 to 20 zero bytes. No
// letter of a run is a hexadecimal digit.
LOG_FACT_LINE_ZERO_RUN_FIRST: u8 : 'g'
// The longest run of zero bytes that one letter writes.
LOG_FACT_LINE_ZERO_RUN_MOST :: int('z' - 'g') + 1
// The mark after the key tag of the first record of a fact of several
// records, before the digit of its count of records: "*2".
LOG_FACT_LINE_PART_COUNT_MARK: u8 : '*'
// The mark before the values of each record of a fact after its first.
LOG_FACT_LINE_PART_MARK: u8 : '/'
// The most bytes that one record of a fact puts on the line of its fact
// (log_fact_line): "#", the digits of the module tag, ":", the digits of the
// key tag, the mark and the digit of a count of records, a space or the
// mark of a part, and two digits for each value byte. A run of zero bytes
// takes fewer bytes than their digits.
LOG_FACT_LINE_BYTES_MOST :: 1 + 2 * LOG_FACT_LINE_MODULE_HASH_BYTES + 1 + 2 * LOG_FACT_LINE_KEY_BYTES + 2 + 1 + 2 * LOG_FACT_VALUE_CAPACITY
#assert(LOG_FACT_RECORDS_MOST <= 9) // One digit says the count of the records of a fact.
// The most bytes that one record puts on the serial port: the end of a line
// that a lost record left open, the head, its text or the line of its fact,
// and the end of the line.
LOG_SERIAL_LINE_BYTES_MOST :: 2 + LOG_LINE_HEAD_CAPACITY + max(LOG_TEXT_CAPACITY, LOG_FACT_LINE_BYTES_MOST) + 2

// log_record_form reads the form of a record through the border: false for
// a byte that names no form. A record comes from the memory of the log, and
// a reader trusts its bytes no more than the bytes of a file.
log_record_form :: proc "contextless" (record: ^Log_Record) -> (form: Log_Record_Form, ok: bool) {
	return enum_word.member_of_word(Log_Record_Form, u64(record.form))
}

// log_record_fact gives the fact of a record of the form Fact: the bytes
// after the name of the process. The caller read the form first.
log_record_fact :: proc "contextless" (record: ^Log_Record) -> ^Log_Fact {
	return (^Log_Fact)(&record.runs)
}

// log_fact_key_tag gives the key tag of a fact key: its high
// LOG_FACT_LINE_KEY_BYTES bytes, which the line of a fact names.
log_fact_key_tag :: proc "contextless" (key: u64) -> u32 {
	return u32(key >> (64 - 8 * LOG_FACT_LINE_KEY_BYTES))
}

// log_fact_line writes into `line` the line of a fact on the serial port,
// after its head, and gives its bytes: "#", the module tag (the first
// bytes of the module hash), ":" and the key tag (the high bytes of the
// fact key), in hexadecimal, then a space and the value bytes up to their
// last byte that is not zero; no space when every value byte is zero. A
// value byte that is not zero is two hexadecimal digits. A run of zero
// bytes is one letter from "g", one byte, to "z", 20 bytes, and a longer
// run is "z" until the rest fits one letter: most values are small
// integers in words of 8 bytes and short names in Text fields, so most
// value bytes are zero. It writes no text of the writer, so a fact cannot
// forge or hide a line (src/md/features/log_facts.md, "The serial port").
// A count past the capacity takes the capacity.
//
// A fact of several records is one line (src/md/features/log_facts.md, "A
// fact of several records"): its first record writes "*" and the digit of
// its count of records after the key tag; each next record, which
// continues the line (`continuation`), writes "/" and its values. A record
// after the first that starts a line, because the drain lost the record
// before it, writes its head and "/" with no count: the tool refuses that
// line, and shows it raw. Each record cuts its own last zeros: each record
// before the last of a fact holds LOG_FACT_VALUE_CAPACITY bytes.
//
// Example: the hash 1a2b3c4d..., the key 0xfa0adf38a559f4d1 and the
// values 0c 00 00 23 00 give "#1a2b3c4d:fa0adf 0ch23"; a fact of two
// records whose second record holds 0d gives "#1a2b3c4d:fa0adf*2 0ch23" then
// "/0d" on the same line.
log_fact_line :: proc "contextless" (fact: ^Log_Fact, line: ^[LOG_FACT_LINE_BYTES_MOST]u8, continuation := false) -> int {
	count := 0
	put_byte :: proc "contextless" (line: ^[LOG_FACT_LINE_BYTES_MOST]u8, count: ^int, value: u8) {
		digit :: proc "contextless" (nibble: u8) -> u8 {
			return nibble < 10 ? '0' + nibble : 'a' + nibble - 10
		}
		line[count^] = digit(value >> 4)
		line[count^ + 1] = digit(value & 0xF)
		count^ += 2
	}
	if !continuation {
		line[count] = '#'
		count += 1
		for value in fact.module_hash[:LOG_FACT_LINE_MODULE_HASH_BYTES] {
			put_byte(line, &count, value)
		}
		line[count] = ':'
		count += 1
		for shift := 56; shift >= 64 - 8 * LOG_FACT_LINE_KEY_BYTES; shift -= 8 {
			put_byte(line, &count, u8(fact.key >> uint(shift)))
		}
		if fact.part == 0 && fact.part_count >= 2 {
			line[count] = LOG_FACT_LINE_PART_COUNT_MARK
			line[count + 1] = '0' + min(fact.part_count, 9)
			count += 2
		}
	}
	used := min(int(fact.value_count), LOG_FACT_VALUE_CAPACITY)
	for used > 0 && fact.values[used - 1] == 0 {
		used -= 1
	}
	if continuation || fact.part > 0 {
		line[count] = LOG_FACT_LINE_PART_MARK
		count += 1
	} else {
		if used == 0 {
			return count
		}
		line[count] = ' '
		count += 1
	}
	place := 0
	for place < used {
		if fact.values[place] != 0 {
			put_byte(line, &count, fact.values[place])
			place += 1
			continue
		}
		// The bound is in the loop itself: a fact in memory that another
		// thread writes can turn the byte at used - 1 to zero after the
		// loop above read it.
		run := 0
		for place < used && fact.values[place] == 0 {
			run += 1
			place += 1
		}
		for run > 0 {
			letter_run := min(run, LOG_FACT_LINE_ZERO_RUN_MOST)
			line[count] = LOG_FACT_LINE_ZERO_RUN_FIRST + u8(letter_run - 1)
			count += 1
			run -= letter_run
		}
	}
	return count
}

// log_line_head writes into `head` the head of the line of a record on the
// serial port, and gives its bytes: `[name] ` for a record of a process
// that starts a line, and nothing for a record of the kernel or a record
// that continues the line of the record before it (`line_open`). The
// kernel writes the serial port from the whole log with it, so the line of
// a long text that the log splits into records is one line again
// (src/md/features/log_side_channels.md).
log_line_head :: proc "contextless" (record: ^Log_Record, line_open: bool, head: ^[LOG_LINE_HEAD_CAPACITY]u8) -> int {
	if line_open || record.process == 0 {
		return 0
	}
	count := 0
	head[count] = '['
	count += 1
	for byte_value in record.name {
		if byte_value == 0 {
			break
		}
		head[count] = byte_value
		count += 1
	}
	head[count] = ']'
	head[count + 1] = ' '
	return count + 2
}

#assert(4096 % size_of(Log_Record) == 0)
#assert(OWN_LOG_RECORD_CAPACITY == OWN_LOG_PAGES * (4096 / size_of(Log_Record)))
