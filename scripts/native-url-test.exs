Mix.start()
Code.require_file("../mix.exs", __DIR__)

for app <- ~w(oxc oxide vize quickbeam) do
  Code.require_file("../apps/duskmoon_#{app}/lib/#{app}/native_url.ex", __DIR__)
end

ExUnit.start()

defmodule NativeURLTest do
  use ExUnit.Case, async: false

  setup_all do
    flags = ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy)
    saved = for flag <- flags, do: {flag, System.get_env(flag)}
    Enum.each(flags, &System.delete_env/1)

    on_exit(fn ->
      for {flag, value} <- saved do
        if value, do: System.put_env(flag, value), else: System.delete_env(flag)
      end
    end)
  end

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"
    server = spawn_link(fn -> serve(listener, origin) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
    end)

    %{origin: origin}
  end

  for resolver <- [OXC.NativeURL, Oxide.NativeURL, Vize.NativeURL, QuickBEAM.NativeURL] do
    @resolver resolver

    test "#{resolver} resolves a redirect whose combined headers exceed 10 KiB", %{origin: origin} do
      assert @resolver.resolve(origin <> "/expanded") == origin <> "/asset"
    end

    test "#{resolver} bounds the redirect headers at 64 KiB", %{origin: origin} do
      assert_raise RuntimeError, ~r/header_too_long.*65536/, fn ->
        @resolver.resolve(origin <> "/oversized")
      end
    end

    test "#{resolver} keeps missing artifacts as HTTP errors", %{origin: origin} do
      assert_raise RuntimeError, ~r/HTTP 404/, fn ->
        @resolver.resolve(origin <> "/missing")
      end
    end

    test "#{resolver} rejects redirects to non-HTTP schemes", %{origin: origin} do
      assert_raise RuntimeError, ~r/Unsafe native artifact redirect/, fn ->
        @resolver.resolve(origin <> "/unsafe")
      end
    end
  end

  defp serve(listener, origin) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_headers(socket, "")
        [_, path | _] = String.split(request, " ")

        {status, headers} =
          case path do
            "/expanded" ->
              {"302 Found",
               "Location: #{origin}/asset\r\nContent-Security-Policy: " <>
                 String.duplicate("a", 8_192) <>
                 "\r\nX-Extra-Policy: " <> String.duplicate("b", 4_096) <> "\r\n"}

            "/oversized" ->
              {"302 Found",
               "Location: #{origin}/asset\r\nX-Policy: " <>
                 String.duplicate("a", 100_000) <> "\r\n"}

            "/unsafe" ->
              {"302 Found", "Location: ftp://127.0.0.1/artifact\r\n"}

            "/missing" ->
              {"404 Not Found", ""}

            "/asset" ->
              {"200 OK", ""}
          end

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status}\r\n#{headers}Content-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
        serve(listener, origin)

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
