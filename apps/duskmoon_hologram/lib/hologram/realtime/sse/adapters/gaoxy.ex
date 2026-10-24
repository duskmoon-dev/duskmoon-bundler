defmodule Hologram.Realtime.SSE.Adapters.Gaoxy do
  @moduledoc false

  @behaviour Hologram.Realtime.SSE.Adapter

  # The host selects its HTTP server; Gaoxy is not a required Hologram dependency.
  @compile {:no_warn_undefined, Gaoxy.HTTP}

  @poll_interval_ms 1_000

  @impl Hologram.Realtime.SSE.Adapter
  def prepare(conn), do: Gaoxy.HTTP.put_stream_timeout(conn, :infinity)

  @impl Hologram.Realtime.SSE.Adapter
  def watch(_conn) do
    schedule_poll()
    :ok
  end

  @impl Hologram.Realtime.SSE.Adapter
  def handle_message({__MODULE__, :poll}), do: :poll
  def handle_message(_message), do: :ignore

  @impl Hologram.Realtime.SSE.Adapter
  def poll(conn) do
    case Gaoxy.HTTP.poll_connection(conn, 0) do
      {:pending, conn} ->
        schedule_poll()
        {:cont, conn}

      {:more, conn} ->
        # Retain pipelined input for the server's next request after this stream ends.
        {:halt, conn}

      {:error, reason, conn} ->
        case Gaoxy.HTTP.abort(conn, reason) do
          {:ok, conn} -> {:halt, conn}
          {:error, _reason} -> {:halt, conn}
        end
    end
  end

  defp schedule_poll do
    Process.send_after(self(), {__MODULE__, :poll}, @poll_interval_ms)
  end
end
