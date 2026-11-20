defmodule DuskmoonBundler.Builder.Output.ChunkURLsTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.{Builder, Manifest}

  @tag :tmp_dir
  test "hashed split output resolves a shared chunk cycle and invalidates its importers", %{
    tmp_dir: tmp_dir
  } do
    entry = Path.join(tmp_dir, "app.js")
    lazy_a = Path.join(tmp_dir, "lazy-a.js")

    File.write!(entry, """
    export { refresh } from './shared.js';
    export const loadA = () => import('./lazy-a.js');
    export const loadB = () => import('./lazy-b.js');
    export const loadIdle = () => import('./idle.js');
    """)

    File.write!(Path.join(tmp_dir, "shared.js"), """
    export const state = 7;
    export const refresh = () => import('./lazy-a.js');
    """)

    File.write!(lazy_a, """
    import { state } from './shared.js';
    export const value = state + 1;
    """)

    File.write!(Path.join(tmp_dir, "lazy-b.js"), """
    import { state } from './shared.js';
    export const value = state + 2;
    """)

    File.write!(Path.join(tmp_dir, "idle.js"), "export const value = 42;")

    {manifest, chunks} = build(entry, Path.join(tmp_dir, "dist-1"))
    assert {manifest, chunks} == build(entry, Path.join(tmp_dir, "dist-2"))

    assert %{
             "entry" => {entry_file, entry_code},
             "common" => {common_file, common_code},
             "lazy-a" => {lazy_a_file, lazy_a_code},
             "lazy-b" => {lazy_b_file, lazy_b_code},
             "idle" => {idle_file, _idle_code}
           } = chunks

    assert entry_code =~ "import('./#{lazy_a_file}')"
    assert entry_code =~ "import('./#{lazy_b_file}')"
    assert entry_code =~ ~s("./#{common_file}")
    assert common_code =~ "import('./#{lazy_a_file}')"
    assert lazy_a_code =~ "from './#{common_file}'"
    assert lazy_b_code =~ "from './#{common_file}'"

    assert %{
             "file" => ^entry_file,
             "isEntry" => true,
             "imports" => [^common_file],
             "dynamicImports" => entry_dynamic_imports
           } = manifest["app.js"]

    assert Enum.sort(entry_dynamic_imports) == Enum.sort([idle_file, lazy_a_file, lazy_b_file])
    assert %{"dynamicImports" => [^lazy_a_file]} = manifest[common_file]
    assert %{"imports" => [^common_file]} = manifest[lazy_a_file]

    File.write!(lazy_a, """
    import { state } from './shared.js';
    export const value = state + 10;
    """)

    {_manifest, updated} = build(entry, Path.join(tmp_dir, "dist-updated"))
    assert updated["idle"] == chunks["idle"]

    for id <- ["entry", "common", "lazy-a", "lazy-b"] do
      assert elem(updated[id], 0) != elem(chunks[id], 0)
    end
  end

  defp build(entry, outdir) do
    assert {:ok, result} =
             Builder.build(
               entry: entry,
               root: Path.dirname(entry),
               outdir: outdir,
               name: "app",
               hash: true,
               minify: false,
               sourcemap: false
             )

    chunks =
      Map.new(result.chunks, fn %{chunk_id: id, path: path} ->
        {id, {Path.basename(path), File.read!(path)}}
      end)

    emitted = MapSet.new(chunks, fn {_id, {file, _code}} -> file end)

    for {_id, {file, code}} <- chunks,
        [_, reference] <- Regex.scan(~r/["'`]\.\/([^"'`]+\.js)["'`]/, code) do
      assert reference in emitted, "#{file} references missing chunk #{reference}"
    end

    manifest = outdir |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
    entries = Manifest.entries!(manifest)

    for {key, entry} <- entries,
        reference <- [entry["file"] | entry["imports"] ++ entry["dynamicImports"]] do
      assert reference in emitted, "manifest entry #{key} references missing chunk #{reference}"
    end

    {entries, chunks}
  end
end
