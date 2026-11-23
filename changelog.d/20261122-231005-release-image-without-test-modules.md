type: Changed

**A release ships no test module.** The release volume holds the boot image of the build without the modules of the group `tests`, each other module with the bytes that the tests ran, and the release refuses a volume that holds a test module.
