defmodule NPM.SecurityRegressionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias NPM.{Cache, Config, Lockfile, Tarball}
  alias NPM.Install.Linker

  setup do
    old_cwd = File.cwd!()
    old_home = System.get_env("HOME")
    old_cache_dir = Application.get_env(:duskmoon_npm, :cache_dir)
    old_env = Map.new(~w(NPM_TOKEN NPM_REGISTRY), &{&1, System.get_env(&1)})
    old_app = Map.new([:token, :registry], &{&1, Application.get_env(:duskmoon_npm, &1)})

    tmp_dir =
      Path.join(System.tmp_dir!(), "npm_security_test_#{System.unique_integer([:positive])}")

    project = Path.join(tmp_dir, "project")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(project)
    File.mkdir_p!(Path.join(tmp_dir, "home"))
    File.cd!(project)
    System.put_env("HOME", Path.join(tmp_dir, "home"))
    Enum.each(Map.keys(old_env), &System.delete_env/1)
    Enum.each(Map.keys(old_app), &Application.delete_env(:duskmoon_npm, &1))
    Application.put_env(:duskmoon_npm, :cache_dir, Path.join(tmp_dir, "cache-root"))

    on_exit(fn ->
      File.cd!(old_cwd)
      restore_env("HOME", old_home)
      Enum.each(old_env, fn {k, v} -> restore_env(k, v) end)
      Enum.each(old_app, fn {k, v} -> restore_app_env(k, v) end)
      restore_app_env(:cache_dir, old_cache_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, project: project}
  end

  describe "lockfile entry validation" do
    for location <- ~w(node_modules/.. node_modules/. node_modules/@x/.. node_modules/a/../..) do
      test "rejects #{location}" do
        write_package_lock!(%{unquote(location) => entry("1.0.0")})

        assert {:error, {:invalid_lockfile_entry, _, _}} = Lockfile.read("package-lock.json")

        assert {:error, {:invalid_lockfile_entry, _, _}} =
                 Lockfile.all_package_names("package-lock.json")
      end
    end

    test "rejects path-traversal versions" do
      write_package_lock!(%{"node_modules/foo" => entry("../../..")})

      assert {:error,
              {:invalid_lockfile_entry, "node_modules/foo",
               {:invalid_package_version, "foo", "../../.."}}} =
               Lockfile.read("package-lock.json")
    end

    test "rejects unsafe versions in nested locations" do
      write_package_lock!(%{
        "node_modules/a" => entry("1.0.0"),
        "node_modules/a/node_modules/b" => entry("../x")
      })

      assert {:error, {:invalid_lockfile_entry, _, {:invalid_package_version, "b", "../x"}}} =
               Lockfile.read_nested("package-lock.json")
    end

    test "rejects unsafe names in legacy npm.lock" do
      File.write!(
        "npm.lock",
        :json.encode(%{"lockfileVersion" => 1, "packages" => %{".." => %{"version" => "1.0.0"}}})
      )

      assert {:error, {:invalid_lockfile_entry, "..", {:invalid_package_name, ".."}}} =
               Lockfile.read("npm.lock")
    end

    test "accepts legacy uppercase and scoped names" do
      write_package_lock!(%{
        "node_modules/JSONStream" => entry("1.3.5"),
        "node_modules/@scope/pkg" => entry("2.0.0-beta.1")
      })

      assert {:ok, %{"JSONStream" => _, "@scope/pkg" => _}} = Lockfile.read("package-lock.json")
    end
  end

  describe "cache path validation" do
    test "package_dir rejects unsafe names and versions" do
      assert_raise ArgumentError, fn -> Cache.package_dir("..", "1.0.0") end
      assert_raise ArgumentError, fn -> Cache.package_dir("foo", "../../..") end
      assert_raise ArgumentError, fn -> Cache.package_dir("@x/..", "1.0.0") end
      refute Cache.cached?("foo", "../x")
    end

    test "ensure returns an error without touching the filesystem", %{tmp_dir: tmp_dir} do
      sentinel = Path.join(tmp_dir, "sentinel")
      File.write!(sentinel, "keep")

      assert {:error, {:invalid_package_version, "foo", "../../.."}} =
               Cache.ensure("foo", "../../..", "https://registry.npmjs.org/x.tgz", "")

      assert File.read!(sentinel) == "keep"
    end

    test "cache hits are re-verified against the expected integrity" do
      dir = Cache.package_dir("pkg", "1.0.0")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "package.json"), "{}")
      File.write!(Path.join(dir, ".npm-ex-cache-complete"), "1\nsha512-AAAA\n")

      assert Cache.cached?("pkg", "1.0.0", "sha512-AAAA")
      assert Cache.cached?("pkg", "1.0.0", "sha1-ZZZZ sha512-AAAA")
      assert Cache.cached?("pkg", "1.0.0", "")
      refute Cache.cached?("pkg", "1.0.0", "sha512-BBBB")

      File.write!(Path.join(dir, ".npm-ex-cache-complete"), "1\n")
      refute Cache.cached?("pkg", "1.0.0", "sha512-AAAA")
    end
  end

  describe "bin linking" do
    test "skips unsafe bin names, targets and directories.bin", %{tmp_dir: tmp_dir} do
      nm = Path.join(tmp_dir, "project/node_modules")
      pkg = Path.join(nm, "evil")
      outside = Path.join(tmp_dir, "outside.sh")
      File.mkdir_p!(Path.join(pkg, "bin"))
      File.write!(Path.join(pkg, "bin/ok.js"), "")
      File.write!(outside, "")
      File.chmod!(outside, 0o600)

      File.write!(
        Path.join(pkg, "package.json"),
        :json.encode(%{
          "name" => "evil",
          "bin" => %{
            "../../escape" => "bin/ok.js",
            ".." => "bin/ok.js",
            "a\\b" => "bin/ok.js",
            "" => "bin/ok.js",
            "abs" => outside,
            "up" => "../../../outside.sh",
            "@scope/good" => "bin/ok.js"
          }
        })
      )

      output =
        capture_io(:stderr, fn -> assert :ok = Linker.link_bins(nm, [{"evil", "1.0.0"}]) end)

      assert File.ls!(Path.join(nm, ".bin")) == ["good"]
      assert {:ok, _} = File.read_link(Path.join(nm, ".bin/good"))
      assert File.stat!(outside).mode |> Bitwise.band(0o777) == 0o600
      refute File.exists?(Path.join(tmp_dir, "escape"))
      assert output =~ "skipping unsafe bin"
    end

    test "rejects directories.bin outside the package", %{tmp_dir: tmp_dir} do
      nm = Path.join(tmp_dir, "project/node_modules")
      pkg = Path.join(nm, "evil")
      File.mkdir_p!(pkg)
      File.mkdir_p!(Path.join(tmp_dir, "outside_bin"))
      File.write!(Path.join(tmp_dir, "outside_bin/tool"), "")
      File.chmod!(Path.join(tmp_dir, "outside_bin/tool"), 0o600)

      File.write!(
        Path.join(pkg, "package.json"),
        :json.encode(%{"name" => "evil", "directories" => %{"bin" => "../../../outside_bin"}})
      )

      capture_io(:stderr, fn -> assert :ok = Linker.link_bins(nm, [{"evil", "1.0.0"}]) end)

      refute File.exists?(Path.join(nm, ".bin"))

      assert File.stat!(Path.join(tmp_dir, "outside_bin/tool")).mode |> Bitwise.band(0o777) ==
               0o600
    end
  end

  describe "auth token scoping" do
    test "NPM_TOKEN and app token are not sent to an .npmrc-configured registry" do
      File.write!(".npmrc", "registry=https://attacker.example/\n")
      System.put_env("NPM_TOKEN", "env-token")

      assert Config.registry() == "https://attacker.example"
      refute Config.auth_token()
      refute Config.auth_token("https://attacker.example")
      assert Config.auth_token("https://registry.npmjs.org") == "env-token"

      System.delete_env("NPM_TOKEN")
      Application.put_env(:duskmoon_npm, :token, "app-token")
      refute Config.auth_token("https://attacker.example")
      assert Config.auth_token("https://registry.npmjs.org/") == "app-token"
    end

    test "global token applies to an explicitly configured trusted registry" do
      System.put_env("NPM_TOKEN", "env-token")
      System.put_env("NPM_REGISTRY", "https://nexus.example/repository/npm/")

      assert Config.auth_token() == "env-token"
    end

    test "registry-matched .npmrc tokens still work for custom registries" do
      File.write!(".npmrc", """
      registry=https://nexus.example/repo/
      //nexus.example/repo/:_authToken=nexus-token
      """)

      System.put_env("NPM_TOKEN", "env-token")
      assert Config.auth_token() == "nexus-token"
    end
  end

  describe "integrity" do
    test "rejects empty, malformed and unknown-algorithm integrity" do
      assert {:error, :invalid_integrity} = Tarball.verify_integrity("x", "")
      assert {:error, :invalid_integrity} = Tarball.verify_integrity("x", nil)
      assert {:error, :invalid_integrity} = Tarball.verify_integrity("x", "md5-abc")
      assert {:error, :invalid_integrity} = Tarball.verify_integrity("x", "garbage")
    end

    test "accepts multi-hash SRI when the strongest hash matches" do
      sha512 = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "x"))
      sha1 = "sha1-" <> Base.encode64(:crypto.hash(:sha, "x"))

      assert :ok = Tarball.verify_integrity("x", "sha1-bogus " <> sha512)
      assert :ok = Tarball.verify_integrity("x", sha1 <> " md5-zzz")
      assert :ok = Tarball.verify_integrity("x", sha512 <> "?opt")

      assert {:error, :integrity_mismatch} =
               Tarball.verify_integrity("x", sha1 <> " sha512-bogus")
    end
  end

  describe "tarball extraction" do
    @tag :tmp_dir
    test "drops setuid, setgid and sticky bits", %{tmp_dir: dir} do
      archive = Path.join(dir, "suid.tgz")
      src = Path.join(dir, "src/package")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "run"), "#!/bin/sh\n")
      File.chmod!(Path.join(src, "run"), 0o4755)

      :ok =
        :erl_tar.create(
          String.to_charlist(archive),
          [{~c"package/run", String.to_charlist(Path.join(src, "run"))}],
          [:compressed]
        )

      dest = Path.join(dir, "out")
      assert {:ok, 1} = Tarball.extract(File.read!(archive), dest)
      assert File.stat!(Path.join(dest, "run")).mode |> Bitwise.band(0o7777) == 0o755
    end
  end

  defp entry(version), do: %{"version" => version, "resolved" => "", "integrity" => ""}

  defp write_package_lock!(packages) do
    File.write!(
      "package-lock.json",
      :json.encode(%{"lockfileVersion" => 3, "packages" => Map.put(packages, "", %{})})
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
