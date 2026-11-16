# Changelog

## Unreleased

### Documentation

- Clarify that `scan/1` returns the complete sorted set of known candidates on
  each call, including candidates from new or changed files. `scan_files/2`
  returns newly discovered candidates.
- Document the existing precompiled NIF platforms and distinguish source builds
  from installations using precompiled artifacts.

### Tests

- Cover filesystem scanning, negated sources, repeated scans, file and glob
  discovery, and scanner recovery after invalid native inputs.
