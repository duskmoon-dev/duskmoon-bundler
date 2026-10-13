import Config

config :duskmoon_bundler, :lint,
  tsgolint: Path.expand("../node_modules/.bin/tsgolint", __DIR__),
  cwd: Path.expand("../apps/duskmoon_bundler", __DIR__)

import_config "#{config_env()}.exs"
