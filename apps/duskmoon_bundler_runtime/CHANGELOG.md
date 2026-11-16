# Changelog

## Unreleased

### Added
- New `duskmoon_bundler_runtime` package for production-safe manifest reading,
  static path resolution, and modulepreload tag generation.

### Fixed

- Reuse parsed production manifests only while their exact file contents match.
  Same-second rebuilds and atomic replacements with unchanged size and timestamps
  now refresh asset URLs correctly.
- Log invalid JSON and unsupported manifest versions when `static_path` falls
  back to an unhashed path. Missing manifests and unmanaged assets retain their
  silent fallback behavior.
