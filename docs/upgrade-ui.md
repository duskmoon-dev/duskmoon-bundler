# Optional downstream UI compatibility and adoption

`phoenix-duskmoon-ui` consumes the Bundler toolchain. It is not a dependency of
Bundler source checks, publication or recovery. Toolchain releases require their
own source gates and independent package/native consumers. UI compatibility or
adoption failures do not block a toolchain release.

The normal release and published-verification workflows do not check out or write
the UI repository, create UI upgrade PRs, or require cross-repository credentials.
UI work is a separate, explicitly authorized operation.

## Optional source compatibility

Manually dispatch `ui-compatibility.yml` when a downstream compatibility check is
needed. Select the Bundler source revision with the dispatch ref and supply an
immutable UI revision:

```sh
gh workflow run ui-compatibility.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref TOOLCHAIN_REF -f ui_sha=FULL_UI_SHA
```

The workflow stages the candidate toolchain and runs the UI's explicit isolated
`scripts/candidate-integration.sh` helper with native sources, including
third-party Rust NIF dependencies via `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL=1`.
The UI revision must contain a helper compatible with the candidate toolchain;
its dependency constraints and locks must also admit that candidate. This is a
source integration check, not proof of registry/precompiled installation. Its
result is independent of the toolchain publication and recovery gates.

## Published-release verification and consumer recovery

If a published B cohort needs its consumer gates rerun after a validation-script
fix, dispatch `verify-published-release.yml` from the corrected validation
revision with `version` and the original artifact `source_sha`:

```sh
gh workflow run verify-published-release.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref VALIDATION_REF -f version=B -f source_sha=FULL_ARTIFACT_SOURCE_SHA
```

This calls the published-release jobs in `test.yml`, which download and hash all
47 public native artifacts and all nine release Hex tarballs against release
provenance, then run cold native, glibc and both Alpine consumers. It does not
rebuild or publish packages, change release assets or move the release tag.
The artifact source SHA remains unchanged.

Only after all required consumers pass does the workflow upload
`verified-toolchain-release-vB`. Its `verified-release.json` records the original
artifact `source_sha`, the separate `validation_sha`, publication and test run
URLs, all nine release package names and every consumer gate. This record is
available for manual downstream adoption without UI credentials.

## Explicit manual adoption

A UI upgrade requires separate authorization to modify that repository. After
successful published verification, download its evidence using the successful
**Toolchain Tests** run ID. With a clean, authorized UI checkout:

```sh
gh run download SUCCESSFUL_RUN_ID --repo duskmoon-dev/duskmoon-bundler \
  --name verified-toolchain-release-vB --dir /tmp/verified-B
elixir scripts/upgrade-ui.exs B FULL_TOOLCHAIN_SHA /absolute/ui-checkout /tmp/verified-B/verified-release.json
```

The command verifies release provenance and actual registry package bytes, pins
`BUNDLER_VERSION`, resolves the real lock, validates the eight UI toolchain Hex
entries and records provenance in `docs/bundler-upgrades/vB.json`. It rejects
downgrades, unrelated origins, dirty checkouts and mismatching publication
provenance. It does not create a branch, commit, push or PR. Run the UI's normal
full checks and production assets, then inspect the changes before delivery.

The script's `--push` mode creates or reuses `deps/bundler-vB` and a PR to UI
`main`; it requires explicit branch, push and PR authorization and appropriately
scoped GitHub credentials. It never writes directly to main or merges. Retries
reuse matching branches/PRs without force pushes or duplicate commits; if main
already adopted B, they verify the existing pin, lock and provenance before any
branch operation. Do not add UI credentials to the Bundler release workflow for
this optional operation.

U remains unchanged until a separately reviewed UI version change and UI Release
dispatch. UI changes or failures never trigger another Bundler release. From
B=10.0.3, release provenance includes `duskmoon_hologram` as a ninth package; the
UI's eight-package lock checks remain distinct from verification of the complete
nine-package release.
