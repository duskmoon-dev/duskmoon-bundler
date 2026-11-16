defmodule NPM.PackumentCache do
  @moduledoc """
  Disk cache for npm registry packuments.

  Registry packuments are fetched frequently during dependency resolution.
  Caching them under `NPM.Cache.dir()/packuments` reduces repeat network
  requests while keeping the cache short-lived enough to pick up newly published
  versions during normal development.

  The TTL defaults to one hour and can be configured with
  `config :duskmoon_npm, :packument_cache_ttl`.
  """

  @default_ttl_seconds 3600

  def dir do
    Path.join(NPM.Cache.dir(), "packuments")
  end

  @doc """
  Read a cached packument fetched from `registry`.

  Entries are keyed by registry as well as package name, so metadata served by
  one registry is never reused for another. `registry` defaults to the
  registry configured for the package. With `full: true`, abbreviated and
  legacy cache entries are misses so publication timestamps can be fetched.
  A successful full response is reusable even when a registry omits timestamps.
  """
  @spec get(String.t(), String.t() | nil, keyword()) :: {:ok, term()} | :miss
  def get(package, registry \\ nil, opts \\ []) do
    path = path_for(package, registry)

    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- System.os_time(:second) - mtime < ttl(),
         {:ok, data} <- File.read(path) do
      data
      |> :erlang.binary_to_term([:safe])
      |> cached_packument(Keyword.get(opts, :full, false))
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Cache a packument fetched from `registry`.

  The default assumes complete metadata. Registry clients fetching abbreviated
  metadata must pass `full: false`; the acquisition mode is stored separately
  from the returned packument and preserved even when timestamps are absent.
  """
  @spec put(String.t(), term(), String.t() | nil, keyword()) :: :ok
  def put(package, packument, registry \\ nil, opts \\ []) do
    path = path_for(package, registry)
    tmp_path = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"
    File.mkdir_p!(Path.dirname(path))

    try do
      cached = {:npm_packument_cache, Keyword.get(opts, :full, true), packument}
      File.write!(tmp_path, :erlang.term_to_binary(cached))
      File.rename!(tmp_path, path)
    after
      File.rm(tmp_path)
    end

    :ok
  end

  defp cached_packument({:npm_packument_cache, fetched_full?, packument}, needs_full?)
       when is_boolean(fetched_full?) do
    if needs_full? and not fetched_full?, do: :miss, else: {:ok, packument}
  end

  defp cached_packument(_legacy_packument, true), do: :miss
  defp cached_packument(legacy_packument, false), do: {:ok, legacy_packument}

  defp path_for(package, registry) do
    encoded = String.replace(package, "/", "__")
    registry = registry || NPM.Config.registry_for(package)
    Path.join([dir(), registry_key(registry), "#{encoded}.etf"])
  end

  defp registry_key(registry) do
    :crypto.hash(:sha256, String.trim_trailing(registry, "/"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp ttl do
    Application.get_env(:duskmoon_npm, :packument_cache_ttl, @default_ttl_seconds)
  end
end
