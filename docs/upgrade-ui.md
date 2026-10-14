# One-way pinned UI upgrade

The successful formal B release waits for every package, public artifact,
installed glibc consumer and both Alpine consumers before the upgrade job runs.
It targets only `duskmoon-dev/phoenix-duskmoon-ui`, branch `deps/bundler-vB`, base
`main`. It pins `BUNDLER_VERSION`, runs real `mix deps.get`, validates all eight
Hex lock entries, and records release URL/toolchain SHA in
`docs/bundler-upgrades/vB.json`. It rejects downgrades, unrelated origins, dirty
checkouts and mismatching publication provenance. Retries reuse matching branches
and PRs, including closed/merged PRs, without force pushes or duplicate commits.
Conflicting outputs stop. The workflow never writes directly to main or merges.
When main has already adopted B and its upgrade branch was deleted, a retry
verifies the existing pin, matching release metadata and all eight actual Hex
lock entries before any branch operation. It completes without a new branch,
commit, push or PR. Missing, stale or non-Hex cohort entries fail instead of
accepting the pin alone.

Prefer a GitHub App installed **only on the UI repository**, with Contents
read/write, Pull requests read/write and Metadata read permissions. Configure
`UI_UPGRADE_APP_ID` (repository variable) and `UI_UPGRADE_APP_PRIVATE_KEY`
(destination secret). `actions/create-github-app-token` requests an installation
token restricted to that repository and those two writable permissions.
Alternative: destination secret `UI_UPGRADE_TOKEN`, a fine-grained PAT restricted
to that same repository and Contents/Pull requests read/write. Do not grant broad
organization permissions or reuse the source's publishing secrets.

App/PAT pushes and PR creation start the UI's push/pull_request CI, Test and
Package E2E workflows. A destination `GITHUB_TOKEN` neither writes the other
repository nor provides the required normal event behavior. No repository
settings/secrets/apps are configured by this migration. If credentials are
absent, B remains successful and the job reports **UI coordination unconfigured**
in its summary; it does not claim a PR was created.

## Published-release verification and consumer recovery

If a published B cohort needs its final consumer gates rerun after a validation
script fix, dispatch `verify-published-release.yml` from the corrected validation
revision with `version` and the original artifact `source_sha`. This workflow
downloads and hashes all 47 public native artifacts and all eight actual Hex
tarballs against release provenance, then runs a cold glibc consumer and both
Alpine consumers. It does not rebuild or publish packages, change release assets
or move the release tag. The artifact source SHA remains unchanged.

Only after all three jobs pass does it upload `verified-toolchain-release-vB`
and run the same configured UI upgrade coordination. Its `verified-release.json`
records the original artifact `source_sha`, the separate `validation_sha`, all
eight package names and every consumer gate. Without UI credentials it reports
**UI coordination unconfigured** and retains the record for manual adoption.

```sh
gh workflow run verify-published-release.yml --repo duskmoon-dev/duskmoon-bundler \
  --ref VALIDATION_REF -f version=B -f source_sha=FULL_ARTIFACT_SOURCE_SHA
```

## Manual fallback

After the formal release or published-release verification workflow's glibc and
both Alpine consumer jobs passed, retain a
verification record (B, source SHA, all eight package names and the four gate
booleans `public_assets_verified`, `registry_consumer_verified`,
`musl_amd64_verified`, `musl_arm64_verified`). Do not mark unrun checks true.
The successful gated upgrade job uploads `verified-release.json` as workflow
artifact `verified-toolchain-release-vB` even when cross-repository credentials
are absent. With a clean existing UI checkout:

```sh
gh run download SUCCESSFUL_RUN_ID --repo duskmoon-dev/duskmoon-bundler \
  --name verified-toolchain-release-vB --dir /tmp/verified-B
elixir scripts/upgrade-ui.exs B FULL_TOOLCHAIN_SHA /absolute/ui-checkout /tmp/verified-B/verified-release.json
```

The command independently verifies release provenance and actual registry
package bytes, applies the pin, resolves the actual lock and writes provenance.
It does not create a branch, commit, push or PR. Then run the UI's normal full
checks and production assets, inspect changes and use the reviewed PR workflow.
`--push` enables the automated branch/commit/push/PR path and must only be used
with authorized operational credentials. U remains untouched until a separately
reviewed UI version change and UI Release dispatch. No reverse trigger starts
another B release when the UI changes or fails.
