type: Added

**A machine test of a guest build.** The test part `guest_build` builds a recipe of the guest builder on a machine: a static `init` in the guest unpacks the input disk, runs the command with busybox, writes the output disk and gives its exit status, and the realisation names the tree hash that the host computed. The new export `recipes.build_stored` builds a recipe of the store named by its hash as text.
