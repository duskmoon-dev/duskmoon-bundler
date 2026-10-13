ExUnit.start()

defmodule NativeDownloadFailureTest do
  use ExUnit.Case, async: false
  @root Path.expand("..", __DIR__)
  @moduletag :tmp_dir

  for backend <- [:rustler_precompiled, :zigler_precompiled], failure <- [:missing, :corrupt] do
    @backend backend
    @failure failure
    test "#{backend} #{failure} artifact fails without compiler invocation", %{tmp_dir: temp} do
      run_failure!(@backend, @failure, temp)
    end
  end

  defp run_failure!(backend, failure, temp) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    server = spawn_link(fn -> serve(listener, failure) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
    end)

    bin = Path.join(temp, "bin")
    File.mkdir_p!(bin)
    trap = Path.join(temp, "compiler.log")

    for compiler <- ~w(cargo rustc zig cc gcc clang) do
      path = Path.join(bin, compiler)

      File.write!(
        path,
        "#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \"$DUSKMOON_COMPILER_LOG\"\nexit 97\n"
      )

      File.chmod!(path, 0o755)
    end

    lib = Path.join(temp, "_build/dev/lib/download_failure")
    ebin = Path.join(lib, "ebin")
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "download_failure.app"),
      "{application, download_failure, [{vsn, \"0.0.0\"}, {modules, []}, {applications, [kernel, stdlib, elixir]}]}."
    )

    module = "Elixir.DownloadFailure.Native"

    filename =
      case backend do
        :rustler_precompiled ->
          "libfailure_probe-v9.16.17-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz"

        :zigler_precompiled ->
          "#{module}-v9.16.17-x86_64-linux-gnu.so.tar.gz"
      end

    checksum =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, "expected fixture artifact"), case: :lower)

    checksum_file =
      case backend do
        :rustler_precompiled -> "checksum-#{module}.exs"
        :zigler_precompiled -> "checksum-DownloadFailure.Native.exs"
      end

    File.write!(Path.join(temp, checksum_file), inspect(%{filename => checksum}) <> "\n")

    {library, policy, _app, flag, target, extras} =
      case backend do
        :rustler_precompiled ->
          {RustlerPrecompiled, OXC.NativePolicy, "oxc", "OXC_EX_BUILD",
           "x86_64-unknown-linux-gnu", "crate: \"failure_probe\", nif_versions: [\"2.15\"],"}

        :zigler_precompiled ->
          {ZiglerPrecompiled, QuickBEAM.NativePolicy, "quickbeam", "QUICKBEAM_BUILD",
           "x86_64-linux-gnu", "nifs: [eval: 0],"}
      end

    source = """
    Mix.start()
    defmodule FailureProject do
      use Mix.Project
      def project, do: [app: :download_failure, version: "0.0.0"]
    end
    true = Code.ensure_loaded?(#{inspect(policy)})
    Application.load(:download_failure)
    defmodule DownloadFailure.Native do
      use #{inspect(library)}, otp_app: :download_failure,
        base_url: "http://127.0.0.1:#{port}/artifacts/", version: "9.16.17",
        force_build: #{inspect(policy)}.force_build!(:download_failure, #{inspect(flag)}, "9.16.17", #{inspect(backend)}),
        #{extras} targets: [#{inspect(target)}], max_retries: 0
    end
    """

    File.write!(Path.join(temp, "probe.exs"), source)
    paths = Path.wildcard(Path.join(@root, "_build/dev/lib/*/ebin"))

    unless Enum.any?(paths, &String.contains?(&1, "/#{backend}/")),
      do: raise("Compile destination dependencies before running native download failure tests")

    args = Enum.flat_map([ebin | paths], &["-pa", &1]) ++ ["probe.exs"]

    {output, status} =
      System.cmd("elixir", args,
        cd: temp,
        stderr_to_stdout: true,
        env: [
          {"DUSKMOON_NATIVE_MODE", "precompiled"},
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"DUSKMOON_COMPILER_LOG", trap},
          {"ZIG_EXECUTABLE_PATH", Path.join(bin, "zig")},
          {"NO_PROXY", "127.0.0.1,localhost"},
          {"RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(temp, "rust-cache")},
          {"ZIGLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(temp, "zig-cache")},
          {"DUSKMOON_BUILD_NATIVE_FROM_SOURCE", nil},
          {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", nil},
          {"ZIGLER_PRECOMPILED_FORCE_BUILD_ALL", nil},
          {flag, nil}
        ]
      )

    assert status != 0, output

    case failure do
      :missing -> assert output =~ "404", output
      :corrupt -> assert output =~ "checksum" and output =~ "match", output
    end

    refute File.exists?(trap), output
    assert Path.wildcard(Path.join(lib, "priv/**/*.so")) == []
  end

  defp serve(listener, failure) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.recv(socket, 0, 5_000)

        {status, body} =
          case failure do
            :missing -> {"404 Not Found", "missing fixture artifact"}
            :corrupt -> {"200 OK", "corrupt fixture artifact"}
          end

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(socket)
        serve(listener, failure)

      {:error, :closed} ->
        :ok
    end
  end
end
