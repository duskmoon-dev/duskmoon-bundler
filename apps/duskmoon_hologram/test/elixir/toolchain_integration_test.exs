defmodule Hologram.ToolchainIntegrationTest do
  use ExUnit.Case, async: false

  alias Hologram.Compiler
  alias Hologram.Reflection

  @moduletag :tmp_dir

  test "uses the renamed OTP application and local source assets" do
    assert Application.get_application(Hologram) == :duskmoon_hologram
    assert Application.spec(:hologram) == nil
    assert File.regular?(Path.join(Reflection.hologram_dep_dir(), "assets/package.json"))
    assert Reflection.build_dir() == Application.app_dir(:duskmoon_hologram, "priv")
  end

  test "installs JS dependencies through duskmoon_npm and records the manifest digest", %{
    tmp_dir: tmp_dir
  } do
    assets = Path.join(tmp_dir, "assets")
    build = Path.join(tmp_dir, "build")
    File.mkdir_p!(assets)
    File.mkdir_p!(build)
    manifest = ~s({"private":true,"dependencies":{}})
    File.write!(Path.join(assets, "package.json"), manifest)

    assert :ok = Compiler.install_js_deps(assets, build)

    assert File.read!(Path.join(build, "package_json_digest.bin")) ==
             :crypto.hash(:sha256, manifest)
  end

  test "native bundle executes, links a source map and tracks imported inputs", %{tmp_dir: dir} do
    input = Path.join(dir, "helper.js")
    File.write!(input, "export const answer = 42;\n")
    opts = build_opts(dir)
    entry = Path.join(opts[:tmp_dir], "page.entry.js")
    File.write!(entry, "import {answer} from '../helper.js'; console.log(answer);\n")

    result = Compiler.bundle(MyPage, entry, "page", opts)
    assert result.digest =~ ~r/^[0-9a-f]{8}$/
    assert %{^input => _fingerprint} = result.js_inputs
    assert {"42\n", 0} = System.cmd("bun", [result.static_bundle_path])

    assert File.read!(result.static_bundle_path) =~
             "//# sourceMappingURL=#{Path.basename(result.static_source_map_path)}"

    assert %{"version" => 3, "sourcesContent" => sources, "mappings" => mappings} =
             result.static_source_map_path |> File.read!() |> JSON.decode!()

    assert Enum.any?(sources, &String.contains?(&1, "answer"))
    assert mappings != ""

    File.write!(input, "export const answer = 43;\n")
    rebuilt = Compiler.bundle(MyPage, entry, "page", opts)
    assert rebuilt.digest != result.digest
    assert {"43\n", 0} = System.cmd("bun", [rebuilt.static_bundle_path])
  end

  test "independent chunks preserve order and runtime side effects", %{tmp_dir: dir} do
    opts = build_opts(dir)
    first = Path.join(opts[:tmp_dir], "first.entry.js")
    second = Path.join(opts[:tmp_dir], "second.entry.js")
    File.write!(first, "console.log('first');")
    File.write!(second, "console.log('second');")

    assert [%{entry_name: "first"} = a, %{entry_name: "second"} = b] =
             Compiler.bundle_chunks([{"first", first}, {"second", second}], opts)

    assert a.digest != b.digest
    assert {"first\n", 0} = System.cmd("bun", [a.static_bundle_path])
    assert {"second\n", 0} = System.cmd("bun", [b.static_bundle_path])
  end

  test "syntax errors do not publish a bundle", %{tmp_dir: dir} do
    opts = build_opts(dir)
    entry = Path.join(opts[:tmp_dir], "invalid.entry.js")
    File.write!(entry, "export const value 123;")

    assert_raise RuntimeError, ~r/DuskmoonBundler failed/, fn ->
      Compiler.bundle(MyPage, entry, "page", opts)
    end

    assert File.ls!(opts[:static_dir]) == []
  end

  defp build_opts(dir) do
    tmp = Path.join(dir, "entries")
    static = Path.join(dir, "static")
    File.mkdir_p!(tmp)
    File.mkdir_p!(static)
    [tmp_dir: tmp, static_dir: static]
  end
end
