defmodule App1.MixProject do
  use Mix.Project

  def application do
    [
      mod: {App1.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:app_2, in_umbrella: true},
      {:app_3, in_umbrella: true},
      {:gaoxy_http, "~> 0.12.2"},
      {:duskmoon_hologram, path: Path.expand("../../../../..", __DIR__)},
      {:jason, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:wallaby, "~> 0.30", only: :test}
    ]
  end

  defp elixirc_paths(:test) do
    ["app", "lib", "test/support"]
  end

  defp elixirc_paths(_env) do
    ["app", "lib"]
  end

  def project do
    [
      app: :app_1,
      build_path: "../../_build",
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      compilers: Mix.compilers() ++ [:hologram],
      config_path: "../../config/config.exs",
      deps: deps(),
      deps_path: "../../deps",
      elixir: "~> 1.0",
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: [Phoenix.CodeReloader],
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      version: "0.1.0"
    ]
  end
end
