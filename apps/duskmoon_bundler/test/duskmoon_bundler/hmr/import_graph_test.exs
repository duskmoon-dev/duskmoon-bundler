defmodule DuskmoonBundler.HMR.ImportGraphTest do
  use ExUnit.Case, async: false

  alias DuskmoonBundler.HMR.ImportGraph

  setup do
    ImportGraph.clear()
    :ok
  end

  test "tracks imports for a file" do
    ImportGraph.update("/src/App.vue", ["vue", "./utils"])
    assert ImportGraph.imports_of("/src/App.vue") == ["vue", "./utils"]
  end

  test "finds dependents of a specifier" do
    ImportGraph.update("/src/App.vue", ["./utils", "vue"])
    ImportGraph.update("/src/Page.vue", ["./utils"])
    ImportGraph.update("/src/main.ts", ["vue"])

    dependents = ImportGraph.dependents("./utils")
    assert "/src/App.vue" in dependents
    assert "/src/Page.vue" in dependents
    refute "/src/main.ts" in dependents
  end

  test "update replaces previous imports" do
    ImportGraph.update("/src/App.vue", ["vue", "./old"])
    ImportGraph.update("/src/App.vue", ["vue", "./new"])
    assert ImportGraph.imports_of("/src/App.vue") == ["vue", "./new"]
  end

  test "update_from_compiled extracts imports" do
    compiled = """
    import './setup'
    const pages = { './pages/home.ts': () => import('./pages/home.ts') }
    """

    ImportGraph.update_from_compiled("/src/routes.ts", compiled)

    assert "./setup" in ImportGraph.imports_of("/src/routes.ts")
  end

  test "remove deletes a file from the graph" do
    ImportGraph.update("/src/App.vue", ["vue"])
    ImportGraph.remove("/src/App.vue")
    assert ImportGraph.imports_of("/src/App.vue") == []
  end
end
