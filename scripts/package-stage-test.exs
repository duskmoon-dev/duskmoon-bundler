Code.require_file("lib/package_stage.exs", __DIR__)
ExUnit.start()

defmodule PackageStageTest do
  use ExUnit.Case, async: true

  test "registry normalization preserves dependency semantics and eliminates umbrella paths" do
    input = """
    defmodule Example.MixProject do
      use Mix.Project
      @version "9.16.16"
      def project, do: [version: @version, build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", deps: [{:duskmoon_npm, in_umbrella: true, optional: true, runtime: false, only: :prod}, {:plug, "~> 1.19", override: true}]]
    end
    """

    result = DuskmoonToolchain.PackageStage.normalize_manifest(input, "9.16.17")
    assert result =~ ~s(@version "9.16.17")

    assert result =~
             ~s({:duskmoon_npm, "== 9.16.17", optional: true, runtime: false, only: :prod})

    {_, nodes} =
      Macro.prewalk(Code.string_to_quoted!(result), [], fn node, acc -> {node, [node | acc]} end)

    assert Enum.any?(nodes, &match?({:{}, _, [:plug, "~> 1.19", []]}, &1))
    refute result =~ "override:"
    refute result =~ "in_umbrella"
    refute result =~ "../../"
  end

  test "all eight package sources stage without changing checked-out manifests" do
    root = Path.expand("..", __DIR__)
    output = Path.join(System.tmp_dir!(), "duskmoon-stage-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(output) end)

    before =
      for app <- DuskmoonToolchain.PackageStage.apps(),
          into: %{},
          do: {app, File.read!(Path.join([root, "apps", to_string(app), "mix.exs"]))}

    manifest = DuskmoonToolchain.PackageStage.stage!(root, output, "9.16.17")
    assert length(manifest.packages) == 8

    for {app, source} <- before do
      assert File.read!(Path.join([root, "apps", to_string(app), "mix.exs"])) == source
      assert File.exists?(Path.join([output, to_string(app), "mix.exs"]))
    end

    assert File.exists?(Path.join([output, "duskmoon_quickbeam", "priv/c_src/quickjs.c"]))
    assert File.exists?(Path.join([output, "duskmoon_oxc", "native/oxc_ex_nif/src/lib.rs"]))
    assert File.exists?(Path.join([output, "duskmoon_bundler", "priv/ts/dev/hmr-client.ts"]))
    assert File.exists?(Path.join([output, "duskmoon_bundler_runtime", "LICENSE"]))
  end

  test "staging without an explicit version uses the current toolchain cohort" do
    root = Path.expand("..", __DIR__)

    output =
      Path.join(System.tmp_dir!(), "duskmoon-stage-default-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(output) end)

    {message, 0} =
      System.cmd("elixir", [Path.join(__DIR__, "stage-packages.exs"), "--output", output],
        stderr_to_stdout: true
      )

    Mix.start()

    version =
      Mix.Project.in_project(:duskmoon_toolchain, root, fn _ ->
        Keyword.fetch!(Mix.Project.config(), :version)
      end)

    assert message =~ "for B=#{version}"

    assert %{"version" => ^version, "packages" => packages} =
             JSON.decode!(File.read!(Path.join(output, "manifest.json")))

    for %{"name" => name, "version" => package_version} <- packages do
      assert package_version == version
      assert File.read!(Path.join([output, name, "mix.exs"])) =~ ~s(@version "#{version}")
    end
  end
end
