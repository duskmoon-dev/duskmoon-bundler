defmodule DuskmoonBundler.Integration.VendorCacheTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir

  alias DuskmoonBundler.Integration.CDPBrowser

  defmodule RuntimePlug do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      conn =
        if opts[:legacy_cache] == true and String.starts_with?(conn.request_path, "/@vendor/") and
             conn.query_string == "" do
          Plug.Conn.register_before_send(conn, fn conn ->
            Plug.Conn.put_resp_header(conn, "cache-control", "max-age=31536000, immutable")
          end)
        else
          conn
        end

      config =
        DuskmoonBundler.DevServer.init(
          root: opts[:root],
          entry: Path.join(opts[:root], "app.ts"),
          prefix: "/assets",
          vendor_prebundle: opts[:prebundle]
        )

      case DuskmoonBundler.DevServer.call(conn, config) do
        %{halted: true} = conn ->
          conn

        conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, File.read!(Path.join(opts[:root], "index.html")))
      end
    end
  end

  for prebundle <- [false, true] do
    @tag prebundle: prebundle
    test "cached vendor entries share the current runtime after graph changes and restart (prebundle=#{prebundle})",
         %{tmp_dir: root, prebundle: prebundle} do
      packages = ["cache-button", "cache-editor"]

      write_package(
        root,
        "singleton-state",
        "export const state = {value: 'first', url: import.meta.url};"
      )

      for package <- packages do
        write_package(root, package, "export {state} from 'singleton-state';")
      end

      write_entry(root, packages)
      File.write!(Path.join(root, "bun.lock"), "graph-first")
      DuskmoonBundler.Cache.clear()

      server = start_server(root, prebundle, 0)
      %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
      url = "http://127.0.0.1:#{port}/"
      browser = start_supervised!(CDPBrowser)
      {:ok, page} = CDPBrowser.new_page(browser)
      {:ok, _} = CDPBrowser.command(page, "Network.enable")
      {:ok, _} = CDPBrowser.command(page, "Network.setCacheDisabled", %{cacheDisabled: false})

      for _ <- 1..2 do
        assert :ok = CDPBrowser.goto(page, url)
        assert_current_runtime(page, "first", 3)
      end

      # Keep the browser context and its HTTP cache while all vendor entry bytes change.
      write_package(
        root,
        "singleton-state",
        "export const state = {value: 'later', url: import.meta.url};"
      )

      write_package(root, "cache-late", "export {state} from 'singleton-state';")
      write_entry(root, packages ++ ["cache-late"])
      File.write!(Path.join(root, "bun.lock"), "graph-later")
      assert :ok = CDPBrowser.goto(page, url)
      assert_current_runtime(page, "later", 4)

      # A normal navigation to the restarted listener must retain the same guarantee.
      stop_supervised!(:vendor_cache_http)
      start_server(root, prebundle, port)
      assert :ok = CDPBrowser.goto(page, url)
      assert_current_runtime(page, "later", 4)
    end

    @tag prebundle: prebundle
    test "versioned imports avoid immutable aliases cached before upgrade (prebundle=#{prebundle})",
         %{tmp_dir: root, prebundle: prebundle} do
      packages = ["cache-button", "cache-editor", "singleton-state"]
      write_package(root, "singleton-state", "export const state = {value: 'first'};")

      for package <- Enum.take(packages, 2) do
        write_package(root, package, "export {state} from 'singleton-state';")
      end

      write_versioned_entry(root, packages)
      File.write!(Path.join(root, "bun.lock"), "graph-first")
      DuskmoonBundler.Cache.clear()

      server = start_server(root, prebundle, 0, legacy_cache: true)
      %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
      url = "http://127.0.0.1:#{port}/"
      browser = start_supervised!(CDPBrowser)
      {:ok, page} = CDPBrowser.new_page(browser)
      {:ok, _} = CDPBrowser.command(page, "Network.enable")
      {:ok, _} = CDPBrowser.command(page, "Network.setCacheDisabled", %{cacheDisabled: false})
      assert :ok = CDPBrowser.goto(page, url)
      assert_current_runtime(page, "first", 3)

      assert {:ok, %{"header" => "max-age=31536000, immutable", "code" => cached_code}} =
               CDPBrowser.evaluate(page, """
               (async () => {
                 const response = await fetch('/@vendor/singleton-state.js');
                 return {header: response.headers.get('cache-control'), code: await response.text()};
               })()
               """)

      write_package(root, "singleton-state", "export const state = {value: 'later'};")
      File.write!(Path.join(root, "bun.lock"), "graph-later")
      stop_supervised!(:vendor_cache_http)
      start_server(root, prebundle, port)
      assert :ok = CDPBrowser.goto(page, url)
      assert_current_runtime(page, "later", 3)

      # The old alias stays cached; the current graph must avoid that URL.
      assert {:ok, ^cached_code} =
               CDPBrowser.evaluate(
                 page,
                 "fetch('/@vendor/singleton-state.js').then(r => r.text())"
               )
    end
  end

  defp start_server(root, prebundle, port, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Gaoxy.HTTP,
         plug: {RuntimePlug, [root: root, prebundle: prebundle] ++ opts},
         port: port,
         ip: {127, 0, 0, 1}},
        id: :vendor_cache_http
      )
    )
  end

  defp assert_current_runtime(page, value, count) do
    assert {:ok, %{"shared" => true, "values" => values}} =
             CDPBrowser.evaluate(page, """
             (() => {
               const states = [window.currentVendorState, ...window.cachedVendorStates];
               return {
                 shared: states.every(state => state === states[0]),
                 values: states.map(state => state.value),
                 urls: states.map(state => state.url)
               };
             })()
             """)

    assert values == List.duplicate(value, count)
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
        "import {state as state#{n}} from '/@vendor/#{package}.js';"
      end)

    states = Enum.map(Enum.with_index(packages), fn {_, n} -> "state#{n}" end)

    File.write!(Path.join(root, "app.ts"), """
    import {state as current} from 'cache-button';
    #{Enum.map_join(packages, "\n", &"import '#{&1}';")}
    window.currentVendorState = current;
    """)

    File.write!(Path.join(root, "index.html"), """
    <script type="module" src="/assets/app.ts"></script>
    <script type="module">
    #{imports}
    window.cachedVendorStates = [#{Enum.join(states, ",")}];
    </script>
    """)
  end

  defp write_versioned_entry(root, packages) do
    imports =
      packages
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {package, n} ->
        "import {state as state#{n}} from '#{package}';"
      end)

    states = Enum.map(Enum.with_index(packages), fn {_, n} -> "state#{n}" end)

    File.write!(Path.join(root, "app.ts"), """
    #{imports}
    window.currentVendorState = state0;
    window.cachedVendorStates = [#{states |> Enum.drop(1) |> Enum.join(",")}];
    """)

    File.write!(Path.join(root, "index.html"), """
    <script type="module" src="/assets/app.ts"></script>
    """)
  end
end
