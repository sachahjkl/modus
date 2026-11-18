package modustool

import "core:strings"
import "core:testing"
import "modustool:checks"

// The chart of one measure over four releases, one with no number: the
// golden SVG.
@(test)
measure_history_chart_golden :: proc(t: ^testing.T) {
	releases := make([]checks.Measure_History_Release, 4, context.temp_allocator)
	releases[0] = checks.measure_history_release_example({0, 92, 0}, "2026-11-14 11:46 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", checks.measure_history_locks_line_example("100"))
	releases[1] = checks.measure_history_release_example({0, 93, 0}, "2026-11-16 06:05 UTC", "b7dedc5e85cd3b40c462f9562b0dc389aac1d792", checks.measure_history_locks_line_example("200"))
	releases[2] = checks.measure_history_release_example({0, 94, 0}, "2026-11-17 06:05 UTC", "", "")
	releases[3] = checks.measure_history_release_example({0, 95, 0}, "2026-11-18 06:05 UTC", "", checks.measure_history_locks_line_example("50"))
	points, present_count := checks.measure_history_points(checks.measure_history_series[0], releases)
	testing.expect_value(t, present_count, 3)
	testing.expect_value(t, len(points), 4)
	testing.expect(t, !points[2].present)
	testing.expect_value(t, points[2].missing, "the record has no line of this measure")
	golden := `<svg class="measure-history-chart" viewBox="0 0 600 120" role="img" aria-label="Kernel entries in one second, 4 processes">
<line class="measure-history-scale" x1="0" y1="6" x2="600" y2="6"/>
<line class="measure-history-scale" x1="0" y1="114" x2="600" y2="114"/>
<polyline class="measure-history-line" points="6,60 202,6"/>
<rect class="measure-history-point" x="3" y="57" width="6" height="6"><title>0.92.0: 100</title></rect>
<rect class="measure-history-point" x="199" y="3" width="6" height="6"><title>0.93.0: 200</title></rect>
<rect class="measure-history-point" x="591" y="84" width="6" height="6"><title>0.95.0: 50</title></rect>
</svg>
`
	testing.expect_value(t, checks.measure_history_chart_svg(points, checks.measure_history_series[0].title), golden)

	// The places: equal steps, a release alone in the middle; the heights
	// from zero at the bottom.
	testing.expect_value(t, checks.measure_history_point_x(0, 1), checks.MEASURE_HISTORY_CHART_WIDTH / 2)
	testing.expect_value(t, checks.measure_history_point_y(0, 200), checks.MEASURE_HISTORY_CHART_HEIGHT - checks.MEASURE_HISTORY_CHART_MARGIN)
	testing.expect_value(t, checks.measure_history_point_y(200, 200), checks.MEASURE_HISTORY_CHART_MARGIN)

	// The section of the page: one card, for the one measure with points.
	site: Site
	site.measure_history = releases
	b := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &b)
	html := strings.to_string(b)
	testing.expect_value(t, strings.count(html, "<article class=\"card measure-chart "), 1)
	for part in ([]string {
		"<h2 id=\"history\">Each measure over the releases</h2>",
		"holds the measure record of 4 releases, from 0.92.0 to 0.95.0",
		"Two runs of the same build differ",
		"id=\"history-kernel-entries-in-one-second",
		"<p class=\"measure-unit\">From 0 to <code class=\"value value-number\">200</code> kernel entries in one second. A higher number is faster.</p>",
		"<p class=\"measure-history-releases\"><span>0.92.0</span><span>0.95.0</span></p>",
		"<li>0.93.0: <code class=\"value value-number\">200</code>, the run of <code>b7dedc5</code> at 2026-11-16 06:05 UTC</li>",
		"<li>0.94.0: no number: the record has no line of this measure</li>",
		"<li>0.95.0: <code class=\"value value-number\">50</code>, the run of an unknown commit at 2026-11-18 06:05 UTC</li>",
		"<a href=\"#reading-kernel-entries-in-one-second",
	}) {
		testing.expectf(t, strings.contains(html, part), "the section has no %q:\n%s", part, html)
	}
	// One host: the list does not repeat it.
	testing.expect(t, !strings.contains(html, ", on AMD"))
	testing.expect(t, !strings.contains(html, "hosts measured these releases"))

	// One release: no chart, and the section says why.
	site.measure_history = releases[:1]
	one := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &one)
	testing.expect(t, strings.contains(strings.to_string(one), "holds the measure record of one release, 0.92.0"))
	testing.expect(t, strings.contains(strings.to_string(one), "No measure has a number in 2 releases yet"))
	testing.expect(t, !strings.contains(strings.to_string(one), "<svg"))
	// No history.
	site.measure_history = nil
	none := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &none)
	testing.expect(t, strings.contains(strings.to_string(none), "holds no measure record of a release"))
}
