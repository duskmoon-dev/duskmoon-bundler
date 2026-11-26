defmodule Mix.Tasks.Npm.CheckUpdatesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    cwd = File.cwd!()
    cache = System.get_env("NPM_EX_CACHE_DIR")
    System.put_env("NPM_EX_CACHE_DIR", Path.join(tmp_dir, "cache"))
    File.cd!(tmp_dir)

    on_exit(fn ->
      File.cd!(cwd)

      if cache,
        do: System.put_env("NPM_EX_CACHE_DIR", cache),
        else: System.delete_env("NPM_EX_CACHE_DIR")
    end)

    NPM.PackumentCache.put("registry-dep", %{
      name: "registry-dep",
      versions: %{},
      dist_tags: %{"latest" => "2.3.4"}
    })

    :ok
  end

  test "previews root updates without requiring a lockfile or writing the manifest" do
    manifest = %{"dependencies" => %{"registry-dep" => "^1.0.0"}}
    write_manifest!("package.json", manifest)

    output = capture_io(fn -> run([]) end)

    assert output =~ "registry-dep  ^1.0.0 → ^2.3.4"
    assert {:ok, ^manifest} = NPM.JSON.read_file("package.json")
    refute File.exists?("package-lock.json")
  end

  test "writes registry updates to each workspace and root, preserving the declaration style" do
    root = %{
      "workspaces" => %{"packages" => ["apps/*", "apps/web"]},
      "dependencies" => %{"registry-dep" => "^1.0.0", "web" => "1.0.0"},
      "scripts" => %{"check" => "echo ^1.0.0"}
    }

    web = %{
      "name" => "web",
      "dependencies" => %{"registry-dep" => "1.x", "api" => "workspace:*"},
      "devDependencies" => %{"registry-dep" => "~1.2.0", "alias" => "npm:registry-dep@1.0.0"}
    }

    api = %{
      "name" => "api",
      "optionalDependencies" => %{"registry-dep" => "1.0.0", "local" => "file:../web"}
    }

    write_manifest!("package.json", root)
    write_manifest!("apps/web/package.json", web)
    write_manifest!("apps/api/package.json", api)
    File.write!("package-lock.json", "lockfile sentinel\n")

    output = capture_io(fn -> run(["-w"]) end)
    assert output =~ "apps/web/package.json"
    assert output =~ "apps/api/package.json"
    assert {:ok, ^root} = NPM.JSON.read_file("package.json")
    assert {:ok, ^web} = NPM.JSON.read_file("apps/web/package.json")
    assert {:ok, ^api} = NPM.JSON.read_file("apps/api/package.json")

    capture_io(fn -> run(["-w", "-u"]) end)

    expected_root = put_in(root, ["dependencies", "registry-dep"], "^2.3.4")

    expected_web =
      web
      |> put_in(["dependencies", "registry-dep"], "2.x")
      |> put_in(["devDependencies", "registry-dep"], "~2.3.4")
      |> put_in(["devDependencies", "alias"], "npm:registry-dep@2.3.4")

    expected_api = put_in(api, ["optionalDependencies", "registry-dep"], "2.3.4")

    assert {:ok, ^expected_root} = NPM.JSON.read_file("package.json")
    assert {:ok, ^expected_web} = NPM.JSON.read_file("apps/web/package.json")
    assert {:ok, ^expected_api} = NPM.JSON.read_file("apps/api/package.json")
    assert File.read!("package-lock.json") == "lockfile sentinel\n"
    refute File.exists?("node_modules")
  end

  test "accepts the long options and can exclude the root manifest" do
    root = %{"workspaces" => ["apps/*"], "dependencies" => %{"registry-dep" => "1.0.0"}}
    write_manifest!("package.json", root)
    write_manifest!("apps/web/package.json", %{"dependencies" => %{"registry-dep" => "1.0.0"}})

    capture_io(fn -> run(["--workspaces", "--upgrade", "--no-root"]) end)

    assert {:ok, ^root} = NPM.JSON.read_file("package.json")

    assert {:ok, %{"dependencies" => %{"registry-dep" => "2.3.4"}}} =
             NPM.JSON.read_file("apps/web/package.json")
  end

  test "fails when -w is used with a package without workspaces" do
    write_manifest!("package.json", %{"name" => "single-package"})

    assert_raise Mix.Error, ~r/workspaces property missing/, fn ->
      run(["-w", "-u"])
    end
  end

  test "upgrades only the root when -u is used without -w" do
    root = %{"workspaces" => ["apps/*"], "dependencies" => %{"registry-dep" => "^2.0.0"}}
    workspace = %{"dependencies" => %{"registry-dep" => "1.0.0"}}
    write_manifest!("package.json", root)
    write_manifest!("apps/web/package.json", workspace)

    output = capture_io(fn -> run(["-u"]) end)

    assert output =~ "Upgrading package.json"

    assert {:ok, %{"dependencies" => %{"registry-dep" => "^2.3.4"}}} =
             NPM.JSON.read_file("package.json")

    assert {:ok, ^workspace} = NPM.JSON.read_file("apps/web/package.json")
  end

  test "does not rewrite a manifest without eligible upgrades" do
    original =
      ~s({"dependencies":{"registry-dep":"^3.0.0","compound":">=1.0.0 <2.0.0","local":"file:../local"}})

    File.write!("package.json", original)

    output = capture_io(fn -> run(["-u"]) end)

    assert output =~ "No dependency updates found."
    assert File.read!("package.json") == original
  end

  test "rejects invalid options before rewriting the manifest" do
    manifest = %{"dependencies" => %{"registry-dep" => "1.0.0"}}
    write_manifest!("package.json", manifest)

    assert_raise Mix.Error, ~r/Usage: mix npm.check-updates/, fn -> run(["-u", "--unknown"]) end
    assert_raise Mix.Error, ~r/require --workspaces/, fn -> run(["-u", "--no-root"]) end
    assert {:ok, ^manifest} = NPM.JSON.read_file("package.json")
  end

  defp run(args) do
    # Umbrella test runs redirect non-recursive Mix tasks to the project root.
    task = Mix.Task.get!("npm.check-updates")
    task.run(args)
  end

  defp write_manifest!(path, manifest) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, NPM.JSON.encode_pretty(manifest))
  end
end
