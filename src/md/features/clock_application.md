# The clock application

The process `clock` is the clock of the desktop: the local time, the date, a calendar of a month, a stopwatch with laps and a countdown timer. A principal opens it from the bar, from the menu of the desktop ("open clock") or with `start("clock")`. This file records why it has its form.

## Purpose

Before, `clock` was a demonstration of the time page: it counted the reads of the time and the kernel entries. That is not what a principal expects behind the name and the icon of a clock. The demonstration keeps its checks and its measures under the name `time_page`, and the name `clock` goes to an application.

## Constraints

- The time of the system (`system.time()`, the milliseconds since the boot) is read from the time page: no kernel entry. The date is the date page plus that time (`modus:contract/date`): no kernel entry either.
- The local time is the date in UTC plus the time zone of the date page, which the process `date` copies from the setting `time_zone` ([time_zone.md](time_zone.md)). The clock does not read the settings page for the zone: the date page holds the whole local time.
- A machine with no date page, or a page with no date, has no date: the clock says so in place of a wrong date.
- The window is resizable ([window_resize.md](window_resize.md)): each part takes its size from the window at each frame.
- On one screen, each piece of information is said once.

## The chosen form

- **Three sections, one at a time**: `clock`, `stopwatch` and `timer`, as a row of tab buttons at the top. The keys 1, 2 and 3 choose a section, as a press on its tab does. A section uses the whole window under the tabs.
- **The section clock**: the local time in large digits (`HH:MM:SS`), the date in words with the zone after it (`Sunday 22 November 2026, UTC+01:00`), and the calendar of a month. The calendar starts at the month of today and marks today. The buttons "previous" and "next", Page Up and Page Down, change the month; "today" and the key Home come back. The weeks start on Monday (ISO 8601).
- **The calendar arithmetic is the support package `modus:calendar`**: `civil`, `days_in_month` and `days_from_civil`, which the bar of the compositor and `notes` use too.
- **The stopwatch** counts from the time of the system, not by ticks: the elapsed time is the sum of the closed runs and the time since the last start. A pause and a start lose no millisecond. A lap keeps the elapsed time at the press; the list shows each lap with its own time and the total, the newest first. Space starts and stops, L takes a lap, R resets. The laps hold at most 99 entries; past that the button lap is gone and the key L is refused. Only the acts that the state takes have a button: start, or stop and lap, and reset for a stopped stopwatch with a time.
- **The timer** counts down from a duration that the principal sets with buttons (+1 min, -1 min, +10 s, -10 s, and presets of 1, 5, 10 and 25 minutes), from 1 second to 99 hours 59 minutes 59 seconds. Space starts and pauses, R resets to the duration. A rectangular bar shows the part that is left. The end is a time of the system: a late wake does not move it.
- **The end of the timer** shows in the window (the time left is 0, in the warning color, until a reset) and posts a desktop notification through the export `notify` of the compositor. The banner shows the name `clock` before its title: the compositor takes it from the connection ([tray_widgets.md](tray_widgets.md), "The export notify"). The connection and the call run in a job of the worker thread of the window, never on the thread of the window ([background_work.md](background_work.md)).
- **The waits**: the window wakes at the next whole second of the local time for the section clock, and every 50 ms while the stopwatch or the timer runs and is shown, so the tenths of a second move. A timer that runs while another section is shown wakes the process at its end only.
- **The state machines** of the stopwatch and of the timer are pure procedures in `internal:clock/clock_model`, with host tests: they take the time as an argument and read no clock.

## The grants

`{.Connect, .Image}` with `callable = {"compositor"}`: a connection to the compositor only, and the boot image for the description of its exports. It holds no right of the machine: the measures of the kernel entries went with the demonstration `time_page`, which keeps the grant `Inspect`.

## Refused forms

- **The library module `calendar`** (`src/modules/libraries/calendar`). It has a fault by design: it forgets the rule of the 400 years, so that the replacement of an import can correct it (`calendar_fixed`). An application must not show a wrong February.
- **An analog face beside the digits.** Hands and digits would say the time twice on one screen.
- **A stopwatch that adds a tick at each wake.** A late wake would lose time.
- **The grant `Acts_For_Principal` for the notification.** That grant would let the clock read what the compositor and each other service hold for all callers, only to post its own card: a new authority for a process is the last answer. The export `notify` takes a connection that does not act for the principal, with a label and a bound.
- **Named time zones and summer time**: see [time_zone.md](time_zone.md).

## Subtle points

- The digits of the time are drawn in the cells font at a large size: each digit has one width, so the text does not move when a digit changes.
- The local date of the calendar mark is computed from the same read of the date page as the time, so midnight changes both in one frame.
- The timer is stopped at its end by the frame that sees the end, not by the wait: a frame that comes after a long sleep shows 0 and posts one notification.

## State

Built: the three sections, the calendar, the keys, the resizable layout, the notification on a worker thread, the host tests of the model, a machine test of the stopwatch and of a timer of 1 second. Left: alarms at a time of the day.
