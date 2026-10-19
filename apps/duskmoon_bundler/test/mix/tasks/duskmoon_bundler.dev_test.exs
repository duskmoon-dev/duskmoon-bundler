defmodule Mix.Tasks.DuskmoonBundler.DevTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  for {profile, source_mode} <- [
        {:dev_configured_sources_test, :external},
        {:dev_empty_sources_test, :empty}
      ] do
    @profile profile
    @source_mode source_mode

    test "forwards #{@source_mode} profile Tailwind sources to the watcher", %{tmp_dir: dir} do
      root = Path.join(dir, "assets")
      external = Path.join(dir, "dependency")
      File.mkdir_p!(root)
      File.mkdir_p!(external)
      File.write!(Path.join(root, "page.heex"), ~s(<div class="w-[652px]"></div>))
      File.write!(Path.join(external, "page.heex"), ~s(<div class="w-[651px]"></div>))

      sources =
        if @source_mode == :external, do: [%{base: external, pattern: "**/*.heex"}], else: []

      outdir = Path.join(dir, "dist")
      previous = Application.get_env(:duskmoon_bundler, @profile)

      Application.put_env(:duskmoon_bundler, @profile,
        root: root,
        outdir: outdir,
        tailwind: [sources: sources],
        server: [watch_dirs: []]
      )

      runner = spawn(fn -> Mix.Tasks.DuskmoonBundler.Dev.run([Atom.to_string(@profile)]) end)

      name =
        Module.concat(DuskmoonBundler.Watcher, @profile |> Atom.to_string() |> Macro.camelize())

      on_exit(fn ->
        if watcher = Process.whereis(name), do: GenServer.stop(watcher)
        if Process.alive?(runner), do: Process.exit(runner, :kill)

        if previous do
          Application.put_env(:duskmoon_bundler, @profile, previous)
        else
          Application.delete_env(:duskmoon_bundler, @profile)
        end
      end)

      assert_eventually(fn ->
        Process.whereis(name) != nil and File.exists?(Path.join(outdir, "css/app.css"))
      end)

      css = File.read!(Path.join(outdir, "css/app.css"))
      refute css =~ "width: 652px;"

      if @source_mode == :external do
        assert css =~ "width: 651px;"
      else
        refute css =~ "width: 651px;"
      end

      assert :sys.get_state(name).config.tailwind_sources == sources
    end
  end

  defp assert_eventually(fun, attempts \\ 100)
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
