type: Changed

**Wire QMP boot snapshots and the 10-shard `main` split into `flake.nix`.** The flake builds a cached QMP usable-boot VM snapshot through `modustool boot-snapshot` and runs the `main` machine scenario as 10 parallel `main_*` shard derivations that restore from that snapshot.
