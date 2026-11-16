defmodule NPM.PackumentCacheTest do
  use ExUnit.Case, async: false

  alias NPM.PackumentCache

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_app = Map.new([:cache_dir, :registry], &{&1, Application.get_env(:duskmoon_npm, &1)})
    old_env = Map.new(~w(NPM_REGISTRY NPM_EX_CACHE_DIR HOME), &{&1, System.get_env(&1)})
    old_cwd = File.cwd!()

    System.delete_env("NPM_REGISTRY")
    System.delete_env("NPM_EX_CACHE_DIR")
    System.put_env("HOME", tmp_dir)
    File.cd!(tmp_dir)
    Application.put_env(:duskmoon_npm, :cache_dir, Path.join(tmp_dir, "cache-root"))
    Application.put_env(:duskmoon_npm, :registry, "https://registry-a.example")

    on_exit(fn ->
      File.cd!(old_cwd)
      Enum.each(old_env, fn {k, v} -> restore_env(k, v) end)
      Enum.each(old_app, fn {k, v} -> restore_app_env(k, v) end)
    end)

    :ok
  end

  defp packument(name), do: %{name: name, versions: %{}, dist_tags: %{}}

  defp cache_files, do: Path.wildcard(Path.join(PackumentCache.dir(), "**/*"), match_dot: true)

  test "round-trips a packument for the same registry" do
    assert :ok = PackumentCache.put("react", packument("react"))
    assert {:ok, %{name: "react"}} = PackumentCache.get("react")
    assert :ok = PackumentCache.put("@scope/pkg", packument("@scope/pkg"))
    assert {:ok, %{name: "@scope/pkg"}} = PackumentCache.get("@scope/pkg")
  end

  test "full requests upgrade abbreviated metadata and complete responses serve either mode" do
    metadata = packument("private-without-timestamps")
    registry = "https://registry-a.example"
    assert :ok = PackumentCache.put("private", metadata, registry, full: false)
    assert {:ok, ^metadata} = PackumentCache.get("private", registry)
    assert :miss = PackumentCache.get("private", registry, full: true)

    assert :ok = PackumentCache.put("private", metadata, registry, full: true)
    assert {:ok, ^metadata} = PackumentCache.get("private", registry, full: true)
    assert {:ok, ^metadata} = PackumentCache.get("private", registry)
  end

  test "legacy entries remain readable but do not satisfy requests for full metadata" do
    metadata = packument("legacy")
    assert :ok = PackumentCache.put("legacy", metadata)
    [file] = Enum.filter(cache_files(), &File.regular?/1)
    File.write!(file, :erlang.term_to_binary(metadata))

    assert {:ok, ^metadata} = PackumentCache.get("legacy")
    assert :miss = PackumentCache.get("legacy", nil, full: true)
  end

  test "does not reuse a packument cached from a different registry" do
    assert :ok = PackumentCache.put("react", packument("from-registry-a"))

    Application.put_env(:duskmoon_npm, :registry, "https://registry-b.example")
    assert :miss = PackumentCache.get("react")

    assert :ok = PackumentCache.put("react", packument("from-registry-b"))
    assert {:ok, %{name: "from-registry-b"}} = PackumentCache.get("react")

    Application.put_env(:duskmoon_npm, :registry, "https://registry-a.example")
    assert {:ok, %{name: "from-registry-a"}} = PackumentCache.get("react")
  end

  test "separates registries that share an origin but differ in path" do
    assert :ok = PackumentCache.put("react", packument("a"), "https://nexus.example/repo/a")
    assert :miss = PackumentCache.get("react", "https://nexus.example/repo/b")
    assert {:ok, %{name: "a"}} = PackumentCache.get("react", "https://nexus.example/repo/a/")
  end

  test "decodes cache files in safe mode" do
    assert :ok = PackumentCache.put("react", packument("react"))
    [file] = Enum.filter(cache_files(), &File.regular?/1)

    atom_name = "npm_packument_cache_unknown_atom_#{System.unique_integer([:positive])}"
    # SMALL_ATOM_UTF8_EXT for an atom that does not exist in this VM.
    File.write!(file, <<131, 119, byte_size(atom_name)>> <> atom_name)

    assert :miss = PackumentCache.get("react")
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "replaces entries atomically without leaving temp files" do
    assert :ok = PackumentCache.put("react", packument("old"))
    [file] = Enum.filter(cache_files(), &File.regular?/1)
    # A rename replaces the entry even when the old file is not writable;
    # an in-place write would fail here.
    File.chmod!(file, 0o444)

    assert :ok = PackumentCache.put("react", packument("new"))
    assert {:ok, %{name: "new"}} = PackumentCache.get("react")
    assert Enum.filter(cache_files(), &File.regular?/1) == [file]
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
