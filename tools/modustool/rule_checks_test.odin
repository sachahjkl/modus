package modustool

import "core:testing"
import "modustool:foundation"

@(test)
operation_count_reads_the_enumeration :: proc(t: ^testing.T) {
	source := "Other :: enum u32 {\n\tA = 0,\n}\n\nOperation :: enum u32 {\n\tNone = 0,\n\tLog  = 1, // (log, address).\n\t// A comment with a = sign.\n\tStop = 2,\n}\nAfter :: 3\n"
	count, ok := operation_count_of_source(source)
	testing.expect(t, ok)
	testing.expect_value(t, count, 2)
	_, without := operation_count_of_source("Other :: enum u32 {\n\tA = 0,\n}\n")
	testing.expect(t, !without)
	_, open := operation_count_of_source("Operation :: enum u32 {\n\tNone = 0,\n")
	testing.expect(t, !open)
}

@(test)
operation_count_reads_the_sentence_of_the_document :: proc(t: ^testing.T) {
	count, ok := operation_count_of_document("The first target was 32 operations or fewer. The kernel has 33 operations: each one has its reason.")
	testing.expect(t, ok)
	testing.expect_value(t, count, 33)
	// A sentence with the same start and no number before " operations".
	count, ok = operation_count_of_document("The kernel has few operations. The kernel has 7 operations.")
	testing.expect(t, ok)
	testing.expect_value(t, count, 7)
	_, none := operation_count_of_document("The kernel has a small count of them.")
	testing.expect(t, !none)
}

@(test)
allocator_uses_are_calls_and_names :: proc(t: ^testing.T) {
	source := `package x
list := make([]u8, 4)
other := isolated.caller_grant_make(1, 2, true)
queue := ring.make(4)
// make(a comment)
system.log("the process cannot make(it)")
values: [dynamic]int
context.allocator = nil
item := new(Thing)
remake(3)
`
	uses := allocator_uses_of_source("x.odin", source)
	testing.expect_value(t, len(uses), 4)
	if len(uses) == 4 {
		testing.expect_value(t, uses[0].line, 2)
		testing.expect_value(t, uses[0].what, "make(")
		testing.expect_value(t, uses[1].what, "[dynamic]")
		testing.expect_value(t, uses[2].what, "context.allocator")
		testing.expect_value(t, uses[3].line, 9)
		testing.expect_value(t, uses[3].what, "new(")
	}
	testing.expect(t, source_is_a_test("src/library/support/graphics/blend_vectors_test_amd64.odin"))
	testing.expect(t, source_is_a_test("a/b_test.odin"))
	testing.expect(t, !source_is_a_test("a_test/b.odin"))
}

// The two rules hold in the sources of the repository.
@(test)
rules_of_the_repository :: proc(t: ^testing.T) {
	source, source_ok := foundation.site_read_quiet(foundation.OPERATION_SOURCE)
	document, document_ok := foundation.site_read_quiet(OPERATION_PROPERTY_DOCUMENT)
	testing.expect(t, source_ok && document_ok)
	declared, declared_ok := operation_count_of_source(source)
	stated, stated_ok := operation_count_of_document(document)
	testing.expect(t, declared_ok && stated_ok)
	testing.expect_value(t, declared, stated)
	uses, file_count, ok := allocator_uses_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 100)
	for use in uses {
		testing.expectf(t, false, "%s:%d: %s", use.file, use.line, use.what)
	}
}
