Code.require_file("release_support.exs", __DIR__)
ExUnit.start()

defmodule ReleasePlanningTest do
  use ExUnit.Case, async: true

  test "stable versions and immutable refs reject arbitrary payloads" do
    assert "9.16.17" = ReleaseSupport.stable!("9.16.17")
    assert_raise RuntimeError, fn -> ReleaseSupport.stable!("9.16.17-dev") end
    assert_raise RuntimeError, fn -> ReleaseSupport.sha!("main") end
  end

  test "publication follows dependencies and detects cycles" do
    assert ["runtime", "bundler"] =
             ReleaseSupport.order!(%{"bundler" => ["runtime"], "runtime" => []})

    assert_raise RuntimeError, fn -> ReleaseSupport.order!(%{"a" => ["b"], "b" => ["a"]}) end
  end

  test "native retry requires every final immutable asset digest" do
    assets = Map.new(1..47, &{"asset-#{&1}.tar.gz", String.duplicate("a", 64)})
    assert ReleaseSupport.reusable_native?(%{"native_assets" => assets})

    refute ReleaseSupport.reusable_native?(%{
             "native_assets" => Map.delete(assets, "asset-1.tar.gz")
           })

    refute ReleaseSupport.reusable_native?(%{
             "native_assets" => Map.put(assets, "asset-1.tar.gz", "invalid")
           })
  end

  test "retry reuses matching output and refuses replacement" do
    assert :create = ReleaseSupport.immutable_action(nil, "sha256:a")
    assert :reuse = ReleaseSupport.immutable_action("sha256:a", "sha256:a")
    assert_raise RuntimeError, fn -> ReleaseSupport.immutable_action("sha256:a", "sha256:b") end
  end

  test "partial release and missing platform validation prevent UI adoption" do
    state = %{
      "public_assets_verified" => true,
      "registry_consumer_verified" => true,
      "musl_amd64_verified" => true,
      "musl_arm64_verified" => true,
      "packages" => ReleaseSupport.cohort()
    }

    assert ReleaseSupport.adoption_ready?(state)
    refute ReleaseSupport.adoption_ready?(Map.put(state, "packages", ["duskmoon_bundler"]))
    refute ReleaseSupport.adoption_ready?(Map.put(state, "musl_arm64_verified", false))
    refute ReleaseSupport.adoption_ready?(Map.put(state, "public_assets_verified", false))
  end
end

defmodule NativeChecksumContractTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  defp artifacts(tmp_dir) do
    assets = Path.join(tmp_dir, "assets")
    File.mkdir_p!(assets)

    rust_targets =
      ~w(aarch64-apple-darwin aarch64-unknown-linux-gnu aarch64-unknown-linux-musl x86_64-apple-darwin x86_64-pc-windows-gnu x86_64-unknown-freebsd x86_64-unknown-linux-gnu x86_64-unknown-linux-musl)

    quickbeam_targets =
      ~w(aarch64-linux-gnu aarch64-linux-musl aarch64-macos-none x86_64-freebsd-none x86_64-linux-gnu x86_64-linux-musl x86_64-macos-none)

    names =
      for crate <- ~w(oxc_ex_nif oxc_fmt_nif oxc_lint_nif oxide_ex_nif vize_ex_nif),
          target <- rust_targets do
        if target == "x86_64-pc-windows-gnu",
          do: "#{crate}-v9.16.17-nif-2.15-#{target}.dll.tar.gz",
          else: "lib#{crate}-v9.16.17-nif-2.15-#{target}.so.tar.gz"
      end

    names =
      names ++ Enum.map(quickbeam_targets, &"Elixir.QuickBEAM.Native-v9.16.17-#{&1}.so.tar.gz")

    for name <- names, do: File.write!(Path.join(assets, name), "fixture bytes for #{name}")
    {assets, names}
  end

  test "hashes every final archive byte without native compilation", %{tmp_dir: tmp_dir} do
    {assets, _} = artifacts(tmp_dir)
    output = Path.join(tmp_dir, "stage")

    {_, 0} =
      System.cmd(
        "elixir",
        [Path.join(__DIR__, "generate_native_checksums.exs"), "9.16.17", assets, output],
        stderr_to_stdout: true
      )

    groups = Path.wildcard(Path.join([output, "*", "checksum-*.exs"]))

    entries =
      Enum.flat_map(groups, fn file ->
        {checksums, _} = Code.eval_file(file)
        Enum.to_list(checksums)
      end)

    assert 47 == length(entries)

    for {name, digest} <- entries do
      expected =
        :crypto.hash(:sha256, File.read!(Path.join(assets, name))) |> Base.encode16(case: :lower)

      assert digest == "sha256:#{expected}"
    end
  end

  test "partial artifact set fails before writing package checksums", %{tmp_dir: tmp_dir} do
    {assets, [missing | _]} = artifacts(tmp_dir)
    File.rm!(Path.join(assets, missing))
    output = Path.join(tmp_dir, "stage")

    {error, status} =
      System.cmd(
        "elixir",
        [Path.join(__DIR__, "generate_native_checksums.exs"), "9.16.17", assets, output],
        stderr_to_stdout: true
      )

    assert status != 0
    assert error =~ "native asset set does not match the release contract"
    refute File.exists?(output)
  end
end
