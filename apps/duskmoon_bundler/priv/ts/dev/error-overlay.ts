globalThis.renderErrorOverlay = function renderErrorOverlay(message: string) {
  console.error(`[DuskmoonBundler] Compilation error:\n${message}`)

  if (typeof document === 'undefined') {
    return
  }

  let overlay = document.getElementById('duskmoon_bundler-error-overlay')

  if (!overlay) {
    overlay = document.createElement('div')
    overlay.id = 'duskmoon_bundler-error-overlay'
    overlay.style.cssText =
      'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.85);color:#ff6b6b;font:14px/1.6 monospace;padding:2em;white-space:pre-wrap;overflow:auto;cursor:pointer'
    overlay.onclick = () => overlay?.remove()
    document.body.appendChild(overlay)
  }

  overlay.textContent = `[DuskmoonBundler] Compilation error:\n\n${message}`
}
