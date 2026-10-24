defmodule Hologram.Realtime.SSE.Adapters.GaoxyTest do
  use ExUnit.Case, async: true

  alias Hologram.Realtime.SSE
  alias Hologram.Realtime.SSE.Adapters.Gaoxy, as: GaoxyAdapter

  defmodule StreamPlug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(owner), do: owner

    @impl Plug
    def call(conn, owner) do
      conn = SSE.prepare(conn)
      :ok = GaoxyAdapter.watch(conn)
      send(owner, {:stream_opened, self()})
      pump(conn)
    end

    defp pump(conn) do
      case SSE.process_message(conn, nil, nil, adapter: GaoxyAdapter) do
        {:cont, conn} -> pump(conn)
        {:halt, conn} -> conn
      end
    end
  end

  test "SSE outlives the request deadline and releases its process when the peer closes" do
    server =
      start_supervised!(
        {Gaoxy.HTTP,
         plug: {StreamPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: 200}}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:stream_opened, stream}, 1_000
    monitor = Process.monitor(stream)

    {:ok, headers} = :gen_tcp.recv(socket, 0, 1_000)
    assert headers =~ "200 OK"
    assert headers =~ "content-type: text/event-stream"

    # Let both the finite request deadline and the first connection poll pass.
    Process.sleep(1_100)
    send(stream, :heartbeat)
    assert {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
    assert chunk =~ "event: heartbeat\ndata:\n\n"

    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^stream, _reason}, 2_000
  end
end
