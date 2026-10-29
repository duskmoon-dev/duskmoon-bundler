# Duskmoon Hologram

This umbrella sub-application tracks the released Hologram
[v0.12.4 tag](https://github.com/bartblast/hologram/releases/tag/v0.12.4) at commit
`abe401764d112acbc482e115e1b162ff9831f4fe`.
The original import, `ccdf843fdc82ec270301832f24263095dd791658`, was a `dev`
snapshot reporting version 0.12.2, rather than the v0.12.2 release tag.
The upstream Apache-2.0 license and attribution are preserved in `LICENSE`.

## v0.12.4 synchronization

- Keyboard events without a key, including Chromium autofill events, are ignored
  instead of raising in `$key_down` or `$key_up` handlers.
- Non-text binaries compare and sort by their bytes, including equivalent binaries
  assembled with different segment boundaries.
- Response headers set by middleware, page/layout initialization or commands are
  applied to initial pages, client navigations and command replies. A `content-type`
  set on a response Hologram itself writes raises; middleware may set it on a
  terminal response. Navigation redirects discard the original content type when
  sending their JSON payload.
- Includes upstream unit/browser regressions and reference documentation.
  The root lockfile already contains upstream's `hackney` 4.9.1 security update
  and its transitive dependencies, so those entries are preserved.
- Unreleased changes, including `$focused`, remain outside this synchronization.

## v0.12.3 synchronization

- Command replies retain the page epoch from dispatch, so their next action is
  dropped after navigation. Commands dispatched during a page transition are
  dropped before sending; server effects of an already-sent command still apply.
- Command self echoes follow broadcast delivery: a shared layout can receive an
  echo after navigation, while targets absent from the current page are skipped.
- An asynchronous action that finishes after its page has been left has its
  entire result dropped, including state, chained actions, commands and navigation.
- The Hologram app's setup alias and JavaScript tests use `duskmoon_npm` frozen installs.
  The feature and umbrella fixture asset lockfiles are committed as well.
  Production compilation still permits a first install without a lockfile.
- The root lockfile already has upstream's `plug_crypto` 2.2.1 update; the five
  standalone test fixture lockfiles now use it too.
- Upstream regressions and reference documentation are synchronized, preserving
  local native bundling, OXC formatting, OTP naming and HTTP integrations.

## Local integration

- OTP application and configuration namespace: `:duskmoon_hologram`.
- Public modules remain `Hologram.*`; Mix tasks remain `holo`, `holo.*`, and
  `compile.hologram`. The compiler name remains `:hologram`, and telemetry events
  retain the `[:hologram, ...]` prefix.
- Requires Elixir >= 1.18.0 and Erlang/OTP >= 28.
- Uses the umbrella build, dependencies, lockfile, and configuration. Configure
  this app in the umbrella's `config/`, not the preserved upstream config files.
- JavaScript installation uses `duskmoon_npm` (`NPM.install/1`); builds use
  `DuskmoonBundler.Builder.build/1`. No npm CLI or esbuild binary is required.
  Bun runs the imported Mocha + jsdom JavaScript suite; Node.js is not needed.
  CI pins Bun 1.4.0 and the scripts force its runtime with `bun --bun`.
- Both `duskmoon_npm` and `duskmoon_bundler` are build dependencies
  (`runtime: false`). They remain available for asset compilation and development
  live reload without entering Hologram's production application closure.
- Bundles remain standalone IIFEs with linked source maps and content hashes.
  Hashes use Duskmoon Bundler's eight lowercase hexadecimal characters. Asset
  discovery also accepts historical Hologram base32 hashes.
- Incremental compilation tracks the complete collected import graph, including
  imports optimized out of the emitted JavaScript.
- Chunk entries build independently through the native bundler. The upstream
  esbuild subprocess batching and Windows command-line limits no longer apply.
- The fork joins the synchronized nine-package B cohort at version 10.0.3.
  Its upstream source baseline is the Hologram v0.12.4 release tag. Packaging,
  publication, registry verification, and production consumer checks use the shared workflow.

Use from another application in this umbrella:

```elixir
{:duskmoon_hologram, in_umbrella: true}
```

For a standalone local consumer, use a path dependency pointing at this app.
Also provide path overrides for `duskmoon_bundler` and its toolchain dependencies;
the source checkout intentionally uses `in_umbrella` dependencies.

Consumer configuration uses the new OTP name:

```elixir
config :duskmoon_hologram, client_stacktraces: true
```

Keep `compilers: Mix.compilers() ++ [:hologram]` in consumer projects. Existing
Hologram and this fork share module names and must not be loaded together.

## JavaScript tooling

ESLint and Prettier are replaced by the native OXC tooling in Duskmoon Bundler.
From the umbrella root, run:

```sh
mix duskmoon_bundler.js.format duskmoon_hologram
mix duskmoon_bundler.js.check duskmoon_hologram
```

The `duskmoon_hologram` profile scopes discovery to this app's JavaScript runtime,
tests, benchmarks and scripts, excludes vendored code, preserves the upstream
`bracketSpacing: false` preference, and treats correctness lint findings as errors.
`mix format.js`, `mix format.js.check` and `mix lint.js` are aliases inside the app.
The JavaScript formatter handles JS/TS; JSON/YAML/Markdown are outside its scope.

## Development

From the umbrella root:

```sh
mix deps.get
DUSKMOON_NATIVE_MODE=source mix compile --warnings-as-errors
DUSKMOON_NATIVE_MODE=source mix test --timeout 300000 apps/duskmoon_hologram/test/elixir
DUSKMOON_NATIVE_MODE=source MIX_ENV=dev mix test.js
```

Run these commands from the umbrella root so optional development dependencies
share the umbrella's dependency context. `mix test.js` installs JavaScript
dependencies through `duskmoon_npm` without rewriting the committed lockfile
and runs the imported JavaScript suite under Bun. Single-file runs use the same runtime, for example
`DUSKMOON_NATIVE_MODE=source MIX_ENV=dev mix test.js test/javascript/serializer_test.mjs`.
Nested feature, ecosystem, cluster, Cowboy and umbrella fixtures use this local
fork rather than fetching the original `:hologram` application.

See the [README](README.md) for the main entry point and the
[documentation index](docs/README.md) for design references and the historical
scope of imported benchmark reports.

## CI and releases

The root [CI workflow](../../.github/workflows/ci.yml) checks Elixir formatting,
warnings-as-errors compilation and native OXC formatting/linting. The separate
[test workflow](../../.github/workflows/test.yml) runs the full umbrella/Elixir
suite, Hologram Mocha under Bun and generic JavaScript tests. A manual test run
also accepts an immutable UI SHA for candidate integration. The shared
[release workflow](../../.github/workflows/release.yml) requires successful checks
for the exact source/UI SHAs, builds NIFs through eight target workflows, and
publishes Hologram after its toolchain dependencies without rerunning tests.
Published-package tests run afterward in `test.yml` and gate UI adoption.
See the [release runbook](../../docs/releasing.md).
