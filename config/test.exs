import Config
config :logger, level: :warning
config :duskmoon_bundler, file_system_backend: :fs_poll, file_system_interval: 50
config :duskmoon_npm, registry: "https://registry.npmjs.org"
