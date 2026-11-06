# Dependency Workflows

## Add packages

```bash
mix npm.install lodash
mix npm.install lodash@^4.17
mix npm.install @types/node@^20
```

By default packages are saved to `dependencies`.

Ordinary installs and additions preserve satisfiable locked versions and their
package metadata, including workspace-local and nested records. Only new
requirements and conflicting dependency edges are resolved. Use the update
commands below when you intend to refresh locked versions.

Ordinary and frozen installs resolve declarations from each manifest's package
location. A workspace's exact pin can coexist with a different hoisted version
used by a broader transitive requirement. Repeating an install or reconstructing
`node_modules` preserves the existing lockfile bytes when that graph is valid.

## Development dependencies

```bash
mix npm.install eslint --save-dev
```

Development dependencies are skipped during production installs:

```bash
mix npm.install --production
```

## Exact versions

```bash
mix npm.install lodash --save-exact
```

Without `--save-exact`, npm_ex uses npm-style semver ranges when adding registry packages.

## Remove packages

```bash
mix npm.remove lodash
```

`mix npm.uninstall` is also available as an alias.

## Update packages

Update all packages within their configured ranges:

```bash
mix npm.update
```

Update one package:

```bash
mix npm.update lodash
```

This refreshes the named package while retaining other satisfiable locked
versions. A failed resolution leaves the previous lockfile intact.

## Inspect dependencies

```bash
mix npm.list
mix npm.tree
mix npm.why accepts
mix npm.outdated
mix npm.deprecations
mix npm.licenses
```

## Fetch from lockfile

If `package-lock.json` already exists, fetch and link locked packages without re-resolving:

```bash
mix npm.get
```

## Clean installed packages

```bash
mix npm.clean
```

This removes `node_modules/`. The global cache is left intact.

## Cache maintenance

```bash
mix npm.cache status
mix npm.cache clean
```

Downloaded packages are cached globally so repeated installs across projects reuse the same package contents.
