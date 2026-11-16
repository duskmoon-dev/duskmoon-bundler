defmodule DuskmoonBundler.ChunkGraphTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.ChunkGraph

  describe "build/3" do
    test "single entry with no dynamic imports produces one chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/utils.ts", "utils.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: ["/app/utils.ts"], dynamic: []},
        "/app/utils.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert map_size(graph.chunks) == 1
      assert graph.chunks["entry"].type == :entry
      assert "/app/main.ts" in graph.chunks["entry"].modules
      assert "/app/utils.ts" in graph.chunks["entry"].modules
    end

    test "dynamic import creates async chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/utils.ts", "utils.ts", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: ["/app/utils.ts"], dynamic: ["/app/lazy.ts"]},
        "/app/utils.ts" => %{static: [], dynamic: []},
        "/app/lazy.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert map_size(graph.chunks) == 2
      assert graph.chunks["entry"].type == :entry
      refute "/app/lazy.ts" in graph.chunks["entry"].modules

      async_chunk = Enum.find(Map.values(graph.chunks), &(&1.type == :async))
      assert async_chunk
      assert "/app/lazy.ts" in async_chunk.modules
    end

    test "shared module extracted to common chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/shared.ts", "shared.ts", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: ["/app/shared.ts"], dynamic: ["/app/lazy.ts"]},
        "/app/shared.ts" => %{static: [], dynamic: []},
        "/app/lazy.ts" => %{static: ["/app/shared.ts"], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      common = graph.chunks["common"]
      assert common
      assert common.type == :common
      assert "/app/shared.ts" in common.modules
    end

    test "keeps CommonJS require chains with a shared singleton" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/node_modules/react/index.js", "react/index.js", ""},
        {"/app/node_modules/react-dom/client.js", "react-dom/client.js", ""},
        {"/app/node_modules/react-dom/cjs/client.js", "react-dom/cjs/client.js", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      react = "/app/node_modules/react/index.js"
      react_dom = "/app/node_modules/react-dom/client.js"
      react_dom_client = "/app/node_modules/react-dom/cjs/client.js"

      dep_map = %{
        "/app/main.ts" => %{
          static: [react, react_dom],
          dynamic: ["/app/lazy.ts"],
          requires: []
        },
        react => %{static: [], dynamic: [], requires: []},
        react_dom => %{static: [react_dom_client], dynamic: [], requires: [react_dom_client]},
        react_dom_client => %{static: [react], dynamic: [], requires: [react]},
        "/app/lazy.ts" => %{static: [react], dynamic: [], requires: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert graph.module_to_chunk[react] == "common"
      assert graph.module_to_chunk[react_dom] == "common"
      assert graph.module_to_chunk[react_dom_client] == "common"
      assert graph.module_to_chunk["/app/main.ts"] == "entry"
      assert graph.module_to_chunk["/app/lazy.ts"] not in ["entry", "common"]
    end

    test "never extracts a CommonJS entry into the common chunk" do
      react = "/app/node_modules/react/index.js"

      modules = [
        {"/app/main.js", "main.js", ""},
        {react, "react/index.js", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.js" => %{
          static: [react],
          dynamic: ["/app/lazy.ts"],
          requires: [react]
        },
        react => %{static: ["/app/main.js"], dynamic: [], requires: ["/app/main.js"]},
        "/app/lazy.ts" => %{static: [react], dynamic: [], requires: []}
      }

      graph = ChunkGraph.build("/app/main.js", modules, dep_map)

      assert graph.module_to_chunk["/app/main.js"] == "entry"
      assert graph.module_to_chunk[react] == "common"
    end

    test "extracts modules shared by async chunks even when entry does not import them" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/lazy-a.ts", "lazy-a.ts", ""},
        {"/app/lazy-b.ts", "lazy-b.ts", ""},
        {"/app/shared.ts", "shared.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: [], dynamic: ["/app/lazy-a.ts", "/app/lazy-b.ts"]},
        "/app/lazy-a.ts" => %{static: ["/app/shared.ts"], dynamic: []},
        "/app/lazy-b.ts" => %{static: ["/app/shared.ts"], dynamic: []},
        "/app/shared.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert "/app/shared.ts" in graph.chunks["common"].modules

      refute Enum.any?(Map.values(graph.chunks), fn chunk ->
               chunk.type == :async and "/app/shared.ts" in chunk.modules
             end)
    end

    test "maps dynamic entries shared by multiple chunks to common chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/entry-a.ts", "entry-a.ts", ""},
        {"/app/entry-b.ts", "entry-b.ts", ""},
        {"/app/shared-lazy.ts", "shared-lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: [], dynamic: ["/app/entry-a.ts", "/app/entry-b.ts"]},
        "/app/entry-a.ts" => %{static: ["/app/shared-lazy.ts"], dynamic: []},
        "/app/entry-b.ts" => %{static: ["/app/shared-lazy.ts"], dynamic: []},
        "/app/shared-lazy.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert graph.module_to_chunk["/app/shared-lazy.ts"] == "common"
    end

    test "async chunk importing the entry does not duplicate the entry module" do
      modules = [
        {"/app/router.ts", "router.ts", ""},
        {"/app/page.ts", "page.ts", ""}
      ]

      dep_map = %{
        "/app/router.ts" => %{static: [], dynamic: ["/app/page.ts"]},
        "/app/page.ts" => %{static: ["/app/router.ts"], dynamic: []}
      }

      graph = ChunkGraph.build("/app/router.ts", modules, dep_map)

      assert graph.chunks["entry"].modules == ["/app/router.ts"]
      assert graph.chunks["page"].modules == ["/app/page.ts"]
      assert graph.module_to_chunk["/app/router.ts"] == "entry"
      assert graph.chunks["page"].imports == ["entry"]
      assert graph.chunks["entry"].dynamic_imports == ["page"]
    end

    test "creates chunks for nested dynamic imports" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/lazy-parent.ts", "lazy-parent.ts", ""},
        {"/app/lazy-child.ts", "lazy-child.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: [], dynamic: ["/app/lazy-parent.ts"]},
        "/app/lazy-parent.ts" => %{static: [], dynamic: ["/app/lazy-child.ts"]},
        "/app/lazy-child.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert graph.module_to_chunk["/app/lazy-parent.ts"] != nil
      assert graph.module_to_chunk["/app/lazy-child.ts"] != nil

      assert graph.module_to_chunk["/app/lazy-parent.ts"] !=
               graph.module_to_chunk["/app/lazy-child.ts"]
    end

    test "records static and dynamic chunk links" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/static-vendor.ts", "static-vendor.ts", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: ["/app/static-vendor.ts"],
          dynamic: ["/app/lazy.ts"]
        },
        "/app/static-vendor.ts" => %{static: [], dynamic: []},
        "/app/lazy.ts" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map,
          manual_chunks: %{"vendor" => ["/app/static-vendor.ts"]}
        )

      assert graph.chunks["entry"].imports == ["vendor"]
      assert graph.chunks["entry"].dynamic_imports == [graph.module_to_chunk["/app/lazy.ts"]]
    end

    test "module_to_chunk maps dynamic entry to async chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: [], dynamic: ["/app/lazy.ts"]},
        "/app/lazy.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)
      assert graph.module_to_chunk["/app/lazy.ts"] != "entry"
    end

    test "keeps dynamic entry facade even when the entry also imports it statically" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/feature.ts", "feature.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: ["/app/feature.ts"], dynamic: ["/app/feature.ts"]},
        "/app/feature.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map)

      assert graph.module_to_chunk["/app/feature.ts"] != "common"
      assert graph.module_to_chunk["/app/feature.ts"] != "entry"
      assert "/app/feature.ts" in graph.chunks[graph.module_to_chunk["/app/feature.ts"]].modules
    end
  end

  describe "manual chunks" do
    test "extracts matching modules into a named chunk" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/node_modules/vue/index.js", "vue", ""},
        {"/app/node_modules/vue-router/index.js", "vue-router", ""},
        {"/app/utils.ts", "utils.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: [
            "/app/node_modules/vue/index.js",
            "/app/node_modules/vue-router/index.js",
            "/app/utils.ts"
          ],
          dynamic: []
        },
        "/app/node_modules/vue/index.js" => %{static: [], dynamic: []},
        "/app/node_modules/vue-router/index.js" => %{static: [], dynamic: []},
        "/app/utils.ts" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map,
          manual_chunks: %{"vendor" => ["vue", "vue-router"]}
        )

      assert graph.chunks["vendor"].type == :manual
      assert "/app/node_modules/vue/index.js" in graph.chunks["vendor"].modules
      assert "/app/node_modules/vue-router/index.js" in graph.chunks["vendor"].modules

      refute "/app/node_modules/vue/index.js" in graph.chunks["entry"].modules
      assert "/app/utils.ts" in graph.chunks["entry"].modules

      assert "vendor" in graph.chunks["entry"].imports
    end

    test "path patterns match by directory prefix" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/src/components/Button.ts", "Button.ts", ""},
        {"/app/src/components/Modal.ts", "Modal.ts", ""},
        {"/app/src/utils.ts", "utils.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: [
            "/app/src/components/Button.ts",
            "/app/src/components/Modal.ts",
            "/app/src/utils.ts"
          ],
          dynamic: []
        },
        "/app/src/components/Button.ts" => %{static: [], dynamic: []},
        "/app/src/components/Modal.ts" => %{static: [], dynamic: []},
        "/app/src/utils.ts" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map,
          manual_chunks: %{"ui" => ["/app/src/components"]}
        )

      assert graph.chunks["ui"].type == :manual
      assert "/app/src/components/Button.ts" in graph.chunks["ui"].modules
      assert "/app/src/components/Modal.ts" in graph.chunks["ui"].modules

      refute "/app/src/utils.ts" in graph.chunks["ui"].modules
    end

    test "manual chunks coexist with dynamic imports" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/node_modules/vue/index.js", "vue", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: ["/app/node_modules/vue/index.js"],
          dynamic: ["/app/lazy.ts"]
        },
        "/app/node_modules/vue/index.js" => %{static: [], dynamic: []},
        "/app/lazy.ts" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map, manual_chunks: %{"vendor" => ["vue"]})

      assert graph.chunks["vendor"].type == :manual
      assert graph.chunks["entry"].type == :entry

      async = Enum.find(Map.values(graph.chunks), &(&1.type == :async))
      assert async
      assert "/app/lazy.ts" in async.modules
    end

    test "module_to_chunk reflects manual assignments" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/node_modules/lodash/index.js", "lodash", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: ["/app/node_modules/lodash/index.js"],
          dynamic: []
        },
        "/app/node_modules/lodash/index.js" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map,
          manual_chunks: %{"vendor" => ["lodash"]}
        )

      assert graph.module_to_chunk["/app/node_modules/lodash/index.js"] == "vendor"
    end

    defp manual_graph(paths, manual_chunks, opts \\ []) do
      modules = [{"/app/main.ts", "main.ts", ""} | Enum.map(paths, &{&1, Path.basename(&1), ""})]

      dep_map =
        paths
        |> Map.new(&{&1, %{static: [], dynamic: []}})
        |> Map.put("/app/main.ts", %{static: paths, dynamic: []})

      ChunkGraph.build("/app/main.ts", modules, dep_map, [manual_chunks: manual_chunks] ++ opts)
    end

    test "bare patterns match scoped packages" do
      core = "/app/node_modules/@duskmoon-dev/core/dist/index.js"
      other = "/app/node_modules/@duskmoon-dev/core-extras/index.js"

      graph = manual_graph([core, other], %{"vendor" => ["@duskmoon-dev/core"]})

      assert graph.chunks["vendor"].modules == [core]
      assert graph.module_to_chunk[other] == "entry"
    end

    test "bare patterns match package subpaths" do
      fp_file = "/app/node_modules/lodash/fp.js"
      fp_dir = "/app/node_modules/lodash/fp/placeholder.js"
      main = "/app/node_modules/lodash/lodash.js"

      graph = manual_graph([fp_file, fp_dir, main], %{"fp" => ["lodash/fp"]})

      assert graph.chunks["fp"].modules == [fp_file, fp_dir]
      assert graph.module_to_chunk[main] == "entry"
    end

    test "bare patterns match packages under configured package directories" do
      phoenix = "/app/deps/phoenix/priv/static/phoenix.mjs"
      html = "/app/deps/phoenix_html/priv/static/phoenix_html.js"

      graph =
        manual_graph([phoenix, html], %{"vendor" => ["phoenix"]}, package_dirs: ["/app/deps"])

      assert graph.chunks["vendor"].modules == [phoenix]
      assert graph.module_to_chunk[html] == "entry"
    end

    test "relative directory patterns containing a slash still match by path" do
      button = Path.expand("assets/src/components/Button.ts")
      utils = Path.expand("assets/src/utils.ts")

      graph = manual_graph([button, utils], %{"ui" => ["assets/src/components"]})

      assert graph.chunks["ui"].modules == [button]
      assert graph.unmatched_patterns == []
    end

    test "reports patterns that match no module" do
      vue = "/app/node_modules/vue/index.js"

      graph = manual_graph([vue], %{"vendor" => ["vue", "pinia"], "ui" => ["@scope/missing"]})

      assert graph.unmatched_patterns == [{"ui", "@scope/missing"}, {"vendor", "pinia"}]
      refute Map.has_key?(graph.chunks, "ui")
    end

    test "async chunk ids do not collide with manual chunk names" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/node_modules/vue/index.js", "vue", ""},
        {"/app/lazy.ts", "lazy.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{
          static: ["/app/node_modules/vue/index.js"],
          dynamic: ["/app/lazy.ts"]
        },
        "/app/node_modules/vue/index.js" => %{static: [], dynamic: []},
        "/app/lazy.ts" => %{static: [], dynamic: []}
      }

      graph =
        ChunkGraph.build("/app/main.ts", modules, dep_map, manual_chunks: %{"lazy" => ["vue"]})

      assert graph.chunks["lazy"].type == :manual
      assert graph.chunks["lazy"].modules == ["/app/node_modules/vue/index.js"]

      async = Enum.find(Map.values(graph.chunks), &(&1.type == :async))
      assert async.modules == ["/app/lazy.ts"]
      assert graph.module_to_chunk["/app/lazy.ts"] == async.id
    end

    test "empty manual chunks config has no effect" do
      modules = [
        {"/app/main.ts", "main.ts", ""},
        {"/app/utils.ts", "utils.ts", ""}
      ]

      dep_map = %{
        "/app/main.ts" => %{static: ["/app/utils.ts"], dynamic: []},
        "/app/utils.ts" => %{static: [], dynamic: []}
      }

      graph = ChunkGraph.build("/app/main.ts", modules, dep_map, manual_chunks: %{})
      assert map_size(graph.chunks) == 1
    end
  end
end
