type: Changed

**A start list holds as many wiring rows as it needs, and its start policy is paid for them.** The list no longer stops at 8 wiring rows. Its header gives the pages that its wirings cost, and the root service adds them to the budget of the start policy, which no longer keeps a fixed reserve of 64 pages. The build refuses a writer with more rows than one start holds, and a list whose pages pass the largest budget of one process.
