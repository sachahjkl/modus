package site

import "core:strings"
import "core:testing"
import "modustool:checks"
import "modustool:foundation"

@(test)
site_credits_tables_render_all_three_categories :: proc(t: ^testing.T) {
	text, ok := foundation.read_text_file_quiet(checks.CREDITS_FILE)
	testing.expect(t, ok)
	problems := make([dynamic]string, context.temp_allocator)
	credits := checks.credits_parse(text, &problems)
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, len(credits.reused) > 0)
	testing.expect(t, len(credits.algorithms) > 0)
	testing.expect(t, len(credits.inspirations) > 0)

	site := Site{commit = "master"}
	b := strings.builder_make(context.temp_allocator)
	site_credits_tables(&site, &b, credits)
	html := strings.to_string(b)

	testing.expect(t, strings.contains(html, `<h2 id="reused-code">Reused code</h2>`))
	testing.expect(t, strings.contains(html, `<h2 id="reimplemented-algorithms">Reimplemented algorithms</h2>`))
	testing.expect(t, strings.contains(html, `<h2 id="inspirations">Inspirations</h2>`))
	testing.expect(t, strings.contains(html, "EEVDF"))
	testing.expect(t, strings.contains(html, "seL4"))
	testing.expect(t, strings.contains(html, "<code>base:runtime</code>"))
	testing.expect(t, strings.contains(html, `href="https://github.com/sponsors/gingerBill"`))
	testing.expect(t, strings.contains(html, `src/modulus/schedule.odin`))
}
