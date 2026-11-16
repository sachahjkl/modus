#+build !freestanding
package operation

import "core:testing"

// Each writer has its word in a row, and a value that a later kernel could
// give has a word too, not an empty field.
@(test)
each_module_writer_has_its_word :: proc(t: ^testing.T) {
	testing.expect_value(t, module_writer_name(.Program), "program")
	testing.expect_value(t, module_writer_name(.Starter), "starter")
	testing.expect_value(t, module_writer_name(Module_Writer(u64(max(Module_Writer)) + 1)), "unknown")
	// A record that no kernel wrote is of the program: the starter must be
	// a fact that the kernel adds, never the zero of a record.
	record: Module_Record
	testing.expect_value(t, record.writer, Module_Writer.Program)
	// Each word fits the field of a row.
	for writer in Module_Writer {
		testing.expect(t, len(module_writer_name(writer)) <= MODULE_WRITER_NAME_CAPACITY, module_writer_name(writer))
	}
	testing.expect(t, len(module_writer_name(Module_Writer(u64(max(Module_Writer)) + 1))) <= MODULE_WRITER_NAME_CAPACITY)
}
