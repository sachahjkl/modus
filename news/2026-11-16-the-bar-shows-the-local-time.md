title: The bar shows the local time
date: 2026-11-16
release: next
picture: docs/screenshots/settings.png
kind: Shown
guide: docs/FONTS.md

The system has a time zone. The setting `time_zone` is an offset from UTC, from `-12:00` to `+14:00` by quarters of an hour: `settings.set("time_zone", "+08:00")` in the console, or the row "time zone" of the window of `settings`, with four buttons that move it by an hour or by 15 minutes. The default is `+00:00`, UTC.

The bar then shows the local date and time. The setting `appearance` `auto` turns light at 07:00 and dark at 19:00 of the local time, and no longer of UTC. A change of the zone takes effect at once, and the log says the zone that the date service now gives.

The zone is a fixed offset: it has no summer time. A principal in a zone with summer time changes it twice a year, for example `+01:00` in winter and `+02:00` in summer in Paris. The date that the system keeps, in the store and on the network, stays in UTC.
