defmodule DuskmoonBundler.Application do
  @moduledoc false
  use Application

  alias DuskmoonBundler.DevServer.ConfigCache
  alias DuskmoonBundler.HMR.{CompileErrors, GlobGraph, ImportGraph, ModuleGraph}
  alias DuskmoonBundler.JS.Vendor

  @impl true
  def start(_type, _args) do
    DuskmoonBundler.Cache.create_table()
    Vendor.create_table()
    ImportGraph.create_table()
    GlobGraph.create_table()
    ModuleGraph.create_table()
    CompileErrors.create_table()
    ConfigCache.create_table()

    children = [
      {Registry, keys: :duplicate, name: DuskmoonBundler.HMR.Registry},
      {DuskmoonBundler.Tailwind, DuskmoonBundler.Config.tailwind()}
    ]

    opts = [strategy: :one_for_one, name: DuskmoonBundler.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
