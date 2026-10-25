# Changelog

## 10.0.6 - 2026-10-25

- Reuse development vendor discovery until the application import graph changes,
  avoiding repeated prebundle checks during Phoenix runtime Plug initialization.
- Reuse one dependency signature per vendor request and serve unchanged cached
  dependencies without waiting for optimizer or dependency revision locks.
- Preserve content-based dependency invalidation, shared vendor graphs, and
  browser cache-busting URLs after source or package changes.

## 10.0.2 - 2026-10-19

- Honor configured Tailwind source directories and patterns during development,
  including dependency sources outside the normal watch directories.
- Keep each development profile's Tailwind scanner and compiler independent so
  shared source updates reach every profile regardless of startup order.
- Regenerate styles after CSS-only edits and changes to configured sources such
  as HTML and Markdown files.
- Avoid rewriting unchanged generated styles when profiles watch each other's
  output directories.

## 10.0.1 - 2026-10-14

- Restore required OTP code paths after Mix dependency compilation before npm
  tasks use HTTPS, including when SSL applications are already running.
- Fail immediately when npm task HTTP bootstrap fails instead of reporting a
  later package download timeout.
- Default candidate package staging to the current toolchain cohort version.
- Rebuild Tailwind CSS and update browser styles when `.exs` templates such as
  Storybook variations change during development.

## 10.0.0 - 2026-10-14

- Release the eight Duskmoon toolchain Hex packages from the independent
  `duskmoon-dev/duskmoon-bundler` repository with synchronized versions.
- Publish native artifacts and checksums from this repository while preserving
  existing package names, module namespaces, target platforms and NIF ABI.
- Stage standalone packages with exact cohort dependency versions and verify
  source, precompiled, glibc and Alpine consumers before UI adoption.
- Keep the Phoenix UI release version independent of the toolchain version.
- Install the 10.x toolchain through the Igniter installer and documented
  dependency examples.
- Publish the verified Hex archives directly without resolving optional source
  toolchains or rebuilding package contents.
