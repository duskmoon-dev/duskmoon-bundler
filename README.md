# Duskmoon Bundler

Independent Elixir toolchain for frontend assets, native JS/CSS compilers, and the QuickBEAM runtime. The eight Hex packages retain their existing names and namespaces: `duskmoon_bundler`, `duskmoon_bundler_runtime`, `duskmoon_oxc`, `duskmoon_oxide`, `duskmoon_vize`, `duskmoon_quickbeam`, `duskmoon_npm`, and `duskmoon_hex_solver`.

The synchronized toolchain version is **10.0.1**. All eight packages and their native artifacts are released from this repository. Earlier packages retain their native downloads from historical UI releases. UI version U is maintained independently in `phoenix-duskmoon-ui`.

## Development

Use `devenv shell` for the Elixir/OTP, Rust, Zig, Bun and Tailwind toolchains. Development explicitly builds candidate native sources; the ordinary UI consumer requires published artifacts.

```sh
bun install --frozen-lockfile
mix deps.get
DUSKMOON_NATIVE_MODE=source mix compile --warnings-as-errors
DUSKMOON_NATIVE_MODE=source mix test
bun test test/js
elixir scripts/native-policy-test.exs
elixir scripts/package-stage-test.exs
elixir scripts/native-download-failure-test.exs
```

`DUSKMOON_NATIVE_MODE=source` selects all five Rust crates and QuickBEAM sources. `precompiled` requires verified downloads and rejects legacy source flags, Rustler/Zigler force-build configuration, and `-dev` versions which the pinned download libraries interpret as source builds. Without the mode variable, legacy explicit source flags still work; no umbrella build-path heuristic remains. Missing downloads and checksum errors raise through the pinned precompiled libraries without source fallback.

Runtime-only Phoenix applications can use `duskmoon_bundler_runtime` without the compiler family. The package preserves `manifest_version = 1` and historical manifest behavior.

## Package staging

```sh
elixir scripts/stage-packages.exs --version 10.0.1 --output /tmp/bundler-packages
elixir scripts/package-consumer-smoke.exs --stage /tmp/bundler-packages --mode source
```

Staging refuses existing output directories and outputs inside this checkout. Each app becomes a standalone source package with local umbrella paths removed and internal requirements pinned to `== B`; optional/runtime/environment flags are retained. `manifest.json` records source commit/tree, dirty-state marker, lock hashes, package dependency graph and every staged file SHA-256. The isolated smoke consumer uses explicit path overrides for the complete eight-package candidate cohort and separate build/deps state. This source check is not proof of registry/precompiled installation. Use the strict lane only after native assets and matching checksums exist.

Historical assets must remain untouched. Future native URLs use `https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/vB`. Checksum files are generated from final native artifacts by release automation; candidate source staging deliberately does not fabricate them.

See [migration inventory](docs/migration-inventory.md), [progress](docs/extraction-progress.md), and the release runbook for bootstrap order and gates. The UI-only browser hook/chat/form regression stays in the UI repository; generic compiler, HMR, manifest and resolver coverage lives here.
