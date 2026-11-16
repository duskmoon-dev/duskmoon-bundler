# Changelog

## Unreleased

### Fixed

- Use the same pinned LightningCSS fork as the SFC compiler, removing the
  vulnerable `rkyv` 0.7 dependency (RUSTSEC-2026-0235) without changing the
  Elixir CSS API.
- Rebase CSS asset URLs from each imported stylesheet to the bundle entry
  directory before minification, preserving image/font paths and URL suffixes.
- Normalize imported stylesheet paths so cyclic imports terminate, preserving
  symlink asset aliases and filesystem semantics for parent traversal.
- Collect and rewrite other CSS URLs when an escaped URL cannot be mapped to a
  source byte range. Unrewritable URLs remain unchanged instead of failing the
  entire stylesheet.

### Documentation

- Document the existing legacy and structured error contracts without changing
  public return shapes, and correct the CSS bundle result type.
- Describe the atom-keyed `vapor_split/1` result and its recoverable diagnostics.
- Document the existing precompiled NIF platforms and distinguish source builds
  from installations using precompiled artifacts.

### Tests

- Cover CSS compilation, CSS Modules, URL rewriting, nested stylesheet imports,
  Vue SFC output, and template splitting.
- Cover repeated imports under multiple media conditions and cyclic imports,
  including asset URL rebasing before and after minification.
