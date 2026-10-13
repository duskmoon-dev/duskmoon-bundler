# Bundler extraction verification report

Implementation is complete locally on `codex/bundler-extraction` as of
2026-10-13. This report records local implementation and executed acceptance
checks; it does not assert that B1 has been released or that remote workflows ran.

## Revisions and ownership

| Repository | Original anchor | Verified code head before final documentation commits |
| --- | --- | --- |
| `phoenix-duskmoon-ui` | `bca8e460adabe0454dd41125ed71a02662807767` | `4df3ff78ff3c3c4b112ab6697df6c131f01de634` |
| `duskmoon-bundler` | `5251f8a29231d8cf3f8f9ff4507ad428d2b1cde6` | `27cc3088ad427a751b84a52debc277c1162263d9` |

Both repositories use local migration branch `codex/bundler-extraction` and retain
their original origins. Final documentation commits will advance these heads.
Snapshot import `c78c95b4150a7c4b4068d835554acf63837d2754` preceded removal
of active toolchain sources from the UI repository. The inventory classifies all
11,371 original tracked paths, including 1,344 initially imported paths; original
path, destination, source SHA and content hashes are retained. Final inventory
verification matched every moved, duplicated and split snapshot hash and found
the required destination paths.

The independent destination owns `duskmoon_bundler`, `duskmoon_bundler_runtime`,
`duskmoon_oxc`, `duskmoon_oxide`, `duskmoon_vize`, `duskmoon_quickbeam`,
`duskmoon_npm` and `duskmoon_hex_solver`. Its Mix/config/Bun fixtures, native
resources, licenses, development environment, staging and release automation are
self-contained. The UI owns only `phoenix_duskmoon` and `duskmoon_storybook`.
The public component package retains its dependency boundary. Manifest version 1
and existing package/module names remain unchanged.

## Bootstrap and package evidence

B0 **9.16.16** is the published eight-package cohort selected for the initial UI
cutover. All 47 historical native archives were downloaded and verified against
their published checksum contracts. Its unchanged loaders still use the UI
repository's historical release. B1 **9.16.17** is the independent destination
candidate and remains unpublished. Read-only checks found all eight B1 Hex
release endpoints and the destination tag absent on 2026-10-13; availability must
be checked again before publication. UI U and toolchain B remain independent.

All eight actual candidate Hex tarballs were built and inspected outside the
checkout, with six real source-built host NIF archives/checksums for
`x86_64-linux-gnu`. The tarball SHA256 values and file counts are recorded in
[local-verification.json](local-verification.json). Exact archives were also
extracted into a disposable cohort for a runtime-only consumer regression.
An isolated complete eight-package source consumer compiled with warnings as
errors and exercised OXC parsing/selection/format/lint, Oxide extraction, Vize SFC
and QuickBEAM execution. Staging removes workspace paths, root helpers,
`in_umbrella` and publication-invalid overrides while preserving optional,
runtime and environment dependency semantics. Staging provenance records commit,
tree, dirty state, actual locks and package source hashes.

These are **host-only candidate package checks**, separate from an installed B1
registry/precompiled consumer and separate from full release artifact proof.
No candidate host checksum was installed into active repository release metadata.
The isolated runtime consumer passed one manifest-v1 test and verified that
Builder is absent. A published B0 runtime-only consumer independently passed the
same boundary check.

## Executed acceptance checks

| Scenario | Actual result and limit |
| --- | --- |
| Independent extraction | Destination source compile with warnings as errors passed; 655 Elixir tests plus 2 doctests passed. Inventory verification accounted for all 11,371 original paths. No UI checkout is an implicit toolchain input. |
| Destination scoped contracts | Native policy 4 tests, package staging 2 tests, JS preload 2 tests passed. Oxide and Vize have no baseline test directories; their native APIs passed the isolated source smoke. |
| Strict missing/corrupt downloads | 4 actual failure probes passed: Rustler and Zigler each rejected a localhost 404 and checksum mismatch. Compiler traps remained untouched and no fallback NIF appeared. Conflicting native source flags are covered separately by strict policy tests. |
| Cold ordinary UI | Published B0 cold build from an archived UI checkout at `c805bb89` passed 3,099 component tests plus 22 Storybook tests and 56 JS tests, generated both real UI/Storybook assets and icons, and left an empty Duskmoon native compiler invocation log. The ordinary path needs no destination checkout. |
| Representative UI change and HMR | A new `.heex` `p-[61px]` utility was absent before and present after the edit; the filtered bundler websocket delivered the CSS update. LiveView connected and the React hook mounted. Native invocation count remained zero. |
| Candidate/native identity | Explicit isolated integration used the complete eight-package candidate source closure. A disposable OXC sentinel returned false through `OXC.valid?/2` with candidate source and true with B0 for the same valid JS, demonstrating candidate native execution. Full 3,099 + 22 Elixir/56 JS suites and both assets/icons passed. |
| Production/runtime and package boundary | UI production assets/icons, release application inspection, hooks/forms regressions, isolated component/npm package checks and manifest-v1 runtime checks passed. Storybook's runtime release excludes the build toolchain. |
| Historical/native compatibility | B0 registry cohort and all 47 historical archives verified. A fresh amd64 Alpine image executed the actual B0 native smoke without cargo, rustc or zig. Arm64 execution was attempted but stopped with `exec format error`; no local arm64 consumer success is claimed. |
| UI release dry plan | U/B 9.16.16 plan lists only UI Hex/npm publication and empty native-build/toolchain-publication lists. UI release contract tests passed 5 tests. |
| Bundler release dry plan | B1 plan derives all eight packages' dependency order and preserves five Rust crates × eight targets plus seven QuickBEAM targets: 47 archives. Public assets, complete registry/glibc/both-musl gates precede one pinned UI upgrade. Release contract tests passed 7 tests. |
| Retry and adoption safety | Upgrade regression tests passed 3 tests: two no-op adopted-main retries, rejection of five bad-lock variants, and conflicting metadata. Tests forbid remote Git, PR and dependency-resolution commands and verify unchanged refs/files. Matching immutable outputs are reused; partial release adoption and conflicting bytes are rejected. |
| Workflow/static checks | actionlint v1.7.11 passed both repositories' workflows. Formatting and diff checks passed. Final scoped destination warnings-as-errors compile passed against the existing source build state in 0.37 seconds; that repeat is not cold-build evidence. |

The release checksum tests deliberately use synthetic fixture bytes to prove
complete-set validation and hashing of final archives. They provide no native
binary or cross-platform execution evidence. The release matrix is maintained in
workflow definitions, not represented as a locally executed 47-target build.

The existing B0 Tailwind watcher excludes `.exs`, although production scanning
includes it. That development limitation is tracked as severity **needed** in
[UI internal request #199](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/199).
The UI extraction runbook contains the explicit manual build workaround and
upstream TODO. `.heex` HMR passed; automatic `.exs` utility regeneration is not
claimed fixed in B0.

## Reproducible checks and retained evidence

Executed destination command families include:

```sh
DUSKMOON_NATIVE_MODE=source mix compile --warnings-as-errors
DUSKMOON_NATIVE_MODE=source mix test
bun test test/js
elixir scripts/native-policy-test.exs
elixir scripts/native-download-failure-test.exs
elixir scripts/package-stage-test.exs
elixir .github/scripts/release_test.exs
elixir scripts/upgrade-ui-test.exs
elixir scripts/verify-inventory.exs --source /home/gao/Workspace/duskmoon-dev/phoenix-duskmoon-ui
```

Source tests need the documented Rust/Zig development environment and a working
browser. The actual source lanes used OTP 28, Elixir 1.18.5 and Zig 0.16.0.
The local actionlint executable was `/tmp/duskmoon-migration-tools/actionlint`;
the final scoped run used `-shellcheck='' .github/workflows/ci.yml
.github/workflows/release.yml`. Shell smoke scripts were checked separately.

Durable evidence is the inventory and `local-verification.json`. Temporary logs
and artifact directories may be removed by host cleanup:

- `/tmp/duskmoon-toolchain-tests-20261013.log`
- `/tmp/duskmoon-staged-consumer-20261013.log`
- `/tmp/duskmoon-inventory-verification-20261013.log`
- `/tmp/duskmoon-stage-candidate-20261013c/host-package-inspection.json`
- `/tmp/duskmoon-release-tar-extracted` (eight extracted host candidate archives)
- `/tmp/duskmoon-ui-release-stage-final/validation-provenance.json` and
  `/tmp/duskmoon-ui-package-smoke-final.log` (actual final UI archive consumer
  checks; Hex/npm tarball hashes retained in the paired source
  `docs/verification/local-acceptance.json`)

The paired source repository's `docs/verification-report.md` contains UI cold,
browser/HMR, asset, package and release application evidence. Its paired PR
description is `docs/ui-cutover-pr.md`.

## Remaining operational gates and rollout

1. Review/merge the destination extraction, then the independently verified B0 UI
   cutover. B0 permits initial UI isolation before publishing B1; retain all
   unpublished candidate fixes in the destination.
2. Configure destination package ownership, protected release approval, registry
   credentials and a least-privilege UI GitHub App or narrowly scoped PAT as
   documented in [releasing.md](releasing.md) and [upgrade-ui.md](upgrade-ui.md).
   Cross-repository coordination remains **unconfigured**, not executed.
3. With separate authorization, execute the formal B1 release against an immutable
   destination SHA and pinned compatible UI SHA. The full 47-archive matrix,
   anonymous public-byte verification, exact staged packages, all eight registry
   installations and glibc/Alpine amd64/arm64 consumers remain required gates.
   Only their complete success allows adoption automation.
4. Review the pinned UI dependency-upgrade PR and its full UI checks, then use
   the independently authorized UI release process for the next U. A successful
   B remains intact if the UI upgrade fails.

Nix expression syntax passed, and actual native source builds used Zig 0.16.0.
Full devenv realization remains **BLOCKED_ENV**: remote nixpkgs fetching stalled
and reported `Truncated tar archive detected while reading data`. The owned
command was stopped safely. Syntax and raw upstream Zig definitions do not prove
successful Nix realization.

Runbook commands below are remaining steps, **not recorded completed releases**.
Substitute actual B and final immutable SHA after documentation commits. `prepare`
requires all 47 actual artifacts and a fresh output directory:

```sh
elixir scripts/release.exs plan B FULL_TOOLCHAIN_SHA
elixir scripts/release.exs prepare B FULL_TOOLCHAIN_SHA /tmp/final-native-assets /tmp/staged-b
elixir .github/scripts/runtime_consumer.exs B /tmp/staged-b
```

For partial release recovery, the runbook preserves successful matrix artifacts:

```sh
gh run rerun FAILED_RUN_ID --failed --repo duskmoon-dev/duskmoon-bundler
```

When a complete release passed glibc and both Alpine gates but coordination
credentials are absent, use the runbook's version-pinned manual fallback:

```sh
gh run download SUCCESSFUL_RUN_ID --repo duskmoon-dev/duskmoon-bundler \
  --name verified-toolchain-release-vB --dir /tmp/verified-B
elixir scripts/upgrade-ui.exs B FULL_TOOLCHAIN_SHA /absolute/ui-checkout /tmp/verified-B/verified-release.json
```

That upgrade command verifies registry bytes and real lock entries without
creating a branch, commit, push or PR. Normal full UI checks and review follow.
The formal Toolchain Release workflow, rather than an isolated publish script,
must execute all release gates. No remote push, tag, publication, PR creation,
deployment or settings/secrets change was authorized or performed by this task.
No owned validation command remains running.
