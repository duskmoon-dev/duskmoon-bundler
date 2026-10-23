# Duskmoon Hologram

This umbrella sub-application imports Hologram 0.12.2 from
<https://github.com/bartblast/hologram> at commit
`ccdf843fdc82ec270301832f24263095dd791658`.
The upstream Apache-2.0 license and attribution are preserved in `LICENSE`.

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
- Bundles remain standalone IIFEs with linked source maps and content hashes.
  Hashes use Duskmoon Bundler's eight lowercase hexadecimal characters. Asset
  discovery also accepts historical Hologram base32 hashes.
- Incremental compilation tracks the complete collected import graph, including
  imports optimized out of the emitted JavaScript.
- Chunk entries build independently through the native bundler. The upstream
  esbuild subprocess batching and Windows command-line limits no longer apply.
- The fork joins the synchronized nine-package B cohort at version 10.0.3.
  Its upstream source provenance remains Hologram 0.12.2. Packaging, publication,
  registry verification, and production consumer checks use the shared workflow.

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
dependencies through `duskmoon_npm` and runs the imported JavaScript suite
under Bun. Single-file runs use the same runtime, for example
`DUSKMOON_NATIVE_MODE=source MIX_ENV=dev mix test.js test/javascript/serializer_test.mjs`.
Nested feature, ecosystem, cluster, Cowboy and umbrella fixtures use this local
fork rather than fetching the original `:hologram` application.

See the [README](README.md) for the main entry point and the
[documentation index](docs/README.md) for design references and the historical
scope of imported benchmark reports.

## CI and releases

The root [CI workflow](../../.github/workflows/ci.yml) checks Elixir formatting,
warnings-as-errors compilation, the full umbrella/Elixir test suite, native OXC
checks, and the JavaScript suite under Bun. It supports push, pull requests, and
manual runs. The shared [release workflow](../../.github/workflows/release.yml)
uses the same version for all nine packages and publishes Hologram after its
toolchain dependencies. See the [release runbook](../../docs/releasing.md).
