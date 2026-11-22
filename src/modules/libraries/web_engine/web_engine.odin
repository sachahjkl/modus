// Freestanding shared library module combining HTTP/1.1 framing, WHATWG-subset
// HTML/CSS layout, and PNG/JPEG image probing so per-origin browser processes
// share one verified read-only engine module.
package web_engine_module

import "modus:contract/errors"
import "modus:contract/html_css"
import "modus:contract/http_client"
import "modus:contract/image_decode"

ERROR :: -1

// Static scratch arenas avoid large stack frames in freestanding library calls.
@(private)
engine_dom: html_css.Dom_Tree
@(private)
engine_sheet: html_css.Css_Stylesheet
@(private)
engine_layout: html_css.Layout_Tree

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
	html_css.parse_html(&engine_dom, {}, transmute([]u8)(html^))
	engine_sheet = {}
	html_css.parse_document_styles(&engine_dom, &engine_sheet)
	html_css.compute_layout(&engine_dom, &engine_sheet, i32(viewport_width), i32(viewport_height), &engine_layout)
	return i64(engine_layout.box_count)
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
