# Toolchain release runbook

All nine Hex applications share stable **B**. UI **U** is independently released
by `phoenix-duskmoon-ui`. No packages are published on pushes, pull requests or
arbitrary repository dispatches. **Toolchain Release**, with an approved
`release` environment and explicit stable B, immutable toolchain SHA and pinned
UI integration SHA, performs initial publishing. **Resume Exact Hex Publication**
can finish the original package upload after verifying those completed build gates.
Commit version changes first; the
workflow neither changes versions nor pushes a release commit to main. Select a
dispatch ref whose head equals the supplied toolchain SHA; the validation gate
requires the workflow definition and source checkout to share that exact SHA.

The migration prepares B1 above existing versions; registry/tag absence must be
checked at the time of first publication. A B value whose native URLs change
must never reuse historical UI release bytes or package versions. Historical
UI repository tags remain the source for earlier toolchains.

## Bootstrap and gates

1. Review and merge destination extraction. Keep any already-verified B0 UI
   consumer operational until a new destination B is published and installed.
2. Run `ci.yml` for format/lint/compilation and `test.yml` for pure release,
   staging and native-policy contracts, all nine source test suites, Bun tests
   and pinned UI source integration. Before release, manually dispatch `test.yml`
   at the toolchain source SHA with the intended `ui_sha`. Release checks the
   latest CI and test runs at that exact source SHA and the successful UI job
   named with that exact UI SHA; it never executes those tests again. PR checks
   and post-release checks cannot substitute for these source gates. Candidate
   integration uses the UI's isolated candidate closure and native sources,
   including third-party Rust NIF dependencies via
   `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=1`.
3. Release calls eight independent `native-<rust-target>.yml` workflows. Each
   delegates to `native-prebuild.yml` for five Rust crates and, except Windows,
   one QuickBEAM target. Rust and QuickBEAM builds are independent, so one target
   never waits for an unrelated target's Rust builds. Builds start without any
   restored compilation cache; CI/test retain their shared native cache.
   Preserve NIF 2.15, musl shared-library checks, portable x86_64 CPU checks, Rust
   and Zig 0.16.0 requirements. Native jobs only upload workflow artifacts.
4. Collect exactly 47 final archives. Generate checksums directly from those
   bytes, stage standalone package sources, derive package order from evaluated
   manifests, build exact Hex tarballs, and record source/lock/asset/package
   hashes in `release-provenance.json`. No extra native compile generates hashes.
5. Create/reuse vB pointing at the immutable SHA and upload missing assets only.
   Validate existing digests and anonymously download every final asset. A draft
   or authenticated download is insufficient. Publish the nine exact tarballs
   in dependency order, then upload `release-request` with the immutable B/SHA.
   The normal release ends here and contains no source or consumer tests.
6. A successful **Toolchain Release** automatically starts **Toolchain Tests**
   through `workflow_run`. It validates the publication request against the
   original successful run, verifies all public bytes, extracts the exact Hex
   tarballs outside both checkouts, and runs strict precompiled consumers and
   the runtime-only manifest regression. It also runs cold registry smoke checks
   on Ubuntu 26.04 glibc and Alpine amd64/arm64, with no Rust/Zig compiler in
   those containers.
   A separate OTP 28.5.0.8 matrix loads and executes all six published NIFs on
   Ubuntu 26.04 amd64/arm64, macOS 26 Intel and macOS 27 ARM.
   The complete registry consumers bootstrap the third-party `lazy_html` NIF
   through ElixirMake's target/URL/cache interfaces with a bounded 64 KiB header
   budget and the checksum from its published Hex package. Its default downloader
   otherwise discards the OTP 28 header-limit error and attempts a source build.
   Duskmoon NIF downloads remain cold, with no native compiler fallback.
   These tests run after publication; a consumer failure blocks adoption but
   does not roll back already published packages.
7. Only successful published-artifact, registry and platform tests in `test.yml`
   enable a single pinned UI upgrade PR and its verified-release record.
   Partial publication or a failed platform consumer cannot start adoption.

Commands with **no publishing side effects** (substitute real B/SHA):

```sh
elixir .github/scripts/release_test.exs
elixir .github/scripts/workflow_checks_test.exs
elixir scripts/package-stage-test.exs
elixir scripts/native-policy-test.exs
elixir scripts/release.exs plan B FULL_TOOLCHAIN_SHA
elixir scripts/release.exs prepare B FULL_TOOLCHAIN_SHA /tmp/final-native-assets /tmp/staged-b
elixir .github/scripts/runtime_consumer.exs B /tmp/staged-b
```

Dry plans record `source_dirty`; formal preflight, preparation and publication
reject source dirt. Explicit candidate transformations remain isolated and labelled.
`prepare` needs all actual target artifacts; dummy hashes never substitute for
release validation. Its output directory must not exist. `publish-assets` and
`publish-packages` are side-effecting release operations and require explicit
operational authorization outside this implementation task. `publish-packages`
rechecks public artifacts rather than assuming a preceding upload succeeded.
For the source/UI gate, confirm `main` points at the intended toolchain SHA, then
run this before the release dispatch. GitHub requires a branch or tag as the
dispatch ref; a bare commit SHA is not accepted. Check the created run's
`head_sha` against that intended SHA:

```sh
gh workflow run test.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref main -f ui_sha=FULL_UI_SHA
```

Wait for that run and `ci.yml` at the same source SHA to succeed. A new failed,
cancelled or unfinished source run blocks release instead of reusing older green
results. After publication, wait for the separate **Toolchain Tests** run before
considering the cohort verified for UI adoption.

Hosted runners use `ubuntu-26.04`, `ubuntu-26.04-arm`, `macos-26-intel`,
`xcode-27` (macOS 27 ARM) and `windows-2025`. GitHub currently provides macOS 27
through its `xcode-27` preview image label. Linux GNU Rust and QuickBEAM builds
run directly on the matching Ubuntu 26.04 host. This internal toolchain follows
the current runner's glibc and does not impose an older-distribution ABI ceiling.
Cross builds remain in use for the other Rust targets that require them.

The CI download regression additionally pins OTP `28.5.0.8` on the consumer
environments `ubuntu-26.04`, `ubuntu-26.04-arm`, `macos-26-intel` and `xcode-27`.
These consumers run directly on their hosted runners.
It checks expanded redirect headers and the 64 KiB limit, then extracts verified
10.0.3 Hex packages outside the checkout and overlays only the candidate URL
callbacks and their call sites. Both runs use the original public native
artifacts and checksum files with empty caches and compiler traps. This isolates
download compatibility from source builds and from a not-yet-published cohort;
the normal release still builds all 47 archives and tests the new exact packages.
All six NIFs must execute in every matrix environment before adoption.

Publication uploads the verified tarballs directly through Hex's package API
with replacement disabled. It does not resolve optional source dependencies or
rebuild package contents; the registry downloads must match those exact bytes.

## Credentials and permissions

Configure destination-owned `HEX_API_KEY` with ownership of all nine
Hex packages and a protected `release` environment. This repository needs no UI
npm publishing key. `contents: write` is limited to the publication job; normal
CI/native jobs have read-only contents permission. No historical secrets are
copied. Registry ownership, environment approvals and GitHub App installation
are external setup prerequisites and are not performed by this migration.
See `upgrade-ui.md` for the separately scoped cross-repository GitHub App/token.

## Partial release recovery

Preserve the failed run's native/package workflow artifacts and public
`release-provenance.json`. For a partial run before a complete public provenance
record exists, use `gh run rerun FAILED_RUN_ID --failed --repo duskmoon-dev/duskmoon-bundler`
so successful native target outputs are retained. The eight called target
workflows share the original release run's artifact store, so staging collects
successful artifacts from earlier attempts together with the retried artifacts.
Use the failed job's **Re-run job** control to retry one build and its dependents.
For the CLI, use the job's `databaseId` rather than the number in its browser URL:

```sh
gh run view RELEASE_RUN_ID --repo duskmoon-dev/duskmoon-bundler \
  --json jobs --jq '.jobs[] | {name, databaseId, conclusion}'
gh run rerun --repo duskmoon-dev/duskmoon-bundler --job FAILED_JOB_DATABASE_ID
```

Do not choose **Re-run all jobs** or create a
new release dispatch to retry a single failed architecture. The native artifact
uploads permit replacement within that same run; published bytes remain immutable.
A new formal dispatch with a complete public record downloads and verifies all
47 immutable native assets and skips the native target workflows explicitly;
staging/publication still revalidate exact hashes.
Retry the same B/SHA only with identical outputs;
existing matching tags/assets/registry tarballs are reused. Existing conflicting
bytes fail clearly. There is no `--replace`, asset clobber, moving a tag, registry
rollback, or deletion. A rebuilt nonidentical artifact requires inspection and
usually a new B; do not relabel historical binaries. Rerun missing gates before
adoption. If B succeeds and UI fails, retain B and repair/review the pending UI
upgrade; do not bounce release workflows between repositories.

For historical runs where the complete GitHub release is already public but the
exact-package consumer failed before Hex publication, preserve the original tag,
provenance, native files and package archives. A consumer-script fix must not rebuild packages under that
same version. Dispatch **Resume Exact Hex Publication** from the corrected
validation revision, supplying the original source SHA and release run:

```sh
gh workflow run resume-hex-publication.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref VALIDATION_REF -f version=B -f source_sha=FULL_ARTIFACT_SOURCE_SHA \
  -f release_run=ORIGINAL_RELEASE_RUN_ID
```

Recovery requires the original run's successful source/UI gates, all 47 native
builds and staging jobs, and its retained `exact-publish-packages` artifact. Source
and UI gates in new releases refer to the prior successful CI/test run. Recovery
accepts historical matrix job names and the split target workflows, and checks
the latest execution of each job across partial reruns. It
downloads and checks the public native bytes, extracts the original tarballs into
a fresh consumer, and runs the corrected strict precompiled checks. Before any
Hex upload it verifies the original checkout/locks, tag, provenance, all source
and package hashes, and every existing public asset. Missing or conflicting public
assets stop recovery; this mode cannot create a release, upload an asset, move a
tag or rebuild a package. Registry uploads use the original tarballs with
replacement disabled. Expired original workflow artifacts require a separate
reviewed recovery; this workflow does not reconstruct them.

The recovery publication job holds the same cohort lock and `release` environment
as initial publication, with read-only GitHub permissions and the existing Hex
credential. It releases the lock before calling the normal published-release
verifier for public hashes, glibc and both musl consumers, and the adoption record.
The record separates original artifact `source_sha` from corrected `validation_sha`.

For a fully published cohort whose consumer validation needs a script fix,
dispatch **Toolchain Release** from the corrected validation revision with
`verify_published=true`, the original B and artifact source SHA:

```sh
gh workflow run release.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref VALIDATION_REF -f version=B -f source_sha=FULL_ARTIFACT_SOURCE_SHA \
  -f verify_published=true
```

This mode calls the published-release verifier, checks all 47 public native
archives and nine Hex tarballs against original provenance, then runs the cold
`test.yml` public-artifact, glibc and both Alpine consumers before recording the verified gates. Build,
staging and publication jobs are skipped; no artifacts, packages or tags change.
`ui_sha` is required only for normal publication. The record keeps artifact
`source_sha` separate from `validation_sha`. See `upgrade-ui.md` for coordination
and the standalone verification dispatch.

GitHub reruns use the original workflow and source revision, so rerunning the
old failed attempt cannot pick up a later validation-script repair. Its failed
result remains in history; the corrected dispatch supplies new verification.

Workflow definitions specify cross-platform coverage but local script validation
alone does not prove those target builds, publication, remote credential setup
or public consumer installation. Those remain actual release-run evidence.

## Hologram in the synchronized cohort

From 10.0.3, `duskmoon_hologram` uses the same B version as the eight existing
packages. The manifest-derived publish order places it after `duskmoon_npm`
and `duskmoon_bundler`. The native artifact matrix remains 47 archives.
`ci.yml` runs native OXC format/lint checks. `test.yml` runs its full Elixir suite
and the Mocha + jsdom suite under Bun through `duskmoon_npm`, installing Hologram's
asset dependencies before the Elixir compiler/helper tests. Release checks those
successful source/UI results and builds/packages without rerunning the suites.
The staged package includes its local docs and preserves upstream/vendor licenses.
The production source/tar/registry consumers also load Hologram. Consumers that
start Hologram register `Mix.compilers() ++ [:hologram]`, so its
runtime PLTs and bundles are generated before application startup. The installed
consumer checks assert its supervisor and page resolver are running.
UI candidate validation and upgrade locks cover the eight asset dependencies actually used
by the UI; release provenance and registry verification cover all nine packages.

## Local automation verification

On 2026-10-13, `actionlint` v1.7.11 accepted all destination workflows, including
the full 5x8 Rust and seven-target QuickBEAM matrix. Release script tests passed
7/7: stable refs/versions, manifest order/cycle rejection, immutable retry,
partial-cohort adoption rejection, full native retry validation, exact47 checksum generation and missing-asset
failure. The checksum tests use clearly synthetic temporary fixture bytes and
provide no cross-platform binary evidence. B=9.16.17's side-effect-free plan
listed all eight packages in manifest-derived order; read-only preflight found
all eight registry versions absent. The migrated JS preload tests passed 2/2.
The extraction verification report records the separately executed native/source
and host-package checks. No publication, tag, PR, secrets or settings changed.

The pure release helper is intentionally duplicated in the UI repository so each
checkout is independent. Normal CI caches dependency downloads with repository,
locks, platform/libc, Elixir/OTP and source-mode/toolchain keys through the shared
`setup-toolchain` action; release jobs retain
cold target builds. A bootstrap candidate UI SHA must include the migration's
`scripts/candidate-integration.sh`, not the old pre-extraction main commit.
