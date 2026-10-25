defmodule DuskmoonBundler.Integration.RuntimeVendorTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir

  alias DuskmoonBundler.Integration.CDPBrowser

  defmodule RuntimePlug do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      # Match Phoenix's :plug_init_mode, :runtime, including pass-through requests.
      config = DuskmoonBundler.DevServer.init(root: opts[:root], prefix: "/assets")

      case DuskmoonBundler.DevServer.call(conn, config) do
        %{halted: true} = conn ->
          conn

        conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, ~s(<script type="module" src="/assets/app.ts"></script>))
      end
    end
  end

  test "cache-disabled browser reloads and concurrent requests preserve dependency invalidation",
       %{
         tmp_dir: root
       } do
    packages = Enum.map(1..10, &"runtime-vendor-#{&1}")
    write_package(root, "singleton-state", "export const state = {value: 'first'};")

    for package <- packages do
      write_package(root, package, "export {state} from 'singleton-state';")
    end

    write_entry(root, packages)
    DuskmoonBundler.Cache.clear()
    port = 40_000 + rem(System.unique_integer([:positive]), 10_000)

    start_supervised!(
      {Gaoxy.HTTP, plug: {RuntimePlug, root: root}, port: port, ip: {127, 0, 0, 1}}
    )

    browser = start_supervised!(CDPBrowser)
    {:ok, page} = CDPBrowser.new_page(browser)
    {:ok, _} = CDPBrowser.command(page, "Network.enable")
    {:ok, _} = CDPBrowser.command(page, "Network.setCacheDisabled", %{cacheDisabled: true})

    for _ <- 1..3 do
      :ok = CDPBrowser.goto(page, "http://127.0.0.1:#{port}/")

      assert {:ok, %{"shared" => true, "values" => values}} =
               CDPBrowser.evaluate(page, "window.vendorResult")

      assert values == List.duplicate("first", 10)
    end

    assert {:ok, results} =
             CDPBrowser.evaluate(page, """
             Promise.all(Array.from({length: 16}, async (_, i) => {
               const response = await fetch('/@vendor/runtime-vendor-' + (i % 4 + 1) + '.js',
                 {cache: 'no-store'});
               return {status: response.status, code: (await response.text()).includes('state')};
             }))
             """)

    assert results == List.duplicate(%{"status" => 200, "code" => true}, 16)

    # Same-length edits must invalidate without a lockfile or an mtime delay.
    write_package(root, "singleton-state", "export const state = {value: 'later'};")
    :ok = CDPBrowser.goto(page, "http://127.0.0.1:#{port}/")

    assert {:ok, %{"shared" => true, "values" => values}} =
             CDPBrowser.evaluate(page, "window.vendorResult")

    assert values == List.duplicate("later", 10)

    # A changed local import graph must still be prebundled as one shared graph.
    write_package(root, "late-vendor", "export {state} from 'singleton-state';")
    write_entry(root, packages ++ ["late-vendor"])
    :ok = CDPBrowser.goto(page, "http://127.0.0.1:#{port}/")

    assert {:ok, %{"shared" => true, "values" => values}} =
             CDPBrowser.evaluate(page, "window.vendorResult")

    assert values == List.duplicate("later", 11)
  end

  defp write_package(root, package, source) do
    dir = Path.join(root, "node_modules/#{package}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "package.json"),
      JSON.encode!(%{"name" => package, "main" => "index.js", "type" => "module"})
    )

    File.write!(Path.join(dir, "index.js"), source)
  end

  defp write_entry(root, packages) do
    imports =
      packages
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {package, n} ->
        "import {state as state#{n}} from '#{package}';"
      end)

    states = packages |> Enum.with_index() |> Enum.map_join(",", fn {_, n} -> "state#{n}" end)

    File.write!(Path.join(root, "app.ts"), """
    #{imports}
    const states = [#{states}];
    window.vendorResult = {
      shared: states.every(state => state === states[0]),
      values: states.map(state => state.value)
    };
    """)
  end
end
