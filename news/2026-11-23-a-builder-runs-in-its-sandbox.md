title: A build runs its builder in a sandbox
date: 2026-11-23
release: next
picture: none
kind: Shown
guide: none

The service recipes now runs a builder: a module named by its hash in a recipe. It starts the module in a process of its own, with a store of its inputs that reads only and an empty store for its output. The builder has no network, and its seed is the hash of its recipe.

The hash of the output is the hash of the tree that the builder left. A second build of the same recipe takes that result and runs nothing.

The machine test starts a test builder that tries to write its inputs, to find a handle of the network, and to run forever. The system refuses each try, and keeps nothing.
