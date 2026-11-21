package operation

// The join of a log fact of several records (src/md/features/log_facts.md,
// "A fact of several records"). The kernel writes the records of one fact
// in a row, under one lock: the first record holds the first
// LOG_FACT_VALUE_CAPACITY value bytes, each next record the next ones, and
// each but the last has `more`. A reader that takes the records in their
// order joins them with log_fact_join_take. A record that the log lost
// (the log wrote over it, the reader did not read it) breaks its fact: the
// reader shows each record of a broken fact raw, after
// LOG_FACT_JOIN_BROKEN_MARK, and never writes a sentence from the values
// of two facts or from a fact with a hole.

// log_fact_part_count gives the records of a fact of a count of value
// bytes: one for a fact of 0 to LOG_FACT_VALUE_CAPACITY bytes, then one for
// each LOG_FACT_VALUE_CAPACITY bytes more.
//
// Example: 0 and 144 bytes are 1 record; 145 bytes are 2; 576 bytes are 4.
log_fact_part_count :: proc "contextless" (value_bytes: int) -> int {
	if value_bytes <= LOG_FACT_VALUE_CAPACITY {
		return 1
	}
	return (value_bytes + LOG_FACT_VALUE_CAPACITY - 1) / LOG_FACT_VALUE_CAPACITY
}

// The words that a reader writes before the raw form of a record of a fact
// that it cannot join.
LOG_FACT_JOIN_BROKEN_MARK :: "(a fact whose records are not whole) "

// Why a reader cannot join a fact of several records.
Log_Fact_Join_Fault :: enum u8 {
	None               = 0, // The record is the next part of the open fact, or a fact of its own.
	Part_Without_First = 1, // A record after the first of its fact, and no fact is open: its first record is lost.
	Missing_Part       = 2, // The open fact lost a record: the number of the record is not the next one, or its part is not the next part.
	Other_Process      = 3, // The record after a record of the open fact is a record of another process.
	Other_Fact         = 4, // The next record of the process is a part of another fact: another hash, key or count of records.
	Part_Count         = 5, // A count of records of 0, or past LOG_FACT_RECORDS_MOST, or a part past its count.
	Value_Count        = 6, // A record before the last of its fact that does not hold LOG_FACT_VALUE_CAPACITY bytes, or a record of more.
}

// One record of a fact, as a reader read it.
Log_Fact_Part :: struct {
	number:      u64, // The number of the record in the numbering of the reader: the whole log, or the own records of a process. The records of one fact have numbers that follow each other.
	writer:      u64, // The process of the record: its slot and its process serial (log_fact_writer), or 0 for a reader that does not know it.
	module_hash: [32]u8,
	key:         u64,
	part:        int, // The place of the record in its fact, from 0.
	part_count:  int, // The records of its fact.
	values:      []u8, // The value bytes of the record: value_count of them.
}

// What a reader keeps while it joins the records of one fact. A zero
// value has no open fact.
Log_Fact_Join :: struct {
	open:        bool, // A fact has its first records here, and waits for the next one.
	number:      u64, // The number of the last record taken.
	writer:      u64,
	module_hash: [32]u8,
	key:         u64,
	part_count:  int,
	next_part:   int,
	value_count: int, // The value bytes taken: values[:value_count] of a whole fact.
	values:      [LOG_FACT_VALUES_MOST]u8,
}

// log_fact_writer gives the writer of a record: its process slot and its
// process serial in one word.
log_fact_writer :: proc "contextless" (record: ^Log_Record) -> u64 {
	return u64(record.process) << 32 | u64(record.process_serial)
}

// log_fact_part_of_record gives the part of a record of the form Fact, as
// the kernel wrote it, with the number that the reader gives it.
log_fact_part_of_record :: proc "contextless" (record: ^Log_Record, number: u64) -> Log_Fact_Part {
	fact := log_record_fact(record)
	return {
		number = number,
		writer = log_fact_writer(record),
		module_hash = fact.module_hash,
		key = fact.key,
		part = int(fact.part),
		part_count = int(fact.part_count),
		values = fact.values[:min(int(fact.value_count), LOG_FACT_VALUE_CAPACITY)],
	}
}

// log_fact_join_take takes the next record of the form Fact that a reader
// reads, in the order of its numbers. whole is true when the record ends a
// fact: its value bytes are join.values[:join.value_count], the fact of one
// record too. fault says that the open fact, or this record, cannot be
// joined: the open fact is dropped, and the reader shows each record of it
// raw. A record that a fault follows is taken again as the start of a fact,
// so a fact of one record after a broken fact is whole, with the fault of
// the fact before. A reader that meets a record that is no fact, or the end
// of what it reads, while a fact is open calls log_fact_join_other_record.
log_fact_join_take :: proc "contextless" (join: ^Log_Fact_Join, record: Log_Fact_Part) -> (whole: bool, fault: Log_Fact_Join_Fault) {
	if join.open {
		continues := true
		switch {
		case join.number == max(u64) || record.number != join.number + 1:
			// The largest number has no next one: a number that wraps to
			// 0 is no record after it.
			fault, continues = .Missing_Part, false
		case record.writer != join.writer:
			fault, continues = .Other_Process, false
		case record.part != join.next_part:
			fault, continues = .Missing_Part, false
		case record.module_hash != join.module_hash || record.key != join.key || record.part_count != join.part_count:
			fault, continues = .Other_Fact, false
		}
		if continues {
			last := record.part == join.part_count - 1
			// The values of the fact stay inside the bound of a fact: the
			// last record of a fact of the most records holds less than
			// one record.
			if len(record.values) > LOG_FACT_VALUE_CAPACITY || !last && len(record.values) != LOG_FACT_VALUE_CAPACITY || len(record.values) > LOG_FACT_VALUES_MOST - join.value_count {
				join.open = false
				return false, .Value_Count
			}
			copy(join.values[join.value_count:], record.values)
			join.value_count += len(record.values)
			join.number = record.number
			join.next_part += 1
			if last {
				join.open = false
				return true, .None
			}
			return false, .None
		}
		join.open = false
	}
	// The start of a fact.
	start_fault := Log_Fact_Join_Fault.None
	switch {
	case record.part_count < 1 || record.part_count > LOG_FACT_RECORDS_MOST || record.part < 0 || record.part >= record.part_count:
		start_fault = .Part_Count
	case record.part != 0:
		start_fault = .Part_Without_First
	case len(record.values) > LOG_FACT_VALUE_CAPACITY || record.part_count > 1 && len(record.values) != LOG_FACT_VALUE_CAPACITY:
		start_fault = .Value_Count
	}
	if start_fault != .None {
		return false, fault != .None ? fault : start_fault
	}
	join^ = {
		number = record.number,
		writer = record.writer,
		module_hash = record.module_hash,
		key = record.key,
		part_count = record.part_count,
		next_part = 1,
	}
	join.value_count = copy(join.values[:], record.values)
	if record.part_count == 1 {
		return true, fault
	}
	join.open = true
	return false, fault
}

// log_fact_join_end ends the join at the end of a read. A fact still open
// when the read had no record after it lost its next record: the join
// closes, Missing_Part, and the reader shows each record of the fact raw
// after the mark, never nothing. A read that stopped at its page (the
// records after it are past what the reader asked for) keeps the fact
// open, None: its next record comes with the next read.
log_fact_join_end :: proc "contextless" (join: ^Log_Fact_Join, stopped_at_page: bool) -> Log_Fact_Join_Fault {
	if !join.open || stopped_at_page {
		return .None
	}
	join.open = false
	return .Missing_Part
}

// log_fact_join_other_record says what a record that is no fact does to an
// open fact: the next record of the open fact must be its next part, so a
// record of the same process breaks it (Missing_Part) and a record of
// another process with the next number too (Other_Process). It closes the
// open fact on a fault. A reader that ends its read with a fact open keeps
// it open: the next read can bring its next part.
log_fact_join_other_record :: proc "contextless" (join: ^Log_Fact_Join, number: u64, writer: u64) -> Log_Fact_Join_Fault {
	if !join.open {
		return .None
	}
	join.open = false
	if number == join.number + 1 && writer != join.writer {
		return .Other_Process
	}
	return .Missing_Part
}
