defmodule DuskmoonBundler.Builder.CompileOnceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defmodule CountingPlugin do
    def name, do: "counting"

    def load(path, opts) do
      send(opts[:owner], {:loaded, path})
      nil
    end

    def compile(path, source, _compile_opts, opts) do
      send(opts[:owner], {:compiled, path})

      if Path.extname(path) == ".js" do
        {:ok, %DuskmoonBundler.Pipeline.Result{code: source}}
      end
    end

    def transform(code, path, opts) do
      send(opts[:owner], {:transformed, path})
      {:ok, code}
    end
  end

  test "loads, compiles and transforms each module once while discovering dependencies", %{
    tmp_dir: dir
  } do
    entry = Path.join(dir, "app.js")
    dependency = Path.join(dir, "dependency.js")
    data = Path.join(dir, "data.json")
    File.write!(entry, "import { value } from './dependency.js'; console.log(value)")
    File.write!(dependency, "import data from './data.json'; export const value = data.value")
    File.write!(data, ~s({"value": "compiled-once"}))

    assert {:ok, result} =
             DuskmoonBundler.Builder.build(
               entry: entry,
               outdir: Path.join(dir, "dist"),
               root: dir,
               plugins: [{CountingPlugin, owner: self()}],
               minify: false,
               sourcemap: false
             )

    assert File.read!(result.js.path) =~ "compiled-once"

    for path <- [entry, dependency, data], event <- [:loaded, :compiled, :transformed] do
      assert_received {^event, ^path}
      refute_received {^event, ^path}
    end
  end

  test "query variants of JSON modules retain their JavaScript wrapper", %{tmp_dir: dir} do
    entry = Path.join(dir, "app.js")
    File.write!(entry, "import data from './data.json?custom'; console.log(data.message)")
    File.write!(Path.join(dir, "data.json"), ~s({"message": "json-query-value"}))

    assert {:ok, result} =
             DuskmoonBundler.Builder.build(
               entry: entry,
               root: dir,
               outdir: Path.join(dir, "dist"),
               minify: false,
               sourcemap: false
             )

    assert File.read!(result.js.path) =~ "json-query-value"
  end
end
