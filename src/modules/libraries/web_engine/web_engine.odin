// Freestanding shared library module combining HTTP/1.1 framing, WHATWG-subset
// HTML/CSS layout, and PNG/JPEG image probing so per-origin browser processes
// share one verified read-only engine module.
package web_engine_module

import "modus:contract/errors"
import "modus:contract/html_css"
import "modus:contract/http_client"
import "modus:contract/image_decode"
import "modus:system"
import "modus:web"

ERROR :: -1

// The document of a call: its tree, its style sheet and its boxes are in
// arenas of the budget of the process that imports this module, made at
// the first call and kept, which grow with the page: a page has no fixed
// count of nodes (src/md/features/desktop_to_browser.md, "The memory of a
// document").
@(private)
engine_dom: html_css.Dom_Tree
@(private)
engine_sheet: html_css.Css_Stylesheet
@(private)
engine_layout: html_css.Layout_Tree
@(private)
engine_arenas: web.Document_Arenas
@(private)
engine_memory_ready: bool

// engine_memory makes the arenas of the document at the first call: each
// reserves the pages that the budget holds. false: the budget did not pay
// a reservation.
@(private)
engine_memory :: proc "contextless" () -> bool {
	if engine_memory_ready {
		return true
	}
	own, _ := system.budget_read()
	if web.document_arenas_create(&engine_arenas, system.arena_reservation_pages(own.pages)) != .Ok {
		return false
	}
	web.document_memory_bind(&engine_arenas, &engine_dom, &engine_sheet, &engine_layout)
	engine_memory_ready = true
	return true
}

// http_request_build formats a strict RFC 9112 HTTP/1.1 GET request into result,
// refusing CRLF header injection and invalid paths with a typed error record.
@(export, link_name = "http_request_build")
http_request_build :: proc "c" (host: ^string, path: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	buf := result^
	written, refusal := http_client.encode_request(.Get, host^, path^, nil, nil, buf)
	if refusal != .None {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1, i64(refusal))
	}
	return i64(written)
}

// html_layout_count parses an HTML document and lays out its CSS block/inline
// boxes within viewport_width x viewport_height, returning the layout box count.
@(export, link_name = "html_layout_count")
html_layout_count :: proc "c" (html: ^string, viewport_width: i64, viewport_height: i64, error: ^errors.Error_Record) -> i64 {
	if viewport_width <= 0 || viewport_width > 8192 || viewport_height <= 0 || viewport_height > 8192 {
		return errors.fail(error, ERROR, .Out_Of_Range, .Counts, 2)
	}
	if !engine_memory() {
		return errors.fail(error, ERROR, .Budget, .Pages, 0)
	}
	html_css.parse_html(&engine_dom, {}, transmute([]u8)(html^))
	html_css.stylesheet_clear(&engine_sheet)
	html_css.parse_document_styles(&engine_dom, &engine_sheet)
	html_css.compute_layout(&engine_dom, &engine_sheet, i32(viewport_width), i32(viewport_height), &engine_layout)
	box_count := i64(engine_layout.box_count)
	// The pages past the need of this page go back to the budget.
	web.document_memory_trim(&engine_arenas, &engine_dom, &engine_sheet, &engine_layout)
	return box_count
}

// image_probe_pixels inspects PNG or JPEG bytes and returns width * height on
// valid headers, or an error record on malformed/oversized images.
@(export, link_name = "image_probe_pixels")
image_probe_pixels :: proc "c" (bytes: ^string, error: ^errors.Error_Record) -> i64 {
	raw := transmute([]u8)(bytes^)
	if len(raw) < 8 {
		return errors.fail(error, ERROR, .Empty, .Bytes, 1)
	}
	hdr, refusal := image_decode.image_probe(raw)
	if refusal != .None {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1, i64(refusal))
	}
	return i64(u64(hdr.width) * u64(hdr.height))
}
