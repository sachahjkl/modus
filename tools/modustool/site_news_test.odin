package modustool

import "core:strings"
import "core:testing"
import "modustool:checks"

@(test)
news_of_a_good_entry :: proc(t: ^testing.T) {
	entry, problems := checks.news_parse(checks.NEWS_EXAMPLE_NAME, checks.NEWS_EXAMPLE_TEXT)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, entry.title, "A thing a reader can see")
	testing.expect_value(t, entry.date, "2026-11-11")
	testing.expect_value(t, entry.subject, "a-thing")
	testing.expect_value(t, entry.release, "0.58.0")
	testing.expect_value(t, entry.picture, "docs/screenshots/console.png")
	testing.expect_value(t, entry.kind, checks.News_Kind.Measured)
	testing.expect_value(t, entry.guide, "docs/CONSOLE.md")
	testing.expect_value(t, entry.text_line, 8)
	testing.expect(t, strings.has_prefix(entry.text, "The first sentence."))
	testing.expect(t, strings.has_suffix(entry.text, "A line that continues it."))
	testing.expect_value(t, site_news_lead(entry), "The first sentence.")
	testing.expect_value(t, site_news_anchor(entry), "news-2026-11-11-a-thing")
	// "next", "none" and the head in another order are well formed too.
	other := "kind: Fixed\nguide: none\npicture: none\nrelease: next\ndate: 2026-11-11\ntitle: Another\n\nText.\n"
	_, other_problems := checks.news_parse(checks.NEWS_EXAMPLE_NAME, other)
	testing.expectf(t, len(other_problems) == 0, "problems: %v", other_problems)
}

// An entry with a film on the site: the video element of the page of the
// news, the picture with its mark on the home, and the link of the feed.
@(test)
news_film_on_the_site :: proc(t: ^testing.T) {
	entry, _ := checks.news_parse(checks.NEWS_EXAMPLE_NAME, checks.NEWS_EXAMPLE_TEXT)
	entry.film = "docs/films/palette.webm"
	item := Site_News {
		entry          = entry,
		anchor         = site_news_anchor(entry),
		body           = "<p>x</p>\n",
		picture        = "pictures/console.png",
		picture_width  = 1024,
		picture_height = 768,
		picture_alt    = "A \"picture\"",
		film           = "films/palette.webm",
		film_width     = 2048,
		film_height    = 1536,
		film_bytes     = 1572784,
	}

	// The page of the news: the film does not play by itself, the picture
	// stands in its place, and its size keeps its room.
	page := strings.builder_make(context.temp_allocator)
	site_news_film(&page, site_section_page(.News), item)
	testing.expect_value(
		t,
		strings.to_string(page),
		"<figure class=\"news-film\"><video controls preload=\"metadata\" playsinline muted loop poster=\"../pictures/console.png\" width=\"2048\" height=\"1536\">" +
		"<source src=\"../films/palette.webm\" type='video/webm; codecs=\"av01.0.12M.08\"'>" +
		"<a href=\"../films/palette.webm\"><img src=\"../pictures/console.png\" width=\"1024\" height=\"768\" loading=\"lazy\" decoding=\"async\" alt=\"A &quot;picture&quot;\"></a></video>" +
		"<figcaption>Film: <a href=\"../films/palette.webm\">palette.webm</a>, WebM with AV1, 1.5 MiB.</figcaption></figure>\n",
	)
	testing.expect(t, !strings.contains(strings.to_string(page), "autoplay"), "a film starts only when the reader starts it")
	// An entry with no film writes no video element.
	without := item
	without.film = ""
	none := strings.builder_make(context.temp_allocator)
	site_news_film(&none, site_section_page(.News), without)
	testing.expect_value(t, strings.to_string(none), "")

	// The home: the picture, the mark, a link to the entry, and no video.
	site: Site
	site.news = []Site_News{item}
	home := strings.builder_make(context.temp_allocator)
	site_news_home(&site, &home)
	home_text := strings.to_string(home)
	testing.expect(t, strings.contains(home_text, "<figure class=\"news-card-picture\"><a class=\"film-link\" href=\"news/index.html#news-2026-11-11-a-thing\"><img src=\"pictures/console.png\" width=\"1024\" height=\"768\" loading=\"lazy\" decoding=\"async\" alt=\"A &quot;picture&quot;\"><span class=\"film-mark\">film</span></a></figure>"), home_text)
	testing.expect(t, !strings.contains(home_text, "<video"), "the home has no video element")
	site.news = []Site_News{without}
	home_without := strings.builder_make(context.temp_allocator)
	site_news_home(&site, &home_without)
	testing.expect(t, !strings.contains(strings.to_string(home_without), "film-mark"), "an entry with no film has no mark of a film")

	// The feed: the film as an enclosure, with its type and its size, and
	// a link in the content.
	site.news = []Site_News{item}
	feed := site_news_feed(&site)
	testing.expect(t, strings.contains(feed, "<link rel=\"enclosure\" type=\"video/webm\" href=\"films/palette.webm\" length=\"1572784\"/>"), feed)
	testing.expect(t, strings.contains(feed, "&lt;p&gt;&lt;a href=&quot;films/palette.webm&quot;&gt;Film&lt;/a&gt; (WebM with AV1, 1.5 MiB)&lt;/p&gt;"), feed)
	testing.expect(t, !strings.contains(feed, "<video") && !strings.contains(feed, "&lt;video"), "the feed has no video element")
	site.address = "https://example.org/modus"
	addressed := site_news_feed(&site)
	testing.expect(t, strings.contains(addressed, "<link rel=\"enclosure\" type=\"video/webm\" href=\"https://example.org/modus/films/palette.webm\" length=\"1572784\"/>"), addressed)
	site.address = ""
	site.news = []Site_News{without}
	testing.expect(t, !strings.contains(site_news_feed(&site), "enclosure"), "an entry with no film has no enclosure")

	// The style sheet: the film takes the width of its column, and the
	// mark of the home is a rectangle.
	style := site_style_sheet("")
	testing.expect(t, strings.contains(style, ".news-film video { display: block; width: 100%; height: auto;"))
	testing.expect(t, strings.contains(style, ".film-mark { position: absolute;"))
}

@(test)
news_feed_escapes_and_links :: proc(t: ^testing.T) {
	entry, _ := checks.news_parse(checks.NEWS_EXAMPLE_NAME, checks.NEWS_EXAMPLE_TEXT)
	site: Site
	site.news = []Site_News{{entry = entry, anchor = site_news_anchor(entry), body = "<p>x &amp; \"y\"</p>\n", picture = "pictures/console.png", picture_width = 1024, picture_height = 768, picture_alt = "A <b> & \"c\""}}
	feed := site_news_feed(&site)
	testing.expect(t, strings.has_prefix(feed, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">"))
	testing.expect(t, strings.contains(feed, "<title>A thing a reader can see</title>"))
	testing.expect(t, strings.contains(feed, "<updated>2026-11-11T00:00:00Z</updated>"))
	testing.expect(t, strings.contains(feed, "<id>" + checks.SITE_REPOSITORY_ADDRESS + "/blob/master/news/" + checks.NEWS_EXAMPLE_NAME + "</id>"))
	// With no address: relative links and no link "self".
	testing.expect(t, strings.contains(feed, "href=\"news/index.html#news-2026-11-11-a-thing\""))
	testing.expect(t, !strings.contains(feed, "rel=\"self\""))
	// The HTML of the content is escaped once more: no markup of it is markup of the feed.
	testing.expect(t, strings.contains(feed, "&lt;p&gt;x &amp;amp; &quot;y&quot;&lt;/p&gt;"))
	testing.expect(t, !strings.contains(feed, "<p>"))
	testing.expect(t, !strings.contains(feed, "<b>"))
	testing.expect(t, strings.contains(feed, "<summary>The first sentence.</summary>"))

	site.address = "https://example.org/modus"
	addressed := site_news_feed(&site)
	testing.expect(t, strings.contains(addressed, "href=\"https://example.org/modus/news/#news-2026-11-11-a-thing\""))
	testing.expect(t, strings.contains(addressed, "<link rel=\"self\" type=\"application/atom+xml\" href=\"https://example.org/modus/news.xml\"/>"))
}
