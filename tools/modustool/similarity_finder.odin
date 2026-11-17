package modustool

import "core:container/priority_queue"
import "core:mem"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The similarity finder (src/md/infrastructure/similarity_finder.md): the
// analysis of a set of sources, from the parse to the ranked families and
// the measures. similarity_report.odin writes what it found, and the
// command reads the sources of the repository.

Similarity_Area :: enum u8 {
	System, // src/, no test.
	Tool, // tools/, no test.
	Test, // The host tests and the test scenarios.
}

Similarity_Category :: enum u8 {
	Utility_To_Centralise,
	Local_Repetition,
	Parametric_Family,
	Repeated_Expression,
	Similar_Behaviour,
	Kept_Apart_By_The_Rules,
	Platform_Variant,
}

similarity_category_name :: proc(category: Similarity_Category) -> string {
	switch category {
	case .Utility_To_Centralise:
		return "utility to centralise"
	case .Local_Repetition:
		return "local repetition"
	case .Parametric_Family:
		return "parametric family"
	case .Repeated_Expression:
		return "repeated expression"
	case .Similar_Behaviour:
		return "similar behaviour"
	case .Kept_Apart_By_The_Rules:
		return "kept apart by the rules"
	case .Platform_Variant:
		return "platform variant"
	}
	return ""
}

// A family of these categories is one procedure: the ranking counts what
// its factoring saves.
similarity_category_is_factorable :: proc(category: Similarity_Category) -> bool {
	#partial switch category {
	case .Utility_To_Centralise, .Local_Repetition, .Parametric_Family, .Repeated_Expression:
		return true
	}
	return false
}

similarity_area_name :: proc(area: Similarity_Area) -> string {
	switch area {
	case .System:
		return "system"
	case .Tool:
		return "tool"
	case .Test:
		return "tests"
	}
	return ""
}

Similarity_Phase :: enum u8 {
	Parse,
	Normal_Form_And_Hashes,
	Candidates,
	Anti_Unification,
	Families,
	Ranking,
}

similarity_phase_name :: proc(phase: Similarity_Phase) -> string {
	switch phase {
	case .Parse:
		return "the parse"
	case .Normal_Form_And_Hashes:
		return "the normal form and the hashes"
	case .Candidates:
		return "the candidates"
	case .Anti_Unification:
		return "the anti-unification of the near pairs"
	case .Families:
		return "the families"
	case .Ranking:
		return "the ranking"
	}
	return ""
}

// One source file: its path from the root of the repository, and its text.
Similarity_Source :: struct {
	path: string,
	text: string,
}

// A file that the finder does not read, and why.
Similarity_Skipped_File :: struct {
	path:   string,
	reason: string,
}

Similarity_File :: struct {
	path:            string,
	folder:          string, // The package: the folder of the file.
	text:            string,
	area:            Similarity_Area,
	line_count:      i32,
	support_imports: []string, // The import paths under modus:support/, sorted.
	parsed:          bool,
}

Similarity_Family :: struct {
	template:       Similarity_Template,
	kind:           Similarity_Piece_Kind,
	category:       Similarity_Category,
	home:           string,
	packages:       []string,
	template_hash:  u64,
	template_lines: i64,
	control_leaves: bool, // A member is a run or an expression that control leaves.
	holds_using:    bool,
	rules:          Similarity_Rules, // The rules of the normal form that some members needed and others not.
	run_inputs:     i32,
	run_outputs:    i32,
	reported:       bool, // No larger family holds it.
	kept:           bool,
	kept_reason:    string,
	rank:           i32, // 1 for the first family of the greedy selection, 0 when it is not selected.
	selected_uses:  i32,
	saved_nodes:    i64,
	saved_lines:    i64,
}

// One line of the kept list.
Similarity_Kept_Line :: struct {
	line:   i32,
	text:   string,
	hash:   u64,
	reason: string,
	valid:  bool,
	used:   bool,
}

Similarity_Measures :: struct {
	files:                 [Similarity_Area]i64,
	procedures:            [Similarity_Area]i64,
	nodes:                 [Similarity_Area]i64,
	lines:                 [Similarity_Area]i64,
	family_nodes:          [Similarity_Category][Similarity_Area]i64,
	family_lines:          [Similarity_Category][Similarity_Area]i64,
	any_family_nodes:      [Similarity_Area]i64,
	any_family_lines:      [Similarity_Area]i64,
	saved_nodes:           i64,
	saved_lines:           i64,
	near_pieces:           i64,
	near_filter:           Similarity_Near_Filter_Counts,
	near_pairs_above:      i64, // The pairs whose bound reached the threshold.
	cheap_pairs:           i64, // The pairs aligned by the shape of the children only.
	near_threshold_pairs:  i64, // The pairs whose bound is just below the threshold.
	near_minimum_groups:   [Similarity_Piece_Kind]i64, // The groups just below the minimum size.
	families_found:        i64,
	families_held:         i64, // The families that a larger family holds.
	families_unranked:     i64, // The families that save nothing after the ones taken before them.
	members_below_coverage: i64, // The members that a family dropped under the least coverage.
	times:                 [Similarity_Phase]time.Duration,
}

Similarity_Analysis :: struct {
	allocator:   mem.Allocator,
	files:       []Similarity_File,
	nodes:       []Similarity_Node,
	pieces:      [dynamic]Similarity_Piece,
	families:    [dynamic]Similarity_Family,
	alignments:  map[[2]i32]^Similarity_Alignment,
	kept:        []Similarity_Kept_Line,
	measures:    Similarity_Measures,
	parse_fault: [dynamic]string, // The files that the parser did not read whole.
	unify_arena: virtual.Arena,
	family_arena: virtual.Arena,
}

// The suffixes of a file name that name a system (AGENTS.md, "Iteration And Tests").
@(private = "file")
SIMILARITY_SYSTEM_SUFFIXES :: [?]string{"_windows", "_linux", "_darwin", "_freebsd", "_openbsd", "_netbsd", "_unix", "_posix", "_other"}

// similarity_area_of gives the area of a file from its path and its first
// line: a host test, a test scenario of the tool, and a file that only
// the host compiles are tests.
similarity_area_of :: proc(path, text: string) -> Similarity_Area {
	first_line := text
	if end := strings.index_byte(text, '\n'); end >= 0 {
		first_line = text[:end]
	}
	switch {
	case strings.has_suffix(path, "_test.odin"):
		return .Test
	case strings.has_prefix(path, "tools/") && strings.has_suffix(path, "_scenario.odin"):
		return .Test
	case strings.has_prefix(first_line, "#+build") && strings.contains(first_line, "!freestanding"):
		return .Test
	case strings.has_prefix(path, "tools/"):
		return .Tool
	}
	return .System
}

similarity_folder_of :: proc(path: string) -> string {
	if at := strings.last_index_byte(path, '/'); at >= 0 {
		return path[:at]
	}
	return "."
}

@(private = "file")
Similarity_Source_Order :: struct {
	folder: string,
	path:   string,
	index:  i32,
}

// similarity_analysis_make reads the sources into the table. The result
// lives in allocator; similarity_analysis_destroy frees the memory of the
// anti-unification.
similarity_analysis_make :: proc(sources: []Similarity_Source, allocator: mem.Allocator) -> ^Similarity_Analysis {
	context.allocator = allocator
	analysis := new(Similarity_Analysis, allocator)
	analysis.allocator = allocator
	analysis.pieces = make([dynamic]Similarity_Piece, allocator)
	analysis.families = make([dynamic]Similarity_Family, allocator)
	analysis.alignments = make(map[[2]i32]^Similarity_Alignment, allocator)
	analysis.parse_fault = make([dynamic]string, allocator)
	_ = virtual.arena_init_growing(&analysis.unify_arena)
	_ = virtual.arena_init_growing(&analysis.family_arena)
	similarity_read_sources(analysis, sources)
	return analysis
}

similarity_analysis_destroy :: proc(analysis: ^Similarity_Analysis) {
	virtual.arena_destroy(&analysis.unify_arena)
	virtual.arena_destroy(&analysis.family_arena)
}

// similarity_add_procedure_pieces makes a piece of each procedure of at
// least the minimum size, for the commands `near` and `pair`.
similarity_add_procedure_pieces :: proc(analysis: ^Similarity_Analysis) {
	for node in 0 ..< i32(len(analysis.nodes)) {
		if kind, is_piece := similarity_piece_kind_of_node(analysis.nodes, node); is_piece && kind == .Procedure {
			similarity_add_piece(analysis, .Procedure, node, node, 1)
		}
	}
}

// similarity_analyse finds the families of the sources and ranks them.
// kept_text is the kept list. The caller destroys the result with
// similarity_analysis_destroy.
similarity_analyse :: proc(sources: []Similarity_Source, kept_text: string, allocator: mem.Allocator) -> ^Similarity_Analysis {
	context.allocator = allocator
	analysis := similarity_analysis_make(sources, allocator)

	start := time.tick_now()
	stream := similarity_statement_stream(analysis.nodes, allocator)
	run_groups, near_runs := similarity_repeated_runs(analysis.nodes, stream, allocator)
	analysis.measures.near_minimum_groups[.Run] = i64(near_runs)
	groups := similarity_piece_groups(analysis, stream, run_groups)
	analysis.measures.times[.Candidates] = time.tick_since(start)

	start = time.tick_now()
	similarity_make_group_families(analysis, groups)
	in_family := similarity_pieces_in_families(analysis)
	near := similarity_near_candidates(analysis, in_family)
	analysis.measures.near_pieces = i64(len(near))
	pairs, filter_counts := similarity_near_pairs(analysis.nodes, analysis.pieces[:], near, SIMILARITY_COVERAGE_LEAST, allocator)
	analysis.measures.near_filter = filter_counts
	scores, cheap := similarity_compare_pairs(analysis.nodes, analysis.pieces[:], pairs, allocator)
	analysis.measures.times[.Anti_Unification] = time.tick_since(start)

	start = time.tick_now()
	similarity_make_near_families(analysis, pairs, scores, cheap)
	similarity_mark_held_families(analysis)
	for &family in analysis.families {
		similarity_family_describe(analysis, &family)
	}
	analysis.kept = similarity_kept_lines(kept_text, allocator)
	similarity_apply_kept(analysis)
	analysis.measures.times[.Families] = time.tick_since(start)

	start = time.tick_now()
	similarity_rank(analysis)
	similarity_count_measures(analysis)
	analysis.measures.times[.Ranking] = time.tick_since(start)
	return analysis
}

// similarity_read_sources parses each source, one package at a time, and
// copies each tree into the table. The memory of the parser for a package
// is freed after its copy.
@(private = "file")
similarity_read_sources :: proc(analysis: ^Similarity_Analysis, sources: []Similarity_Source) {
	allocator := analysis.allocator
	order := make([]Similarity_Source_Order, len(sources), allocator)
	for source, index in sources {
		order[index] = Similarity_Source_Order{folder = similarity_folder_of(source.path), path = source.path, index = i32(index)}
	}
	slice.sort_by(order, proc(a, b: Similarity_Source_Order) -> bool {
		return a.folder < b.folder || (a.folder == b.folder && a.path < b.path)
	})
	files := make([]Similarity_File, len(sources), allocator)
	for item, index in order {
		source := sources[item.index]
		files[index] = Similarity_File{path = source.path, folder = item.folder, text = source.text, area = similarity_area_of(source.path, source.text), line_count = i32(strings.count(source.text, "\n") + (strings.has_suffix(source.text, "\n") || len(source.text) == 0 ? 0 : 1))}
	}
	analysis.files = files
	builder := similarity_builder_make(allocator)
	parse_time: time.Duration
	copy_time: time.Duration
	package_start := 0
	for package_start < len(files) {
		package_end := package_start + 1
		for package_end < len(files) && files[package_end].folder == files[package_start].folder {
			package_end += 1
		}
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		{
			context.allocator = virtual.arena_allocator(&arena)
			tick := time.tick_now()
			trees := make([]^ast.File, package_end - package_start)
			for index in package_start ..< package_end {
				tree := ast.new_from_positions(ast.File, {}, {})
				tree.src = files[index].text
				tree.fullpath = files[index].path
				reader := parser.default_parser()
				if parser.parse_file(&reader, tree) && tree.syntax_error_count == 0 {
					trees[index - package_start] = tree
					files[index].parsed = true
				} else {
					append(&analysis.parse_fault, files[index].path)
				}
			}
			parse_time += time.tick_since(tick)
			tick = time.tick_now()
			builder.package_types = make(map[string]bool)
			for tree in trees {
				if tree == nil {
					continue
				}
				for declaration in tree.decls {
					value, is_value := declaration.derived.(^ast.Value_Decl)
					if !is_value || value.is_mutable {
						continue
					}
					for name, position in value.names {
						identifier, is_name := name.derived.(^ast.Ident)
						if is_name && position < len(value.values) && similarity_type_declaration(value.values[position]) {
							builder.package_types[identifier.name] = true
						}
					}
				}
			}
			for tree, offset in trees {
				if tree == nil {
					continue
				}
				file_index := package_start + offset
				builder.file = i32(file_index)
				builder.imports = make(map[string]string)
				support := make([dynamic]string, allocator)
				for declaration in tree.imports {
					name, path := similarity_import_name(declaration)
					builder.imports[name] = path
					// A private part is compiled in as a support package is.
					if strings.has_prefix(path, SUPPORT_IMPORT_START) || strings.has_prefix(path, PRIVATE_IMPORT_START) {
						append(&support, path)
					}
				}
				slice.sort(support[:])
				files[file_index].support_imports = support[:]
				builder.scopes = nil
				builder.procedure = -1
				builder.binding_count = 0
				for declaration in tree.decls {
					similarity_flatten(&builder, declaration, .Statement)
				}
			}
			builder.package_types = nil
			builder.imports = nil
			builder.scopes = nil
			copy_time += time.tick_since(tick)
		}
		virtual.arena_destroy(&arena)
		package_start = package_end
	}
	analysis.nodes = builder.nodes[:]
	analysis.measures.times[.Parse] = parse_time
	analysis.measures.times[.Normal_Form_And_Hashes] = copy_time
}

@(private = "file")
similarity_add_piece :: proc(analysis: ^Similarity_Analysis, kind: Similarity_Piece_Kind, first, last, root_count: i32) -> i32 {
	low := first
	high := last + analysis.nodes[last].size
	append(&analysis.pieces, Similarity_Piece{first = first, last = last, root_count = root_count, size = high - low, kind = kind})
	return i32(len(analysis.pieces) - 1)
}

// A procedure literal with a body, a block that is not the body of a
// procedure, and an expression that is read and is not a whole statement.
@(private = "file")
similarity_piece_kind_of_node :: proc(nodes: []Similarity_Node, node: i32) -> (kind: Similarity_Piece_Kind, is_piece: bool) {
	item := nodes[node]
	parent_kind := item.parent >= 0 ? nodes[item.parent].kind : Similarity_Kind.Bad
	switch {
	case item.kind == .Proc_Lit:
		return .Procedure, !strings.contains(item.label, "foreign") && item.size >= SIMILARITY_PIECE_NODES_LEAST
	case item.kind == .Block_Stmt:
		return .Block, item.parent >= 0 && parent_kind != .Proc_Lit && item.size >= SIMILARITY_PIECE_NODES_LEAST
	case item.role == .Value && !similarity_kind_is_statement(item.kind) && !similarity_kind_is_type(item.kind) && item.parent >= 0 && parent_kind != .Expr_Stmt:
		return .Expression, item.size >= SIMILARITY_EXPRESSION_NODES_LEAST
	}
	return .Expression, false
}

// The groups of pieces with one hash, and the groups of the repeated runs.
@(private = "file")
Similarity_Piece_Groups :: struct {
	equal:      [][]i32, // Procedures with one exact hash.
	shape:      [][]i32, // Procedures and blocks with one shape hash and more than one exact hash.
	expression: [][]i32,
	runs:       [][]i32,
}

@(private = "file")
similarity_piece_groups :: proc(analysis: ^Similarity_Analysis, stream: Similarity_Statement_Stream, run_groups: []Similarity_Run_Group) -> Similarity_Piece_Groups {
	allocator := analysis.allocator
	nodes := analysis.nodes
	exact_keys := make([dynamic]Similarity_Keyed_Piece, allocator)
	shape_keys := make([dynamic]Similarity_Keyed_Piece, allocator)
	expression_keys := make([dynamic]Similarity_Keyed_Piece, allocator)
	near_procedure_keys := make([dynamic]Similarity_Keyed_Piece, allocator)
	near_expression_keys := make([dynamic]Similarity_Keyed_Piece, allocator)
	for node in 0 ..< i32(len(nodes)) {
		kind, is_piece := similarity_piece_kind_of_node(nodes, node)
		if !is_piece {
			size := nodes[node].size
			if kind == .Expression && size >= SIMILARITY_EXPRESSION_NODES_NEAR_MINIMUM && size < SIMILARITY_EXPRESSION_NODES_LEAST && nodes[node].role == .Value && !similarity_kind_is_statement(nodes[node].kind) && !similarity_kind_is_type(nodes[node].kind) {
				append(&near_expression_keys, Similarity_Keyed_Piece{key = nodes[node].shape_hash, piece = node})
			}
			if nodes[node].kind == .Proc_Lit && size >= SIMILARITY_PIECE_NODES_NEAR_MINIMUM && size < SIMILARITY_PIECE_NODES_LEAST {
				append(&near_procedure_keys, Similarity_Keyed_Piece{key = nodes[node].shape_hash, piece = node})
			}
			continue
		}
		piece := similarity_add_piece(analysis, kind, node, node, 1)
		switch kind {
		case .Procedure, .Block:
			append(&exact_keys, Similarity_Keyed_Piece{key = nodes[node].exact_hash ~ u64(kind), piece = piece})
			append(&shape_keys, Similarity_Keyed_Piece{key = nodes[node].shape_hash ~ u64(kind), piece = piece})
		case .Expression:
			append(&expression_keys, Similarity_Keyed_Piece{key = nodes[node].shape_hash, piece = piece})
		case .Run:
		}
	}
	analysis.measures.near_minimum_groups[.Procedure] = i64(len(similarity_groups_by_key(near_procedure_keys[:], 2, allocator)))
	analysis.measures.near_minimum_groups[.Expression] = i64(len(similarity_groups_by_key(near_expression_keys[:], SIMILARITY_EXPRESSION_USES_LEAST, allocator)))
	groups: Similarity_Piece_Groups
	groups.equal = similarity_groups_by_key(exact_keys[:], 2, allocator)
	// A shape group whose members all share one exact hash is the equal
	// group already.
	shape := make([dynamic][]i32, allocator)
	for group in similarity_groups_by_key(shape_keys[:], 2, allocator) {
		first_hash := nodes[analysis.pieces[group[0]].first].exact_hash
		for member in group[1:] {
			if nodes[analysis.pieces[member].first].exact_hash != first_hash {
				append(&shape, group)
				break
			}
		}
	}
	groups.shape = shape[:]
	groups.expression = similarity_groups_by_key(expression_keys[:], SIMILARITY_EXPRESSION_USES_LEAST, allocator)
	runs := make([dynamic][]i32, allocator)
	for run in run_groups {
		members := make([]i32, len(run.starts), allocator)
		for start, index in run.starts {
			first := stream.nodes[start]
			last := stream.nodes[start + run.length - 1]
			members[index] = similarity_add_piece(analysis, .Run, first, last, run.length)
		}
		append(&runs, members)
	}
	groups.runs = runs[:]
	return groups
}

// similarity_alignment_of gives the anti-unification of two pieces, and
// keeps it for the next family that needs it.
similarity_alignment_of :: proc(analysis: ^Similarity_Analysis, first, other: i32) -> ^Similarity_Alignment {
	key := [2]i32{first, other}
	if known, found := analysis.alignments[key]; found {
		return known
	}
	alignment := similarity_unify(analysis.nodes, analysis.pieces[:], first, other, virtual.arena_allocator(&analysis.unify_arena), analysis.allocator)
	virtual.arena_free_all(&analysis.unify_arena)
	analysis.alignments[key] = alignment
	return alignment
}

@(private = "file")
Similarity_Ordered_Member :: struct {
	first: i32,
	piece: i32,
}

// The members of a family in the order of the table: the first member is
// the first in the order of the files and of their bytes.
@(private = "file")
similarity_sort_members :: proc(analysis: ^Similarity_Analysis, members: []i32) {
	ordered := make([]Similarity_Ordered_Member, len(members), context.temp_allocator)
	for member, index in members {
		ordered[index] = Similarity_Ordered_Member{first = analysis.pieces[member].first, piece = member}
	}
	slice.sort_by(ordered, proc(a, b: Similarity_Ordered_Member) -> bool {
		return a.first < b.first || (a.first == b.first && a.piece < b.piece)
	})
	for item, index in ordered {
		members[index] = item.piece
	}
}

// similarity_family_template computes the template of a set of members,
// and drops each member that it covers under the least coverage, until
// each member reaches it. ok is false when fewer than `least` members stay.
@(private = "file")
similarity_family_template :: proc(analysis: ^Similarity_Analysis, members_in: []i32, least: int) -> (template: Similarity_Template, ok: bool) {
	members := make([dynamic]i32, analysis.allocator)
	append(&members, ..members_in)
	similarity_sort_members(analysis, members[:])
	for len(members) >= least {
		alignments := make([]^Similarity_Alignment, len(members) - 1, analysis.allocator)
		for member, index in members[1:] {
			alignments[index] = similarity_alignment_of(analysis, members[0], member)
		}
		template = similarity_template(analysis.nodes, analysis.pieces[:], members[:], alignments, analysis.allocator, virtual.arena_allocator(&analysis.family_arena))
		virtual.arena_free_all(&analysis.family_arena)
		lowest := 0
		for coverage, index in template.coverages {
			if coverage < template.coverages[lowest] {
				lowest = index
			}
		}
		if template.coverages[lowest] >= SIMILARITY_COVERAGE_LEAST {
			return template, true
		}
		ordered_remove(&members, lowest)
		analysis.measures.members_below_coverage += 1
	}
	return {}, false
}

@(private = "file")
similarity_add_family :: proc(analysis: ^Similarity_Analysis, members: []i32, least: int) -> bool {
	template, ok := similarity_family_template(analysis, members, least)
	if !ok {
		return false
	}
	append(&analysis.families, Similarity_Family{template = template, kind = analysis.pieces[template.members[0]].kind, reported = true})
	return true
}

@(private = "file")
similarity_make_group_families :: proc(analysis: ^Similarity_Analysis, groups: Similarity_Piece_Groups) {
	for group in groups.equal {
		similarity_add_family(analysis, group, 2)
	}
	for group in groups.shape {
		similarity_add_family(analysis, group, 2)
	}
	for group in groups.runs {
		similarity_add_family(analysis, group, 2)
	}
	for group in groups.expression {
		similarity_add_family(analysis, group, SIMILARITY_EXPRESSION_USES_LEAST)
	}
}

@(private = "file")
similarity_pieces_in_families :: proc(analysis: ^Similarity_Analysis) -> []bool {
	in_family := make([]bool, len(analysis.pieces), analysis.allocator)
	for family in analysis.families {
		for member in family.template.members {
			in_family[member] = true
		}
	}
	return in_family
}

// The near pieces: each procedure and block that no family of equal hashes
// holds, and that is not inside a procedure of such a family.
@(private = "file")
similarity_near_candidates :: proc(analysis: ^Similarity_Analysis, in_family: []bool) -> []i32 {
	nodes := analysis.nodes
	procedure_in_family := make(map[i32]bool, analysis.allocator)
	for piece, index in analysis.pieces {
		if piece.kind == .Procedure && in_family[index] {
			procedure_in_family[piece.first] = true
		}
	}
	near := make([dynamic]i32, analysis.allocator)
	for piece, index in analysis.pieces {
		if (piece.kind != .Procedure && piece.kind != .Block) || in_family[index] {
			continue
		}
		if piece.kind == .Block && nodes[piece.first].procedure in procedure_in_family {
			continue
		}
		append(&near, i32(index))
	}
	return near[:]
}

@(private = "file")
Similarity_Scored_Pair :: struct {
	score: f64,
	pair:  [2]i32,
}

// similarity_make_near_families joins the near pairs into families, from
// the highest score: two families join when the template of the joined
// family covers each member at least at the least coverage.
@(private = "file")
similarity_make_near_families :: proc(analysis: ^Similarity_Analysis, pairs: [][2]i32, scores: []f64, cheap: []bool) {
	edges := make([dynamic]Similarity_Scored_Pair, analysis.allocator)
	for pair, index in pairs {
		if cheap[index] {
			analysis.measures.cheap_pairs += 1
		}
		switch {
		case scores[index] >= SIMILARITY_COVERAGE_LEAST:
			analysis.measures.near_pairs_above += 1
			append(&edges, Similarity_Scored_Pair{score = scores[index], pair = pair})
		case scores[index] >= SIMILARITY_SCORE_NEAR_THRESHOLD:
			analysis.measures.near_threshold_pairs += 1
		}
	}
	slice.sort_by(edges[:], proc(a, b: Similarity_Scored_Pair) -> bool {
		return a.score > b.score || (a.score == b.score && (a.pair[0] < b.pair[0] || (a.pair[0] == b.pair[0] && a.pair[1] < b.pair[1])))
	})
	family_of := make(map[i32]i32, analysis.allocator)
	near_members := make([dynamic][dynamic]i32, analysis.allocator)
	for edge in edges {
		first_family, first_found := family_of[edge.pair[0]]
		other_family, other_found := family_of[edge.pair[1]]
		if first_found && other_found && first_family == other_family {
			continue
		}
		joined := make([dynamic]i32, analysis.allocator)
		if first_found {
			append(&joined, ..near_members[first_family][:])
		} else {
			append(&joined, edge.pair[0])
		}
		if other_found {
			append(&joined, ..near_members[other_family][:])
		} else {
			append(&joined, edge.pair[1])
		}
		template, ok := similarity_family_template(analysis, joined[:], 2)
		if !ok || len(template.members) != len(joined) {
			continue
		}
		target: i32
		switch {
		case first_found:
			target = first_family
		case other_found:
			target = other_family
		case:
			target = i32(len(near_members))
			append(&near_members, make([dynamic]i32, analysis.allocator))
		}
		if first_found && other_found {
			clear(&near_members[other_family])
		}
		clear(&near_members[target])
		append(&near_members[target], ..joined[:])
		for member in joined {
			family_of[member] = target
		}
	}
	for members in near_members {
		if len(members) >= 2 {
			similarity_add_family(analysis, members[:], 2)
		}
	}
}

@(private = "file")
Similarity_Root_Owner :: struct {
	family: i32,
	piece:  i32,
}

// similarity_mark_held_families marks the families whose members are all
// inside the members of one larger family with as many uses or more.
@(private = "file")
similarity_mark_held_families :: proc(analysis: ^Similarity_Analysis) {
	nodes := analysis.nodes
	owners := make(map[i32][dynamic]Similarity_Root_Owner, analysis.allocator)
	for family, family_index in analysis.families {
		for member in family.template.members {
			piece := analysis.pieces[member]
			root := piece.first
			for _ in 0 ..< piece.root_count {
				list := owners[root]
				append(&list, Similarity_Root_Owner{family = i32(family_index), piece = member})
				owners[root] = list
				root = nodes[root].next_sibling
			}
		}
	}
	analysis.measures.families_found = i64(len(analysis.families))
	held := make([]bool, len(analysis.families), context.temp_allocator)
	for family, family_index in analysis.families {
		holders: map[i32]bool
		for member, member_position in family.template.members {
			piece := analysis.pieces[member]
			found := make(map[i32]bool, context.temp_allocator)
			ancestor := piece.first
			for ancestor >= 0 {
				for owner in owners[ancestor] {
					if owner.family != i32(family_index) && similarity_piece_contains(nodes, analysis.pieces[owner.piece], piece) {
						found[owner.family] = true
					}
				}
				ancestor = nodes[ancestor].parent
			}
			if member_position == 0 {
				holders = found
			} else {
				gone := make([dynamic]i32, context.temp_allocator)
				for holder in holders {
					if holder not_in found {
						append(&gone, holder)
					}
				}
				for holder in gone {
					delete_key(&holders, holder)
				}
			}
			if len(holders) == 0 {
				break
			}
		}
		for holder in holders {
			other := analysis.families[holder]
			if len(other.template.members) < len(family.template.members) {
				continue
			}
			// Two families that hold each other with as many uses: the
			// first one stays.
			if len(other.template.members) == len(family.template.members) && similarity_family_holds(analysis, family, other) && i32(family_index) < holder {
				continue
			}
			held[family_index] = true
			break
		}
	}
	for &family, family_index in analysis.families {
		family.reported = !held[family_index]
		if held[family_index] {
			analysis.measures.families_held += 1
		}
	}
}

// Each member of the inner family is inside a member of the outer one.
@(private = "file")
similarity_family_holds :: proc(analysis: ^Similarity_Analysis, outer, inner: Similarity_Family) -> bool {
	for member in inner.template.members {
		inside := false
		for holder in outer.template.members {
			if similarity_piece_contains(analysis.nodes, analysis.pieces[holder], analysis.pieces[member]) {
				inside = true
				break
			}
		}
		if !inside {
			return false
		}
	}
	return true
}

@(private = "file")
similarity_piece_lines :: proc(nodes: []Similarity_Node, piece: Similarity_Piece) -> i64 {
	return i64(nodes[piece.last].last_line - nodes[piece.first].first_line + 1)
}

// The data flow of a run of statements: the locals that it reads from
// before it, the locals that it gives to the statements after it, and
// whether control leaves it. Control leaves an expression with an
// `or_return` too.
@(private = "file")
similarity_piece_flow :: proc(analysis: ^Similarity_Analysis, piece: Similarity_Piece) -> (inputs, outputs: i32, control_leaves: bool) {
	nodes := analysis.nodes
	if piece.kind == .Procedure {
		// A whole procedure is replaced by a call of one procedure: its
		// returns are its own.
		return 0, 0, false
	}
	low, high := similarity_piece_range(nodes, piece)
	procedure := nodes[piece.first].procedure
	declared := make(map[i32]bool, context.temp_allocator)
	written := make(map[i32]bool, context.temp_allocator)
	used := make(map[i32]bool, context.temp_allocator)
	for node := low; node < high; node += 1 {
		item := nodes[node]
		if item.procedure != procedure {
			continue
		}
		if item.local >= 0 {
			switch item.role {
			case .Declared, .Label:
				declared[item.local] = true
			case .Place:
				written[item.local] = true
				used[item.local] = true
			case .Value, .Type, .Called, .Field, .Statement, .Structure:
				used[item.local] = true
			}
		}
		#partial switch item.kind {
		case .Return_Stmt, .Or_Return_Expr, .Or_Branch_Expr, .Defer_Stmt:
			control_leaves = true
		case .Branch_Stmt:
			if strings.contains(item.label, "label") || !similarity_loop_inside(nodes, node, low) {
				control_leaves = true
			}
		}
	}
	if piece.kind != .Run {
		return 0, 0, control_leaves
	}
	for local in used {
		if local not_in declared {
			inputs += 1
		}
	}
	given := make(map[i32]bool, context.temp_allocator)
	if procedure >= 0 {
		procedure_end := procedure + nodes[procedure].size
		for node := high; node < procedure_end; node += 1 {
			item := nodes[node]
			if item.local < 0 || item.procedure != procedure || item.role == .Declared {
				continue
			}
			if item.local in declared || item.local in written {
				given[item.local] = true
			}
		}
	}
	return inputs, i32(len(given)), control_leaves
}

// A `break` or a `continue` whose loop or switch is inside the piece.
@(private = "file")
similarity_loop_inside :: proc(nodes: []Similarity_Node, node: i32, low: i32) -> bool {
	ancestor := nodes[node].parent
	for ancestor >= low {
		#partial switch nodes[ancestor].kind {
		case .For_Stmt, .Range_Stmt, .Unroll_Range_Stmt, .Switch_Stmt, .Type_Switch_Stmt:
			return true
		}
		ancestor = nodes[ancestor].parent
	}
	return false
}

@(private = "file")
similarity_piece_rules :: proc(nodes: []Similarity_Node, piece: Similarity_Piece) -> (rules: Similarity_Rules, holds_using: bool) {
	low, high := similarity_piece_range(nodes, piece)
	for node := low; node < high; node += 1 {
		rules += nodes[node].rules
		holds_using = holds_using || .Holds_Using in nodes[node].flags
	}
	return rules, holds_using
}

// The base name of a file with a system suffix, and whether it has one.
@(private = "file")
similarity_platform_base :: proc(path: string) -> (base: string, suffix: string, found: bool) {
	name := strings.trim_suffix(path, ".odin")
	suffixes := SIMILARITY_SYSTEM_SUFFIXES
	for candidate in suffixes {
		if strings.has_suffix(name, candidate) {
			return name[:len(name) - len(candidate)], candidate, true
		}
	}
	return "", "", false
}

// A template that a home under src/ cannot hold: it calls an allocator,
// or names a package that only the host has.
@(private = "file")
similarity_template_needs_the_host :: proc(analysis: ^Similarity_Analysis, template: Similarity_Template) -> bool {
	nodes := analysis.nodes
	first := analysis.pieces[template.members[0]]
	low, high := similarity_piece_range(nodes, first)
	calls := ALLOCATOR_CALLS
	for node := low; node < high; node += 1 {
		if !template.in_template[node - low] {
			continue
		}
		item := nodes[node]
		switch {
		case item.kind == .Dynamic_Array_Type:
			return true
		case item.kind == .Qualified_Name && (strings.has_prefix(item.label, "core:fmt.") || strings.has_prefix(item.label, "core:os.")):
			return true
		case item.kind == .Ident && item.local < 0 && item.role == .Called:
			for call in calls {
				if item.label == call {
					return true
				}
			}
		case item.kind == .Selector_Expr && item.child_count == 2:
			base := nodes[item.first_child]
			field := nodes[base.next_sibling]
			if base.kind == .Implicit && base.label == "context" && (field.label == "allocator" || field.label == "temp_allocator") {
				return true
			}
		}
	}
	return false
}

// similarity_family_home gives the home of a factored procedure, and
// whether the rules keep the members apart
// (src/md/infrastructure/similarity_finder.md, "9. The home of a factored procedure").
@(private = "file")
similarity_family_home :: proc(analysis: ^Similarity_Analysis, family: ^Similarity_Family) -> (home: string, kept_apart: bool) {
	if len(family.packages) == 1 {
		return family.packages[0], false
	}
	under_source := false
	under_tools := false
	for member in family.template.members {
		path := analysis.files[analysis.nodes[analysis.pieces[member].first].file].path
		if strings.has_prefix(path, SOURCE_FOLDER_KERNEL + "/") || strings.has_prefix(path, SOURCE_FOLDER_CONTRACT + "/") {
			return "a contract package, by a decision", true
		}
		under_source = under_source || strings.has_prefix(path, "src/")
		under_tools = under_tools || strings.has_prefix(path, "tools/")
	}
	if under_source && under_tools && similarity_template_needs_the_host(analysis, family.template) {
		return "none: the template needs the host, and a member is under src/", true
	}
	shared: []string
	for member, position in family.template.members {
		imports := analysis.files[analysis.nodes[analysis.pieces[member].first].file].support_imports
		if position == 0 {
			shared = imports
			continue
		}
		kept := make([dynamic]string, context.temp_allocator)
		for path in shared {
			if _, found := slice.binary_search(imports, path); found {
				append(&kept, path)
			}
		}
		shared = kept[:]
	}
	if len(shared) > 0 {
		return strings.clone(shared[0], analysis.allocator), false
	}
	return "a new support package", false
}

// similarity_family_describe gives a family its category, its home, its
// hash, the size of its template in lines and its flow.
@(private = "file")
similarity_family_describe :: proc(analysis: ^Similarity_Analysis, family: ^Similarity_Family) {
	nodes := analysis.nodes
	template := family.template
	first := analysis.pieces[template.members[0]]
	packages := make([dynamic]string, analysis.allocator)
	all_rules: Similarity_Rules
	common_rules := ~Similarity_Rules{}
	platform := true
	platform_base := ""
	platform_suffixes := make(map[string]bool, context.temp_allocator)
	for member, position in template.members {
		piece := analysis.pieces[member]
		file := analysis.files[nodes[piece.first].file]
		if _, found := slice.linear_search(packages[:], file.folder); !found {
			append(&packages, file.folder)
		}
		rules, holds_using := similarity_piece_rules(nodes, piece)
		all_rules += rules
		common_rules &= rules
		family.holds_using = family.holds_using || holds_using
		inputs, outputs, leaves := similarity_piece_flow(analysis, piece)
		family.control_leaves = family.control_leaves || leaves
		if position == 0 {
			family.run_inputs = inputs
			family.run_outputs = outputs
		}
		base, suffix, has_suffix := similarity_platform_base(file.path)
		if !has_suffix || (position > 0 && base != platform_base) {
			platform = false
		}
		platform_base = base
		platform_suffixes[suffix] = true
	}
	slice.sort(packages[:])
	family.packages = packages[:]
	family.rules = all_rules - common_rules
	family.template_hash = similarity_template_hash(nodes, analysis.pieces[:], template)
	family.template_lines = i64(f64(similarity_piece_lines(nodes, first)) * f64(template.matched) / f64(max(first.size, 1)) + 0.5)
	one_procedure := similarity_template_is_one_procedure(template) && !family.control_leaves
	equal := one_procedure && template.parameter_count == 0
	home, kept_apart := similarity_family_home(analysis, family)
	family.home = home
	switch {
	case platform && len(platform_suffixes) >= 2:
		family.category = .Platform_Variant
		family.home = "none: the variants are the design of the platform code"
	case !one_procedure:
		family.category = .Similar_Behaviour
		family.home = "none: no one call replaces the members"
	case kept_apart:
		family.category = .Kept_Apart_By_The_Rules
	case family.kind == .Expression:
		family.category = .Repeated_Expression
	case equal && len(family.packages) >= 2:
		family.category = .Utility_To_Centralise
	case equal:
		family.category = .Local_Repetition
	case:
		family.category = .Parametric_Family
	}
}

// similarity_kept_lines reads the kept list: on each line that is not
// empty, the template hash in 16 hexadecimal digits, a space, the reason.
similarity_kept_lines :: proc(text: string, allocator: mem.Allocator) -> []Similarity_Kept_Line {
	lines := make([dynamic]Similarity_Kept_Line, allocator)
	number: i32 = 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		item := Similarity_Kept_Line{line = number, text = trimmed}
		space := strings.index_byte(trimmed, ' ')
		if space == 16 {
			if value, ok := strconv.parse_u64_of_base(trimmed[:16], 16); ok {
				reason := strings.trim_space(trimmed[17:])
				if reason != "" {
					item.hash = value
					item.reason = reason
					item.valid = true
				}
			}
		}
		append(&lines, item)
	}
	return lines[:]
}

@(private = "file")
similarity_apply_kept :: proc(analysis: ^Similarity_Analysis) {
	for &line in analysis.kept {
		if !line.valid {
			continue
		}
		for &family in analysis.families {
			if family.reported && family.template_hash == line.hash {
				family.kept = true
				family.kept_reason = line.reason
				line.used = true
			}
		}
	}
}

@(private = "file")
similarity_family_saved :: proc(analysis: ^Similarity_Analysis, family: Similarity_Family, uses: i64) -> (nodes, lines: i64) {
	matched := i64(family.template.matched)
	nodes = (uses - 1) * matched - uses - family.template.parameter_cost
	lines = (uses - 1) * family.template_lines - uses - 2
	return nodes, lines
}

@(private = "file")
Similarity_Candidate :: struct {
	saved:  i64,
	hash:   u64,
	family: i32,
}

// similarity_rank takes the family that saves the most nodes, marks the
// nodes of its members as used, counts the others again without them, and
// repeats, as Stitch does. A count that only falls lets the queue keep an
// old count until its family comes to the top.
@(private = "file")
similarity_rank :: proc(analysis: ^Similarity_Analysis) {
	used := make([]bool, len(analysis.nodes), analysis.allocator)
	queue: priority_queue.Priority_Queue(Similarity_Candidate)
	priority_queue.init(&queue, proc(a, b: Similarity_Candidate) -> bool {
		return a.saved > b.saved || (a.saved == b.saved && (a.hash < b.hash || (a.hash == b.hash && a.family < b.family)))
	}, proc(items: []Similarity_Candidate, i, j: int) {
		items[i], items[j] = items[j], items[i]
	}, allocator = context.temp_allocator)
	for family, index in analysis.families {
		if !family.reported || family.kept || !similarity_category_is_factorable(family.category) {
			continue
		}
		saved, _ := similarity_family_saved(analysis, family, i64(len(family.template.members)))
		if saved > 0 {
			priority_queue.push(&queue, Similarity_Candidate{saved = saved, hash = family.template_hash, family = i32(index)})
		} else {
			analysis.measures.families_unranked += 1
		}
	}
	rank: i32 = 0
	for priority_queue.len(queue) > 0 {
		candidate := priority_queue.pop(&queue)
		family := &analysis.families[candidate.family]
		uses: i64 = 0
		for member in family.template.members {
			if !similarity_piece_touches(analysis, analysis.pieces[member], used) {
				uses += 1
			}
		}
		saved, saved_lines := similarity_family_saved(analysis, family^, uses)
		if uses < 2 || saved <= 0 {
			analysis.measures.families_unranked += 1
			continue
		}
		if saved < candidate.saved {
			priority_queue.push(&queue, Similarity_Candidate{saved = saved, hash = candidate.hash, family = candidate.family})
			continue
		}
		rank += 1
		family.rank = rank
		family.selected_uses = i32(uses)
		family.saved_nodes = saved
		family.saved_lines = saved_lines
		analysis.measures.saved_nodes += saved
		analysis.measures.saved_lines += saved_lines
		for member in family.template.members {
			piece := analysis.pieces[member]
			if similarity_piece_touches(analysis, piece, used) {
				continue
			}
			low, high := similarity_piece_range(analysis.nodes, piece)
			for node := low; node < high; node += 1 {
				used[node] = true
			}
		}
	}
}

@(private = "file")
similarity_piece_touches :: proc(analysis: ^Similarity_Analysis, piece: Similarity_Piece, used: []bool) -> bool {
	low, high := similarity_piece_range(analysis.nodes, piece)
	for node := low; node < high; node += 1 {
		if used[node] {
			return true
		}
	}
	return false
}

// similarity_count_measures counts the nodes and the lines of each area,
// and those in a family of each category, each node and each line once.
@(private = "file")
similarity_count_measures :: proc(analysis: ^Similarity_Analysis) {
	measures := &analysis.measures
	nodes := analysis.nodes
	for file in analysis.files {
		measures.files[file.area] += 1
		measures.lines[file.area] += i64(file.line_count)
	}
	for item in nodes {
		area := analysis.files[item.file].area
		measures.nodes[area] += 1
		if item.kind == .Proc_Lit && !strings.contains(item.label, "foreign") {
			measures.procedures[area] += 1
		}
	}
	node_marks := make([]u8, len(nodes), context.temp_allocator)
	line_marks := make([][]u8, len(analysis.files), context.temp_allocator)
	for file, index in analysis.files {
		line_marks[index] = make([]u8, file.line_count + 2, context.temp_allocator)
	}
	for family in analysis.families {
		if !family.reported {
			continue
		}
		bit := u8(1) << u8(family.category)
		for member in family.template.members {
			piece := analysis.pieces[member]
			low, high := similarity_piece_range(nodes, piece)
			for node := low; node < high; node += 1 {
				node_marks[node] |= bit
			}
			file := nodes[piece.first].file
			for line := nodes[piece.first].first_line; line <= nodes[piece.last].last_line; line += 1 {
				if line >= 0 && int(line) < len(line_marks[file]) {
					line_marks[file][line] |= bit
				}
			}
		}
	}
	for mark, node in node_marks {
		if mark == 0 {
			continue
		}
		area := analysis.files[nodes[node].file].area
		measures.any_family_nodes[area] += 1
		for category in Similarity_Category {
			if mark & (u8(1) << u8(category)) != 0 {
				measures.family_nodes[category][area] += 1
			}
		}
	}
	for marks, file in line_marks {
		area := analysis.files[file].area
		for mark in marks {
			if mark == 0 {
				continue
			}
			measures.any_family_lines[area] += 1
			for category in Similarity_Category {
				if mark & (u8(1) << u8(category)) != 0 {
					measures.family_lines[category][area] += 1
				}
			}
		}
	}
}

// similarity_procedure_at gives the innermost procedure piece of a file
// that holds a line, or -1.
similarity_procedure_at :: proc(analysis: ^Similarity_Analysis, path: string, line: i32) -> i32 {
	best: i32 = -1
	for piece, index in analysis.pieces {
		if piece.kind != .Procedure {
			continue
		}
		node := analysis.nodes[piece.first]
		if analysis.files[node.file].path != path || line < node.first_line || line > node.last_line {
			continue
		}
		if best < 0 || analysis.pieces[best].size > piece.size {
			best = i32(index)
		}
	}
	return best
}

// similarity_procedure_piece_at makes a piece of the procedure that holds a
// line, of any size, for the commands `near` and `pair`.
similarity_procedure_piece_at :: proc(analysis: ^Similarity_Analysis, path: string, line: i32) -> i32 {
	if found := similarity_procedure_at(analysis, path, line); found >= 0 {
		return found
	}
	best: i32 = -1
	for node, index in analysis.nodes {
		if node.kind != .Proc_Lit || strings.contains(node.label, "foreign") || analysis.files[node.file].path != path || line < node.first_line || line > node.last_line {
			continue
		}
		if best < 0 || analysis.nodes[best].size > node.size {
			best = i32(index)
		}
	}
	if best < 0 {
		return -1
	}
	return similarity_add_piece(analysis, .Procedure, best, best, 1)
}

// One code piece near another, for the command `near`.
Similarity_Near_Result :: struct {
	piece:     i32,
	score:     f64,
	alignment: ^Similarity_Alignment,
}

// similarity_near_procedures gives the procedures whose score with one
// piece is at least `least`, from the highest score.
similarity_near_procedures :: proc(analysis: ^Similarity_Analysis, target: i32, least: f64) -> []Similarity_Near_Result {
	results := make([dynamic]Similarity_Near_Result, analysis.allocator)
	size := analysis.pieces[target].size
	target_piece := analysis.pieces[target]
	candidates := make([dynamic][2]i32, analysis.allocator)
	for piece, index in analysis.pieces {
		if i32(index) == target || piece.kind != .Procedure || similarity_pieces_overlap(analysis.nodes, piece, target_piece) {
			continue
		}
		smaller := min(size, piece.size)
		if similarity_score(smaller, size, piece.size) < least {
			continue
		}
		append(&candidates, [2]i32{target, i32(index)})
	}
	scores, _ := similarity_compare_pairs(analysis.nodes, analysis.pieces[:], candidates[:], analysis.allocator)
	for pair, index in candidates {
		if scores[index] < least {
			continue
		}
		alignment := similarity_alignment_of(analysis, pair[0], pair[1])
		score := similarity_score(alignment.matched, size, analysis.pieces[pair[1]].size)
		if score >= least {
			append(&results, Similarity_Near_Result{piece = pair[1], score = score, alignment = alignment})
		}
	}
	slice.sort_by(results[:], proc(a, b: Similarity_Near_Result) -> bool {
		return a.score > b.score || (a.score == b.score && a.piece < b.piece)
	})
	return results[:]
}

// similarity_pair_template gives the template of two pieces, whatever
// their score.
similarity_pair_template :: proc(analysis: ^Similarity_Analysis, first, other: i32) -> Similarity_Template {
	members := make([]i32, 2, analysis.allocator)
	members[0] = first
	members[1] = other
	alignments := make([]^Similarity_Alignment, 1, analysis.allocator)
	alignments[0] = similarity_alignment_of(analysis, first, other)
	template := similarity_template(analysis.nodes, analysis.pieces[:], members, alignments, analysis.allocator, virtual.arena_allocator(&analysis.family_arena))
	virtual.arena_free_all(&analysis.family_arena)
	return template
}
