defmodule DuskmoonToolchain.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "10.1.12",
      elixir: ">= 1.18.0",
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        plt_add_apps: [:ex_unit, :gaoxy_http, :iex, :mix, :wallaby, :zigler],
        flags: [:no_opaque]
      ],
      deps: deps(),
      aliases: [setup: ["deps.get"], "package.stage": "cmd elixir scripts/stage-packages.exs"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", runtime: false, override: true},
      {:gaoxy_http, "~> 0.16.6", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.20.4"},
      {:websock_adapter, "~> 0.16.6", hex: :gaoxy_websock_adapter, override: true}
    ]
  end
end
