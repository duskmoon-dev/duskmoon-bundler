# Duskmoon Hologram documentation

This directory documents the local `:duskmoon_hologram` fork. Start with the
[README](../README.md) for installation and development commands and
[UPSTREAM.md](../UPSTREAM.md) for provenance and compatibility details.

The fork shares version 10.0.3 and the root workflows with the other eight
toolchain packages. `ci.yml` runs formatting, linting and compilation; `test.yml`
runs Elixir and Bun suites, pinned UI integration, and published-package checks.
Release reuses successful checks at the exact source/UI SHAs and calls separate
NIF target workflows. See the [release runbook](../../../docs/releasing.md).

## Fork conventions

- Elixir >= 1.18.0 and Erlang/OTP >= 28 are required. JavaScript tests run
  Mocha + jsdom under Bun (CI: 1.4.0), without Node.js or npm CLI.
- Dependencies and configuration use `:duskmoon_hologram`; public modules remain
  `Hologram.*`, the compiler remains `:hologram`, and routes remain `/hologram/`.
- JavaScript dependencies use `duskmoon_npm`; compilation uses
  `DuskmoonBundler.Builder`, replacing the upstream npm CLI and esbuild path.
- Native OXC formatting and linting replace Prettier and ESLint. Run the
  `duskmoon_hologram` profile from the umbrella root; vendored JavaScript is
  excluded. JSON/YAML/Markdown formatting is outside that profile's scope.
- Bundles remain standalone IIFEs with linked source maps. New content hashes
  are eight lowercase hexadecimal characters; discovery also accepts historical
  uppercase base32 hashes.

## Design references

- [Navigation payload wire format](navigation_payload_wire_format.md) preserves
  upstream measurements and their original source pins. These figures have not
  been remeasured with the native toolchain.
- [Erlang time functions porting strategy](erlang_time_functions_porting_strategy.md)
  describes browser-side time semantics; the newer server OTP requirement does
  not make browser clocks equivalent to BEAM clocks.

The imported benchmark reports under `../benchmarks/` are historical upstream
results, not measurements of this fork. This includes compiler bundling and
JavaScript dependency installation timings, whose implementations have changed.
Upstream website and bundled LLM references describe framework APIs; use the
local integration instructions for dependency names, requirements, and tooling.
