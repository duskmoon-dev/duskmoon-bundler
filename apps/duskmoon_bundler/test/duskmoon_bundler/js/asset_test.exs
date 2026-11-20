defmodule DuskmoonBundler.JS.AssetTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.JS.Asset

  test "reads TypeScript assets from priv/ts" do
    code = Asset.read!("dev/hmr-client.ts")
    assert code =~ "const proto"
  end

  test "rewrites type-checkable support imports to runtime client URL" do
    code =
      Asset.compiled_template!("dev/hmr-preamble.ts",
        mod_url: "/assets/app.ts"
      )

    assert code =~ ~s(from "/@duskmoon_bundler/client.js")
    refute code =~ "./hmr-client"
  end
end
