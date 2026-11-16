defmodule DuskmoonBundler.DevServer.ConfigCache do
  @moduledoc false
  @table :duskmoon_bundler_dev_config
  @files ~w(tsconfig.json .env .env.local .env.development .env.development.local)

  def create_table, do: DuskmoonBundler.ETS.create_named_set(@table)

  # Read the small configuration files to detect same-size, same-second saves.
  # Cache parsing and dotenv expansion, not source graphs or package discovery:
  # those must still see edits when a consumer runs without our Watcher.
  def fetch(opts, resolve, root \\ File.cwd!()) do
    if :ets.whereis(@table) == :undefined do
      resolve.()
    else
      key = {root, opts}
      signature = signature(root)

      case :ets.lookup(@table, key) do
        [{^key, ^signature, config}] -> config
        _ -> resolve_and_cache(key, signature, resolve, root)
      end
    end
  end

  defp resolve_and_cache(key, signature, resolve, root) do
    config = resolve.()

    if signature == signature(root) do
      if :ets.info(@table, :size) >= 128, do: :ets.delete_all_objects(@table)
      :ets.insert(@table, {key, signature, config})
    end

    config
  end

  defp signature(root) do
    files = Enum.map(@files, &File.read(Path.join(root, &1)))
    application = Application.get_all_env(:duskmoon_bundler) |> Enum.sort()
    environment = System.get_env()
    :crypto.hash(:sha256, :erlang.term_to_binary({files, application, environment}))
  end
end
