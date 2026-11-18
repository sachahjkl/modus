package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:checks"

// The film of a document (docs/TOOLS.md, "The film of a document").
//
// The command `film` writes its files in the build folder. A film that a
// news entry names is also a file of the repository, as a screen picture
// is: the site copies it and needs no encoder. That file is WebM with AV1,
// the smallest of the formats that were measured for a film of the screen.
// This file holds the checks of such a file, from its bytes only, and the
// copy from the build folder to the repository.

// film_document_path gives the path of the film with a name in the
// repository.
film_document_path :: proc(name: string) -> string {
	return strings.concatenate({checks.FILM_DOCUMENT_FOLDER, "/", name, checks.FILM_DOCUMENT_SUFFIX}, context.temp_allocator)
}

// film_is_named_by_a_news_entry says whether an entry of the news names
// the film with this name. The faults of the entries are not printed here:
// `news check` prints them, and the entry that names a film is faulty
// until the first run of the command writes the file.
film_is_named_by_a_news_entry :: proc(name: string) -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	path := film_document_path(name)
	for entry in checks.news_read(checks.NEWS_FOLDER, &problems) {
		if entry.film == path {
			return true
		}
	}
	return false
}

// film_document_write copies the WebM file of a film from the build
// folder to the repository, after the checks that `news check` makes on
// it: the command never leaves a file there that the check refuses.
film_document_write :: proc(name, source: string) -> bool {
	data := foundation.read_file(source) or_return
	if problem := checks.film_document_problem(data); problem != "" {
		fmt.eprintfln("modustool: the film: %s %s; the repository keeps the film that it has", source, problem)
		return false
	}
	foundation.make_folder(checks.FILM_DOCUMENT_FOLDER) or_return
	target := film_document_path(name)
	if write_error := os.write_entire_file(target, data); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, write_error)
		return false
	}
	fmt.printfln("modustool: wrote %s (%d bytes): a news entry names this film, and the repository holds it", target, len(data))
	return true
}
