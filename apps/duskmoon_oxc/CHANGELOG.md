# Changelog

## Unreleased

### Changed

- Raise `ArgumentError` for unknown output formats or JSX runtimes, invalid
  `define` maps, invalid target value types, and unknown `OXC.Bundle.new/1`
  options instead of silently substituting defaults or ignoring options.
  Unsupported target strings return compilation errors.
- Validate formatter `print_width` in `1..320` and `tab_width` in `0..24`, raising
  `ArgumentError` for invalid values. Correct the documented default line width
  to 100 and remove documentation for unsupported formatter options.
- Reject overlapping source patches with `ArgumentError`, while retaining
  first-patch precedence for duplicate ranges and supporting insertions at the
  start of a replacement.

### Fixed

- Preserve configured lint severity for `jsx_a11y`, `react_perf`, and `nextjs`
  rules instead of incorrectly reporting denied rules as warnings.
- Read the type-aware linter executable from `:duskmoon_oxc` configuration,
  retaining the legacy `:oxc` fallback. Keep temporary source payloads in a private
  directory and clean them up after execution.
- Preserve atom-keyed sourcemap results and normalize `OXC.Bundle.run/1` errors
  to maps with a `:message` field; return structured bundle warnings.
- Generate numeric literals and property keys above the signed 64-bit range
  instead of substituting zero, and reject AST numeric literals without a numeric
  value.
- Render bundle preambles through Rolldown's format-aware intro, preserving their
  placement inside IIFE wrappers and accounting for them in source maps.

### Documentation

- Document the bundle configuration API and the existing precompiled platforms,
  including Windows and FreeBSD.
