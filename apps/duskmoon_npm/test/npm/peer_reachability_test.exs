defmodule NPM.PeerReachabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @react "@fixture-peer/react"
  @react_dom "@fixture-peer/react-dom"
  @scheduler "@fixture-peer/scheduler"
  @widget "@fixture-peer/widget"
  @types "@fixture-peer/types"
  @absent "@fixture-peer/absent"

  setup do
    old_cwd = File.cwd!()
    old_cache_dir = Application.get_env(:duskmoon_npm, :cache_dir)
    old_link_strategy = System.get_env("NPM_EX_LINK_STRATEGY")
    System.delete_env("NPM_EX_LINK_STRATEGY")

    tmp_dir = Path.join(System.tmp_dir!(), "npm_peer_test_#{System.unique_integer([:positive])}")
    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(project_dir)
    Application.put_env(:duskmoon_npm, :cache_dir, Path.join(tmp_dir, "cache-root"))
    File.cd!(project_dir)

    on_exit(fn ->
      File.cd!(old_cwd)

      if old_cache_dir,
        do: Application.put_env(:duskmoon_npm, :cache_dir, old_cache_dir),
        else: Application.delete_env(:duskmoon_npm, :cache_dir)

      if old_link_strategy, do: System.put_env("NPM_EX_LINK_STRATEGY", old_link_strategy)
      File.rm_rf!(tmp_dir)
    end)

    original = peer_fixture!()
    capture_io(fn -> assert :ok = NPM.install(frozen: true) end)
    assert File.read!("package-lock.json") == original

    {:ok, original: original}
  end

  test "plain install keeps peer-only and optional peer records", context do
    output = capture_io(fn -> assert :ok = NPM.install() end)

    assert output =~ "Already up to date."
    assert File.read!("package-lock.json") == context.original
    assert File.exists?(Path.join(["node_modules", @react, "package.json"]))
    assert File.exists?(Path.join(["node_modules", @types, "package.json"]))
  end

  test "removing the peer consumer prunes it and its peer-only dependency", context do
    {:ok, root} = NPM.JSON.read_file("package.json")
    write_json!("package.json", update_in(root, ["dependencies"], &Map.delete(&1, @react_dom)))

    capture_io(fn -> assert :ok = NPM.install() end)
    assert {:ok, lock} = NPM.JSON.read_file("package-lock.json")
    original = NPM.JSON.decode!(context.original)

    for name <- [@react_dom, @react, @scheduler],
        do: refute(Map.has_key?(lock["packages"], "node_modules/#{name}"))

    for name <- [@widget, @types] do
      location = "node_modules/#{name}"
      assert lock["packages"][location] == original["packages"][location]
    end

    refute File.exists?(Path.join("node_modules", @react))
    written = File.read!("package-lock.json")
    output = capture_io(fn -> assert :ok = NPM.install() end)
    assert output =~ "Already up to date."
    assert File.read!("package-lock.json") == written
  end

  test "peer metadata round-trips through the lockfile writer" do
    assert {:ok, flat} = NPM.Lockfile.read()
    assert %{peer_dependencies: %{@react => "^18.0.0"}} = flat[@react_dom]
    assert %{peer: true} = flat[@react]

    assert %{peer_dependencies_meta: %{@types => %{"optional" => true}}} = flat[@widget]

    assert :ok = NPM.Lockfile.write(flat)
    assert {:ok, ^flat} = NPM.Lockfile.read()
  end

  defp peer_fixture! do
    write_json!("package.json", %{
      "name" => "peer-root",
      "dependencies" => %{@react_dom => "^18.0.0", @widget => "^1.0.0"}
    })

    flat = %{
      @react_dom =>
        entry(@react_dom, "18.2.0",
          dependencies: %{@scheduler => "^0.23.0"},
          peer_dependencies: %{@react => "^18.0.0"}
        ),
      @scheduler => entry(@scheduler, "0.23.0"),
      @react => entry(@react, "18.2.0", peer: true),
      @widget =>
        entry(@widget, "1.0.0",
          peer_dependencies: %{@types => "*", @absent => "*"},
          peer_dependencies_meta: %{
            @types => %{"optional" => true},
            @absent => %{"optional" => true}
          }
        ),
      @types => entry(@types, "18.0.0", peer: true)
    }

    Enum.each(flat, fn {name, entry} -> write_cached_package!(name, entry.version) end)
    assert :ok = NPM.Lockfile.write(flat)
    File.read!("package-lock.json")
  end

  defp entry(name, version, opts \\ []) do
    %{
      version: version,
      integrity: "",
      tarball: "https://registry.npmjs.org/#{name}/-/#{Path.basename(name)}-#{version}.tgz",
      dependencies: Keyword.get(opts, :dependencies, %{}),
      optional_dependencies: %{},
      has_install_script: false
    }
    |> Map.merge(Map.new(Keyword.drop(opts, [:dependencies])))
  end

  defp write_cached_package!(name, version) do
    cache_path = NPM.Cache.package_dir(name, version)
    File.mkdir_p!(cache_path)
    write_json!(Path.join(cache_path, "package.json"), %{"name" => name, "version" => version})
    File.write!(Path.join(cache_path, ".npm-ex-cache-complete"), "1\n")
  end

  defp write_json!(path, data), do: File.write!(path, NPM.JSON.encode_pretty(data))
end
