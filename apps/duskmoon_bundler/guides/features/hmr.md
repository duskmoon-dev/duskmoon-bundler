# Hot Module Replacement

The file watcher monitors your asset and template directories and pushes updates to the browser over a WebSocket.

## What Gets Updated

| File type | Action |
| --- | --- |
| `.ts`, `.tsx`, `.js`, `.jsx`, `.vue`, `.svelte`, `.css` | Recompile, push update over WebSocket |
| `.ex`, `.heex`, `.eex` | Incremental Tailwind rebuild, CSS hot-swap |
| `.vue` (style-only change) | CSS hot-swap, no page reload |

The browser client auto-reconnects on disconnect and shows compilation errors as an overlay.

An entry module and its local imports keep the same vendor generation while loading,
even if installed dependencies change between concurrent requests. Previously emitted
vendor entries retain their shared chunks, so a loading graph keeps one instance of
singleton dependencies such as React. A fresh entry request selects the current
dependency generation without restarting the server.
Hot updates preserve the loaded module's vendor generation and original entry URL,
including when a local import cycle leads back to that entry.

## `import.meta.hot`

Each module served in dev mode includes an `import.meta.hot` object for granular HMR:

```javascript
let timer: ReturnType<typeof setInterval>

export function startClock(el: HTMLElement) {
  const update = () => { el.textContent = new Date().toLocaleTimeString() }
  update()
  timer = setInterval(update, 1000)
}

if (import.meta.hot) {
  import.meta.hot.dispose(() => clearInterval(timer))
  import.meta.hot.accept()
}
```

When a file changes, DuskmoonBundler walks the dev module graph upward to find the nearest module with `import.meta.hot.accept()`. Only that module is re-imported — no full page reload. If no boundary is found, the client falls back to `location.reload()`.

## API

- `accept()` — mark this module as an HMR boundary
- `accept(deps, cb)` — accept updates for specific dependencies
- `dispose(cb)` — clean up before the module is replaced (receives `data` for state transfer)
- `data` — persistent object that survives HMR updates (populated by `dispose`)
- `invalidate()` — force a full page reload
