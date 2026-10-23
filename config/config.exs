import Config

config :duskmoon_bundler, :lint,
  tsgolint: Path.expand("../node_modules/.bin/tsgolint", __DIR__),
  cwd: Path.expand("../apps/duskmoon_bundler", __DIR__)

config :duskmoon_hologram,
  debug_encoder: false,
  debug_parser: false,
  debug_transformer: false

import_config "#{config_env()}.exs"

# Scope JavaScript tooling to Hologram without changing the bundler app's sources.
config :duskmoon_bundler, :duskmoon_hologram,
  root: Path.expand("../apps/duskmoon_hologram", __DIR__),
  sources: [
    "assets/js/**/*.{js,mjs}",
    "benchmarks/javascript/**/*.{js,mjs}",
    "scripts/**/*.{js,mjs}",
    "test/javascript/**/*.{js,mjs}",
    "test/features/assets/js/**/*.{js,mjs}",
    "test/cluster/assets/js/**/*.{js,mjs}"
  ],
  ignore: ["assets/js/vendor/**"],
  format: [bracket_spacing: false],
  lint: [plugins: [], rules: %{"correctness" => :deny}]
