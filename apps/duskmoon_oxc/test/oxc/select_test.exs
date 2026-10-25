defmodule OXC.SelectTest do
  use ExUnit.Case, async: true

  test "selects static worker URL literals with their complete byte spans" do
    for {constructor, kind} <- [{"Worker", :worker}, {"SharedWorker", :shared_worker}],
        literal <- [~S("./worker.js"), ~S(`./worker.js`), ~S(`./\u0077orker.js`)] do
      source =
        ~s|const marker = "😀"; new #{constructor}(new URL(#{literal}, import.meta.url), {type: "module"});|

      assert {:ok, [%{specifier: "./worker.js", kind: ^kind, start: start, end: finish}]} =
               OXC.select(source, "worker.js", :workers)

      assert binary_part(source, start, finish - start) == literal
    end
  end

  test "selects static template asset URLs using their cooked value and full span" do
    literal = ~S(`./\u0069mage.png`)
    source = "new URL(#{literal}, import.meta.url);"

    assert {:ok, [%{specifier: "./image.png", start: start, end: finish}]} =
             OXC.select(source, "asset.js", :asset_urls)

    assert binary_part(source, start, finish - start) == literal
  end

  test "ignores worker and asset URLs with substitutions or a different base" do
    for argument <- [~S(`./${name}.js`, import.meta.url), ~S("./worker.js", location.href)] do
      source = "new SharedWorker(new URL(#{argument}), {type: 'module'});"

      assert {:ok, []} = OXC.select(source, "dynamic.js", :workers)
      assert {:ok, []} = OXC.select(source, "dynamic.js", :asset_urls)
    end
  end

  test "selects worker URL literals emitted by minification" do
    for {constructor, kind} <- [{"Worker", :worker}, {"SharedWorker", :shared_worker}] do
      source =
        ~s|new #{constructor}(new URL("./worker.js", import.meta.url), {type: "module"});|

      assert {:ok, minified} = OXC.minify(source, "worker.js")

      assert {:ok, [%{specifier: "./worker.js", kind: ^kind}]} =
               OXC.select(minified, "worker.js", :workers)
    end
  end
end
