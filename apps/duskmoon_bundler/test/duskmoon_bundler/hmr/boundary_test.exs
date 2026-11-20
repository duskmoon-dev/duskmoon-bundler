defmodule DuskmoonBundler.HMR.BoundaryTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.HMR.{Boundary, ImportGraph, ModuleGraph}

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

  describe "self_accepting?/2" do
    @typed_source """
    export const count: number = 1
    export function double(value: number): number { return value * 2 }
    if (import.meta.hot) import.meta.hot.accept()
    """

    test "parses TypeScript sources by their real filename" do
      refute Boundary.self_accepting?(@typed_source)
      assert Boundary.self_accepting?(@typed_source, "/app/counter.ts")
      refute Boundary.self_accepting?("export const count: number = 1", "/app/counter.ts")
    end

    test "parses TSX sources by their real filename" do
      assert Boundary.self_accepting?(
               """
               export const View = (props: { label: string }) => <b>{props.label}</b>
               import.meta.hot?.accept()
               """,
               "/app/View.tsx"
             ) ==
               Boundary.self_accepting?(
                 "export const View = (props) => null\nimport.meta.hot?.accept()",
                 "/app/View.js"
               )
    end

    test "keeps the JavaScript default for non-script extensions" do
      assert Boundary.self_accepting?("import.meta.hot.accept()", "/app/Widget.vue")
    end
  end

  describe "component script boundaries" do
    for extension <- ["vue", "svelte"] do
      @extension extension

      test "detects TypeScript self-acceptance inside .#{extension} script blocks" do
        source = """
        <script lang="ts">
          const count: number = 1
          import.meta.hot.accept()
        </script>
        <p>{count}</p>
        """

        assert Boundary.self_accepting?(source, "/app/Widget.#{@extension}")
      end

      test "ignores template text and comments in .#{extension}" do
        source = """
        <script>const text = "import.meta.hot.accept()"</script>
        <!-- import.meta.hot.accept() -->
        <p>import.meta.hot.accept()</p>
        """

        refute Boundary.self_accepting?(source, "/app/Widget.#{@extension}")
      end
    end

    test "detects Vue script setup and both Svelte script contexts" do
      assert Boundary.self_accepting?(
               "<script setup lang=\"ts\">import.meta.hot.accept()</script><p>ok</p>",
               "/app/Widget.vue"
             )

      assert Boundary.self_accepting?(
               """
               <script context="module" lang="ts">const value: number = 1</script>
               <script lang="ts">import.meta.hot.accept()</script>
               <p>ok</p>
               """,
               "/app/Widget.svelte"
             )
    end
  end

  describe "find_boundary/2" do
    setup do
      ImportGraph.clear()
      ModuleGraph.clear()
      :ok
    end

    test "returns a type-annotated TypeScript file that self-accepts" do
      read = fn _path -> @typed_source end

      assert {:ok, "/app/counter.ts"} = Boundary.find_boundary("/app/counter.ts", read)
    end

    test "detects dependency accepts in type-annotated TypeScript importers" do
      ImportGraph.update("/app/main.ts", ["./dep"])

      read = fn
        "/app/main.ts" ->
          """
          import { dep } from "./dep"
          const label: string = dep
          import.meta.hot.accept("./dep", () => {})
          """

        _ ->
          "export const dep: string = 'dep'"
      end

      assert {:ok, "/app/main.ts"} = Boundary.find_boundary("/app/dep.ts", read)
    end

    for extension <- ["vue", "svelte"] do
      @extension extension

      test "finds dependency acceptance in raw .#{extension} importers" do
        importer = "/app/Widget.#{@extension}"
        ImportGraph.update(importer, ["./dep.ts"])

        read = fn
          ^importer ->
            """
            <script lang="ts">
              import { value } from "./dep.ts"
              import.meta.hot.accept("./dep.ts", () => {})
            </script>
            <p>{value}</p>
            """

          _ ->
            "export const value: number = 2"
        end

        assert {:ok, ^importer} = Boundary.find_boundary("/app/dep.ts", read)
      end
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
      ModuleGraph.update_module(
        "/assets/App.tsx",
        "/assets/App.tsx",
        "/app/App.tsx",
        ["/assets/Button.tsx"]
      )

      ModuleGraph.update_module(
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
      ModuleGraph.update_module(
        "/assets/App.tsx",
        "/assets/App.tsx",
        "/app/App.tsx",
        ["/assets/Button.tsx"],
        self_accepting: true
      )

      ModuleGraph.update_module(
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
      ModuleGraph.update_module(
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
      ImportGraph.update("/app/App.tsx", ["./Button"])

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
      ImportGraph.update("/app/Accepting.ts", ["./util"])
      ImportGraph.update("/app/Plain.ts", ["./util"])
      ImportGraph.update("/app/main.ts", ["./Accepting", "./Plain"])

      read = fn
        "/app/Accepting.ts" -> "import './util'\nimport.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert :full_reload = Boundary.find_boundaries("/app/util.ts", read)
    end

    test "fallback propagation collects every boundary" do
      ImportGraph.update("/app/A.ts", ["./util"])
      ImportGraph.update("/app/B.ts", ["./util.ts"])

      read = fn
        path when path in ["/app/A.ts", "/app/B.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert {:ok, boundaries} = Boundary.find_boundaries("/app/util.ts", read)
      assert Enum.sort(boundaries) == ["/app/A.ts", "/app/B.ts"]
    end

    test "fallback importer lookup resolves full paths, not basenames" do
      ImportGraph.update("/app/main.ts", ["./b/index"])
      ImportGraph.update("/app/lib.ts", ["lib/index", "@/a/index"])

      read = fn
        path when path in ["/app/main.ts", "/app/lib.ts"] -> "import.meta.hot.accept()"
        _ -> "export const x = 1"
      end

      assert :full_reload = Boundary.find_boundary("/app/a/index.ts", read)
      assert {:ok, "/app/main.ts"} = Boundary.find_boundary("/app/b/index.ts", read)
    end

    test "fallback importer lookup resolves directory index and parent specifiers" do
      ImportGraph.update("/app/main.ts", ["./a"])
      ImportGraph.update("/app/pages/page.ts", ["../shared/util.js"])

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
    ModuleGraph.update_module(file, file, file, imports)
  end
end
