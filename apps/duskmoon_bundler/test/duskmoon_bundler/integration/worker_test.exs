defmodule DuskmoonBundler.Integration.WorkerTest do
  use ExUnit.Case, async: false

  alias DuskmoonBundler.Integration.CDPBrowser

  @moduletag :integration
  @moduletag :tmp_dir

  defmodule WorkerPlug do
    @behaviour Plug

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/"} = conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<!doctype html><html><body></body></html>")
    end

    def call(conn, opts) do
      case DuskmoonBundler.DevServer.call(conn, opts[:dev_server]) do
        %{halted: true} = conn -> conn
        conn -> Plug.Conn.send_resp(conn, 404, "not found")
      end
    end
  end

  setup_all do
    {:ok, browser} = CDPBrowser.start_link()
    on_exit(fn -> CDPBrowser.stop(browser) end)
    %{browser: browser}
  end

  setup %{tmp_dir: root, browser: browser} do
    write_fixture(root)
    DuskmoonBundler.Cache.clear()
    DuskmoonBundler.HMR.ModuleGraph.clear()
    DuskmoonBundler.HMR.ImportGraph.clear()

    config =
      DuskmoonBundler.DevServer.init(
        root: root,
        prefix: "/assets",
        node_modules: Path.join(root, "node_modules"),
        entry: Path.join(root, "page.js")
      )

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {WorkerPlug, dev_server: config}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    {:ok, page} = CDPBrowser.new_page(browser)
    on_exit(fn -> CDPBrowser.close_page(page) end)
    :ok = CDPBrowser.goto(page, "http://127.0.0.1:#{port}/")

    %{page: page, config: config, existing_clients: hmr_clients()}
  end

  for kind <- ["Worker", "SharedWorker"], order <- ["page-first", "worker-first"] do
    test "#{kind} dependencies remain worker-safe with #{order} loading", context do
      kind = unquote(kind)
      order = unquote(order)

      assert {:ok, %{"page" => page_result, "worker" => worker_result, "styles" => 2}} =
               CDPBrowser.evaluate(context.page, browser_probe(kind, order), timeout: 15_000)

      expected_values = %{
        "staticValue" => "static",
        "reexportedValue" => "reexported",
        "dynamicValue" => "dynamic",
        "vendorValue" => "vendor"
      }

      assert Map.take(worker_result, Map.keys(expected_values)) == expected_values
      assert Map.take(page_result, Map.keys(expected_values)) == expected_values

      assert %{
               "windowType" => "undefined",
               "documentType" => "undefined",
               "hotType" => "undefined",
               "consoleForwarding" => false,
               "className" => class_name
             } = worker_result

      assert is_binary(class_name) and class_name != ""

      assert %{
               "windowType" => "object",
               "documentType" => "object",
               "hotType" => "object",
               "consoleForwarding" => true,
               "className" => ^class_name
             } = page_result

      assert [_page_connection] = await_hmr_clients(context.existing_clients)

      # Both realms can reuse the same cached bytes, including headerless requests.
      for path <- ["/assets/worker.js", "/assets/dependency.js", "/assets/dynamic.js"] do
        response = dev_request(path, context.config, nil)
        assert response.status == 200

        for destination <- ["worker", "sharedworker"] do
          other = dev_request(path, context.config, destination)
          assert other.status == 200
          assert other.resp_body == response.resp_body
        end
      end

      assert {:ok, true} =
               CDPBrowser.evaluate(context.page, """
               (() => {
                 const worker = globalThis.workerFixture;
                 if (worker.port) {
                   worker.port.postMessage('close');
                   worker.port.close();
                 } else {
                   worker.terminate();
                 }
                 return true;
               })()
               """)
    end
  end

  defp dev_request(path, config, nil) do
    Plug.Test.conn(:get, path) |> DuskmoonBundler.DevServer.call(config)
  end

  defp dev_request(path, config, destination) do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.put_req_header("sec-fetch-dest", destination)
    |> DuskmoonBundler.DevServer.call(config)
  end

  defp hmr_clients do
    Registry.lookup(DuskmoonBundler.HMR.Registry, :clients)
    |> Enum.map(fn {pid, _} -> pid end)
    |> MapSet.new()
  end

  defp await_hmr_clients(existing, attempts \\ 30) do
    clients = MapSet.difference(hmr_clients(), existing) |> MapSet.to_list()

    if clients == [] and attempts > 0 do
      Process.sleep(50)
      await_hmr_clients(existing, attempts - 1)
    else
      clients
    end
  end

  defp browser_probe(kind, order) do
    """
    (async () => {
      const loadPage = async () => (await import('/assets/page.js')).result;
      const loadWorker = () => new Promise((resolve, reject) => {
        const worker = new #{kind}('/assets/worker.js', {type: 'module'});
        globalThis.workerFixture = worker;
        const port = worker.port || worker;
        const timer = setTimeout(() => reject(new Error('worker message timed out')), 5000);
        worker.onerror = event => {
          clearTimeout(timer);
          reject(new Error(event.message || 'worker failed to load'));
        };
        port.onmessage = event => {
          clearTimeout(timer);
          resolve(event.data);
        };
        if (worker.port) port.start();
        port.postMessage('snapshot');
      });
      let page, worker;
      if (#{JSON.encode!(order)} === 'page-first') {
        page = await loadPage();
        worker = await loadWorker();
      } else {
        worker = await loadWorker();
        page = await loadPage();
      }
      return {page, worker,
        styles: document.querySelectorAll('style[data-duskmoon-bundler-id]').length};
    })()
    """
  end

  defp write_fixture(root) do
    package = Path.join(root, "node_modules/worker-safe-fixture")
    File.mkdir_p!(package)

    File.write!(
      Path.join(package, "package.json"),
      ~s({"name":"worker-safe-fixture","type":"module","main":"index.js"})
    )

    File.write!(Path.join(package, "index.js"), "export const vendorValue = 'vendor';")

    files = %{
      "static.js" => "export const staticValue = 'static';",
      "leaf.js" => "export const reexportedValue = 'reexported';",
      "barrel.js" => "export {reexportedValue} from './leaf.js';",
      "dynamic.js" => "export const dynamicValue = 'dynamic';",
      "plain.css" => ".worker-plain { color: rgb(10, 20, 30); }",
      "token.module.css" => ".token { color: rgb(40, 50, 60); }",
      "page.js" => "import {snapshot} from './dependency.js'; export const result = snapshot();",
      "dependency.js" => """
      import {staticValue} from './static.js';
      import {reexportedValue} from './barrel.js';
      import {vendorValue} from 'worker-safe-fixture';
      import './plain.css';
      import classes from './token.module.css';
      export async function snapshot() {
        const {dynamicValue} = await import('./dynamic.js');
        return {staticValue, reexportedValue, dynamicValue, vendorValue,
          className: classes.token,
          windowType: typeof window, documentType: typeof document,
          hotType: typeof import.meta.hot,
          consoleForwarding: typeof window !== 'undefined' &&
            window.__duskmoon_bundlerConsoleForwarderInstalled === true};
      }
      """,
      "worker.js" => """
      import {snapshot} from './dependency.js';
      const listen = port => {
        port.onmessage = async event => {
          if (event.data === 'close') {
            self.close();
          } else {
            port.postMessage(await snapshot());
          }
        };
      };
      if ('onconnect' in self) {
        self.onconnect = event => {
          const port = event.ports[0];
          listen(port);
          port.start();
        };
      } else {
        listen(self);
      }
      """
    }

    Enum.each(files, fn {path, source} -> File.write!(Path.join(root, path), source) end)
  end
end
