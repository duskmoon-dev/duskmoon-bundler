defmodule DuskmoonBundler.HMR.BoundaryTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.HMR.Boundary

  describe "self_accepting?/1" do
    test "detects import.meta.hot.accept()" do
      assert Boundary.self_accepting?("""
               if (import.meta.hot) {
                 import.meta.hot.accept()
               }
             """)
    end

    test "detects import.meta.hot.accept(callback)" do
      assert Boundary.self_accepting?("import.meta.hot.accept((mod) => console.log(mod))")
    end

    test "rejects dependency accept calls" do
      refute Boundary.self_accepting?(~s|import.meta.hot.accept("./dep", () => {})|)
      refute Boundary.self_accepting?(~s|import.meta.hot.accept(["./dep"], () => {})|)
    end

    test "rejects code without accept" do
      refute Boundary.self_accepting?("const x = 1")
    end

    test "rejects code with only import.meta.hot but no accept" do
      refute Boundary.self_accepting?("if (import.meta.hot) { import.meta.hot.dispose() }")
    end

    test "rejects comments and unrelated hot.accept calls" do
      refute Boundary.self_accepting?("// import.meta.hot.accept()")
      refute Boundary.self_accepting?("foo.hot.accept()")
    end
  end

  describe "find_boundary/2" do
    setup do
      DuskmoonBundler.HMR.ImportGraph.clear()
      DuskmoonBundler.HMR.ModuleGraph.clear()
      :ok
    end

    test "returns changed file when it self-accepts" do
      source_with_hmr = """
        export const x = 1;
        if (import.meta.hot) {
          import.meta.hot.accept()
        }
      """

      read = fn _path -> source_with_hmr end

      assert {:ok, "/app/Button.tsx"} =
               Boundary.find_boundary("/app/Button.tsx", read)
    end

    test "returns :full_reload when no boundary exists" do
      read = fn _path -> "export const x = 1" end

      assert :full_reload = Boundary.find_boundary("/app/utils.ts", read)
    end

    test "finds dependency-accepting boundary in parent module through HMR module graph" do
      DuskmoonBundler.HMR.ModuleGraph.update_module(
        "/assets/App.tsx",
        "/assets/App.tsx",
        "/app/App.tsx",
        ["/assets/Button.tsx"]
      )

      DuskmoonBundler.HMR.ModuleGraph.update_module(
        "/assets/Button.tsx",
        "/assets/Button.tsx",
        "/app/Button.tsx",
        []
      )

      read = fn
        "/app/App.tsx" ->
          "import Button from './Button'\nif (import.meta.hot) { import.meta.hot.accept('./Button', () => {}) }"

        "/app/Button.tsx" ->
          "export default function Button() {}"
      end

      assert {:ok, "/app/App.tsx"} =
               Boundary.find_boundary("/app/Button.tsx", read)
    end

    test "finds boundary in parent module through HMR module graph" do
      DuskmoonBundler.HMR.ModuleGraph.update_module(
        "/assets/App.tsx",
        "/assets/App.tsx",
        "/app/App.tsx",
        ["/assets/Button.tsx"],
        self_accepting: true
      )

      DuskmoonBundler.HMR.ModuleGraph.update_module(
        "/assets/Button.tsx",
        "/assets/Button.tsx",
        "/app/Button.tsx",
        []
      )

      read = fn
        "/app/App.tsx" ->
          "import Button from './Button'\nif (import.meta.hot) { import.meta.hot.accept() }"

        "/app/Button.tsx" ->
          "export default function Button() {}"
      end

      assert {:ok, "/app/App.tsx"} =
               Boundary.find_boundary("/app/Button.tsx", read)
    end

    test "prefers current source over stale graph self-accepting flag" do
      DuskmoonBundler.HMR.ModuleGraph.update_module(
        "/assets/App.tsx",
        "/assets/App.tsx",
        "/app/App.tsx",
        [],
        self_accepting: true
      )

      read = fn "/app/App.tsx" -> "export default function App() {}" end

      assert :full_reload = Boundary.find_boundary("/app/App.tsx", read)
    end

    test "falls back to raw import graph" do
      DuskmoonBundler.HMR.ImportGraph.update("/app/App.tsx", ["./Button"])

      read = fn
        "/app/App.tsx" ->
          "import Button from './Button'\nif (import.meta.hot) { import.meta.hot.accept() }"

        "/app/Button.tsx" ->
          "export default function Button() {}"
      end

      assert {:ok, "/app/App.tsx"} =
               Boundary.find_boundary("/app/Button.tsx", read)
    end

    test "graph propagation full-reloads when any importer path reaches an entry" do
      graph_module("/app/util.ts", [])
      graph_module("/app/Accepting.vue", ["/app/util.ts"])
      graph_module("/app/Plain.ts", ["/app/util.ts"])
      graph_module("/app/main.ts", ["/app/Accepting.vue", "/app/Plain.ts"])

      read = fn
        "/app/Accepting.vue" -> "import './util'\nimport.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert :full_reload = Boundary.find_boundary("/app/util.ts", read)
      assert :full_reload = Boundary.find_boundaries("/app/util.ts", read)
    end

    test "graph propagation collects every boundary" do
      graph_module("/app/util.ts", [])
      graph_module("/app/A.ts", ["/app/util.ts"])
      graph_module("/app/B.ts", ["/app/util.ts"])
      graph_module("/app/main.ts", ["/app/A.ts", "/app/B.ts"])

      read = fn
        path when path in ["/app/A.ts", "/app/B.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert {:ok, boundaries} = Boundary.find_boundaries("/app/util.ts", read)
      assert Enum.sort(boundaries) == ["/app/A.ts", "/app/B.ts"]
      assert :full_reload = Boundary.find_boundary("/app/util.ts", read)
    end

    test "fallback propagation full-reloads when any importer path reaches an entry" do
      DuskmoonBundler.HMR.ImportGraph.update("/app/Accepting.ts", ["./util"])
      DuskmoonBundler.HMR.ImportGraph.update("/app/Plain.ts", ["./util"])
      DuskmoonBundler.HMR.ImportGraph.update("/app/main.ts", ["./Accepting", "./Plain"])

      read = fn
        "/app/Accepting.ts" -> "import './util'\nimport.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert :full_reload = Boundary.find_boundaries("/app/util.ts", read)
    end

    test "fallback propagation collects every boundary" do
      DuskmoonBundler.HMR.ImportGraph.update("/app/A.ts", ["./util"])
      DuskmoonBundler.HMR.ImportGraph.update("/app/B.ts", ["./util.ts"])

      read = fn
        path when path in ["/app/A.ts", "/app/B.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert {:ok, boundaries} = Boundary.find_boundaries("/app/util.ts", read)
      assert Enum.sort(boundaries) == ["/app/A.ts", "/app/B.ts"]
    end

    test "fallback importer lookup resolves full paths, not basenames" do
      DuskmoonBundler.HMR.ImportGraph.update("/app/main.ts", ["./b/index"])
      DuskmoonBundler.HMR.ImportGraph.update("/app/lib.ts", ["lib/index", "@/a/index"])

      read = fn
        path when path in ["/app/main.ts", "/app/lib.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert :full_reload = Boundary.find_boundary("/app/a/index.ts", read)
      assert {:ok, "/app/main.ts"} = Boundary.find_boundary("/app/b/index.ts", read)
    end

    test "fallback importer lookup resolves directory index and parent specifiers" do
      DuskmoonBundler.HMR.ImportGraph.update("/app/main.ts", ["./a"])
      DuskmoonBundler.HMR.ImportGraph.update("/app/pages/page.ts", ["../shared/util.js"])

      read = fn
        path when path in ["/app/main.ts", "/app/pages/page.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert {:ok, "/app/main.ts"} = Boundary.find_boundary("/app/a/index.ts", read)
      assert {:ok, "/app/pages/page.ts"} = Boundary.find_boundary("/app/shared/util.ts", read)
    end

    test "returns :full_reload when file doesn't exist" do
      read = fn _path -> nil end

      assert :full_reload = Boundary.find_boundary("/app/missing.ts", read)
    end
  end

  defp graph_module(file, imports) do
    DuskmoonBundler.HMR.ModuleGraph.update_module(file, file, file, imports)
  end
end
