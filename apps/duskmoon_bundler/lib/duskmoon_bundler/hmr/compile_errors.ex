defmodule DuskmoonBundler.HMR.CompileErrors do
  @moduledoc false

  alias DuskmoonBundler.ETS

  @table :duskmoon_bundler_compile_errors
  @registry DuskmoonBundler.HMR.Registry

  def create_table, do: ETS.create_named_set(@table)

  # Request-specific vendor generations must share the endpoint's error scope.
  # Other compile options remain part of the identity so separate endpoints do
  # not receive each other's errors.
  def scope(config) do
    config
    |> Map.drop([:vendor_hash, :vendor_entry])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  def subscribe(scope), do: Registry.register(@registry, {:compile_errors, scope}, nil)

  def put(scope, key, file, version, reason) do
    # Compilations can finish out of order. Keep each source version separate
    # so a late old result cannot overwrite the current source's error.
    ETS.put(@table, {{scope, key, version}, file, reason})

    Registry.dispatch(@registry, {:compile_errors, scope}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:duskmoon_bundler_compile_error, key, version})
      end
    end)
  end

  def clear(scope, key, version) do
    ETS.delete(@table, {scope, key, version})
  end

  def replay(scope) do
    for {{^scope, key, version}, _file, _reason} <-
          :ets.match_object(@table, {{scope, :_, :_}, :_, :_}) do
      send(self(), {:duskmoon_bundler_compile_error, key, version})
    end
  end

  def get(scope, key, version) do
    case :ets.lookup(@table, {scope, key, version}) do
      [{_, file, reason} = row] ->
        if current_source?(file, version) do
          %{reason: reason}
        else
          # A save, deletion or successful compile can supersede a queued
          # error. Delete only this row, never a concurrent newer error.
          :ets.delete_object(@table, row)
          nil
        end

      _ ->
        nil
    end
  end

  defp current_source?(file, version) do
    case File.read(file) do
      {:ok, source} -> :crypto.hash(:sha256, source) == version
      {:error, _} -> false
    end
  end
end
