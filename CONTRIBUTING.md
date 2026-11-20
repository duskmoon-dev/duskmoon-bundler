# Contributing

Read [AGENTS.md](AGENTS.md) for the synchronized nine-package contract. Use
the repository's `direnv`/`devenv` environment, Bun for JavaScript dependencies,
and `DUSKMOON_NATIVE_MODE=source` for native development. The Rust toolchain is
pinned in `rust-toolchain.toml`; native target/NIF ABI and portable CPU flags
must remain compatible with published consumers.

Before submitting a change, run `mix format --check-formatted`,
`mix compile --warnings-as-errors` and the affected ExUnit suites. Add a
regression for behavioral fixes. Run `bun run test` for the workspace tests;
Hologram's JavaScript suite uses `MIX_ENV=dev mix test.js`. Its five nested
integration suites have separate requirements documented in
[UPSTREAM.md](apps/duskmoon_hologram/UPSTREAM.md).

JavaScript formatting and linting use `mix duskmoon_bundler.js.format` and
`mix duskmoon_bundler.js.check`, backed by OXC. There is no separate Biome
configuration. CI also checks actionlint, native helper copies and Rust Clippy.
The scheduled/manual quality workflow runs dependency audits, Credo and
Dialyzer. The root Credo policy disables module-documentation, TODO-tag,
function-arity, parameter-pattern position, predicate-naming, implicit-try,
conditional-form, cyclomatic-complexity and nesting-depth style checks.
Dialyzer excludes opaque-type checks because MapSet literals and the tested
internal solver cohort contract otherwise produce representation warnings.
All other checks, dependency audits and behavioral tests remain enabled.

Record user-visible changes in the root and affected app's `Unreleased`
CHANGELOG sections. Package staging copies the cohort history into each
package while retaining upstream history. See [releasing.md](docs/releasing.md)
for publication and recovery; stage outside the checkout.

Report security issues using [SECURITY.md](SECURITY.md).
