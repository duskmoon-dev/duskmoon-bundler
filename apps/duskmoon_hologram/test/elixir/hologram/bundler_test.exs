defmodule Hologram.BundlerTest do
  use ExUnit.Case, async: true

  alias Hologram.Bundler

  @tag :tmp_dir
  test "keeps HTTP(S) dynamic imports in the IIFE and tracks local inputs", %{tmp_dir: tmp_dir} do
    entry = Path.join(tmp_dir, "page.js")
    helper = Path.join(tmp_dir, "helper.js")
    https_url = "https://example.test/three.js?v=1#module"
    http_url = "http://example.test/helper.js"

    File.write!(entry, """
    import { loadHelper } from "./helper.js";
    globalThis.loadThree = () => import("#{https_url}");
    globalThis.loadHelper = loadHelper;
    """)

    File.write!(helper, ~s|export const loadHelper = () => import("#{http_url}");|)

    assert {bundle_path, [^entry, ^helper]} =
             Bundler.build!(entry, "page", Path.join(tmp_dir, "output"), [])

    bundle = File.read!(bundle_path)
    assert {:ok, _ast} = OXC.parse(bundle, "page.cjs")

    for url <- [http_url, https_url] do
      assert bundle =~ ~r/import\((["'`])#{Regex.escape(url)}\1\)/
    end
  end
end
