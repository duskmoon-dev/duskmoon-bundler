defmodule DuskmoonBundler.Integration.HMRWebSocketTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Short server-side websocket idle timeout so we can exercise the
  # heartbeat/timeout behavior without waiting 60 seconds.
  @hmr_timeout 2_000

  @fixture_dir Path.expand("../fixtures/integration_hmr_ws", __DIR__)

  defp port do
    # Unique port per test run to avoid TIME_WAIT / :eaddrinuse races between
    # sequential integration tests.
    50_000 + rem(System.unique_integer([:positive, :monotonic]), 10_000)
  end

  defmodule TestPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      case DuskmoonBundler.DevServer.call(conn, opts[:dev_server]) do
        %{halted: true} = conn -> conn
        conn -> Elixir.Plug.Conn.send_resp(conn, 404, "not found")
      end
    end
  end

  setup do
    port = port()
    File.rm_rf!(@fixture_dir)
    File.mkdir_p!(@fixture_dir)
    DuskmoonBundler.Cache.clear()

    File.write!(Path.join(@fixture_dir, "app.ts"), "export const v = 1\n")

    dev_server_opts =
      DuskmoonBundler.DevServer.init(
        root: @fixture_dir,
        prefix: "/assets",
        hmr_timeout: @hmr_timeout
      )

    plug_opts = %{root: @fixture_dir, dev_server: dev_server_opts}

    {:ok, server} =
      Gaoxy.HTTP.start_link(
        plug: {__MODULE__.TestPlug, plug_opts},
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      Process.exit(server, :normal)
      File.rm_rf!(@fixture_dir)
    end)

    {:ok, port: port}
  end

  describe "HMR websocket idle timeout" do
    test "an idle connection is closed by the server after hmr_timeout", %{port: port} do
      socket = connect!(port)

      # Send nothing. The server should close the socket once its read_timeout
      # fires (well within 2x the configured timeout).
      assert {:close, _, _} = recv_frame(socket, @hmr_timeout * 2)
    end

    test "a heartbeat ping keeps the connection alive past hmr_timeout", %{port: port} do
      socket = connect!(port)

      # Send a ping well inside the timeout window and expect a pong.
      :ok = HTTP.WebSocket.send(socket, ~s({"type":"ping"}))
      assert {:text, pong} = recv_frame(socket, 1_000)
      assert Jason.decode!(pong)["type"] == "pong"

      # Keep heartbeating past the idle timeout. If the heartbeat did not
      # reset the read timeout, the server would have closed us by now.
      deadline = System.monotonic_time(:millisecond) + @hmr_timeout * 2

      assert stay_alive?(socket, deadline)
    end
  end

  defp connect!(port) do
    socket =
      HTTP.WebSocket.new("ws://127.0.0.1:#{port}/@duskmoon_bundler/ws", [],
        owner: self(),
        delivery: :ack
      )

    assert %HTTP.WebSocket{} = socket
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Open{}}, 1_000
    on_exit(fn -> HTTP.WebSocket.close(socket) end)
    socket
  end

  defp recv_frame(socket, timeout) do
    receive do
      {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Message{data: data}, ref} ->
        HTTP.WebSocket.acknowledge(socket, ref)
        {:text, data}

      {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{code: code, reason: reason}} ->
        {:close, code, reason}

      {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Error{reason: reason}} ->
        {:error, reason}
    after
      timeout -> :timeout
    end
  end

  defp stay_alive?(socket, deadline) do
    interval = div(@hmr_timeout, 2)
    stay_alive_loop(socket, deadline, interval)
  end

  defp stay_alive_loop(socket, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      true
    else
      :ok = HTTP.WebSocket.send(socket, ~s({"type":"ping"}))

      # Drain any pong (or a close if the server gave up, which would fail us).
      case recv_frame(socket, interval + 500) do
        {:text, pong} when is_binary(pong) ->
          if Jason.decode!(pong)["type"] == "pong" do
            Process.sleep(max(interval - 200, 0))
            stay_alive_loop(socket, deadline, interval)
          else
            {:unexpected, pong}
          end

        {:close, _, _} ->
          false

        :timeout ->
          # No pong this round but socket still open — keep going until deadline.
          stay_alive_loop(socket, deadline, interval)

        other ->
          other
      end
    end
  end
end
