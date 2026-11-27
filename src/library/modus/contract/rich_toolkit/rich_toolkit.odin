// Pure freestanding external/rich-module ABI bridge:
//   - Transitive outside-module import resolver with cycle detection & hash pinning
//   - gui_toolkit modus style palette & spacing tokens matching docs/DESIGN.md
package rich_toolkit

// Plan value: one root module plus up to 64 transitive outside-module imports
// matching the per-process module table capacity.
MAX_OUTSIDE_MODULES :: 65
// Plan value: maximum direct outside-module imports per module matching the
// per-process module table capacity.
MAX_IMPORTS_PER_MODULE :: 64

Modus_Style_Tokens :: struct {
	background_rgba:    u32,
	surface_rgba:       u32,
	border_rgba:        u32,
	text_primary_rgba:  u32,
	text_muted_rgba:    u32,
	accent_rgba:        u32,
	danger_rgba:        u32,
	corner_radius_px:   i32, // 0: rectangular forms preferred by docs/DESIGN.md
	border_width_px:    i32,
	unit_spacing_px:    i32,
	bar_height_px:      i32,
}

MODUS_GUI_TOOLKIT_DARK :: Modus_Style_Tokens{
	background_rgba   = 0x0F1115FF,
	surface_rgba      = 0x161A20FF,
	border_rgba       = 0x2D3440FF,
	text_primary_rgba = 0xE6EBF2FF,
	text_muted_rgba   = 0x9AA5B4FF,
	accent_rgba       = 0x5FA8FFFF,
	danger_rgba       = 0xE05A5AFF,
	corner_radius_px  = 0,
	border_width_px   = 1,
	unit_spacing_px   = 8,
	bar_height_px     = 28,
}

MODUS_GUI_TOOLKIT_HIGH_CONTRAST :: Modus_Style_Tokens{
	background_rgba   = 0x000000FF,
	surface_rgba      = 0x000000FF,
	border_rgba       = 0xFFFFFFFF,
	text_primary_rgba = 0xFFFFFFFF,
	text_muted_rgba   = 0xE6E6E6FF,
	accent_rgba       = 0x7FC8FFFF,
	danger_rgba       = 0xFF8080FF,
	corner_radius_px  = 0,
	border_width_px   = 2,
	unit_spacing_px   = 8,
	bar_height_px     = 28,
}

Outside_Module_Entry :: struct {
	used:         bool,
	hash:         [32]u8,
	import_count: u8,
	imports:      [MAX_IMPORTS_PER_MODULE][32]u8,
}

Import_Graph :: struct {
	modules: [MAX_OUTSIDE_MODULES]Outside_Module_Entry,
	count:   int,
}

Resolve_Refusal :: enum u8 {
	None           = 0,
	Graph_Full     = 1,
	Missing_Import = 2,
	Cycle_Detected = 3,
}

graph_add :: proc "contextless" (g: ^Import_Graph, hash: [32]u8, imports: [][32]u8) -> Resolve_Refusal {
	if g == nil || g.count >= MAX_OUTSIDE_MODULES || len(imports) > MAX_IMPORTS_PER_MODULE {
		return .Graph_Full
	}
	e := &g.modules[g.count]
	e^ = {used = true, hash = hash, import_count = u8(len(imports))}
	for i in 0 ..< len(imports) {
		e.imports[i] = imports[i]
	}
	g.count += 1
	return .None
}

@(private)
find_by_hash :: proc "contextless" (g: ^Import_Graph, h: [32]u8) -> int {
	for i in 0 ..< g.count {
		if g.modules[i].used && g.modules[i].hash == h {
			return i
		}
	}
	return -1
}

// graph_resolve_order performs a topological post-order resolution of outside
// module root_hash and all of its transitive outside-module imports, refusing
// missing hashes or import cycles.
graph_resolve_order :: proc "contextless" (g: ^Import_Graph, root_hash: [32]u8, out_order: []int) -> (count: int, refusal: Resolve_Refusal) {
	if g == nil {
		return 0, .Missing_Import
	}
	root_idx := find_by_hash(g, root_hash)
	if root_idx < 0 {
		return 0, .Missing_Import
	}
	// Iterative DFS using color states: 0=unvisited, 1=visiting, 2=done.
	color: [MAX_OUTSIDE_MODULES]u8
	stack_node: [MAX_OUTSIDE_MODULES]int
	stack_edge: [MAX_OUTSIDE_MODULES]int
	sp := 0
	stack_node[sp] = root_idx
	stack_edge[sp] = 0
	color[root_idx] = 1
	sp += 1

	for sp > 0 {
		cur := stack_node[sp - 1]
		edge := stack_edge[sp - 1]
		if edge < int(g.modules[cur].import_count) {
			stack_edge[sp - 1] = edge + 1
			dep_idx := find_by_hash(g, g.modules[cur].imports[edge])
			if dep_idx < 0 {
				return 0, .Missing_Import
			}
			if color[dep_idx] == 1 {
				return 0, .Cycle_Detected
			}
			if color[dep_idx] == 0 {
				color[dep_idx] = 1
				stack_node[sp] = dep_idx
				stack_edge[sp] = 0
				sp += 1
			}
		} else {
			color[cur] = 2
			sp -= 1
			if count < len(out_order) {
				out_order[count] = cur
				count += 1
			}
		}
	}
	return count, .None
}
