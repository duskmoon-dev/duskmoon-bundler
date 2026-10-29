defmodule Hologram.RuntimeDependenciesTest do
  use ExUnit.Case, async: true

  test "compiled runtime application closure excludes build tools" do
    applications = runtime_applications([:duskmoon_hologram], MapSet.new())

    for app <- [
          :duskmoon_bundler,
          :duskmoon_npm,
          :duskmoon_hex_solver,
          :duskmoon_oxc,
          :duskmoon_oxide,
          :duskmoon_quickbeam,
          :duskmoon_vize
        ] do
      refute MapSet.member?(applications, app), "#{app} must remain a build dependency"
    end
  end

  defp runtime_applications([], visited), do: visited

  defp runtime_applications([app | rest], visited) do
    if MapSet.member?(visited, app) do
      runtime_applications(rest, visited)
    else
      path = :code.where_is_file(String.to_charlist("#{app}.app"))
      assert path != :non_existing, "missing application manifest for #{app}"
      {:ok, [{:application, ^app, properties}]} = :file.consult(path)

      dependencies =
        Keyword.fetch!(properties, :applications) ++
          Keyword.get(properties, :included_applications, [])

      # Missing optional adapters are not included in a release's application closure.
      dependencies =
        Enum.reject(dependencies, fn dependency ->
          dependency in Keyword.get(properties, :optional_applications, []) and
            :code.where_is_file(String.to_charlist("#{dependency}.app")) == :non_existing
        end)

      runtime_applications(dependencies ++ rest, MapSet.put(visited, app))
    end
  end
end
