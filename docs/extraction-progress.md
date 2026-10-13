# Extraction progress

Implementation complete locally on `codex/bundler-extraction`, 2026-10-13.
Final code heads before documentation commits: UI
`4df3ff78ff3c3c4b112ab6697df6c131f01de634`; destination
`27cc3088ad427a751b84a52debc277c1162263d9`. Resume operational rollout from
[verification-report.md](verification-report.md), [releasing.md](releasing.md)
and [upgrade-ui.md](upgrade-ui.md). Remote publication and setup remain gated.

Source baseline bca8e460adabe0454dd41125ed71a02662807767; destination baseline 5251f8a29231d8cf3f8f9ff4507ad428d2b1cde6. Snapshot import c78c95b4150a7c4b4068d835554acf63837d2754 preceded source removal. All 11,371 tracked source paths are classified, including 1,344 initially imported paths. Mixed root files remain immutable provenance snapshots.

B0 9.16.16 is the existing published cohort. B1 9.16.17 was absent from all eight Hex release endpoints and the destination v9.16.17 tag endpoint (HTTP 404 on 2026-10-13). No publish/push/tag operation is authorized or performed.

Implemented: independent root Mix/config/Bun/devenv, preserved package cohort, explicit native policy, standalone staging with hashes, isolated candidate consumer and JS preload regression. Native/checksum release workflows are independently owned here. Source UI browser vendor consumers moved to UI Storybook tests, with original imported file preserved under docs/migration-snapshot.

Completed standalone validation used OTP 28 / Elixir 1.18.5; native policy 4 tests passed; package staging 2 tests passed after correcting literal two-tuple AST normalization and a formatting-dependent assertion. Existing locks resolved without dependency upgrades, then UI-only entries pruned with mix deps.unlock --unused. Bun install is standalone.

Completed checks: warnings-as-errors standalone source compile; full standalone source suite 655 tests plus 2 doctests (solver5, runtime27, OXC11, npm91, QuickBEAM13, bundler508); native policy4, staging2, JS preload2; all8 staged Hex archives built and inspected outside the checkout with six real host-only candidate native archives/checksums. Archive SHA/count evidence is docs/local-verification.json. Oxide/Vize have no baseline test directories; both were directly exercised in the successful source native smoke.

Package integrity fixes: standalone registry staging removes Hex-forbidden override flags while retaining optional/runtime/environment semantics. QuickBEAM referenced absent documentation; the actual two documentation files now ship. HexSolver receives its declared canonical Apache-2.0 license. Generic Phoenix JS fixtures explicitly install the same package versions as the source lock using Bun, without requiring the UI's Hex dependencies. Bun lock files require explicit git add -f on this host because of a global ignore.

Remaining: full cross-platform matrix and final47 checksum proof are release gates, not claimed local results. No active source checksum files are synthesized, and no packages/tags/releases were published.

Final isolated staged source consumer passed: complete eight-package override closure outside both checkouts, separate deps/build state, warnings-as-errors compile, OXC parsing/selection/format/lint, Vize SFC, Oxide extraction and QuickBEAM runtime execution. The source-only consumer mirrors the existing umbrella ExDoc override needed by Zigler/zig_doc; publishable package metadata contains no override flags. Log: /tmp/duskmoon-staged-consumer-20261013.log.

Strict download failure automation passed4 cases: Rustler and Zigler each reject a localhost404 and checksum-mismatched fixture response. Compiler invocation traps (including explicit Zig executable) remained untouched and no fallback NIF appeared. Run `elixir scripts/native-download-failure-test.exs` after the destination development dependencies have compiled.

Native development configuration now selects Zig0.16 to match the pinned Zigler and native CI requirements. Nix expression syntax passed. Full remote Nix evaluation could not complete because the nixpkgs tar fetch stalled/truncated; the owned command was stopped safely. Raw upstream package definitions confirmed zig_0_16, and both source build lanes actually ran Zig0.16.0. Full devenv realization remains unverified (BLOCKED_ENV), without changing lock versions or bypassing permissions.

Staging provenance now records Git commit/tree, dirty-state marker and actual Mix/Bun lock hashes alongside package source hashes, so developer candidate staging does not misrepresent a dirty tree as an immutable release. Formal release automation requires its own clean immutable checkout gates.

Final provenance validation passed `elixir scripts/verify-inventory.exs --source /home/gao/Workspace/duskmoon-dev/phoenix-duskmoon-ui`: every moved/duplicated/split original content hash matched the recorded source snapshot, and all destination paths exist. No owned commands remain running.

Automation complete locally: release contracts 7 tests, upgrade retry contracts
3 tests and actionlint v1.7.11 passed. Adopted-main retries verify pin, metadata
and all eight actual Hex lock entries before any branch operation, including
after an upgrade branch was deleted. No real remote operation ran in these tests.
The release workflow retains all 47 native archives and gates adoption on public
bytes, the complete registry cohort, glibc and both Alpine consumers.

Paired UI acceptance is complete: cold B0 passed 3,099 component + 22 Storybook tests,
56 JS tests, both assets/icons and an empty native invocation log. Complete
candidate source integration exercised the OXC sentinel as false versus B0 true.
A fresh amd64 Alpine image passed actual B0 native smoke without cargo/rustc/zig;
arm64 could not execute (`exec format error`). Browser HMR passed the filtered
bundler websocket CSS update and a fresh `.heex` `p-[61px]` utility; LiveView and
React hook connected with zero native invocations. Existing B0 `.exs` watcher
behavior is tracked by UI internal request #199 (needed) and its explicit manual
build workaround is in the UI runbook.

Remaining gates: actual B1 full matrix/public registry/glibc/both-musl release
proof, release credentials and cross-repository coordination configuration, and
blocked full Nix realization. B0's published historical 47 archives were verified;
B1 remains unpublished 9.16.17. No remote push/tag/publication/deployment/settings
operation is authorized. See the report for exact remaining runbook commands and
the paired source `docs/ui-cutover-pr.md` / `docs/verification-report.md`.
