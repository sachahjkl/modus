package code

// Structured log facts for the AST code editor (src/md/features/codebase_ast.md).
// Text fields stay last because the log fact wire line stops at the final
// non-zero byte.

// Format property: preview width of a definition name in log facts.
NAME_FIELD_BYTES :: 48

// The window presented its first frame.
@(log_fact = "code: window ready, {definitions} definitions")
Window_Ready :: struct {
	definitions: u64,
}

// The binary MODAST1 codebase was restored from the private store.
@(log_fact = "code: restored {definitions} definitions, {bytes} bytes")
Codebase_Restored :: struct {
	definitions: u64,
	bytes:       u64,
}

// A MODAST1 snapshot was committed to the private store.
@(log_fact = "code: committed {bytes} bytes, generation {generation}")
Codebase_Committed :: struct {
	generation: i64,
	bytes:      u64,
}

// A definition was renamed in Name_Table without changing its content hash.
@(log_fact = "code: renamed definition to \"{name}\", hash unchanged")
Definition_Renamed :: struct {
	name: [48]u8,
}

// The process has no private store grant: changes live in memory only.
@(log_fact = "code: no store: changes are not kept")
No_Store :: struct {}

#assert(size_of(Definition_Renamed) == NAME_FIELD_BYTES)
