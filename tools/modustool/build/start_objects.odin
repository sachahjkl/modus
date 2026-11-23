package build

import "core:odin/ast"
import "core:strings"

// The start objects of a module and of its packages
// (src/md/features/module_budget_request.md, "The floor is counted whole";
// system.Start_Object): the memory objects that the process makes before
// its first state of work, each by the name of the constant that its code
// passes to memory_create. The tool reads the lists from the sources that
// the compiler read for the module, resolves each name to its integer
// literal, and the count of the floor prices each object. It evaluates
// nothing: a name whose value is not one integer literal is refused.

// The list of the objects of the package of a module, and of a package that
// it imports.
MODULE_START_OBJECTS_NAME :: "MODULE_START_OBJECTS"
PACKAGE_START_OBJECTS_NAME :: "PACKAGE_START_OBJECTS"
// The list of the budgets of a fixed amount that the process of a module
// makes for its children before its first state of work, in the package of
// the module alone (system.Start_Budget): the count of the floor takes
// each one at its pages, as the parent carves them. A child that the
// module table names is counted at its floor; a child whose parent gives
// it a fixed amount is listed here, and not named there.
MODULE_START_BUDGETS_NAME :: "MODULE_START_BUDGETS"

// The form of a list, for the message of a refusal.
@(private = "file")
START_OBJECTS_FORM :: "the form is NAME :: [?]system.Start_Object{RING_PAGES, LENT_PAGES}, each element the name of a constant of the package whose value is one integer literal, with a comment that gives the reasons"

// One list of start objects of one package, as its source declares it.
@(private = "file")
Start_Object_List :: struct {
	path:        string,
	declaration: ^ast.Value_Decl,
	names:       []string,
}

// start_objects_of_sources gives the pages of each start object of a module
// whose package is in module_folder, from the sources that the compiler
// read for it: the list MODULE_START_OBJECTS_NAME of its package, and the
// list PACKAGE_START_OBJECTS_NAME of each package compiled into it. A list
// is declared once in a package, at the top level of a file, as a constant
// array of names; MODULE_START_OBJECTS_NAME only in the package of the
// module, PACKAGE_START_OBJECTS_NAME only in another package. ok is false
// for another form, with its file and its line on the error stream.
start_objects_of_sources :: proc(module_folder: string, sources: []Fact_Source) -> (pages: []u64, ok: bool) {
	state: Describe_State
	// The integer constants and the list of each folder: a name resolves in
	// the package of its list.
	constants := make(map[string]map[string]u64, context.temp_allocator)
	lists := make(map[string]Start_Object_List, context.temp_allocator)
	module_package := strings.trim_right(module_folder, "/")
	for source in sources {
		if strings.has_suffix(source.path, "_test.odin") {
			continue
		}
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		file := parse_source(source.path, source.source, &state) or_return
		if folder not_in constants {
			constants[folder] = make(map[string]u64, context.temp_allocator)
		}
		folder_constants := &constants[folder]
		integer_constants_read(file, folder_constants)
		// The list of sources can name a file by its whole path: the
		// package of the module is the folder that ends with its folder.
		of_the_module := folder == module_package || strings.has_suffix(folder, strings.concatenate({"/", module_package}, context.temp_allocator))
		list, found := start_object_list_read(file, of_the_module) or_return
		if !found {
			continue
		}
		if earlier, twice := lists[folder]; twice {
			return nil, describe_fail(source.path, list.declaration, "the package of %s declares its start objects two times: one list for each package", earlier.path)
		}
		lists[folder] = list
	}
	all := make([dynamic]u64, context.temp_allocator)
	for folder, list in lists {
		for name in list.names {
			value, resolved := constants[folder][name]
			if !resolved {
				return nil, describe_fail(list.path, list.declaration, "the start object %s is not a constant of the package whose value is one integer literal: the tool evaluates no expression. Write its pages as a literal, with #assert of the expression beside it", name)
			}
			if value == 0 {
				return nil, describe_fail(list.path, list.declaration, "the start object %s has no page: leave it out", name)
			}
			append(&all, value)
		}
	}
	return all[:], true
}

// start_budgets_of_sources gives the pages of each budget of a fixed amount
// that the process of a module makes for a child before its first state of
// work: the list MODULE_START_BUDGETS_NAME of the package of the module,
// each element the name of a constant of one integer literal, the constant
// that the code passes as the pages of budget_create. The list is refused
// in another package, and in each form that start_objects_of_sources
// refuses.
start_budgets_of_sources :: proc(module_folder: string, sources: []Fact_Source) -> (pages: []u64, ok: bool) {
	state: Describe_State
	constants := make(map[string]u64, context.temp_allocator)
	module_package := strings.trim_right(module_folder, "/")
	list: Start_Object_List
	listed := false
	for source in sources {
		if strings.has_suffix(source.path, "_test.odin") {
			continue
		}
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		of_the_module := folder == module_package || strings.has_suffix(folder, strings.concatenate({"/", module_package}, context.temp_allocator))
		file := parse_source(source.path, source.source, &state) or_return
		file_list, found := name_list_read(file, MODULE_START_BUDGETS_NAME, "Start_Budget", START_BUDGETS_FORM) or_return
		if !found {
			continue
		}
		if !of_the_module {
			return nil, describe_fail(source.path, file_list.declaration, "%s is in a package that the module imports: a package makes no budget of a child for its importer", MODULE_START_BUDGETS_NAME)
		}
		if listed {
			return nil, describe_fail(source.path, file_list.declaration, "the package of %s lists its start budgets two times: one list for each package", list.path)
		}
		list, listed = file_list, true
	}
	for source in sources {
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		if strings.has_suffix(source.path, "_test.odin") || !(folder == module_package || strings.has_suffix(folder, strings.concatenate({"/", module_package}, context.temp_allocator))) {
			continue
		}
		file := parse_source(source.path, source.source, &state) or_return
		integer_constants_read(file, &constants)
	}
	all := make([dynamic]u64, context.temp_allocator)
	for name in list.names {
		value, resolved := constants[name]
		if !resolved {
			return nil, describe_fail(list.path, list.declaration, "the start budget %s is not a constant of the package whose value is one integer literal: the tool evaluates no expression", name)
		}
		if value == 0 {
			return nil, describe_fail(list.path, list.declaration, "the start budget %s has no page: leave it out", name)
		}
		append(&all, value)
	}
	return all[:], true
}

// The form of a list of start budgets, for the message of a refusal.
@(private = "file")
START_BUDGETS_FORM :: "the form is MODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES, NODE_PAGES}, each element the name of a constant of the package whose value is one integer literal, with a comment that gives the reasons"

// start_object_list_read reads the list of one parsed file: the list of the
// module in the package of the module, else the list of a package. found
// is false for a file with no list.
@(private = "file")
start_object_list_read :: proc(file: ^ast.File, of_the_module: bool) -> (list: Start_Object_List, found: bool, ok: bool) {
	path := file.fullpath
	own_name := of_the_module ? MODULE_START_OBJECTS_NAME : PACKAGE_START_OBJECTS_NAME
	other_name := of_the_module ? PACKAGE_START_OBJECTS_NAME : MODULE_START_OBJECTS_NAME
	for statement in file.decls {
		if declaration, is_value := statement.derived.(^ast.Value_Decl); is_value && declaration_names(declaration, other_name) {
			where_text := of_the_module ? "the package of a module: its name there is " + MODULE_START_OBJECTS_NAME : "a package that the module imports: its name there is " + PACKAGE_START_OBJECTS_NAME
			return {}, false, describe_fail(path, declaration, "%s is in %s", other_name, where_text)
		}
		if when_statement, is_when := statement.derived.(^ast.When_Stmt); is_when {
			if inner := declaration_in_when(when_statement, other_name); inner != nil {
				return {}, false, describe_fail(path, inner, "%s is inside a `when`: the tool reads the source with no setting of the build. Declare it at the top level of a file", other_name)
			}
		}
	}
	return name_list_read(file, own_name, "Start_Object", START_OBJECTS_FORM)
}

// name_list_read reads the constant list_name of one parsed file: a
// constant array literal of the element type element_type, each element a
// name, with a comment. found is false for a file with no such list.
@(private = "file")
name_list_read :: proc(file: ^ast.File, own_name: string, element_type: string, form: string) -> (list: Start_Object_List, found: bool, ok: bool) {
	path := file.fullpath
	for statement in file.decls {
		if when_statement, is_when := statement.derived.(^ast.When_Stmt); is_when {
			if inner := declaration_in_when(when_statement, own_name); inner != nil {
				return {}, false, describe_fail(path, inner, "%s is inside a `when`: the tool reads the source with no setting of the build. Declare it at the top level of a file", own_name)
			}
			continue
		}
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value {
			continue
		}
		if !declaration_names(declaration, own_name) {
			continue
		}
		if found {
			return {}, false, describe_fail(path, declaration, "%s is declared two times in one file", own_name)
		}
		if len(declaration.names) != 1 || declaration.is_mutable || len(declaration.values) != 1 {
			return {}, false, describe_fail(path, declaration, "%s is one constant (::), declared alone: %s", own_name, form)
		}
		literal, is_literal := declaration.values[0].derived.(^ast.Comp_Lit)
		if !is_literal || !named_array_type(literal.type, element_type) {
			return {}, false, describe_fail(path, declaration, "%s is not an array literal of system.%s: %s", own_name, element_type, form)
		}
		if markdown_of(declaration.docs) == "" {
			return {}, false, describe_fail(path, declaration, "%s has no comment: the comment before it says what each object is for", own_name)
		}
		names := make([dynamic]string, context.temp_allocator)
		for element in literal.elems {
			identifier, is_name := element.derived.(^ast.Ident)
			if !is_name {
				return {}, false, describe_fail(path, element, "%s: an element is not a name: %s", own_name, form)
			}
			append(&names, identifier.name)
		}
		if len(names) == 0 {
			return {}, false, describe_fail(path, declaration, "%s names no object: leave the list out", own_name)
		}
		list, found = {path = path, declaration = declaration, names = names[:]}, true
	}
	return list, found, true
}

// named_array_type says if a type is [?]element or [N]element, with or
// without the name of its package.
@(private = "file")
named_array_type :: proc(type: ^ast.Expr, element: string) -> bool {
	if type == nil {
		return false
	}
	array, is_array := type.derived.(^ast.Array_Type)
	if !is_array || array.elem == nil {
		return false
	}
	#partial switch named in array.elem.derived {
	case ^ast.Ident:
		return named.name == element
	case ^ast.Selector_Expr:
		return named.field != nil && named.field.name == element
	}
	return false
}

// declaration_in_when gives a declaration of name in a `when`, at any depth
// of its branches, or nil.
@(private = "file")
declaration_in_when :: proc(statement: ^ast.Stmt, name: string) -> ^ast.Value_Decl {
	#partial switch item in statement.derived {
	case ^ast.When_Stmt:
		if found := declaration_in_when(item.body, name); found != nil {
			return found
		}
		if item.else_stmt != nil {
			return declaration_in_when(item.else_stmt, name)
		}
	case ^ast.Block_Stmt:
		for inner in item.stmts {
			if found := declaration_in_when(inner, name); found != nil {
				return found
			}
		}
	case ^ast.Value_Decl:
		if declaration_names(item, name) {
			return item
		}
	}
	return nil
}
