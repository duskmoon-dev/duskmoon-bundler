defmodule DuskmoonBundler.Cache do
  @moduledoc """
  ETS-backed module cache keyed by path.

  Caches compiled output so repeated requests for unchanged files
  skip the compilation step entirely.

  Keys are strings of the form `file_path` or `file_path <> "?" <> variant`.
  They are stored as `{file_path, variant}` so every variant of a file can be
  matched without scanning the table.
  """

  @table :duskmoon_bundler_cache

  @type entry :: DuskmoonBundler.DevServer.CacheEntry.t()

  @typedoc "Source fingerprint the entry was compiled from (e.g. a content hash)."
  @type version :: term()

  @type cache_entry :: %{version: version(), entry: entry()}

  @doc "Create the cache ETS table. Called once from Application.start/2."
  @spec create_table :: :ok
  def create_table, do: DuskmoonBundler.ETS.create_named_set(@table)

  @doc "Look up a cached entry compiled from `version`. Returns `nil` on miss."
  @spec get(String.t(), version()) :: entry() | nil
  def get(path, version) do
    case :ets.lookup(@table, key(path)) do
      [{_key, %{version: ^version, entry: entry}}] -> entry
      _ -> nil
    end
  end

  @doc "Look up any cached entry for a file path regardless of version."
  @spec get_file(String.t()) :: entry() | nil
  def get_file(path) do
    {file, _variant} = key = key(path)

    case :ets.lookup(@table, key) do
      [{_key, %{entry: entry}}] ->
        entry

      [] ->
        case :ets.match_object(@table, {{file, :_}, :_}, 1) do
          {[{_key, %{entry: entry}}], _continuation} -> entry
          _ -> nil
        end
    end
  end

  @doc "Store a compiled entry."
  @spec put(String.t(), version(), entry()) :: :ok
  def put(path, version, entry) do
    :ets.insert(@table, {key(path), %{version: version, entry: entry}})
    :ok
  end

  @doc "Evict the entry for a cache key."
  @spec evict(String.t()) :: :ok
  def evict(key) do
    :ets.delete(@table, key(key))
    :ok
  end

  @doc "Evict all cache entries derived from a file path, including variant keys like `path <> \"?import\"`."
  @spec evict_file(String.t()) :: :ok
  def evict_file(path) do
    {file, _variant} = key(path)
    :ets.match_delete(@table, {{file, :_}, :_})
    :ok
  end

  @doc """
  Evict all cache entries for files with the given extension (e.g. `".css"`).

  Used when a change can affect files other than the edited one, such as a CSS
  partial inlined into every stylesheet that `@import`s it.
  """
  @spec evict_extension(String.t()) :: :ok
  def evict_extension(extension) do
    @table
    |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.each(fn file ->
      if Path.extname(file) == extension, do: :ets.match_delete(@table, {{file, :_}, :_})
    end)

    :ok
  end

  @doc "Clear all cached entries."
  @spec clear :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp key(path) do
    case :binary.split(path, "?") do
      [file, variant] -> {file, variant}
      [file] -> {file, ""}
    end
  end
end
