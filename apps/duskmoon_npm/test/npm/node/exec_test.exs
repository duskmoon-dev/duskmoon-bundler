defmodule NPM.Node.ExecTest do
  use ExUnit.Case, async: true

  alias NPM.Node.Exec

  @moduletag :tmp_dir

  defp write_package!(nm, dir, data) do
    package_dir = Path.join(nm, dir)
    File.mkdir_p!(package_dir)
    File.write!(Path.join(package_dir, "package.json"), :json.encode(data))
    package_dir
  end

  setup %{tmp_dir: tmp_dir} do
    nm = Path.join([tmp_dir, "project", "node_modules"])
    File.mkdir_p!(nm)
    {:ok, nm: nm}
  end

  test "resolves a string bin inside the package directory", %{nm: nm} do
    package_dir = write_package!(nm, "tool", %{"name" => "tool", "bin" => "./cli.js"})

    assert {:ok, path} = Exec.which("tool", nm)
    assert Path.expand(path) == Path.join(package_dir, "cli.js")
  end

  test "resolves a map bin inside the installed package directory", %{nm: nm} do
    package_dir =
      write_package!(nm, "tool", %{"name" => "tool", "bin" => %{"tool" => "bin/tool.js"}})

    assert {:ok, path} = Exec.which("tool", nm)
    assert Path.expand(path) == Path.join(package_dir, "bin/tool.js")
  end

  test "uses the installed directory, not the manifest name, for map bins", %{nm: nm} do
    package_dir =
      write_package!(nm, "tool", %{"name" => "../../evil", "bin" => %{"tool" => "cli.js"}})

    assert {:ok, path} = Exec.which("tool", nm)
    assert Path.expand(path) == Path.join(package_dir, "cli.js")
  end

  for bin <- ["../../outside.sh", "/bin/sh", "../other/cli.js"] do
    test "rejects string bin #{bin} outside the package", %{nm: nm} do
      write_package!(nm, "tool", %{"name" => "tool", "bin" => unquote(bin)})
      assert {:error, :not_found} = Exec.which("tool", nm)
    end

    test "rejects map bin #{bin} outside the package", %{nm: nm} do
      write_package!(nm, "tool", %{"name" => "tool", "bin" => %{"tool" => unquote(bin)}})
      assert {:error, :not_found} = Exec.which("tool", nm)
    end
  end

  test "does not look up commands outside node_modules", %{nm: nm, tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "elsewhere"))

    File.write!(
      Path.join([tmp_dir, "elsewhere", "package.json"]),
      :json.encode(%{"name" => "elsewhere", "bin" => "cli.js"})
    )

    assert {:error, :not_found} = Exec.which("../../elsewhere", nm)
  end

  test "prefers node_modules/.bin", %{nm: nm} do
    File.mkdir_p!(Path.join(nm, ".bin"))
    File.write!(Path.join([nm, ".bin", "tool"]), "#!/bin/sh\n")

    assert {:ok, path} = Exec.which("tool", nm)
    assert path == Path.join([nm, ".bin", "tool"])
  end
end
