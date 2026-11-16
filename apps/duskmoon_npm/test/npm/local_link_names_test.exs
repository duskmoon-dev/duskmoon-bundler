defmodule NPM.LocalLinkNamesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias NPM.Install.Linker

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Layout: tmp/outer/root/node_modules, so "../../victim" from node_modules
    # resolves to tmp/outer/victim — still inside the ExUnit tmp dir.
    root = Path.join([tmp_dir, "outer", "root"])
    victim = Path.join([tmp_dir, "outer", "victim"])
    File.mkdir_p!(root)
    File.mkdir_p!(victim)
    File.write!(Path.join(victim, "keep.txt"), "precious")

    {:ok, root: root, victim: victim}
  end

  defp write_package!(dir, data) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), :json.encode(data))
  end

  defp assert_victim_untouched(victim) do
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(victim)
    assert File.read!(Path.join(victim, "keep.txt")) == "precious"
  end

  describe "NPM.Workspace.read_all/1" do
    test "rejects a workspace package whose name escapes node_modules", %{root: root} do
      write_package!(root, %{"name" => "root", "workspaces" => ["pkgs/*"]})
      write_package!(Path.join([root, "pkgs", "a"]), %{"name" => "../../victim"})

      manifest = Path.join([root, "pkgs", "a", "package.json"])

      assert {:error, {:invalid_package_name, "../../victim", ^manifest}} =
               NPM.Workspace.read_all(root)
    end

    test "rejects an unnamed workspace whose directory name is not installable", %{root: root} do
      write_package!(root, %{"name" => "root", "workspaces" => ["pkgs/.bin"]})
      write_package!(Path.join([root, "pkgs", ".bin"]), %{})

      assert {:error, {:invalid_package_name, ".bin", _path}} = NPM.Workspace.read_all(root)
    end

    test "rejects a file: dependency whose name escapes node_modules", %{root: root} do
      write_package!(Path.join(root, "lib"), %{"name" => "lib"})

      write_package!(root, %{
        "name" => "root",
        "dependencies" => %{"../../victim" => "file:./lib"}
      })

      manifest = Path.join(root, "package.json")

      assert {:error, {:invalid_package_name, "../../victim", ^manifest}} =
               NPM.Workspace.read_all(root)
    end

    test "still accepts scoped and legacy names", %{root: root} do
      write_package!(root, %{"name" => "root", "workspaces" => ["pkgs/*"]})
      write_package!(Path.join([root, "pkgs", "a"]), %{"name" => "@scope/ui"})
      write_package!(Path.join([root, "pkgs", "b"]), %{"name" => "JSONStream"})

      assert {:ok, %{local_links: links}} = NPM.Workspace.read_all(root)
      assert Map.keys(links) |> Enum.sort() == ["@scope/ui", "JSONStream"]
    end
  end

  describe "Linker.link_local_packages/2" do
    test "never deletes or creates anything outside node_modules", %{root: root, victim: victim} do
      source = Path.join(root, "src")
      write_package!(source, %{"name" => "../../victim"})
      nm = Path.join(root, "node_modules")

      assert {:error, {:invalid_package_name, "../../victim", _}} =
               Linker.link_local_packages(%{"../../victim" => source}, nm)

      assert_victim_untouched(victim)
    end

    test "rejects names that would replace node_modules internals", %{root: root} do
      source = Path.join(root, "src")
      write_package!(source, %{})
      nm = Path.join(root, "node_modules")
      File.mkdir_p!(Path.join(nm, ".bin"))
      File.write!(Path.join([nm, ".bin", "tool"]), "x")

      assert {:error, {:invalid_package_name, ".bin", _}} =
               Linker.link_local_packages(%{".bin" => source}, nm)

      assert File.read!(Path.join([nm, ".bin", "tool"])) == "x"
    end

    test "links valid plain and scoped names", %{root: root} do
      source = Path.join(root, "src")
      write_package!(source, %{"name" => "@scope/ui"})
      nm = Path.join(root, "node_modules")

      assert :ok = Linker.link_local_packages(%{"@scope/ui" => source, "plain" => source}, nm)
      assert File.exists?(Path.join([nm, "@scope", "ui", "package.json"]))
      assert File.exists?(Path.join([nm, "plain", "package.json"]))
    end
  end

  describe "NPM.Install.Link.link/2" do
    test "rejects an escaping package name", %{root: root, victim: victim} do
      source = Path.join(root, "src")
      write_package!(source, %{"name" => "../../victim"})
      nm = Path.join(root, "node_modules")
      File.mkdir_p!(nm)

      assert {:error, {:invalid_package_name, "../../victim", _}} =
               NPM.Install.Link.link(source, nm)

      assert_victim_untouched(victim)
    end

    test "unlink/2 and linked?/2 ignore escaping names", %{root: root, victim: victim} do
      nm = Path.join(root, "node_modules")
      File.mkdir_p!(nm)
      escape = Path.join([root, "..", "escape-link"])
      File.ln_s!(victim, escape)

      assert {:error, :not_linked} = NPM.Install.Link.unlink("../../escape-link", nm)
      refute NPM.Install.Link.linked?("../../escape-link", nm)
      assert {:ok, _} = File.read_link(escape)
    end

    test "links a valid scoped package", %{root: root} do
      source = Path.join(root, "src")
      write_package!(source, %{"name" => "@scope/ui"})
      nm = Path.join(root, "node_modules")

      assert {:ok, %{name: "@scope/ui"}} = NPM.Install.Link.link(source, nm)
      assert NPM.Install.Link.linked?("@scope/ui", nm)
    end
  end

  describe "mix npm.link" do
    for flag <- [[], ["--copy"]] do
      test "rejects an escaping package name #{inspect(flag)}", %{root: root, victim: victim} do
        source = Path.join(root, "src")
        write_package!(source, %{"name" => "../../victim"})

        output =
          capture_io(:stderr, fn ->
            capture_io(fn ->
              File.cd!(root, fn -> Mix.Tasks.Npm.Link.run([source | unquote(flag)]) end)
            end)
          end)

        assert output =~ "Invalid package name"
        assert_victim_untouched(victim)
      end
    end
  end
end
