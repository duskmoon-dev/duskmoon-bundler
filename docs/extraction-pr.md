# Extract the Duskmoon toolchain into its own repository

Moves all eight existing applications and complete native/vendor/test resources into an independent toolchain umbrella with source SHA/path/hash inventory. Standalone configuration, Bun fixtures and development tooling no longer require the UI checkout. B1 is 9.16.17; UI U remains independent, and historical B0 9.16.16 artifacts retain their old download locations.

Explicit source/precompiled native policy replaces umbrella-path inference for all five Rust crates and QuickBEAM. The tested nonmutating package stager pins internal cohort requirements, preserves dependency flags, strips workspace-only metadata and records per-file hashes. UI-specific browser regressions are retained in the paired UI migration; generic toolchain regressions stay here.

Validation: standalone source compile with warnings-as-errors, 655 tests + 2 doctests, 4 policy tests, 2 staging tests, 2 JS preload tests, and all8 isolated staged Hex package builds/inspection with actual host-only source NIF checksums. Full47 cross-platform artifacts and published registry/musl consumers remain release gates. No push or publication performed.

Merge order: review/merge this destination extraction first; verify selected published B0 or independently release/verify B1; then merge paired UI cutover and enable one-way upgrade automation. Paired UI PR text lives in the source repository migration docs.
