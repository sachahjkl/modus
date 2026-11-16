title: Each measure over the releases
date: 2026-11-16
release: next
picture: none
kind: Measured
guide: docs/TOOLS.md

The measure record held one run: the last full check, which the next run replaced. Each release now keeps its own copy of the record, so the numbers of a release stay. The page of the measured numbers draws one chart for each measure, such as the kernel entries in one second or the round trip of one UDP datagram: the releases at equal steps, the number from zero, and a list of the number, the commit and the run of each release. Each point is one run on a host that runs other work, and the page says so: a step that is not larger than the spread of two runs says nothing. Of the 89 release tags, one held a measure record, so the first chart appears with the next release that a full check measured.
