defmodule DuskmoonBundler.Builder.ExternalsTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.Builder.Externals

  describe "rewrite_imports/3" do
    defp rewrite(code, external, globals \\ %{}) do
      [{"app.js", out}] =
        Externals.rewrite_imports([{"app.js", code}], MapSet.new(external), globals)

      out
    end

    test "default import reads the global through globalThis with ES module interop" do
      assert rewrite("import React from 'react'", ["react"], %{"react" => "React"}) ==
               "const React = ((m) => m && m.__esModule ? m.default : m)(globalThis.React);"
    end

    test "namespace import never references its own binding" do
      assert rewrite("import * as Vue from 'vue'", ["vue"], %{"vue" => "Vue"}) ==
               "const Vue = globalThis.Vue;"
    end

    test "named imports destructure the global" do
      assert rewrite("import { ref, h as hh } from 'vue'", ["vue"], %{"vue" => "Vue"}) ==
               "const { ref, h: hh } = globalThis.Vue;"
    end

    test "dotted global names stay a property path" do
      assert rewrite("import { Socket } from 'phoenix'", ["phoenix"], %{
               "phoenix" => "window.Phoenix"
             }) ==
               "const { Socket } = globalThis.window.Phoenix;"
    end

    test "non-identifier global expressions are used verbatim" do
      assert rewrite("import { a } from 'x'", ["x"], %{"x" => ~s(window["my-lib"])}) ==
               ~s|const { a } = window["my-lib"];|
    end

    test "subpath of an external package is rewritten" do
      assert rewrite("import { createRoot } from 'react-dom/client'", ["react-dom"]) ==
               "const { createRoot } = globalThis.ReactDomClient;"
    end

    test "subpath uses an explicit global when configured" do
      globals = %{"react-dom" => "ReactDOM", "react-dom/client" => "ReactDOM"}

      assert rewrite("import { createRoot } from 'react-dom/client'", Map.keys(globals), globals) ==
               "const { createRoot } = globalThis.ReactDOM;"
    end

    test "mixed named and default imports" do
      assert rewrite("import Vue, { ref } from 'vue'", ["vue"], %{"vue" => "VueGlobal"}) ==
               "const { ref } = globalThis.VueGlobal;\n" <>
                 "const Vue = ((m) => m && m.__esModule ? m.default : m)(globalThis.VueGlobal);"
    end

    test "auto-derives the global name when not in the map" do
      assert rewrite("import { Button } from 'reka-ui'", ["reka-ui"]) ==
               "const { Button } = globalThis.RekaUi;"
    end

    test "ignores non-external imports and rewrites every module" do
      files = [
        {"a.js", "import { ref } from 'vue'\nimport { foo } from './utils'"},
        {"b.js", "import { computed } from 'vue'"}
      ]

      assert Externals.rewrite_imports(files, MapSet.new(["vue"]), %{"vue" => "Vue"}) == [
               {"a.js", "const { ref } = globalThis.Vue;\nimport { foo } from './utils'"},
               {"b.js", "const { computed } = globalThis.Vue;"}
             ]
    end

    test "packages sharing a name prefix are not external" do
      code = "import x from 'react-domino'"
      assert rewrite(code, ["react-dom"]) == code
    end
  end

  describe "Builder.derive_global_name/1" do
    test "scoped packages with hyphenated scopes" do
      assert DuskmoonBundler.Builder.derive_global_name("@duskmoon-dev/elements") == "Elements"
    end

    test "dots and other punctuation produce a valid identifier" do
      assert DuskmoonBundler.Builder.derive_global_name("highlight.js") == "HighlightJs"
      assert DuskmoonBundler.Builder.derive_global_name("@scope/pkg/sub.path") == "PkgSubPath"
    end

    test "leading digits are prefixed" do
      assert DuskmoonBundler.Builder.derive_global_name("3d-lib") == "_3dLib"
    end

    test "existing derivations are unchanged" do
      assert DuskmoonBundler.Builder.derive_global_name("reka-ui") == "RekaUi"
      assert DuskmoonBundler.Builder.derive_global_name("phoenix_live_view") == "PhoenixLiveView"
    end
  end
end
