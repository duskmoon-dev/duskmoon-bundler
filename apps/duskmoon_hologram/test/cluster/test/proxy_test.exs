defmodule HologramClusterTests.ProxyTest do
  use ExUnit.Case, async: false

  import HologramClusterTests.Proxy

  alias HologramClusterTests.HTTPClient
  alias HologramClusterTests.Proxy

  defmodule StubUpstream do
    @moduledoc false

    @behaviour Plug

    @impl Plug
    def init(port), do: port

    @impl Plug
    def call(conn, port) do
      case conn.request_path do
        "/echo-cookie" ->
          cookie_header =
            conn.req_headers
            |> Enum.filter(fn {name, _value} -> name == "cookie" end)
            |> Enum.map_join(";", fn {_name, value} -> value end)

          Plug.Conn.send_resp(conn, 200, cookie_header)

        "/set-cookies" ->
          conn
          |> Plug.Conn.put_resp_cookie("stub_cookie_a", "1")
          |> Plug.Conn.put_resp_cookie("stub_cookie_b", "2")
          |> Plug.Conn.send_resp(200, "ok")

        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/redirect-target")
          |> Plug.Conn.send_resp(302, "redirect-body")

        "/gzip" ->
          bytes = :zlib.gzip(<<0, 1, 2, 255>>)
          split = div(byte_size(bytes), 2)
          <<first::binary-size(split), last::binary>> = bytes

          conn =
            conn
            |> Plug.Conn.put_resp_header("content-encoding", "gzip")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, first)
          {:ok, conn} = Plug.Conn.chunk(conn, last)
          conn

        "/echo-body" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, "#{conn.method}:#{body}")

        "/stream" ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk-1\n")

          Process.sleep(300)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk-2\n")

          Process.sleep(300)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk-3\n")

          conn

        _other ->
          Plug.Conn.send_resp(conn, 200, "upstream:#{port}")
      end
    end
  end

  @stub_port_1 4021
  @stub_port_2 4022

  setup do
    for port <- [@stub_port_1, @stub_port_2] do
      start_supervised!({Gaoxy.HTTP, plug: {StubUpstream, port}, port: port},
        id: {:stub_upstream, port}
      )
    end

    start_supervised!({Proxy, upstreams: [@stub_port_1, @stub_port_2]})

    :ok
  end

  defp get_through_proxy(path, request_headers \\ []) do
    proxy_port = Application.fetch_env!(:hologram_cluster_tests, :proxy_port)

    HTTPClient.get("http://127.0.0.1:#{proxy_port}#{path}", request_headers)
  end

  defp served_by(response) do
    {"x-upstream", upstream} = List.keyfind(response.headers, "x-upstream", 0)
    String.to_integer(upstream)
  end

  defp assert_upstream_cancelled(phase) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    test_pid = self()

    upstream =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        request = recv_headers(socket)
        assert request =~ "GET /cancel HTTP/1.1"

        if phase == :body do
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n"
            )
        end

        send(test_pid, {:upstream_ready, self()})
        result = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
        result
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(upstream.pid, :kill)
    end)

    put_upstreams([port])
    proxy_port = Application.fetch_env!(:hologram_cluster_tests, :proxy_port)
    {:ok, downstream} = :gen_tcp.connect({127, 0, 0, 1}, proxy_port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(downstream) end)
    :ok = :gen_tcp.send(downstream, "GET /cancel HTTP/1.1\r\nHost: localhost\r\n\r\n")

    upstream_pid = upstream.pid
    assert_receive {:upstream_ready, ^upstream_pid}, 1_000
    if phase == :body, do: assert(recv_headers(downstream) =~ "HTTP/1.1 200")
    :ok = :gen_tcp.close(downstream)

    assert Task.await(upstream, 3_000) == {:error, :closed}
  end

  defp recv_headers(socket, bytes \\ "") do
    if String.contains?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      recv_headers(socket, bytes <> chunk)
    end
  end

  describe "clear_log/0" do
    test "empties the request log" do
      get_through_proxy("/")
      clear_log()

      assert log() == []
    end
  end

  describe "log/0" do
    test "records method, path and serving upstream for each request, in order" do
      first_upstream = served_by(get_through_proxy("/"))
      second_upstream = served_by(get_through_proxy("/echo-cookie"))

      assert log() == [
               %{method: "GET", path: "/", upstream: first_upstream},
               %{method: "GET", path: "/echo-cookie", upstream: second_upstream}
             ]
    end
  end

  describe "put_upstreams/1" do
    test "replaces the upstream set for subsequent routing" do
      put_upstreams([@stub_port_2])

      assert served_by(get_through_proxy("/")) == @stub_port_2
      assert served_by(get_through_proxy("/")) == @stub_port_2
    end
  end

  describe "register_policy/1" do
    test "routes requests carrying the token cookie through the registered policy" do
      token =
        register_policy(fn _request_facts, %{upstreams: upstreams} -> List.last(upstreams) end)

      request_headers = [{"cookie", "#{route_cookie()}=#{token}"}]

      assert served_by(get_through_proxy("/", request_headers)) == @stub_port_2
      assert served_by(get_through_proxy("/", request_headers)) == @stub_port_2
      assert served_by(get_through_proxy("/", request_headers)) == @stub_port_2
    end

    test "hands the policy the request facts" do
      token =
        register_policy(fn %{method: "GET", path: "/echo-cookie"},
                           %{upstreams: [first | _rest]} ->
          first
        end)

      request_headers = [{"cookie", "#{route_cookie()}=#{token}"}]

      assert served_by(get_through_proxy("/echo-cookie", request_headers)) == @stub_port_1
    end
  end

  describe "request forwarding" do
    test "cancels upstream requests when the browser closes before response headers" do
      assert_upstream_cancelled(:headers)
    end

    test "cancels upstream requests when the browser closes during an idle response body" do
      assert_upstream_cancelled(:body)
    end

    test "alternates upstreams for consecutive requests when no policy cookie is set" do
      first_upstream = served_by(get_through_proxy("/"))
      second_upstream = served_by(get_through_proxy("/"))

      assert Enum.sort([first_upstream, second_upstream]) == [@stub_port_1, @stub_port_2]
    end

    test "stamps the response with the upstream that served it" do
      response = get_through_proxy("/")

      assert response.body == "upstream:#{served_by(response)}"
    end

    test "forwards request cookies to the upstream" do
      response = get_through_proxy("/echo-cookie", [{"cookie", "stub=42"}])

      assert response.body == "stub=42"
    end

    test "passes redirects through with their original status, location and body" do
      response = get_through_proxy("/redirect")

      assert response.status == 302
      assert {"location", "/redirect-target"} in response.headers
      assert response.body == "redirect-body"
    end

    test "preserves streamed gzip bytes and their content-encoding header" do
      response = get_through_proxy("/gzip")

      assert response.status == 200
      assert {"content-encoding", "gzip"} in response.headers
      assert response.body == :zlib.gzip(<<0, 1, 2, 255>>)
    end

    test "forwards a GET request entity without dropping the body" do
      proxy_port = Application.fetch_env!(:hologram_cluster_tests, :proxy_port)

      promise =
        HTTP.fetch("http://127.0.0.1:#{proxy_port}/echo-body",
          method: :get,
          request_mode: :proxy,
          body: "request entity",
          redirect: :manual,
          timeout: 5_000
        )

      try do
        assert %HTTP.Response{status: 200} = response = HTTP.Promise.await(promise)
        assert HTTP.Response.read_all(response) == "GET:request entity"
      after
        assert :ok = HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise))
      end
    end

    test "relays every set-cookie header rather than collapsing them" do
      response = get_through_proxy("/set-cookies")

      set_cookie_headers =
        Enum.filter(response.headers, fn {name, _value} ->
          String.downcase(name) == "set-cookie"
        end)

      assert length(set_cookie_headers) == 2
    end

    test "streams response chunks as the upstream produces them" do
      proxy_port = Application.fetch_env!(:hologram_cluster_tests, :proxy_port)

      chunk_times = HTTPClient.chunk_times("http://127.0.0.1:#{proxy_port}/stream")

      # The upstream sends three chunks, sleeping 300ms between them. Asserted first, so
      # a missing chunk reads as a missing chunk rather than as a short spread.
      assert length(chunk_times) == 3

      # A buffering proxy would deliver all three in one burst at the end - the spread
      # proves each was relayed as it was produced.
      assert List.last(chunk_times) - List.first(chunk_times) >= 400
    end
  end
end
