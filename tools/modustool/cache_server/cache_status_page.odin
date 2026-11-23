// The page of an object cache and its status record
// (src/md/infrastructure/public_object_cache.md, "What the page says"). The
// page takes the style sheet, the bar, the tables and the values of the
// site from the same procedures of the tool, so it has the look of the site
// with no rule of its own. Each fact is on the page once.
package cache_server

import "core:fmt"
import "core:strings"
import "core:time"
import "modus:contract/object_cache"
import "modus:contract/value_kinds"
import "modustool:checks"
import "modustool:foundation"
import "modustool:resources"
import "modustool:site"

// The glossary group and the term that describe the cache protocol on the
// site.
CACHE_PAGE_GLOSSARY_GROUP :: "code"
CACHE_PAGE_GLOSSARY_TERM :: "term-object-cache"

CACHE_PAGE_TITLE :: "public object cache"

// cache_page_site_link gives the address of a page of the site: its folder
// with a final '/', as the site links to its pages when it has an address.
cache_page_site_link :: proc(site_address: string, page_file: string, anchor := "") -> string {
	folder := strings.trim_suffix(page_file, site.SITE_PAGE)
	if anchor != "" {
		return strings.concatenate({site_address, "/", folder, "#", anchor}, context.temp_allocator)
	}
	return strings.concatenate({site_address, "/", folder}, context.temp_allocator)
}

// cache_page_style_sheet gives the style sheet of the site, with each font
// taken from the site: the page has no font file of its own.
cache_page_style_sheet :: proc(site_address: string, allocator := context.allocator) -> string {
	sheet := site.site_style_sheet("")
	site_fonts := strings.concatenate({"url(\"", site_address, "/fonts/"}, context.temp_allocator)
	replaced, _ := strings.replace_all(sheet, "url(\"fonts/", site_fonts, context.temp_allocator)
	return strings.clone(replaced, allocator)
}

// cache_page_security_policy allows the style sheet and PNG previews of
// this host, the pictures and the font of the site, and the GET form of
// the search. The style sheet draws its icons from data addresses. Nothing
// else loads, and no script runs.
cache_page_security_policy :: proc(site_address: string) -> string {
	return fmt.tprintf("default-src 'none'; style-src 'self'; img-src 'self' %s data:; font-src %s; base-uri 'none'; form-action 'self'; frame-ancestors 'none'", site_address, site_address)
}

// cache_page_bytes_text gives a size in the binary units of the site.
cache_page_bytes_text :: proc(bytes: u64) -> string {
	units := [?]string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	if bytes < 1024 {
		return fmt.tprintf("%d bytes", bytes)
	}
	value := f64(bytes) / 1024
	unit := 0
	for value >= 1024 && unit + 1 < len(units) {
		value /= 1024
		unit += 1
	}
	return fmt.tprintf("%.1f %s", value, units[unit])
}

// cache_page_time_shown gives a time as the site shows it, to the minute,
// in UTC; cache_page_time_attribute gives the value of its datetime.
cache_page_time_shown :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, _ := time.clock_from_time(moment)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)
}

cache_page_time_attribute :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, second := time.clock_from_time(moment)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}

@(private = "file")
time_known :: proc(moment: time.Time) -> bool {
	return moment._nsec != 0
}

// Which top-level page of the cache bar is current.
Cache_Bar_Section :: enum u8 {
	None,
	Overview,
	Releases,
	Search,
}

@(private)
time_write :: proc(b: ^strings.Builder, moment: time.Time) {
	fmt.sbprintf(b, "<time class=\"value value-%s\" datetime=\"%s\">%s</time>", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Time], cache_page_time_attribute(moment), cache_page_time_shown(moment))
}

// A hash or a key, whole: its column of the kind Hash shows the digits
// that it holds and the browser cuts the rest, so a copy of the cell takes
// the whole value; the title shows it too.
@(private)
hash_write :: proc(b: ^strings.Builder, value: [32]u8) {
	hex := hash_to_hex(value)
	fmt.sbprintf(b, "<code class=\"value value-%s\" title=\"%s\">%s</code>", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Version], string(hex[:]), string(hex[:]))
}

// A hash as a link to one of the fixed browse prefixes (/tree/, /blob/,
// /realisation/). The href is formed from the validated 32-byte hash.
@(private)
hash_link_write :: proc(b: ^strings.Builder, path_prefix: string, value: [32]u8) {
	hex := hash_to_hex(value)
	fmt.sbprintf(b, "<a href=\"%s%s\" title=\"%s\"><code class=\"value value-%s\">%s</code></a>", path_prefix, string(hex[:]), string(hex[:]), value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Version], string(hex[:]))
}

@(private)
object_path_prefix :: proc(kind: object_cache.Cache_Object_Kind) -> string {
	switch kind {
	case .Blob:
		return "/blob/"
	case .Tree:
		return "/tree/"
	}
	return "/blob/"
}

@(private)
object_kind_text :: proc(kind: object_cache.Cache_Object_Kind) -> string {
	switch kind {
	case .Blob:
		return "blob"
	case .Tree:
		return "tree"
	}
	return "blob"
}

// cache_page_distinct_signers counts the distinct signer keys of the rows:
// at most RECENT_REALISATION_COUNT rows, so a pass over the rows before each
// row costs at most 45 comparisons.
cache_page_distinct_signers :: proc(rows: []Recent_Realisation) -> int {
	count := 0
	for row, index in rows {
		seen := false
		for earlier in rows[:index] {
			if earlier.record.signer_public_key == row.record.signer_public_key {
				seen = true
				break
			}
		}
		if !seen {
			count += 1
		}
	}
	return count
}

// cache_page_html_text gives a text in its escaped form for HTML.
cache_page_html_text :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	foundation.html_escape(&b, text)
	return strings.to_string(b)
}

// cache_page_start writes the head, the bar (the heron, the name, and the
// links of this object cache) and the start of <main> for any page of this
// host.
@(private)
cache_page_start :: proc(b: ^strings.Builder, page: Cache_Page_Settings, title: string, description: string, current: Cache_Bar_Section) {
	site_html := cache_page_html_text(page.site_address)
	pictures := strings.concatenate({site_html, "/", resources.SITE_PICTURE_FOLDER, "/"}, context.temp_allocator)

	strings.write_string(b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>")
	foundation.html_escape(b, title)
	strings.write_string(b, " - " + site.SITE_SYSTEM_NAME + "</title>\n<meta name=\"description\" content=\"")
	foundation.html_escape(b, description)
	strings.write_string(b, "\">\n<meta name=\"color-scheme\" content=\"dark light\">\n")
	fmt.sbprintf(b, "<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"%s\">\n", site.site_color(site.site_dark_colors().background))
	fmt.sbprintf(b, "<meta name=\"theme-color\" media=\"(prefers-color-scheme: light)\" content=\"%s\">\n", site.site_color(site.site_light_colors().background))
	fmt.sbprintf(b, "<link rel=\"icon\" href=\"%s/%s\" sizes=\"32x32\">\n", site_html, resources.SITE_FAVICON)
	fmt.sbprintf(b, "<link rel=\"icon\" href=\"%s%s\" type=\"image/svg+xml\">\n", pictures, resources.SITE_ICON_SVG)
	fmt.sbprintf(b, "<link rel=\"preload\" href=\"%s/%s\" as=\"font\" type=\"font/ttf\" crossorigin>\n", site_html, site.SITE_MARK_FONT)
	fmt.sbprintf(b, "<link rel=\"stylesheet\" href=\"%s\">\n</head>\n", status_path_texts[.Style_Sheet])
	strings.write_string(b, "<body class=\"section-cache layout-presentation\">\n<a class=\"skip\" href=\"#content\">Skip to the content</a>\n")

	// The bar of the site: the heron and the name linking to the site, then
	// the pages of this object cache.
	strings.write_string(b, "<header class=\"bar\">\n<div class=\"bar-inner\">\n")
	fmt.sbprintf(b, "<a class=\"bar-home\" href=\"%s/\"><picture><source media=\"(prefers-color-scheme: light)\" srcset=\"%s%s\">", site_html, pictures, resources.SITE_MARK_BAR_LIGHT)
	fmt.sbprintf(b, "<img src=\"%s%s\" width=\"24\" height=\"24\" alt=\"\"></picture>%s</a>\n", pictures, resources.SITE_MARK_BAR, site.SITE_MARK_NAME_HTML)
	strings.write_string(b, "<nav class=\"bar-sections\" aria-label=\"Object cache\"><ul>")
	bar_link :: proc(b: ^strings.Builder, href, label: string, active: bool) {
		if active {
			fmt.sbprintf(b, "<li><a href=\"%s\" aria-current=\"page\">%s</a></li>", href, label)
		} else {
			fmt.sbprintf(b, "<li><a href=\"%s\">%s</a></li>", href, label)
		}
	}
	bar_link(b, "/", "Overview", current == .Overview)
	bar_link(b, "/releases", "Releases", current == .Releases)
	bar_link(b, "/search", "Search", current == .Search)
	strings.write_string(b, "</ul></nav>\n</div>\n</header>\n<main id=\"content\" class=\"page\">\n")
}

// cache_page_end closes <main> and writes the footer of the host.
@(private)
cache_page_end :: proc(b: ^strings.Builder) {
	strings.write_string(b, "</main>\n<footer class=\"foot\">\n<div class=\"page\">\n<p class=\"foot-maker\">" + site.SITE_MARK_NAME_HTML + " · served by <code>modustool cache-serve</code></p>\n")
	strings.write_string(b, "<p><a href=\"" + checks.REPOSITORY_ADDRESS + "\">The repository</a></p>\n</div>\n</footer>\n</body>\n</html>\n")
}

// cache_page_html writes the page from a copy of the facts. It reads no
// file: the counts, the keys and the settings are in memory.
cache_page_html :: proc(server: ^Cache_Server, page: Cache_Page_Settings, snapshot: Cache_Status_Snapshot, disk_free: u64, disk_free_known: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, text: string) {
		strings.write_string(b, text)
	}
	escape :: proc(b: ^strings.Builder, text: string) {
		foundation.html_escape(b, text)
	}
	site_address := page.site_address

	cache_page_start(&b, page, CACHE_PAGE_TITLE, "An object cache of modus: objects by their BLAKE3 hash and signed realisations of recipes. A client trusts a hash or a signer key, never this host.", .Overview)
	write(&b, "<h1>" + CACHE_PAGE_TITLE + "</h1>\n")
	write(&b, "<p class=\"lead\">modus is a modular operating system, sandboxed by default, in which each module is named by its hash: <a href=\"")
	escape(&b, site_address)
	write(&b, "/\">")
	escape(&b, strings.trim_prefix(strings.trim_prefix(site_address, "https://"), "http://"))
	write(&b, "</a>. This host is an object cache of modus. It keeps objects, the blobs and the trees of builds, by their BLAKE3 hash, and realisations: signed records that say which output a recipe gave. A machine that finds the realisation of a recipe here fetches its output and does not build it.</p>\n")

	// The trust.
	write(&b, "<section class=\"card accent-process\" aria-labelledby=\"trust\">\n<h2 id=\"trust\">Trust</h2>\n")
	write(&b, "<p>A client trusts a hash or a signer key, never this host:</p>\n<ul>\n")
	write(&b, "<li>An object is checked against its hash when it arrives. A changed byte is refused.</li>\n")
	write(&b, "<li>A realisation is used only when a key that the substitution policy of the client trusts signed it.</li>\n</ul>\n</section>\n")

	// The keys.
	write(&b, "<section class=\"card accent-machine\" aria-labelledby=\"signer-keys\">\n<h2 id=\"signer-keys\">Signer keys</h2>\n")
	if len(server.authorized_signers) == 0 {
		write(&b, "<p>This host names no signer key, so it accepts no upload.</p>\n")
	} else {
		write(&b, "<p>This host accepts an upload only when one of these Ed25519 keys signed it. The list is no reason to trust a key: take the key of a publisher from the publisher.</p>\n<ul class=\"download-files\">\n")
		for key in server.authorized_signers {
			hex := hash_to_hex(key)
			fmt.sbprintf(&b, "<li><code class=\"download-key\">%s</code></li>\n", string(hex[:]))
		}
		write(&b, "</ul>\n")
	}
	write(&b, "</section>\n")

	// The endpoint, the protocol and the use.
	write(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"endpoint\">\n<h2 id=\"endpoint\">Endpoint</h2>\n<dl class=\"symbol-facts\">\n<dt>Address</dt><dd><code>")
	escape(&b, page.endpoint)
	write(&b, "</code></dd>\n<dt>Protocol</dt><dd>The cache protocol as binary frames over TCP: a request starts with <code>MOCQ</code>, an answer with <code>MOCR</code>. An object of any size travels in frames of 1 MiB, each checked against the BLAKE3 hash of the whole object (<a href=\"")
	escape(&b, cache_page_site_link(site_address, site.site_page_file(site.SITE_GLOSSARY_FOLDER + "/" + CACHE_PAGE_GLOSSARY_GROUP), CACHE_PAGE_GLOSSARY_TERM))
	write(&b, "\">object cache</a>)</dd>\n</dl>\n")
	write(&b, "<p>A plan names this host in its substitution policy:</p>\n<pre><code>substitution = {\n  sources = [\"")
	escape(&b, page.endpoint)
	write(&b, "\"],\n  signers = [keys.publisher], // a key from its publisher\n  mode = .Prefer_Cache,\n}</code></pre>\n")
	write(&b, "<p>No machine of modus reads an object cache over the network yet: the cache protocol over QUIC is on the <a href=\"")
	escape(&b, cache_page_site_link(site_address, site.site_section_page(.Roadmap)))
	write(&b, "\">roadmap</a>. An object cache of your own runs with the tool of modus:</p>\n")
	write(&b, "<pre><code>modustool cache-serve --dir &lt;folder&gt; --listen 0.0.0.0:5010 --authorized-key &lt;public key file&gt; --status-listen 127.0.0.1:5011</code></pre>\n</section>\n")

	// The store now.
	number :: proc(b: ^strings.Builder, value: u64) {
		site.site_value(b, .Number, fmt.tprintf("%d", value), false)
	}
	write(&b, "<section class=\"card accent-memory\" aria-labelledby=\"store\">\n<h2 id=\"store\">Store</h2>\n<dl class=\"symbol-facts\">\n<dt>Objects</dt><dd>")
	number(&b, snapshot.counts.objects)
	write(&b, "</dd>\n<dt>Realisations</dt><dd>")
	number(&b, snapshot.counts.realisations)
	write(&b, "</dd>\n<dt>Stored</dt><dd>")
	site.site_value(&b, .Size, cache_page_bytes_text(snapshot.counts.object_bytes + snapshot.counts.realisation_bytes), false)
	write(&b, "</dd>\n<dt>Largest object</dt><dd>")
	if snapshot.counts.objects > 0 {
		site.site_value(&b, .Size, cache_page_bytes_text(snapshot.counts.largest_object_bytes), false)
	} else {
		write(&b, "none")
	}
	write(&b, "</dd>\n<dt>Damaged objects</dt><dd>")
	number(&b, snapshot.counts.damaged_objects)
	write(&b, "</dd>\n<dt>Free on the disk</dt><dd>")
	if disk_free_known {
		site.site_value(&b, .Size, cache_page_bytes_text(disk_free), false)
	} else {
		write(&b, "not known on this host")
	}
	write(&b, "</dd>\n<dt>Last write</dt><dd>")
	if time_known(snapshot.counts.last_write) {
		time_write(&b, snapshot.counts.last_write)
	} else {
		write(&b, "none")
	}
	write(&b, "</dd>\n<dt>Running since</dt><dd>")
	time_write(&b, snapshot.started)
	fmt.sbprintf(&b, "</dd>\n</dl>\n<p><a href=\"%s\">status.json</a> gives these facts as a record.</p>\n</section>\n", status_path_texts[.Status_Record])

	// The last realisations.
	write(&b, "<section class=\"card accent-boot\" aria-labelledby=\"realisations\">\n<h2 id=\"realisations\">Last realisations</h2>\n")
	if snapshot.recent_count == 0 {
		write(&b, "<p>No realisation yet.</p>\n")
	} else {
		// A column whose cells are all one key says nothing that the list of
		// the keys does not say: the signer is a column only when the rows
		// name more than one.
		rows := snapshot.recent
		show_signer := cache_page_distinct_signers(rows[:snapshot.recent_count]) > 1
		// Each hash column is of the column kind Hash, so the table takes
		// the width of the card and each hash shows the digits that its
		// column holds (docs/SITE.md, "The tables"). Its values are of the
		// kind Version, so its head carries the icon of the kind, as the
		// Date column carries the icon of Time (docs/SITE.md, "The kinds of
		// values").
		with_signer := [?]site.Site_Column{{"Recipe", .Hash}, {"Output", .Hash}, {"Kind", .Short}, {"Signer", .Hash}, {"Written", .Date}}
		with_signer_kinds := [?]value_kinds.Value_Kind{.Version, .Version, .None, .Version, .None}
		without_signer := [?]site.Site_Column{{"Recipe", .Hash}, {"Output", .Hash}, {"Kind", .Short}, {"Written", .Date}}
		without_signer_kinds := [?]value_kinds.Value_Kind{.Version, .Version, .None, .None}
		table := show_signer ? site.site_table_start(&b, "Last realisations", with_signer[:], with_signer_kinds[:]) : site.site_table_start(&b, "Last realisations", without_signer[:], without_signer_kinds[:])
		for index in 0 ..< snapshot.recent_count {
			entry := snapshot.recent[index]
			write(&b, "<tr><td>")
			hash_link_write(&b, "/realisation/", entry.record.recipe_hash)
			write(&b, "</td><td>")
			hash_link_write(&b, object_path_prefix(entry.record.output_kind), entry.record.output_hash)
			fmt.sbprintf(&b, "</td><td>%s</td><td>", object_kind_text(entry.record.output_kind))
			if show_signer {
				hash_write(&b, entry.record.signer_public_key)
				write(&b, "</td><td>")
			}
			time_write(&b, entry.written)
			write(&b, "</td></tr>\n")
		}
		site.site_table_end(&b, table)
	}
	write(&b, "</section>\n")
	cache_page_end(&b)
	return strings.to_string(b)
}

@(private = "file")
json_text :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	for index in 0 ..< len(text) {
		character := text[index]
		switch {
		case character == '"' || character == '\\':
			strings.write_byte(b, '\\')
			strings.write_byte(b, character)
		case character < 0x20:
			fmt.sbprintf(b, "\\u%04x", character)
		case:
			strings.write_byte(b, character)
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
json_time :: proc(b: ^strings.Builder, moment: time.Time) {
	if !time_known(moment) {
		strings.write_string(b, "null")
		return
	}
	json_text(b, cache_page_time_attribute(moment))
}

@(private = "file")
json_hex :: proc(b: ^strings.Builder, value: [32]u8) {
	hex := hash_to_hex(value)
	strings.write_byte(b, '"')
	strings.write_string(b, string(hex[:]))
	strings.write_byte(b, '"')
}

// cache_status_json writes the status record: the facts of the page, each
// hash and key whole, for a monitor of the host.
cache_status_json :: proc(server: ^Cache_Server, page: Cache_Page_Settings, snapshot: Cache_Status_Snapshot, disk_free: u64, disk_free_known: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n  \"endpoint\": ")
	json_text(&b, page.endpoint)
	strings.write_string(&b, ",\n  \"protocol\": \"MOCQ/MOCR frames over TCP\",\n  \"signer_keys\": [")
	for key, index in server.authorized_signers {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		json_hex(&b, key)
	}
	fmt.sbprintf(&b, "],\n  \"objects\": %d,\n  \"object_bytes\": %d,\n  \"largest_object_bytes\": %d,\n  \"damaged_objects\": %d,\n  \"realisations\": %d,\n  \"realisation_bytes\": %d,\n  \"disk_free_bytes\": ", snapshot.counts.objects, snapshot.counts.object_bytes, snapshot.counts.largest_object_bytes, snapshot.counts.damaged_objects, snapshot.counts.realisations, snapshot.counts.realisation_bytes)
	if disk_free_known {
		fmt.sbprintf(&b, "%d", disk_free)
	} else {
		strings.write_string(&b, "null")
	}
	strings.write_string(&b, ",\n  \"last_write\": ")
	json_time(&b, snapshot.counts.last_write)
	strings.write_string(&b, ",\n  \"started\": ")
	json_time(&b, snapshot.started)
	fmt.sbprintf(&b, ",\n  \"uptime_seconds\": %d,\n  \"recent_realisations\": [", i64(time.duration_seconds(time.tick_since(snapshot.started_tick))))
	for index in 0 ..< snapshot.recent_count {
		entry := snapshot.recent[index]
		strings.write_string(&b, index > 0 ? ",\n    {" : "\n    {")
		strings.write_string(&b, "\"recipe\": ")
		json_hex(&b, entry.record.recipe_hash)
		strings.write_string(&b, ", \"output\": ")
		json_hex(&b, entry.record.output_hash)
		fmt.sbprintf(&b, ", \"kind\": \"%s\", \"signer\": ", object_kind_text(entry.record.output_kind))
		json_hex(&b, entry.record.signer_public_key)
		strings.write_string(&b, ", \"written\": ")
		json_time(&b, entry.written)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, snapshot.recent_count > 0 ? "\n  ]\n}\n" : "]\n}\n")
	return strings.to_string(b)
}
