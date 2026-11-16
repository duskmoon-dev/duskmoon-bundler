defmodule DuskmoonBundler.CSS.ImportedAssetURLsTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.CSS.AssetURLRewriter

  @moduletag :tmp_dir

  test "bundled imports emit assets from their own directories in build and dev", %{
    tmp_dir: tmp_dir
  } do
    entry = Path.join(tmp_dir, "app.css")
    outdir = Path.join(tmp_dir, "dist")
    File.mkdir_p!(Path.join(tmp_dir, "nested"))
    File.write!(entry, "@import './nested/base.css'; .entry { background: url(logo.svg) }")

    File.write!(
      Path.join(tmp_dir, "nested/base.css"),
      ".imported { background: url('./logo.svg?v=1#icon'), url('./logo.svg?v=2') }"
    )

    File.write!(Path.join(tmp_dir, "logo.svg"), "<svg>entry</svg>")
    File.write!(Path.join(tmp_dir, "nested/logo.svg"), "<svg>imported</svg>")

    assert {:ok, %{code: bundled, errors: []}} = Vize.CSS.bundle(entry)

    assert {:ok, %{code: built, assets: [imported, entry_asset]}} =
             AssetURLRewriter.rewrite_with_assets(bundled, entry, outdir, root: tmp_dir)

    assert %{src: "nested/logo.svg", file: imported_file} = imported
    assert %{src: "logo.svg", file: entry_file} = entry_asset
    assert imported_file != entry_file
    assert File.read!(Path.join(outdir, imported_file)) == "<svg>imported</svg>"
    assert File.read!(Path.join(outdir, entry_file)) == "<svg>entry</svg>"
    assert built =~ "/assets/#{imported_file}?v=1#icon"
    assert built =~ "/assets/#{imported_file}?v=2"
    assert built =~ "/assets/#{entry_file}"

    assert {:ok, dev} = AssetURLRewriter.rewrite_dev(bundled, entry, tmp_dir, "/assets")
    assert dev =~ "/assets/nested/logo.svg?v=1#icon"
    assert dev =~ "/assets/nested/logo.svg?v=2"
    assert dev =~ "/assets/logo.svg"
  end
end
