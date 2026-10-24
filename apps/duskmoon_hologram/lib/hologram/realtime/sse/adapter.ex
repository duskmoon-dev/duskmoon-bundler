defmodule Hologram.Realtime.SSE.Adapter do
  @moduledoc false

  # Server-specific stream lifetime and client disconnect handling.

  @doc "Prepares the connection's stream lifetime before response headers are sent."
  @callback prepare(Plug.Conn.t()) :: Plug.Conn.t()

  @doc """
  Classifies a mailbox message the pump doesn't recognise: `:closed` ends the stream,
  `:ignore` leaves it running, and `:poll` checks the connection through `poll/1`.
  Any hand-back the server needs for the message happens here.
  """
  @callback handle_message(term) :: :closed | :ignore | :poll

  @doc "Checks the peer and returns the connection carrying the server's updated state."
  @callback poll(Plug.Conn.t()) :: {:cont, Plug.Conn.t()} | {:halt, Plug.Conn.t()}

  @optional_callbacks poll: 1

  @doc """
  Arms whatever the server needs so that a departed client arrives in the pump's mailbox.
  Called once, right after the stream's response is opened.
  """
  @callback watch(Plug.Conn.t()) :: :ok
end
