import Config

config :hologram_cluster_tests, HologramClusterTestsWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: HologramClusterTests.PubSub,
  render_errors: [
    formats: [json: HologramClusterTestsWeb.ErrorJSON],
    layout: false
  ],
  url: [host: "localhost"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix,
  json_library: Jason,
  plug_init_mode: :runtime

import_config "#{config_env()}.exs"

config :duskmoon_bundler, :duskmoon_hologram,
  root: Path.expand("../assets", __DIR__),
  sources: ["js/**/*.{js,mjs,ts}"],
  ignore: ["js/vendor/**"],
  format: [bracket_spacing: false]
