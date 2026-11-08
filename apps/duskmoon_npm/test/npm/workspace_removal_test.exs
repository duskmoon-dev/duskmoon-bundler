defmodule NPM.WorkspaceRemovalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @alpha "@fixture-rm/alpha"
  @alpha_child "@fixture-rm/alpha-child"
  @beta "@fixture-rm/beta"
  @shared "@fixture-rm/shared"
  @nx "@fixture-rm/nx"
  @gamma "@fixture-rm/gamma"
  @gamma_child "@fixture-rm/gamma-child"

  setup do
    old_cwd = File.cwd!()
    old_cache_dir = Application.get_env(:duskmoon_npm, :cache_dir)
    old_link_strategy = System.get_env("NPM_EX_LINK_STRATEGY")
    System.delete_env("NPM_EX_LINK_STRATEGY")

    tmp_dir =
      Path.join(System.tmp_dir!(), "npm_removal_test_#{System.unique_integer([:positive])}")

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

    original = removal_fixture!(project_dir)
    capture_io(fn -> assert :ok = NPM.install(frozen: true) end)
    assert File.read!("package-lock.json") == original

    {:ok, project_dir: project_dir, original: original}
  end

  test "no manifest change keeps the fast path and lockfile bytes", context do
    output = capture_io(fn -> assert :ok = NPM.install() end)

    assert output =~ "Already up to date."
    assert File.read!("package-lock.json") == context.original
  end

  test "removing a root dependency prunes flat, nested and orphaned transitive records",
       context do
    update_package!(
      context.project_dir,
      &update_in(&1, ["dependencies"], fn deps -> Map.delete(deps, @alpha) end)
    )

    capture_io(fn -> assert :ok = NPM.install() end)

    assert_pruned!(context.original, [
      "node_modules/#{@alpha}",
      "node_modules/#{@alpha_child}",
      "node_modules/#{@alpha}/node_modules/#{@nx}"
    ])

    refute File.exists?(Path.join("node_modules", @alpha))
    refute File.exists?(Path.join("node_modules", @alpha_child))
    assert File.exists?(Path.join(["node_modules", @shared, "package.json"]))
    assert_frozen_and_idempotent!()
  end

  test "NPM.remove/1 prunes the removed dependency graph", context do
    capture_io(fn -> assert :ok = NPM.remove(@alpha) end)

    assert_pruned!(context.original, [
      "node_modules/#{@alpha}",
      "node_modules/#{@alpha_child}",
      "node_modules/#{@alpha}/node_modules/#{@nx}"
    ])

    assert_frozen_and_idempotent!()
  end

  test "removing a dependency from every workspace prunes it and refreshes descriptors",
       context do
    for workspace <- ["apps/web", "apps/admin"] do
      update_package!(
        workspace,
        &update_in(&1, ["dependencies"], fn deps -> Map.delete(deps, @gamma) end)
      )
    end

    capture_io(fn -> assert :ok = NPM.install() end)

    lock =
      assert_pruned!(context.original, [
        "node_modules/#{@gamma}",
        "node_modules/#{@gamma_child}"
      ])

    assert lock["packages"]["apps/web"]["dependencies"] == %{@shared => "^1.0.0"}
    refute Map.has_key?(lock["packages"]["apps/admin"], "dependencies")
    refute File.exists?(Path.join("node_modules", @gamma))
    assert_frozen_and_idempotent!()
  end

  test "a dependency still used by another workspace is retained", context do
    update_package!(
      "apps/web",
      &update_in(&1, ["dependencies"], fn deps -> Map.delete(deps, @gamma) end)
    )

    capture_io(fn -> assert :ok = NPM.install() end)

    lock = assert_pruned!(context.original, [])
    assert lock["packages"]["apps/web"]["dependencies"] == %{@shared => "^1.0.0"}
    assert File.exists?(Path.join(["node_modules", @gamma, "package.json"]))
    assert_frozen_and_idempotent!()
  end

  test "removing every dependency prunes all registry records", context do
    update_package!(context.project_dir, &Map.delete(&1, "dependencies"))

    for workspace <- ["apps/web", "apps/admin"],
        do: update_package!(workspace, &Map.delete(&1, "dependencies"))

    capture_io(fn -> assert :ok = NPM.install() end)

    registry_locations =
      context.original
      |> Jason.decode!()
      |> Map.fetch!("packages")
      |> Map.keys()
      |> Enum.filter(&String.contains?(&1, "node_modules/@fixture-rm/"))

    assert_pruned!(context.original, registry_locations)
    refute File.exists?(Path.join("node_modules", @shared))
    assert_frozen_and_idempotent!()
  end

  test "frozen install rejects a stale lock after a manifest removal", context do
    update_package!(
      context.project_dir,
      &update_in(&1, ["dependencies"], fn deps -> Map.delete(deps, @alpha) end)
    )

    capture_io(:stderr, fn -> assert {:error, :frozen_lockfile} = NPM.install(frozen: true) end)
    assert File.read!("package-lock.json") == context.original
  end

  test "ordinary install prunes unreachable records left behind with current descriptors",
       context do
    lock = Jason.decode!(context.original)

    stale =
      put_in(lock, ["packages", "node_modules/@fixture-rm/orphan"], %{
        "version" => "1.0.0",
        "resolved" => tarball("@fixture-rm/orphan", "1.0.0"),
        "integrity" => ""
      })

    File.write!("package-lock.json", NPM.JSON.encode_pretty(stale))

    output = capture_io(fn -> assert :ok = NPM.install() end)
    refute output =~ "Already up to date."
    assert File.read!("package-lock.json") == context.original
  end

  defp assert_pruned!(original, pruned) do
    original = Jason.decode!(original)
    assert {:ok, lock} = NPM.JSON.read_file("package-lock.json")

    for location <- pruned, do: refute(Map.has_key?(lock["packages"], location))

    for {location, record} <- Map.drop(original["packages"], pruned),
        String.contains?(location, "node_modules/@fixture-rm/") do
      assert lock["packages"][location] == record
    end

    lock
  end

  defp assert_frozen_and_idempotent! do
    written = File.read!("package-lock.json")
    capture_io(fn -> assert :ok = NPM.install(frozen: true) end)
    output = capture_io(fn -> assert :ok = NPM.install() end)
    assert output =~ "Already up to date." or output =~ "Linked 2 local npm packages."
    assert File.read!("package-lock.json") == written
  end

  # Root: alpha (-> alpha-child, nx@2 nested, shared), beta (-> shared, nx@1).
  # Workspaces: web (gamma, shared), admin (gamma). gamma -> gamma-child.
  defp removal_fixture!(project_dir) do
    write_package!(project_dir, %{
      "name" => "removal-root",
      "workspaces" => ["apps/*"],
      "dependencies" => %{@alpha => "^1.0.0", @beta => "^1.0.0"}
    })

    write_package!("apps/web", %{
      "name" => "web",
      "version" => "1.0.0",
      "dependencies" => %{@gamma => "^1.0.0", @shared => "^1.0.0"}
    })

    write_package!("apps/admin", %{
      "name" => "admin",
      "version" => "1.0.0",
      "dependencies" => %{@gamma => "^1.0.0"}
    })

    flat = %{
      @alpha =>
        lock_entry(@alpha, "1.0.0", %{
          @alpha_child => "^1.0.0",
          @nx => "2.0.0",
          @shared => "^1.0.0"
        }),
      @alpha_child => lock_entry(@alpha_child, "1.0.0"),
      @beta => lock_entry(@beta, "1.0.0", %{@shared => "^1.0.0", @nx => "^1.0.0"}),
      @shared => lock_entry(@shared, "1.2.0"),
      @nx => lock_entry(@nx, "1.0.0"),
      @gamma => lock_entry(@gamma, "1.0.0", %{@gamma_child => "1.0.0"}),
      @gamma_child => lock_entry(@gamma_child, "1.0.0")
    }

    nested = %{"node_modules/#{@alpha}/node_modules/#{@nx}" => lock_entry(@nx, "2.0.0")}

    for {location, entry} <- Map.merge(flat, nested) do
      name = if String.contains?(location, "/node_modules/"), do: @nx, else: location
      write_cached_package!(name, entry.version)
    end

    assert :ok = NPM.Lockfile.write(flat, nested: nested)
    assert {:ok, document} = NPM.JSON.read_file("package-lock.json")

    packages =
      Map.new(document["packages"], fn {location, record} ->
        {location, Map.put(record, "license", "MIT")}
      end)

    File.write!("package-lock.json", NPM.JSON.encode_pretty(%{document | "packages" => packages}))
    File.read!("package-lock.json")
  end

  defp lock_entry(name, version, dependencies \\ %{}) do
    %{
      version: version,
      integrity: "",
      tarball: tarball(name, version),
      dependencies: dependencies,
      optional_dependencies: %{},
      has_install_script: false
    }
  end

  defp tarball(name, version) do
    "https://registry.npmjs.org/#{name}/-/#{Path.basename(name)}-#{version}.tgz"
  end

  defp write_cached_package!(name, version) do
    cache_path = NPM.Cache.package_dir(name, version)
    File.mkdir_p!(cache_path)

    File.write!(
      Path.join(cache_path, "package.json"),
      NPM.JSON.encode_pretty(%{"name" => name, "version" => version})
    )

    File.write!(Path.join(cache_path, ".npm-ex-cache-complete"), "1\n")
  end

  defp write_package!(dir, data) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), NPM.JSON.encode_pretty(data))
  end

  defp update_package!(dir, fun) do
    {:ok, data} = dir |> Path.join("package.json") |> NPM.JSON.read_file()
    write_package!(dir, fun.(data))
  end
end
