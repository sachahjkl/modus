type: Changed

**A release gives its time**: the heading of a release in the changelog gives the day and the minute in UTC, `## [0.93.0] - 2026-11-15 18:48`, so two releases of one day keep their order. The releases page shows the time with "UTC", and the feed `releases.xml` gives the true time in place of 00:00. Each release has a release link at the end of the changelog, to its release tag. `modustool changelog times` gives an old heading the time of the commit of its release, and adds the missing links; an old release whose commit is not known keeps its day alone.
