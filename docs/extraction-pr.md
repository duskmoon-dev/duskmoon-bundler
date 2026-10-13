# Extract the Duskmoon toolchain into its own repository

The UI previously carried the complete native build toolchain in its umbrella.
This change moves all eight existing applications and complete native/vendor/test
resources into an independently buildable toolchain repository, with an inventory
of all 11,371 original tracked paths and source SHA/path/content hashes.
Standalone Mix/config/Bun fixtures, staging and development tooling no longer
require the UI checkout. B1 is unpublished 9.16.17; UI U remains independent, and
published B0 9.16.16 retains its unchanged historical artifact locations.

Explicit source/precompiled native policy replaces umbrella-path inference for
all five Rust crates and QuickBEAM. The nonmutating package stager pins the cohort,
preserves dependency flags, removes workspace-only metadata and records source,
lock and package hashes. Formal release automation retains five Rust crates ×
eight targets and seven QuickBEAM targets, hashes the final 47 archives, verifies
public immutable bytes before Hex publication, then requires actual registry,
glibc and both musl consumers before one pinned UI upgrade. Retry guards reuse
matching outputs and adopted UI pins without replacements or duplicate commits.
UI-specific browser regressions remain in the paired UI cutover.

Validation passed: standalone warnings-as-errors compile; 655 tests + 2 doctests;
4 policy, 2 staging, 2 JS preload, 4 actual native 404/checksum-failure probes with
compiler traps, 7 release and 3 upgrade-retry tests; actionlint; complete inventory
verification; an isolated eight-package source/native consumer; and all eight
actual staged Hex archive builds/inspection. Package/native archive evidence is
host-only, not a completed 47-target release. The paired UI passed cold B0 tests,
assets/icons, `.heex` browser HMR and amd64 Alpine smoke with zero Duskmoon native
source compilation. Its existing B0 `.exs` watcher limitation is tracked as
[UI #199](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/199), with an
explicit manual build workaround.

Full B1 cross-platform/public registry/musl execution and credential setup remain
operational gates. Local arm64 Alpine execution failed with `exec format error`;
full Nix realization is blocked by a truncated remote nixpkgs fetch. No remote
push, tag, publication, PR, deployment or settings change was performed.

Review/merge this extraction first, confirm the already-verified published B0,
then review/merge the independent UI cutover. B0 permits that cutover before a B1
release. Configure the separate release environments and one-way upgrade
credentials; subsequently publish/verify B1 through every formal workflow gate,
review its UI upgrade PR and independently release the next U.

Implementation is complete locally on `codex/bundler-extraction`. Code heads before
final documentation commits are destination
`27cc3088ad427a751b84a52debc277c1162263d9` and UI
`4df3ff78ff3c3c4b112ab6697df6c131f01de634`. Full evidence and remaining commands:
[verification-report.md](verification-report.md). Paired UI PR description:
`phoenix-duskmoon-ui/docs/ui-cutover-pr.md`; counterpart UI evidence:
`phoenix-duskmoon-ui/docs/verification-report.md`.
