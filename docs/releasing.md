# Toolchain release runbook

All nine Hex applications share stable **B**. UI **U** is independently released
by `phoenix-duskmoon-ui`. No packages are published on pushes, pull requests or
arbitrary repository dispatches. Only **Toolchain Release**, with an approved
`release` environment and explicit stable B, immutable toolchain SHA and pinned
UI integration SHA, performs publishing. Commit version changes first; the
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
2. Run pure release/staging/native-policy checks, all nine source tests and
   source-mode candidate integration against an explicitly pinned compatible UI
   SHA. That lane uses all candidate packages and their native sources, isolated
   from B0 and the normal UI lock/build/deps state.
3. Build the existing five Rust crates across eight targets, then QuickBEAM's
   seven targets. The historical Rust-to-QuickBEAM dependency barrier remains.
   Preserve NIF 2.15, musl shared-library checks, portable x86_64 CPU checks, Rust
   and Zig 0.16.0 requirements. Native jobs only upload workflow artifacts.
4. Collect exactly 47 final archives. Generate checksums directly from those
   bytes, stage standalone package sources, derive package order from evaluated
   manifests, build exact Hex tarballs, and record source/lock/asset/package
   hashes in `release-provenance.json`. No extra native compile generates hashes.
5. Create/reuse vB pointing at the immutable SHA and upload missing assets only.
   Validate existing digests and anonymously download every final asset. A draft
   or authenticated download is insufficient. Run staged package consumers
   outside both repositories using strict precompiled mode and those public
   artifacts. The consumer inputs are extracted from the exact Hex tarballs into
   a disposable cohort, so downloaded/generated NIF resources never modify the
   verified publish stage. Only then publish the nine registry packages in
   dependency order.
6. Run cold installed-registry native/bundling/Tailwind smoke checks on glibc and
   Alpine amd64/arm64, with no Rust/Zig compiler. The runtime-only manifest-v1
   consumer regression also checks that build modules remain absent.
7. Only success of every preceding gate enables a single pinned UI upgrade PR.
   Partial publication or a failed platform consumer cannot start adoption.

Commands with **no publishing side effects** (substitute real B/SHA):

```sh
elixir .github/scripts/release_test.exs
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
The complete release workflow must be rerun to include all acceptance gates.

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
so successful native matrix outputs are retained. A new formal dispatch with a
complete public record downloads and verifies all47 immutable native assets and
skips the matrix explicitly; staging/publication still revalidate exact hashes.
Retry the same B/SHA only with identical outputs;
existing matching tags/assets/registry tarballs are reused. Existing conflicting
bytes fail clearly. There is no `--replace`, asset clobber, moving a tag, registry
rollback, or deletion. A rebuilt nonidentical artifact requires inspection and
usually a new B; do not relabel historical binaries. Rerun missing gates before
adoption. If B succeeds and UI fails, retain B and repair/review the pending UI
upgrade; do not bounce release workflows between repositories.

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
glibc and both Alpine consumers before recording the verified gates. Build,
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
CI and release validation run its full Elixir suite and the Mocha + jsdom
suite under Bun through `duskmoon_npm`, plus native OXC format/lint checks.
The staged package includes its local docs and preserves upstream/vendor licenses.
The production source/tar/registry consumers also load Hologram. UI candidate
validation and upgrade locks cover the eight asset dependencies actually used
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
locks, platform/libc, Elixir/OTP and source-mode/toolchain keys; release jobs retain
cold target builds. A bootstrap candidate UI SHA must include the migration's
`scripts/candidate-integration.sh`, not the old pre-extraction main commit.
