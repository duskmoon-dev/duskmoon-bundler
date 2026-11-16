defmodule DuskmoonBundler.PackageStylesheetsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias DuskmoonBundler.{Builder, DevServer}
  alias DuskmoonBundler.JS.Vendor

  defmodule BrowserPlug do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, config) do
      conn = DevServer.call(conn, config)

      if conn.halted do
        conn
      else
        body =
          if conn.request_path == "/preview" do
            ~s(<body><script type="module" src="/assets/app.js"></script></body>)
          else
            """
            <style>.package { color: rgb(1, 2, 3) }</style>
            <button class="package">outer</button><iframe src="/preview"></iframe>
            """
          end

        conn |> put_resp_content_type("text/html") |> send_resp(200, body)
      end
    end
  end

  @tag :tmp_dir
  test "cold vendor discovery ignores stylesheet imports and mixed stylesheet entries", %{
    tmp_dir: dir
  } do
    fixture = fixture(dir)

    for entries <- [[fixture.entry], [fixture.css, fixture.entry], [fixture.css]] do
      File.rm_rf!(vendor_cache())

      assert {:ok, vendors} =
               Vendor.prebundle(
                 root: fixture.root,
                 entry: entries,
                 node_modules: fixture.modules
               )

      assert Map.keys(vendors) ==
               if(fixture.entry in entries, do: ["@styles/components"], else: [])
    end
  end

  @tag :tmp_dir
  test "package CSS exports use the CSS pipeline during repeated development requests", %{
    tmp_dir: dir
  } do
    fixture = fixture(dir)
    File.rm_rf!(vendor_cache())

    config =
      DevServer.init(
        root: fixture.root,
        entry: [fixture.css, fixture.entry],
        node_modules: fixture.modules,
        prefix: "/assets"
      )

    for _ <- 1..3 do
      response = conn(:get, "/assets/app.js") |> DevServer.call(config)
      assert response.status == 200
      refute response.resp_body =~ "Compilation error"

      assert {:ok, imports} = OXC.select(response.resp_body, "app.js", :import_specifiers)
      css_url = Enum.find(imports, &String.contains?(&1, "styles.css"))
      assert is_binary(css_url)
      css = conn(:get, css_url) |> DevServer.call(config)
      assert css.status == 200
      assert get_resp_header(css, "content-type") |> hd() =~ "javascript"
      assert css.resp_body =~ "#0c2238"
      assert css.resp_body =~ "updateStyle"
      refute css.resp_body =~ "Compilation error"

      js_url = Enum.find(imports, &(&1 != css_url and String.starts_with?(&1, "/@vendor/")))
      js = conn(:get, js_url) |> DevServer.call(config)
      assert js.status == 200
      assert js.resp_body =~ "package-button"
    end
  end

  @tag :tmp_dir
  test "package styles stay inside the preview across cold startup and repeated navigation", %{
    tmp_dir: dir
  } do
    alias DuskmoonBundler.Integration.CDPBrowser
    fixture = fixture(dir)
    File.rm_rf!(vendor_cache())

    config =
      DevServer.init(
        root: fixture.root,
        entry: [fixture.css, fixture.entry],
        node_modules: fixture.modules,
        prefix: "/assets"
      )

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, server} =
      Gaoxy.HTTP.start_link(
        plug: {BrowserPlug, config},
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn -> Process.exit(server, :normal) end)
    {:ok, browser} = start_supervised(CDPBrowser)
    {:ok, page} = CDPBrowser.new_page(browser)

    for _ <- 1..3 do
      assert :ok = CDPBrowser.goto(page, "http://127.0.0.1:#{port}/", timeout: 10_000)

      assert {:ok, ["package-button", "rgb(12, 34, 56)", "rgb(1, 2, 3)"]} =
               CDPBrowser.evaluate(page, """
               new Promise(resolve => {
                 const check = () => {
                   const frame = document.querySelector('iframe');
                   const button = frame.contentDocument?.querySelector('button');
                   if (button && frame.contentWindow.getComputedStyle(button).color === 'rgb(12, 34, 56)') {
                     resolve([button.textContent, frame.contentWindow.getComputedStyle(button).color,
                       getComputedStyle(document.querySelector('button')).color]);
                   } else { setTimeout(check, 20); }
                 };
                 check();
               })
               """)
    end
  end

  @tag :tmp_dir
  test "package stylesheet imports still emit production CSS", %{tmp_dir: dir} do
    fixture = fixture(dir)
    outdir = Path.join(dir, "dist")

    assert {:ok, _result} =
             Builder.build(
               entry: fixture.entry,
               outdir: outdir,
               node_modules: fixture.modules
             )

    assert [css] = Path.wildcard(Path.join(outdir, "*.css"))
    assert File.read!(css) =~ "#0c2238"
  end

  defp fixture(dir) do
    root = Path.join(dir, "src")
    modules = Path.join(dir, "node_modules")
    package = Path.join(modules, "@styles/components")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(package, "dist"))

    File.write!(
      Path.join(package, "package.json"),
      JSON.encode!(%{
        "name" => "@styles/components",
        "version" => "1.0.0",
        "type" => "module",
        "exports" => %{"." => "./dist/index.js", "./styles.css" => "./dist/styles.css"}
      })
    )

    File.write!(Path.join(package, "dist/index.js"), "export const label = 'package-button';")
    File.write!(Path.join(package, "dist/styles.css"), ".package { color: rgb(12, 34, 56) }")
    css = Path.join(root, "entry.css")
    File.write!(css, ".entry { color: green }")
    entry = Path.join(root, "app.js")

    File.write!(entry, """
    import '@styles/components/styles.css';
    import { label } from '@styles/components';
    document.body.innerHTML = `<button class="package">${label}</button>`;
    """)

    %{root: root, modules: modules, css: css, entry: entry}
  end

  defp vendor_cache, do: Path.join(Mix.Project.build_path(), "duskmoon_bundler/vendor")
end
