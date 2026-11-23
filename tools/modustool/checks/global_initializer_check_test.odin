package checks

import "core:testing"

@(private = "file")
uses_of :: proc(t: ^testing.T, sources: ..[2]string) -> []Global_Initializer_Use {
	uses, ok := global_initializer_uses_of_package(sources)
	testing.expect(t, ok, "the sources parse")
	return uses
}

@(test)
global_initializer_check_refuses_each_initializer_that_needs_a_start :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		line:   int,
		what:   string,
	}
	cases := [?]Case {
		// A slice of another variable, as the role contracts were.
		{"package p\nparams := [1]int{7}\nfaces := [1][]int{params[:]}\n", 3, "a slice expression"},
		// The slice deep in a literal of structs.
		{"package p\nF :: struct { e: []int }\nparams := [1]int{7}\nfaces := [1]F{{e = params[:]}}\n", 4, "a slice expression"},
		// A slice of a constant text is a slice expression too.
		{"package p\nfaces := [1]string{\"text\"[1:]}\n", 2, "a slice expression"},
		// An address of another variable.
		{"package p\ncount := 0\npointer := &count\n", 3, "an address (&)"},
		// A copy of another variable of the package.
		{"package p\nfirst := [2]int{1, 2}\nsecond := first\n", 3, "the package variable first"},
		// A name of a variable as the value of a field.
		{"package p\nF :: struct { n: int }\nlimit := 4\nrow := F{n = limit}\n", 4, "the package variable limit"},
		// A call of a procedure of the package, and of another package.
		{"package p\nmake_table :: proc() -> int { return 1 }\ntable := make_table()\n", 3, "a call of make_table"},
		{"package p\nimport \"modus:system\"\nnow := system.time()\n", 3, "a call of system.time"},
		// A literal of a map and of a dynamic array.
		{"package p\nnames := map[string]int{\"a\" = 1}\n", 2, "a literal of a map"},
		{"package p\nrows := [dynamic]int{1, 2}\n", 2, "a literal of a dynamic array"},
		// A value of the type any.
		{"package p\nvalue: any = 5\n", 2, "a value of the type any"},
		// A variable of another package.
		{"package p\nimport \"modus:system\"\ncopy_of := system.serving\n", 3, "the name system.serving of another package"},
		// A slice in the body of a when block, and of its else.
		{"package p\nparams := [1]int{7}\nwhen ODIN_OS == .Linux {\n\tfaces := [1][]int{params[:]}\n}\n", 4, "a slice expression"},
		{"package p\nparams := [1]int{7}\nwhen ODIN_OS == .Linux {\n} else {\n\tfaces := [1][]int{params[:]}\n}\n", 5, "a slice expression"},
	}
	for item in cases {
		uses := uses_of(t, {"p.odin", item.source})
		testing.expectf(t, len(uses) == 1, "one refusal of %q, found %d", item.source, len(uses))
		if len(uses) == 1 {
			testing.expect_value(t, uses[0].line, item.line)
			testing.expect_value(t, uses[0].what, item.what)
		}
	}
	// A variable that another file of the package declares.
	across := uses_of(t, {"a.odin", "package p\nparams := [1]int{7}\n"}, {"b.odin", "package p\nfaces := [1][]int{params[:]}\n"})
	testing.expect_value(t, len(across), 1)
	// Two refusals in one initializer.
	both := uses_of(t, {"p.odin", "package p\na := [1]int{1}\nb := 2\nc := [2]rawptr{&a, &b}\n"})
	testing.expect_value(t, len(both), 2)
	// A source that does not parse is refused whole.
	_, parsed := global_initializer_uses_of_package({{"bad.odin", "package p\nfaces := [1]int{\n"}})
	testing.expect(t, !parsed, "a source that does not parse is refused")
}

@(test)
global_initializer_check_keeps_constant_data :: proc(t: ^testing.T) {
	sources := [?]string {
		// Slices as literals inside the table: constant data.
		"package p\nF :: struct { n: string, e: []int }\n@(rodata)\nfaces := [1]F{{n = \"f\", e = {7, 8}}}\n",
		// A constant, a member of an enum, a field name and a type.
		"package p\nLIMIT :: 4\nE :: enum { A, B }\nF :: struct { n: int, e: E }\nrow := F{n = LIMIT, e = .B}\n",
		// A name of another package: the check does not read it.
		"package p\nimport \"modus:system\"\nbound := system.PAGE_SIZE\n",
		// A procedure as a value reads no variable.
		"package p\nstep :: proc() {}\nhandler := step\n",
		// A variable with no initializer.
		"package p\nfaces: [4][]int\n",
		// Conversions and the built-ins that the compiler folds.
		"package p\nE :: enum u8 { A }\nfirst := u32(5)\nsecond := E(0)\nthird := size_of(u64) + align_of(u64)\nfourth := min(3, 4)\n",
		"package p\nimport \"modus:system\"\nlimit := system.Handle(0)\n",
		"package p\nfont := #load(\"font.bin\")\n",
		// The body of a procedure literal is no initializer.
		"package p\nparams := [1]int{7}\nstep := proc() { _ = params[:] }\n",
	}
	for source in sources {
		uses := uses_of(t, {"p.odin", source})
		testing.expectf(t, len(uses) == 0, "no refusal of %q, found %d", source, len(uses))
	}
}

@(test)
host_only_source_reads_the_build_line_before_the_package :: proc(t: ^testing.T) {
	testing.expect(t, host_only_source("#+build !freestanding\npackage p\n"))
	testing.expect(t, !host_only_source("package p\n// #+build !freestanding is the line of a host test\n"))
	testing.expect(t, !host_only_source("#+build linux\npackage p\n"))
}
