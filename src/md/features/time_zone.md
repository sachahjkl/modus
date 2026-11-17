# The time zone

The principal sets the time zone of the machine. The bar then shows the local date and time, and the rule of the day of the setting `appearance` `auto` counts its hours in the local time ([appearance.md](appearance.md)). This file records the form of the zone, where it lives, who writes it, and when a change takes effect.

## Constraints

- The date of the system is in UTC: the real-time clock keeps UTC, and the storage service, the HTTP server and `date.now()` give UTC. The zone changes only what a principal reads as an hour.
- The time zone is a choice of the principal. A choice is kept in the private store of `settings`, and the program `settings` is the one writer of the choices.
- The date page has one writer, the program `date`. Its change count is a counter that two writers would break.
- The root service waits on the change count of the date page. Its wait list holds 64 words and is full with 32 started programs (two words for each request ring), so it cannot wait on the settings page too ([appearance.md](appearance.md), "Who writes the appearance in force, and when").
- A wake is not lost only when the word changes: the kernel compares the word with the value that the waiter read. A wake of a word that keeps its value can come before the waiter enters the kernel, and is then lost.

## The chosen form

- **A fixed offset from UTC, in minutes.** The setting `time_zone` is a number of minutes from -720 (`-12:00`) to +840 (`+14:00`), a multiple of 15. Every zone of the earth is in that range, and each offset in use is a whole quarter of an hour (`+05:45`, `+12:45`). The text of a value is the form of ISO 8601: `+08:00`, `-03:30`, `+00:00`. The default is 0, UTC, so an all-zero page and a new disk keep the hours that the system had before.
- **The limit: no daylight saving time.** A fixed offset does not move by itself in spring and in autumn. A principal in a zone with summer time changes the setting twice a year: `+01:00` in winter and `+02:00` in summer for Paris.
- **The settings page holds the choice.** One field, `zone_offset_minutes`, beside the values, written by the program `settings` in the same change as the values. The kept record holds it too: the format of the record is version 2. The boot pass reads a record of version 1 as the defaults and writes the defaults in its place, so the settings of an older disk are lost once, and not at each boot until the next change of a setting.
- **Not a member of `Setting`.** A member of the enumeration has a list of value names: the palette, the palette table, the log lines of the compositor and of `settings`, and the window index those names by the value. A zone has 105 values and no list. So it has its own field, its own name `time_zone` in the exports `set` and `get`, and its own row in the window.
- **The program `date` copies the zone into the date page.** It maps the settings page read-only, as every program that is not a terminal does, and waits on its change count beside its service ring. When the zone of the settings page differs from the zone of the date page, it writes `zone_offset_seconds` in one change of the date page and wakes its waiters. The date page then holds the whole local time: the date of UTC and the zone. A reader of the local time reads one page.
- **The program `date` wakes the waiters of the date page** when the page gets its first date, at each write of the zone, and at each correction of the clock that it writes on the log: a move of a second or more (a machine paused, a clock set again), and the first and each thirtieth correction. Before, it woke nobody: the root service saw a new date only at its next wake for another reason. The other corrections move the date by milliseconds, which moves no edge of the rule, so they wake nobody.

## When a change takes effect

1. `settings.set("time_zone", "+08:00")`, or a button of the row. The program `settings` keeps the record, then writes the values and the zone on the settings page. It computes the appearance in force with the zone of the date page, which is still the old one: the appearance in force does not change in this write.
2. The compositor wakes on the settings page and sends `Settings_Changed` to each window: the zone is a change of the choice (`settings.values_differ`).
3. The program `date` wakes on the settings page, writes the zone in the date page, and wakes its waiters. The log says "date: the time zone of the date page is +08:00, from the setting time_zone".
4. The root service wakes on the date page. It computes the rule with the new zone, writes the appearance in force when it changes ("root: the appearance in force is light: ..."), and sets its deadline to the next edge of the new local time. The compositor then sends `Settings_Changed` a second time.
5. The bar draws its clock each second from the date page: the next second shows the local time. When the zone that it draws changes, the compositor writes one line: "compositor: the bar shows the local time 2026-11-16 09:04:05 with the time zone +08:00, at 1794791045 s since 1970". The default zone, UTC, writes no line at the first date, and the program `date` writes no line while the zone is UTC: a boot with the default zone adds no record to the log, whose room is fixed.

So a change of the zone that crosses an edge of the rule draws each window twice: once for the zone, once for the appearance. Each frame has one appearance. The boot pass of `settings` is the same: it writes the kept zone, and the root service corrects the appearance in force after the copy of the zone.

## The window

The row "time zone" has four buttons and the value: `-1 h`, `-15 min`, the value in the font of the cells, `+15 min`, `+1 h`. A press moves the zone and stops at -12:00 and at +14:00. Each width is measured from the font, so no label is cut. The window is 32 pixels higher for the seventh row.

## The refused forms

- **A named zone with its rules of summer time** (`Europe/Paris`). It needs the tz database. Its release 2026e has 345 zones and 1 971 rules: 103 KB as the compact source `tzdata.zi`, which needs a parser of the rules, and 1.2 MB as compiled files of the format TZif. The database changes several times a year by the law of a country, and each change would need a new signed release of the system: the system has no update service to carry it. A fixed offset has none of this cost, and its limit is one sentence.
- **The zone as a member of `Setting`.** See above: each reader of the value names would need a case for a setting with no names.
- **The program `settings` writes the date page.** Two writers of one change count make a page that a reader reads in the middle of a change.
- **The root service waits on the settings page.** Its wait list is full: see the constraints.
- **The program `settings` wakes the date page with no change.** The word keeps its value, so a wake that comes between the read of the root service and its wait is lost; the root service then keeps the old deadline.
- **Each reader reads the zone from the settings page.** The local time would come from two pages, and the root service would not wake at a change of the zone.
- **The zone on the bar.** The bar has the room of the date and time only, and the window of `settings` says the zone.

## Subtle points

- **The order of the writes is the order of the rule.** The program `settings` computes the rule with the zone of the date page, not with the zone that it writes. So the appearance in force always agrees with the date page, and the root service is the one that moves it at a change of the zone. If `settings` used its new zone, the root service could compute with the old zone of the date page before the copy, and write the other appearance for a moment.
- **A copy that lags.** The program `date` copies the zone after its read of the clock: a change that comes while it waits for the next second of the clock takes effect at most 2 seconds later.
- **A page left in a change.** `settings.read` gives `ok` false and the defaults when it gives up, with an odd count or with an even count that moved after the read, and when the page holds a word that names no value of its setting ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)). The program `date` copies no zone from such a read: it checks `ok` and the count again after the read, and the count only grows, so its wait ends at once and the next turn reads the page again. The root service checks the count the same way before it writes the appearance in force, and writes nothing over a refused page.
- **No program `date`, no local time.** When the program `date` does not run, nobody copies the zone: the window and `settings.get` give the chosen zone, but the bar and the rule of the day stay in UTC. The date page has one writer, and that writer is absent.
- **The test machines.** Their clock is at 01:00 UTC of the day of the host. The machine test sets `+08:00`: the local time is then from 09:00 to 15:00 for a run of up to six hours, so `auto` gives the light appearance, where UTC gives the dark one. The step `Appearance_Auto` checks the line of the root service by the rule over its date and its zone, and checks that the zone is the one that the test set. The step `Bar_Local_Time` checks the line of the bar: its date by order against the clock of the machine, its text against the date and the zone.

## State

Built: the setting `time_zone` on the settings page and in the kept record, the exports, the row of the window, the copy into the date page by the program `date` with its wakes, the bar in the local time, the rule of the day in the local time, the host tests of the text and of the range, and the machine test.

Left: the rules of summer time, if a later form finds a small source for them.
