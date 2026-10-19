defmodule DuskmoonBundler.WatcherTest do
  use ExUnit.Case, async: false

  setup %{test: test_name} do
    watch_dir = Path.expand("fixtures/watcher_test/#{test_name}", __DIR__)
    File.mkdir_p!(watch_dir)
    DuskmoonBundler.HMR.ImportGraph.clear()
    DuskmoonBundler.Cache.clear()
    on_exit(fn -> File.rm_rf!(watch_dir) end)
    {:ok, watch_dir: watch_dir}
  end

  defp write_changed!(path, content) do
    File.write!(path, content)
    File.touch!(path, next_mtime())
  end

  defp next_mtime do
    count = Process.get(:watcher_test_mtime_count, 0)
    Process.put(:watcher_test_mtime_count, count + 1)
    {{2040, 1, 1}, {0, 0, rem(count, 60)}}
  end

  test "broadcasts via registry on dispatch" do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    Registry.dispatch(DuskmoonBundler.HMR.Registry, :clients, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:duskmoon_bundler_hmr, :update, %{path: "test.ts", changes: [:full]}})
      end
    end)

    assert_receive {:duskmoon_bundler_hmr, :update, %{path: "test.ts", changes: [:full]}}
  end

  test "starts and watches a directory", %{watch_dir: watch_dir} do
    {:ok, pid} = DuskmoonBundler.Watcher.start_link(root: watch_dir, name: :test_watcher)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "normalizes tailwind css path for rebuilds", %{watch_dir: watch_dir} do
    css_file = Path.join(watch_dir, "app.css")
    File.write!(css_file, ~s(@import "tailwindcss";))
    relative_css_file = Path.relative_to(css_file, File.cwd!())

    {:ok, pid} =
      DuskmoonBundler.Watcher.start_link(
        root: watch_dir,
        tailwind_css: relative_css_file,
        name: :test_watcher_tailwind_css_path
      )

    state = :sys.get_state(pid)

    assert state.config[:tailwind_css] == Path.expand(relative_css_file)

    GenServer.stop(pid)
  end

  test "detects file changes and broadcasts update", %{watch_dir: watch_dir} do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    ts_file = Path.join(watch_dir, "app.ts")
    File.write!(ts_file, "export const x = 1;")

    {:ok, pid} = DuskmoonBundler.Watcher.start_link(root: watch_dir, name: :test_watcher_change)

    Process.sleep(100)
    write_changed!(ts_file, "export const x = 2;")

    assert_receive {:duskmoon_bundler_hmr, :update, %{path: "app.ts", changes: [:full]}}, 2000

    GenServer.stop(pid)
  end

  test "detects asset changes and broadcasts reload update", %{watch_dir: watch_dir} do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    File.mkdir_p!(Path.join(watch_dir, "images"))
    asset_file = Path.join(watch_dir, "images/logo.svg")
    File.write!(asset_file, "<svg></svg>")

    {:ok, pid} =
      DuskmoonBundler.Watcher.start_link(root: watch_dir, name: :test_watcher_asset_change)

    Process.sleep(100)
    write_changed!(asset_file, "<svg><circle /></svg>")

    assert_receive {:duskmoon_bundler_hmr, :update, %{path: "images/logo.svg", changes: [:full]}},
                   2000

    GenServer.stop(pid)
  end

  test "invalidates import.meta.glob importers when matching files are added", %{
    watch_dir: watch_dir
  } do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    File.mkdir_p!(Path.join(watch_dir, "pages"))
    routes_file = Path.join(watch_dir, "routes.ts")

    File.write!(routes_file, """
    export const pages = import.meta.glob('./pages/*.ts')
    """)

    dev_config = DuskmoonBundler.DevServer.init(root: watch_dir, prefix: "/assets")
    Plug.Test.conn(:get, "/assets/routes.ts") |> DuskmoonBundler.DevServer.call(dev_config)

    {:ok, pid} = DuskmoonBundler.Watcher.start_link(root: watch_dir, name: :test_watcher_glob_add)

    Process.sleep(100)
    File.write!(Path.join(watch_dir, "pages/home.ts"), "export const page = 'home'")

    assert_receive {:duskmoon_bundler_hmr, :update, %{path: "routes.ts", changes: [:full]}}, 2000

    GenServer.stop(pid)
  end

  test "triggers tailwind rebuild on template changes", %{watch_dir: watch_dir} do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    heex_file = Path.join(watch_dir, "page.heex")
    File.write!(heex_file, ~s(<div class="flex">hi</div>))

    outdir = Path.join(watch_dir, "css_out")

    {:ok, pid} =
      DuskmoonBundler.Watcher.start_link(
        root: watch_dir,
        watch_dirs: [watch_dir],
        tailwind: true,
        tailwind_outdir: outdir,
        name: :test_watcher_tw
      )

    Process.sleep(100)
    write_changed!(heex_file, ~s(<div class="flex mt-4 bg-blue-500">hi</div>))

    assert_receive {:duskmoon_bundler_hmr, :update,
                    %{path: "assets/css/app.css", changes: [:style]}},
                   3000

    assert File.exists?(Path.join(outdir, "app.css"))
    css = File.read!(Path.join(outdir, "app.css"))
    assert css =~ "tailwindcss"

    GenServer.stop(pid)
  end

  test "rebuilds new Tailwind utilities after a Storybook exs template edit", %{
    watch_dir: watch_dir
  } do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    assets_dir = Path.join(watch_dir, "assets")
    storybook_dir = Path.join(watch_dir, "storybook")
    File.mkdir_p!(assets_dir)
    File.mkdir_p!(storybook_dir)
    story_file = Path.join(storybook_dir, "button.story.exs")
    File.write!(story_file, ~S|~s(<button class="flex">Story</button>)|)
    outdir = Path.join(watch_dir, "css_out")

    pid =
      start_supervised!(
        {DuskmoonBundler.Watcher,
         root: assets_dir,
         watch_dirs: [storybook_dir],
         tailwind: true,
         tailwind_outdir: outdir,
         name: :test_watcher_storybook_exs}
      )

    css_file = Path.join(outdir, "app.css")
    initial_css = File.read!(css_file)
    refute initial_css =~ ".p-\\[39px\\]"
    refute initial_css =~ "padding: 39px"

    Process.sleep(100)
    write_changed!(story_file, ~S|~s(<button class="flex p-[39px]">Story</button>)|)

    assert_receive {:duskmoon_bundler_hmr, :update,
                    %{path: "assets/css/app.css", changes: [:style]}},
                   3000

    rebuilt_css = File.read!(css_file)
    assert rebuilt_css =~ ".p-\\[39px\\]"
    assert rebuilt_css =~ "padding: 39px;"
    assert Process.alive?(pid)
  end

  test "honors external configured sources and excludes unmatched files", %{watch_dir: dir} do
    assets = Path.join(dir, "assets")
    external = Path.join(dir, "dependency")
    File.mkdir_p!(assets)
    File.mkdir_p!(external)
    File.write!(Path.join(assets, "ignored.heex"), ~s(<div class="w-[619px]"></div>))
    File.write!(Path.join(external, "ignored.heex"), ~s(<div class="w-[620px]"></div>))
    source = Path.join(external, "component.exs")
    File.write!(source, ~s(# w-[617px]))
    outdir = Path.join(dir, "out")

    start_tailwind_watcher!(assets, outdir,
      tailwind_sources: [%{base: external, pattern: "**/*.exs"}]
    )

    assert File.read!(Path.join(outdir, "app.css")) =~ "width: 617px;"
    refute File.read!(Path.join(outdir, "app.css")) =~ "width: 619px;"
    refute File.read!(Path.join(outdir, "app.css")) =~ "width: 620px;"

    Process.sleep(100)
    write_changed!(source, "# w-[617px] w-[618px]")
    assert_eventually(fn -> File.read!(Path.join(outdir, "app.css")) =~ "width: 618px;" end)

    write_changed!(Path.join(external, "ignored.heex"), ~s(<div class="w-[621px]"></div>))
    Process.sleep(300)
    refute File.read!(Path.join(outdir, "app.css")) =~ "width: 621px;"
  end

  test "explicitly empty sources do not scan normal watch directories", %{watch_dir: dir} do
    File.write!(Path.join(dir, "page.heex"), ~s(<div class="w-[622px]"></div>))
    outdir = Path.join(dir, "out")
    start_tailwind_watcher!(dir, outdir, tailwind_sources: [])
    refute File.read!(Path.join(outdir, "app.css")) =~ "width: 622px;"
  end

  for order <- [[:api, :admin], [:admin, :api]] do
    @order order
    test "isolates profile scans and shared updates in #{Enum.join(order, "-")} startup order", %{
      watch_dir: dir
    } do
      shared = Path.join(dir, "shared")
      File.mkdir_p!(shared)
      shared_file = Path.join(shared, "shared.exs")
      File.write!(shared_file, "# w-[631px]")

      profiles =
        for {profile, width} <- [api: 632, admin: 633], into: %{} do
          root = Path.join(dir, Atom.to_string(profile))
          File.mkdir_p!(root)
          File.write!(Path.join(root, "page.heex"), ~s(<div class="w-[#{width}px]"></div>))
          {profile, %{root: root, outdir: Path.join(root, "out"), width: width}}
        end

      watchers =
        for profile <- @order do
          %{root: root, outdir: outdir} = profiles[profile]

          pid =
            start_tailwind_watcher!(root, outdir,
              tailwind_sources: [
                %{base: root, pattern: "**/*.heex"},
                %{base: shared, pattern: "**/*.exs"}
              ]
            )

          {profile, pid}
        end

      for {profile, data} <- profiles do
        css = File.read!(Path.join(data.outdir, "app.css"))
        assert css =~ "width: #{data.width}px;"
        assert css =~ "width: 631px;"
        other = profiles[if(profile == :api, do: :admin, else: :api)]
        refute css =~ "width: #{other.width}px;"
      end

      Process.sleep(100)
      write_changed!(shared_file, "# w-[631px] w-[634px]")

      for {_profile, data} <- profiles do
        assert_eventually(fn ->
          File.read!(Path.join(data.outdir, "app.css")) =~ "width: 634px;"
        end)

        css = File.read!(Path.join(data.outdir, "app.css"))
        assert css =~ "width: #{data.width}px;"
      end

      for {_profile, pid} <- watchers do
        server = :sys.get_state(pid).tailwind_server
        GenServer.stop(pid)
        refute Process.alive?(server)
      end
    end
  end

  test "CSS input edits regenerate disk CSS before style HMR without output loops", %{
    watch_dir: dir
  } do
    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)
    input = Path.join(dir, "input.css")
    File.write!(input, ~s|@import "tailwindcss" source(none);\n.probe { color: red; }|)
    outdir = Path.join(dir, "out")
    start_tailwind_watcher!(dir, outdir, tailwind_css: input, tailwind_sources: [])
    assert File.read!(Path.join(outdir, "app.css")) =~ "color: red;"

    Process.sleep(100)
    write_changed!(input, ~s|@import "tailwindcss" source(none);\n.probe { color: blue; }|)

    assert_receive {:duskmoon_bundler_hmr, :update,
                    %{path: "assets/css/app.css", changes: [:style]}},
                   3000

    assert File.read!(Path.join(outdir, "app.css")) =~ "color: blue;"
    refute File.read!(Path.join(outdir, "app.css")) =~ "color: red;"

    refute_receive {:duskmoon_bundler_hmr, :update, %{path: "out/app.css", changes: [:style]}},
                   300

    refute_receive {:duskmoon_bundler_hmr, :update,
                    %{path: "assets/css/app.css", changes: [:style]}},
                   300
  end

  test "rebuilds external configured HTML and Markdown sources", %{watch_dir: dir} do
    assets = Path.join(dir, "assets")
    external = Path.join(dir, "dependency")
    File.mkdir_p!(assets)
    File.mkdir_p!(external)
    html = Path.join(external, "page.html")
    markdown = Path.join(external, "guide.md")
    File.write!(html, ~s(<div class="w-[661px]"></div>))
    File.write!(markdown, "# Example w-[662px]")
    outdir = Path.join(dir, "out")

    start_tailwind_watcher!(assets, outdir,
      tailwind_sources: [%{base: external, pattern: "**/*.{html,md}"}]
    )

    css_file = Path.join(outdir, "app.css")
    assert File.read!(css_file) =~ "width: 661px;"
    assert File.read!(css_file) =~ "width: 662px;"

    Process.sleep(100)
    write_changed!(html, ~s(<div class="w-[663px]"></div>))
    assert_eventually(fn -> File.read!(css_file) =~ "width: 663px;" end)
    write_changed!(markdown, "# Example w-[664px]")
    assert_eventually(fn -> File.read!(css_file) =~ "width: 664px;" end)
  end

  test "shared-root watchers settle after observing each other's CSS output", %{watch_dir: dir} do
    first_outdir = Path.join(dir, "first")
    second_outdir = Path.join(dir, "second")
    source = Path.join(dir, "page.heex")
    File.write!(source, ~s(<div class="w-[671px]"></div>))
    opts = [tailwind_sources: [%{base: dir, pattern: "**/*.heex"}]]
    start_tailwind_watcher!(dir, first_outdir, opts)
    start_tailwind_watcher!(dir, second_outdir, opts)
    outputs = Enum.map([first_outdir, second_outdir], &Path.join(&1, "app.css"))

    Process.sleep(100)
    write_changed!(source, ~s(<div class="w-[672px]"></div>))

    for output <- outputs do
      assert_eventually(fn -> File.read!(output) =~ "width: 672px;" end)
    end

    # A no-op rewrite changes this timestamp, even when the polling backend
    # would otherwise miss repeated writes within the same second.
    future = {{2041, 1, 1}, {0, 0, 0}}
    for output <- outputs, do: File.touch!(output, future)
    Process.sleep(500)
    for output <- outputs, do: assert(File.stat!(output).mtime == future)

    Registry.register(DuskmoonBundler.HMR.Registry, :clients, nil)

    refute_receive {:duskmoon_bundler_hmr, :update,
                    %{path: "assets/css/app.css", changes: [:style]}},
                   500
  end

  defp start_tailwind_watcher!(root, outdir, opts) do
    opts = Keyword.merge([root: root, tailwind: true, tailwind_outdir: outdir, name: nil], opts)

    spec =
      Supervisor.child_spec({DuskmoonBundler.Watcher, opts}, id: make_ref(), restart: :temporary)

    start_supervised!(spec)
  end

  defp assert_eventually(fun, attempts \\ 60)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end
end
