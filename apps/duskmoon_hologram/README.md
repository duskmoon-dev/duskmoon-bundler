# Duskmoon Hologram

Duskmoon Hologram is the `:duskmoon_hologram` umbrella fork of
[Hologram](https://github.com/bartblast/hologram), based on the v0.12.4 release tag.
The fork version is 10.0.10, synchronized with the other eight toolchain packages.
It uses the Duskmoon native toolchain. See [UPSTREAM.md](UPSTREAM.md) for the
source commit, attribution, and compatibility details.

Build full-stack web apps entirely in Elixir. Hologram rebuilds the Elixir runtime in the browser, so your client-side code runs as Elixir, with no JavaScript framework and no JavaScript to write.

Upstream framework website: https://hologram.page

## What it looks like

```elixir
defmodule MyApp.CounterPage do
  use Hologram.Page

  route "/counter"

  layout MyApp.MainLayout

  def init(_params, component, _server) do
    put_state(component, :count, 0)
  end

  def template do
    ~HOLO"""
    <p>Count: {@count}</p>
    <button $click="increment">+1</button>
    """
  end

  def action(:increment, _params, component) do
    put_state(component, :count, component.state.count + 1)
  end
end
```

The action runs in the browser, so the count updates instantly with no server round-trip.

## Requirements and installation

Requires Elixir >= 1.18.0 and Erlang/OTP >= 28. Bun is used to run the
JavaScript test suite (CI pins Bun 1.4.0); Node.js and the npm CLI are not
required. Asset builds, formatting, and linting use native tools.

In another application in this umbrella, add:

```elixir
# mix.exs, deps/0
{:duskmoon_hologram, in_umbrella: true}
```

The Phoenix endpoint application also needs the Hologram compiler:

```elixir
# mix.exs, project/0
compilers: Mix.compilers() ++ [:hologram]
```

Configure the fork in the umbrella's `config/`:

```elixir
config :duskmoon_hologram, client_stacktraces: true
```

Public modules remain `Hologram.*`, commands remain `mix holo` / `mix holo.*`,
and HTTP routes retain `/hologram/`. Do not load upstream `:hologram` alongside
this fork because they share module names. For standalone path dependencies,
see [local integration](UPSTREAM.md#local-integration).

Use the upstream [Quick Start](https://hologram.page/docs/quick-start) and
[architecture documentation](https://hologram.page/docs/architecture) for the
framework API and Phoenix router/runtime setup. Adapt their dependency and
configuration names as shown above; upstream installation and tooling
instructions do not apply verbatim to this fork.

## Development and JavaScript tooling

Run from the **Duskmoon Bundler umbrella root**:

```sh
mix deps.get
DUSKMOON_NATIVE_MODE=source mix compile --warnings-as-errors
DUSKMOON_NATIVE_MODE=source mix test --timeout 300000 apps/duskmoon_hologram/test/elixir
DUSKMOON_NATIVE_MODE=source MIX_ENV=dev mix test.js
DUSKMOON_NATIVE_MODE=source mix duskmoon_bundler.js.format duskmoon_hologram
DUSKMOON_NATIVE_MODE=source mix duskmoon_bundler.js.check duskmoon_hologram
```

The root `ci.yml` checks formatting, linting and compilation. `test.yml` runs the
Elixir and JavaScript suites, including asset dependency installation before
the Elixir tests. Release checks prior successful results for its exact source
and pinned UI revisions; it builds and publishes without rerunning these tests.
Published-package consumer checks run afterward in `test.yml`.

`mix test.js` runs the existing Mocha + jsdom suite through Bun, using
`bun --bun run mocha` to force the Bun runtime. It does not use `bun test`.

The Hologram app's `setup` alias and umbrella-root `mix test.js` install
JavaScript dependencies from the committed lockfiles through `duskmoon_npm`,
without rewriting them or using the npm CLI.
`duskmoon_bundler` builds standalone IIFEs with linked source maps instead of
esbuild. Its native OXC formatter and linter replace Prettier and ESLint. The
`duskmoon_hologram` profile covers runtime code, tests, benchmarks, and scripts,
excludes vendored JavaScript, and treats correctness lint findings as errors.
Formatting covers JS/TS, not JSON, YAML, or Markdown.

The app's `format.js`, `format.js.check`, and `lint.js` aliases use the same
profile; `format.js.check` also checks lint findings. Prefer the explicit root
commands above to keep the umbrella dependency context.

See the [documentation index](docs/README.md) and
[integration notes](UPSTREAM.md).

## Community

- Elixir Forum: https://elixirforum.com/hologram
- Discord: https://discord.gg/huJWNuqt8J
- Slack: https://elixir-lang.slack.com/channels/hologram

## Build in Public

- LinkedIn: https://www.linkedin.com/in/bartblast/
- X: https://x.com/Bart_Blast
- Bluesky: https://bsky.app/profile/bartblast.com
