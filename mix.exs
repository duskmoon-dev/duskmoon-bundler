defmodule DuskmoonToolchain.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "10.1.10",
      elixir: ">= 1.18.0",
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:ex_unit, :iex, :mix, :wallaby]],
      deps: deps(),
      aliases: [setup: ["deps.get"], "package.stage": "cmd elixir scripts/stage-packages.exs"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", runtime: false, override: true},
      {:plug, "~> 1.20.4"},
      {:websock_adapter, "~> 0.16.6", hex: :gaoxy_websock_adapter, override: true}
    ]
  end
end
