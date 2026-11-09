# Changelog

## 10.1.6 - 2026-11-09

- Retry native artifact URL resolution with backoff, alternating to the
  `?download=1` release-download variant when GitHub returns a sticky 5xx for
  one asset URL; downloaded bytes are still checksum-verified (#22).

## 10.1.5 - 2026-11-09

- Prune npm lock records that are no longer reachable from root or workspace
  manifests after dependency removal, retaining peer-installed packages and
  keeping remaining records unchanged (#21).

## 10.1.4 - 2026-11-09

- Validate development `/@vendor/` specifiers and confine chunk reads to the
  vendor cache, closing a path traversal; key dev compile caches by content.
- Require every HMR importer path to reach a boundary, match fallback
  importers by full path, and store module graph links atomically.
- Harden npm installs: validate lockfile entries and package bins, scope auth
  tokens to trusted registries, enforce SRI integrity on downloads and cache
  hits, and strip setuid/setgid bits from extracted files.
- Report unparseable npm ranges, resolve dist-tags, and apply prerelease
  matching per requirement.
- Requeue QuickBEAM requests received during a pending await and make runtime
  shutdown interrupt running JavaScript.
- Run oxc, formatter, linter and vize NIFs on a 64 MiB stack; return errors for
  invalid oxide scan entries instead of poisoning the scanner.
- Pin release workflow actions, require release sources on main, and keep new
  GitHub releases as drafts until every asset is uploaded.

## 10.1.3 - 2026-11-08

- Refresh changed root and workspace npm lock metadata without re-resolving
  current dependencies; reject stale descriptors during frozen installs.
- Revalidate development vendor responses and share graph query parameters
  across relative imports, keeping cached entries on the current runtime.
- Rebuild stale lazy vendor graphs with newly discovered static entries so
  added imports retain shared dependency instances.

## 10.1.2 - 2026-11-07

- Release the standalone toolchain using its own source and published-consumer
  gates; make downstream UI compatibility an independent, manual workflow.
  Stop automatically opening UI upgrade pull requests.

- Upgrade the coordinated HTTP client family to 1.0.0-rc.4 and Gaoxy to 0.15.0,
  including standalone Hologram test projects.
- Refresh compatible Hex and JavaScript dependencies, OXC to 0.157, Rolldown
  to 1.3, Vize to 0.702 and Tailwind Oxide to 4.3.5.
- Preserve computed method receivers in the isolated JavaScript interpreter,
  including the current Vue SSR dependency graph.
- Retain owned NAPI callback results until their handle scope closes, fixing
  newer native addon initialization that reads returned objects.
- Validate ordinary npm installs from each manifest's actual package location,
  preserving valid workspace-local pins beside different hoisted versions.
- Keep repeated ordinary/frozen installs and node_modules reconstruction stable,
  and retain the existing split graph when adding another workspace dependency.

## 10.1.1 - 2026-11-06

- Preserve satisfiable locked npm dependency versions, locations, integrity,
  URLs and package metadata when adding workspace dependencies.
- Refresh only the named package during targeted npm updates, keep full updates
  explicit, and preserve the lockfile when resolution fails.

## 10.1.0 - 2026-11-05

- Upgrade source builds to Rust 1.99 and Rustler 0.38, OXC to 0.156
  (formatter/linter 0.157), Rolldown to 1.2.16, Tailwind Oxide to 4.3.4,
  and Vize to 0.680 while preserving NIF 2.15 and native target coverage.
- Upgrade Zig to 0.17.1 and Zigler to 0.17, and synchronize QuickBEAM with
  upstream 0.11.3, including QuickJS-NG 0.15.1, isolated BEAM execution,
  grapheme segmentation, and native lifecycle fixes.
- Align Hologram's JavaScript checks with the upgraded OXC tooling and preserve
  published native ABI compatibility in cold download probes.

## 10.0.10 - 2026-10-30

- Keep Hologram's npm and Hex solver build tools out of the production
  application closure while preserving asset compilation and development
  live reload.

## 10.0.9 - 2026-10-29

- Synchronize Hologram with upstream v0.12.4, including stale command/action
  protection, broadcast self echoes, response headers, keyboard event guards,
  and non-text binary comparisons.
- Install Hologram development assets from frozen lockfiles and update its
  standalone fixture security dependencies.
- Refresh locked dependencies while preserving the synchronized nine-package
  toolchain and native artifact contracts.

## 10.0.8 - 2026-10-26

- Apply environment defines, including `process.env.NODE_ENV`, to development
  source with scope-aware replacement that preserves local bindings.
- Keep page-only console forwarding, HMR connections, and style injection
  inactive in workers and imported modules while preserving normal page HMR.

## 10.0.7 - 2026-10-26

- Rewrite minified Worker and SharedWorker module URLs to the emitted hashed
  worker files, including static template literals produced by the minifier.

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
