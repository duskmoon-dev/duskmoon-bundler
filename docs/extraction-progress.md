# Extraction progress

Source baseline bca8e460adabe0454dd41125ed71a02662807767; destination baseline 5251f8a29231d8cf3f8f9ff4507ad428d2b1cde6. Snapshot import c78c95b4150a7c4b4068d835554acf63837d2754 preceded source removal. All 11,371 tracked source paths are classified, including 1,344 initially imported paths. Mixed root files remain immutable provenance snapshots.

B0 9.16.16 is the existing published cohort. B1 9.16.17 was absent from all eight Hex release endpoints and the destination v9.16.17 tag endpoint (HTTP 404 on 2026-10-13). No publish/push/tag operation is authorized or performed.

Implemented: independent root Mix/config/Bun/devenv, preserved package cohort, explicit native policy, standalone staging with hashes, isolated candidate consumer and JS preload regression. Native/checksum release workflows are maintained separately by the automation worker. Source UI browser vendor consumers moved to UI Storybook tests, with original imported file preserved under docs/migration-snapshot.

Verification in progress: destination cold source compile on OTP 28 / Elixir 1.18.5; native policy 4 tests passed; package staging 2 tests passed after correcting literal two-tuple AST normalization and a formatting-dependent assertion. Existing locks resolved without dependency upgrades, then UI-only entries pruned with mix deps.unlock --unused. Bun install is standalone.

Completed checks: warnings-as-errors standalone source compile; full standalone source suite 655 tests plus 2 doctests (solver5, runtime27, OXC11, npm91, QuickBEAM13, bundler508); native policy4, staging2, JS preload2; all8 staged Hex archives built and inspected outside the checkout with six real host-only candidate native archives/checksums. Archive SHA/count evidence is docs/local-verification.json. Oxide/Vize have no baseline test directories; both were directly exercised in the successful source native smoke.

Package integrity fixes: standalone registry staging removes Hex-forbidden override flags while retaining optional/runtime/environment semantics. QuickBEAM referenced absent documentation; the actual two documentation files now ship. HexSolver receives its declared canonical Apache-2.0 license. Generic Phoenix JS fixtures explicitly install the same package versions as the source lock using Bun, without requiring the UI's Hex dependencies. Bun lock files require explicit git add -f on this host because of a global ignore.

Remaining: isolated staged consumer helper verification; full cross-platform matrix and final47 checksum proof are release gates, not claimed local results. No active source checksum files are synthesized, and no packages/tags/releases were published.
