defmodule HologramClusterTests.Proxy do
  @moduledoc """
  The streaming reverse proxy that is the browser's only origin.

  Every browser request lands here and is forwarded to one of the registered
  upstreams (ports on loopback). Which one is the routing policy's decision:
  round-robin by default, or a per-browser policy registered with
  `register_policy/1` and selected by a cookie the test sets on its own
  browser. Response chunks are relayed as the upstream produces them, so
  long-lived streams flow through without buffering.

  Every response is stamped with an `x-upstream` header and every request is
  appended to a log tests can query, so a test asserts which upstream actually
  served a request rather than assuming the policy worked.
  """

  use GenServer

  @log_table :hologram_cluster_tests_proxy_log

  @route_cookie "hologram_cluster_tests_route"

  @state_table :hologram_cluster_tests_proxy_state

  @doc false
  @spec choose_upstream(%{method: String.t(), path: String.t(), cookies: map}) :: pos_integer
  def choose_upstream(request_facts) do
    current_upstreams = upstreams()

    case :ets.lookup(@state_table, {:policy, request_facts.cookies[@route_cookie]}) do
      [{{:policy, _token}, policy}] ->
        policy.(request_facts, %{upstreams: current_upstreams})

      [] ->
        round_robin(current_upstreams)
    end
  end

  @doc """
  Empties the request log.
  """
  @spec clear_log() :: :ok
  def clear_log do
    :ets.delete_all_objects(@log_table)
    :ok
  end

  @doc """
  Returns the proxied requests in the order they were routed, each as a map
  with `:method`, `:path` and `:upstream`.
  """
  @spec log() :: [%{method: String.t(), path: String.t(), upstream: pos_integer}]
  def log do
    @log_table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {key, _entry} -> key end)
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  @doc false
  @spec log_request(String.t(), String.t(), pos_integer) :: :ok
  def log_request(method, path, upstream) do
    key = :erlang.unique_integer([:monotonic, :positive])
    entry = %{method: method, path: path, upstream: upstream}

    :ets.insert(@log_table, {key, entry})
    :ok
  end

  @doc """
  Replaces the upstream set used for subsequent routing decisions.
  """
  @spec put_upstreams([pos_integer]) :: :ok
  def put_upstreams(upstreams) do
    :ets.insert(@state_table, {:upstreams, upstreams})
    :ok
  end

  @doc """
  Stores `policy` and returns the token that selects it: a browser carrying the
  token as the `route_cookie/0` cookie has its requests routed by this policy
  instead of the round-robin default.

  The policy receives the request facts and the cluster facts, and returns the
  upstream to forward to:

      fn %{method: _, path: path, cookies: _}, %{upstreams: [a, b]} ->
        if String.starts_with?(path, "/hologram/sse"), do: a, else: b
      end
  """
  @spec register_policy((%{method: String.t(), path: String.t(), cookies: map},
                         %{upstreams: [pos_integer]} ->
                           pos_integer)) :: String.t()
  def register_policy(policy) do
    token = "policy-#{:erlang.unique_integer([:positive])}"

    :ets.insert(@state_table, {{:policy, token}, policy})
    token
  end

  @doc """
  Returns the name of the cookie whose value selects a registered routing
  policy for the browser carrying it.
  """
  @spec route_cookie() :: String.t()
  def route_cookie, do: @route_cookie

  @doc """
  Starts the proxy: its state tables and the HTTP listener on the configured
  proxy port. `opts` must include `:upstreams`, the initial upstream port list.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current upstream port list.
  """
  @spec upstreams() :: [pos_integer]
  def upstreams do
    [{:upstreams, upstreams}] = :ets.lookup(@state_table, :upstreams)
    upstreams
  end

  # The listener is linked and exits are trapped, so its death arrives here. The proxy
  # can't serve without it, so it stops too, and its supervisor restarts both.
  @impl GenServer
  def handle_info({:EXIT, listener_pid, reason}, %{listener_pid: listener_pid} = state) do
    {:stop, reason, %{state | listener_pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def init(opts) do
    # The listener is linked, so it would already die with this server. Exits are
    # trapped so terminate/2 still runs and stops it synchronously - the next start
    # binds the same port, and an asynchronous teardown races it.
    Process.flag(:trap_exit, true)

    :ets.new(@log_table, [:set, :public, :named_table])
    :ets.new(@state_table, [:set, :public, :named_table])

    :ets.insert(@state_table, {:rr_counter, 0})
    put_upstreams(Keyword.fetch!(opts, :upstreams))

    proxy_port = Application.fetch_env!(:hologram_cluster_tests, :proxy_port)

    {:ok, listener_pid} =
      Gaoxy.HTTP.start_link(
        plug: {HologramClusterTests.Proxy.Forwarder, []},
        ip: {127, 0, 0, 1},
        port: proxy_port
      )

    {:ok, %{listener_pid: listener_pid}}
  end

  @impl GenServer
  def terminate(_reason, %{listener_pid: nil}), do: :ok

  def terminate(_reason, %{listener_pid: listener_pid}) do
    Supervisor.stop(listener_pid)
  end

  defp round_robin(upstreams) do
    index = :ets.update_counter(@state_table, :rr_counter, 1)

    Enum.at(upstreams, rem(index, length(upstreams)))
  end
end

defmodule HologramClusterTests.Proxy.Forwarder do
  @moduledoc false

  @behaviour Plug

  alias HologramClusterTests.Proxy

  # Covers the longest legitimate silence on a proxied stream: SSE heartbeats arrive
  # every 15s, so a minute of nothing means the upstream is gone, not idle.
  @recv_timeout_ms 60_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(initial_conn, _opts) do
    conn = Plug.Conn.fetch_cookies(initial_conn)

    request_facts = %{
      method: conn.method,
      path: conn.request_path,
      cookies: conn.req_cookies
    }

    upstream = Proxy.choose_upstream(request_facts)
    Proxy.log_request(conn.method, conn.request_path, upstream)

    forward(conn, upstream)
  end

  defp build_request_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query_string -> "#{conn.request_path}?#{query_string}"
    end
  end

  # Rewrite the upstream authority and let http_fetch frame the buffered request body.
  # Entity headers and cookies retain their values and duplicates.
  defp build_request_headers(conn, upstream) do
    forwarded_headers =
      Enum.reject(conn.req_headers, fn {name, _value} ->
        name in ["host", "transfer-encoding", "trailer"]
      end)

    [{"host", "127.0.0.1:#{upstream}"} | forwarded_headers]
  end

  defp forward(conn, upstream) do
    {:ok, request_body, conn} = read_full_body(conn, [])

    promise =
      HTTP.fetch("http://127.0.0.1:#{upstream}#{build_request_path(conn)}",
        method: conn.method,
        headers: build_request_headers(conn, upstream),
        body: request_body,
        request_mode: :proxy,
        http_version: :http1,
        redirect: :manual,
        decode_body: false,
        stream_response: true,
        timeout: :infinity,
        connect_timeout: @recv_timeout_ms,
        read_idle_timeout: @recv_timeout_ms,
        response_stream_idle_timeout: @recv_timeout_ms
      )

    try do
      case await_response(conn, promise.task) do
        {:ok, response, conn} ->
          relay_response(conn, response, upstream)

        {:error, conn} ->
          halt_towards_browser(conn, upstream, %{headers: [], status: nil})

        {:closed, conn} ->
          conn
      end
    after
      :ok = HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise))
    end
  end

  defp await_response(conn, task) do
    case Task.yield(task, 100) do
      {:ok, %HTTP.Response{} = response} ->
        {:ok, response, conn}

      {:ok, {:error, _reason}} ->
        {:error, conn}

      {:exit, _reason} ->
        {:error, conn}

      nil ->
        case Gaoxy.HTTP.poll_connection(conn, 0) do
          {kind, conn} when kind in [:pending, :more] ->
            await_response(conn, task)

          {:error, reason, conn} ->
            {:ok, conn} = Gaoxy.HTTP.abort(conn, reason)
            {:closed, conn}
        end
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, part, conn} ->
        body =
          [part | acc]
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, body, conn}

      {:more, part, conn} ->
        read_full_body(conn, [part | acc])
    end
  end

  # Streams the upstream's response to the browser as it arrives. The response is opened
  # towards the browser on the first body chunk. Acknowledgement follows the downstream
  # write, keeping backpressure and the original encoded entity bytes intact.
  defp relay_response(conn, response, upstream) do
    response_head = %{
      status: response.status,
      headers:
        Enum.map(HTTP.Headers.to_list(response.headers), fn {name, value} ->
          {String.downcase(name), value}
        end)
    }

    case HTTP.Response.stream_pid(response) do
      stream when is_pid(stream) ->
        monitor = Process.monitor(stream)
        send(stream, {:read_chunk, self(), :ack})

        try do
          relay_stream(conn, stream, monitor, upstream, response_head)
        after
          Process.demonitor(monitor, [:flush])
        end

      nil ->
        conn
        |> put_response_headers(upstream, response_head)
        |> Plug.Conn.send_resp(response.status, response.body)
    end
  end

  defp relay_stream(conn, stream, monitor, upstream, response) do
    receive do
      {:stream_chunk, ^stream, bytes, ref} ->
        conn = open_towards_browser(conn, upstream, response)

        case Plug.Conn.chunk(conn, bytes) do
          {:ok, conn} ->
            send(stream, {:stream_chunk_ack, ref})
            relay_stream(conn, stream, monitor, upstream, response)

          {:error, _reason} ->
            conn
        end

      {:stream_trailers, ^stream, _headers} ->
        relay_stream(conn, stream, monitor, upstream, response)

      {:stream_end, ^stream} ->
        finish_response(conn, upstream, response)

      {:stream_error, ^stream, _reason} ->
        halt_towards_browser(conn, upstream, response)

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        halt_towards_browser(conn, upstream, response)
    after
      100 ->
        case Gaoxy.HTTP.poll_connection(conn, 0) do
          {kind, conn} when kind in [:pending, :more] ->
            relay_stream(conn, stream, monitor, upstream, response)

          {:error, reason, conn} ->
            {:ok, conn} = Gaoxy.HTTP.abort(conn, reason)
            conn
        end
    end
  end

  defp finish_response(conn, upstream, response) do
    if conn.state == :chunked do
      conn
    else
      # No body at all - answer without entering chunked encoding.
      conn
      |> put_response_headers(upstream, response)
      |> Plug.Conn.send_resp(response.status, "")
    end
  end

  defp halt_towards_browser(conn, upstream, response) do
    if conn.state == :chunked do
      conn
    else
      conn
      |> put_response_headers(upstream, %{response | status: 502, headers: []})
      |> Plug.Conn.send_resp(502, "upstream did not respond")
    end
  end

  defp open_towards_browser(%Plug.Conn{state: :chunked} = conn, _upstream, _response), do: conn

  defp open_towards_browser(conn, upstream, response) do
    conn
    |> put_response_headers(upstream, response)
    |> Gaoxy.HTTP.put_stream_timeout(:infinity)
    |> Plug.Conn.send_chunked(response.status)
  end

  # Hop-by-hop headers describe the upstream connection, not the one to the browser -
  # Plug manages those on its own side. Prepended rather than put one by one, since put
  # replaces same-named headers and would collapse multiple set-cookie headers into one.
  defp put_response_headers(conn, upstream, response) do
    forwarded_headers =
      Enum.reject(response.headers, fn {name, _value} ->
        name in ["connection", "content-length", "transfer-encoding"]
      end)

    conn
    |> Plug.Conn.prepend_resp_headers(forwarded_headers)
    |> Plug.Conn.put_resp_header("x-upstream", Integer.to_string(upstream))
  end
end
