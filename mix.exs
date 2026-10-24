defmodule DuskmoonToolchain.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "10.0.4",
      elixir: ">= 1.18.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [setup: ["deps.get"], "package.stage": "cmd elixir scripts/stage-packages.exs"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", runtime: false, override: true},
      {:plug, "~> 1.19"},
      {:websock_adapter, "~> 0.12.2", hex: :gaoxy_websock_adapter, override: true}
    ]
  end
end
