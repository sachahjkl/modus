#+build !freestanding
package operation

import "core:testing"

// The border of the word of a writer refuses each word that names no
// writer: the word one past the last member, the largest word. No reader
// then has a writer that no kernel marked.
@(test)
the_word_of_no_writer_is_refused :: proc(t: ^testing.T) {
	for word in ([]u64{u64(max(Module_Writer)) + 1, 1 << 32, max(u64) - 1, max(u64)}) {
		_, ok := module_writer_of_word(word)
		testing.expectf(t, !ok, "the word %v names no writer", word)
	}
	// The successful cases last: each member is read back from its word.
	for member in Module_Writer {
		writer, ok := module_writer_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, writer, member)
	}
}

// Each writer has its word in a row, and each word fits the field of a row.
@(test)
each_module_writer_has_its_word :: proc(t: ^testing.T) {
	testing.expect_value(t, module_writer_name(.Process), "process")
	testing.expect_value(t, module_writer_name(.Starter), "starter")
	for member in Module_Writer {
		testing.expect(t, len(module_writer_name(member)) <= MODULE_WRITER_NAME_CAPACITY, module_writer_name(member))
	}
	// A record that no kernel wrote is of the process: the starter must be
	// a fact that the kernel adds, never the zero of a record.
	record: Module_Record
	writer, ok := module_writer_of_word(record.writer)
	testing.expect(t, ok)
	testing.expect_value(t, writer, Module_Writer.Process)
}
