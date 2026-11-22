type: Changed

**The fuzz targets of `modustool check` run at once**: the check runs the children of several targets at the same time, at most one for each processor and at most 8. It prints each target in the order of the targets, as before, and gives the time of all the targets as a measure. The host tests of the heaviest packages of the tool now start first, so none of them runs alone at the end.
