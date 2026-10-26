import { createHotContext as __duskmoon_bundler_createHotContext } from './hmr-client'

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  import.meta.hot = __duskmoon_bundler_createHotContext($mod_url)
}
