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

defmodule PackagePublicationContractTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  defp publish(tmp_dir, http_status) do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    tarball = Path.join(tmp_dir, "duskmoon_quickbeam-10.0.0.tar")
    File.write!(tarball, "verified package bytes")

    File.write!(Path.join(bin, "curl"), ~S"""
    #!/bin/sh
    case "$*" in
      *--request*) ;;
      *) printf 404; exit 0 ;;
    esac
    printf '%s\n' "$@" > "$PUBLISH_TEST_ROOT/arguments"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --header)
          shift
          case "$1" in
            @*)
              header=${1#@}
              cp "$header" "$PUBLISH_TEST_ROOT/header"
              stat -c '%a' "$header" > "$PUBLISH_TEST_ROOT/permissions"
              stat -c '%a' "$(dirname "$header")" >> "$PUBLISH_TEST_ROOT/permissions"
              printf '%s' "$header" > "$PUBLISH_TEST_ROOT/header-path"
              ;;
          esac
          ;;
        --data-binary) shift; cp "${1#@}" "$PUBLISH_TEST_ROOT/body" ;;
      esac
      shift
    done
    printf '%s' "$PUBLISH_TEST_STATUS"
    [ "$PUBLISH_TEST_STATUS" = 201 ] || exit 22
    """)

    File.write!(
      Path.join(bin, "mix"),
      "#!/bin/sh\necho 'Unexpected Mix invocation' >&2\nexit 1\n"
    )

    for command <- ["curl", "mix"], do: File.chmod!(Path.join(bin, command), 0o755)

    result =
      System.cmd(
        "elixir",
        [
          "-r",
          Path.join(__DIR__, "release_support.exs"),
          "-e",
          "System.put_env(\"PATH\", System.fetch_env!(\"PUBLISH_TEST_PATH\")); ReleaseSupport.hex_publish!(\"duskmoon_quickbeam\", \"10.0.0\", hd(System.argv()))",
          tmp_dir
        ],
        stderr_to_stdout: true,
        env: [
          {"PUBLISH_TEST_PATH", bin <> ":" <> System.fetch_env!("PATH")},
          {"HEX_API_KEY", "publication-test-key"},
          {"PUBLISH_TEST_ROOT", tmp_dir},
          {"PUBLISH_TEST_STATUS", http_status}
        ]
      )

    {output, _status} = result
    arguments = File.read!(Path.join(tmp_dir, "arguments"))
    refute arguments =~ "publication-test-key"
    refute output =~ "publication-test-key"
    assert File.read!(Path.join(tmp_dir, "body")) == File.read!(tarball)
    assert File.read!(Path.join(tmp_dir, "header")) == "authorization: publication-test-key\n"
    assert File.read!(Path.join(tmp_dir, "permissions")) == "600\n700\n"
    header = File.read!(Path.join(tmp_dir, "header-path"))
    refute File.exists?(Path.dirname(header))
    assert arguments =~ "content-type: application/octet-stream"
    assert arguments =~ "https://hex.pm/api/packages/duskmoon_quickbeam/releases?replace=false"
    result
  end

  test "publishes exact archive bytes without resolving source dependencies", %{tmp_dir: tmp_dir} do
    assert {_output, 0} = publish(tmp_dir, "201")
  end

  test "HTTP failure stops publication and removes private authorization", %{tmp_dir: tmp_dir} do
    assert {output, status} = publish(tmp_dir, "500")
    assert status != 0
    assert output =~ "failed (22)"
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
