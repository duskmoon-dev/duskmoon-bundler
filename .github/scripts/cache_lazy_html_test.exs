ExUnit.start()

paths =
  for app <- ~w(elixir_make cc_precompiler),
      do: Path.expand("../../_build/dev/lib/#{app}/ebin", __DIR__)

Enum.each(paths, &Code.prepend_path/1)

defmodule CacheLazyHTMLTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @script Path.join(__DIR__, "cache_lazy_html.exs")
  @paths paths

  setup %{tmp_dir: dir} do
    {:ok, target} = CCPrecompiler.current_target()
    filename = "lazy_html-nif-2.16-#{target}-0.1.13.tar.gz"
    body = "verified third-party precompiled archive"
    checksum = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    dependency = Path.join(dir, "deps/lazy_html")
    File.mkdir_p!(dependency)

    File.write!(
      Path.join(dependency, "checksum.exs"),
      inspect(%{filename => "sha256:#{checksum}"})
    )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"
    server = spawn_link(fn -> serve(listener, origin, body) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
    end)

    %{dir: dir, origin: origin, dependency: dependency, filename: filename, body: body}
  end

  test "downloads expanded redirect headers and caches checksum-verified bytes", context do
    {output, 0} = run(context, "/expanded")
    assert output =~ "Verified lazy_html precompiled archive"
    assert File.read!(Path.join([context.dir, "cache", context.filename])) == context.body
  end

  test "rejects bytes that differ from the published dependency checksum", context do
    File.write!(
      Path.join(context.dependency, "checksum.exs"),
      inspect(%{context.filename => "sha256:#{String.duplicate("0", 64)}"})
    )

    {output, status} = run(context, "/expanded")
    assert status != 0
    assert output =~ "lazy_html precompiled checksum mismatch"
    refute File.exists?(Path.join([context.dir, "cache", context.filename]))
  end

  test "keeps the response-header budget bounded at 64 KiB", context do
    {output, status} = run(context, "/oversized")
    assert status != 0
    assert output =~ "header_too_long"
    assert output =~ "65536"
    refute File.exists?(Path.join([context.dir, "cache", context.filename]))
  end

  test "reports missing upstream assets without populating the cache", context do
    {output, status} = run(context, "/missing")
    assert status != 0
    assert output =~ "lazy_html precompiled download returned HTTP 404"
    refute File.exists?(Path.join([context.dir, "cache", context.filename]))
  end

  defp run(context, path) do
    File.write!(Path.join(context.dependency, "mix.exs"), """
    defmodule LazyHTMLBootstrapFixture.MixProject do
      use Mix.Project
      def project do
        [app: :lazy_html, version: "0.1.13",
         make_precompiler: {:nif, CCPrecompiler},
         make_precompiler_url: "#{context.origin}#{path}/@{artefact_filename}",
         make_precompiler_nif_versions: [versions: ["2.16"]]]
      end
    end
    """)

    System.cmd(
      "elixir",
      Enum.flat_map(@paths, &["-pa", &1]) ++ [@script],
      cd: context.dir,
      env: [{"ELIXIR_MAKE_CACHE_DIR", Path.join(context.dir, "cache")}],
      stderr_to_stdout: true
    )
  end

  defp serve(listener, origin, body) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_headers(socket, "")
        [_, path | _] = String.split(request, " ")

        {status, headers, response_body} =
          cond do
            String.starts_with?(path, "/expanded/") ->
              {"302 Found",
               "Location: #{origin}/asset\r\nX-Policy: " <>
                 String.duplicate("a", 12_000) <> "\r\n", ""}

            String.starts_with?(path, "/oversized/") ->
              {"302 Found",
               "Location: #{origin}/asset\r\nX-Policy: " <>
                 String.duplicate("a", 70_000) <> "\r\n", ""}

            path == "/asset" ->
              {"200 OK", "", body}

            true ->
              {"404 Not Found", "", ""}
          end

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status}\r\n#{headers}Content-Length: #{byte_size(response_body)}\r\n" <>
            "Connection: close\r\n\r\n#{response_body}"
        )

        :gen_tcp.close(socket)
        serve(listener, origin, body)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, part} = :gen_tcp.recv(socket, 0, 5_000)
      read_headers(socket, buffer <> part)
    end
  end
end
