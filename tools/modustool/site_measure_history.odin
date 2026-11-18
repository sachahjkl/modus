// The page of the measure history on the site: a chart of each measure over
// the releases, from the measure history that the package checks reads.
package modustool

import "core:fmt"
import "core:strings"
import "modus:contract/value_kinds"
import "modustool:foundation"
import "modustool:checks"

// site_measure_history_write writes the section of the page of the measured
// numbers that draws each measure over the releases. It draws a chart only
// for a measure with a number in two releases or more.
site_measure_history_write :: proc(site: ^Site, b: ^strings.Builder) {
	history := site.measure_history
	strings.write_string(b, "<h2 id=\"history\">Each measure over the releases</h2>\n")
	if len(history) == 0 {
		fmt.sbprintf(b, "<p><code>%s/</code> holds no measure record of a release.</p>\n", checks.MEASURE_HISTORY_FOLDER)
		return
	}
	first := checks.release_number_text(history[0].release)
	newest := checks.release_number_text(history[len(history) - 1].release)
	if len(history) == 1 {
		fmt.sbprintf(b, "<p><code>%s/</code> holds the measure record of one release, %s", checks.MEASURE_HISTORY_FOLDER, first)
	} else {
		fmt.sbprintf(b, "<p><code>%s/</code> holds the measure record of %d releases, from %s to %s", checks.MEASURE_HISTORY_FOLDER, len(history), first, newest)
	}
	strings.write_string(b, ": <code>modustool changelog release</code> copies the record at each release that a full check measured. ")
	strings.write_string(b, "Each point is one run of the full check before its release, on a host that runs other work. Two runs of the same build differ: a step between two releases that is not larger than that spread says nothing. A chart places the releases at equal steps, not on a scale of time, and starts at zero.</p>\n")
	hosts := make(map[string]bool, context.temp_allocator)
	for history_release in history {
		hosts[history_release.record.host] = true
	}
	if len(hosts) > 1 {
		fmt.sbprintf(b, "<p>%d hosts measured these releases: a step where the host changed is not a change of the system. The list under each chart names the host of each release.</p>\n", len(hosts))
	}
	drawn := 0
	for series in checks.measure_history_series {
		measure: checks.Site_Measure
		in_table := false
		for candidate in checks.site_measures {
			if candidate.sentence == series.sentence {
				measure, in_table = candidate, true
			}
		}
		if !in_table {
			continue
		}
		points, present_count := checks.measure_history_points(series, history)
		if present_count < checks.MEASURE_HISTORY_LEAST_POINTS {
			continue
		}
		if drawn == 0 {
			strings.write_string(b, "<div class=\"measure-charts\">\n")
		}
		drawn += 1
		slug := foundation.site_slug(series.sentence)
		most_text := ""
		most := 0.0
		for point in points {
			if point.present && (most_text == "" || point.value > most) {
				most, most_text = point.value, point.value_text
			}
		}
		fmt.sbprintf(b, "<article class=\"card measure-chart %s\" id=\"history-%s\">\n<h3>", site_accent_class(measure.accent), slug)
		foundation.site_escape(b, series.title)
		fmt.sbprintf(b, "</h3>\n<p class=\"measure-unit\">From 0 to <code class=\"value value-%s\">", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Number])
		foundation.site_escape(b, most_text)
		strings.write_string(b, "</code> ")
		foundation.site_escape(b, series.unit)
		faster: string = series.faster == .Higher ? "A higher number is faster." : "A lower number is faster."
		fmt.sbprintf(b, ". %s</p>\n", faster)
		strings.write_string(b, checks.measure_history_chart_svg(points, fmt.tprintf("%s, over %d releases", series.title, len(points))))
		strings.write_string(b, "<p class=\"measure-history-releases\"><span>")
		foundation.site_escape(b, points[0].release)
		strings.write_string(b, "</span><span>")
		foundation.site_escape(b, points[len(points) - 1].release)
		strings.write_string(b, "</span></p>\n<details class=\"measure-history-numbers\"><summary>The number of each release</summary>\n<ul>\n")
		for point in points {
			strings.write_string(b, "<li>")
			foundation.site_escape(b, point.release)
			if !point.present {
				strings.write_string(b, ": no number: ")
				foundation.site_escape(b, point.missing)
				strings.write_string(b, "</li>\n")
				continue
			}
			fmt.sbprintf(b, ": <code class=\"value value-%s\">", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Number])
			foundation.site_escape(b, point.value_text)
			strings.write_string(b, "</code>, the run of ")
			if point.commit != "" {
				strings.write_string(b, "<code>")
				foundation.site_escape(b, point.commit[:min(checks.MEASURE_COMMIT_SHORT_LENGTH, len(point.commit))])
				strings.write_string(b, "</code>")
			} else {
				strings.write_string(b, "an unknown commit")
			}
			strings.write_string(b, " at ")
			foundation.site_escape(b, point.time)
			if len(hosts) > 1 {
				strings.write_string(b, ", on ")
				foundation.site_escape(b, point.host)
			}
			strings.write_string(b, "</li>\n")
		}
		fmt.sbprintf(b, "</ul>\n</details>\n<p><a href=\"#reading-%s\">How to read this measure</a></p>\n</article>\n", slug)
	}
	if drawn == 0 {
		fmt.sbprintf(b, "<p>No measure has a number in %d releases yet, and a chart needs that many to compare.</p>\n", checks.MEASURE_HISTORY_LEAST_POINTS)
		return
	}
	strings.write_string(b, "</div>\n")
}
