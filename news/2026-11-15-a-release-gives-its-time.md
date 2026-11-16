title: A release gives its time
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

Each release on the page of the releases now gives its time, to the minute, in UTC: `2026-11-15 18:48 UTC`. Several releases can come out on one day, and the time keeps them in order. The feed of the releases gives the same time, so a feed reader shows when a release came out, not midnight.

A release is now also a signed git tag, `v` and its number, on the commit of the release. The changelog links each release to its tag. One command makes the release, the commit and the tag, and sends the commit and the tag together, or neither.

Some old releases were written together, after the fact, and no record holds their time. They keep their day alone.
