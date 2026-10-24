defmodule HologramClusterTests.HTTPClient do
  @moduledoc """
  The HTTP client cluster tests make their assertions with.

  Requests use http_fetch, the same client the proxy relays with. Response
  headers retain their arrival order and duplicates, including set-cookie.

  Every request failure raises: a test client that cannot reach its target is a
  broken premise, not a result to assert on. Chunk measurements retain data
  received before a stream fails.
  """

  @recv_timeout_ms 5_000

  @doc "Returns the monotonic millisecond timestamp of each received response chunk."
  @spec chunk_times(String.t(), [{String.t(), String.t()}]) :: [integer]
  def chunk_times(url, request_headers \\ []) do
    with_response(url, request_headers, fn response ->
      case HTTP.Response.stream_pid(response) do
        stream when is_pid(stream) ->
          monitor = Process.monitor(stream)
          send(stream, {:read_chunk, self(), :ack})

          try do
            recv_chunk_times(stream, monitor, [])
          after
            Process.demonitor(monitor, [:flush])
          end

        nil ->
          if response.body == "", do: [], else: [System.monotonic_time(:millisecond)]
      end
    end)
  end

  @doc "Sends a GET and returns its body, headers and status."
  @spec get(String.t(), [{String.t(), String.t()}]) :: %{
          body: String.t(),
          headers: [{String.t(), String.t()}],
          status: pos_integer
        }
  def get(url, request_headers \\ []) do
    with_response(url, request_headers, fn response ->
      %{
        body: HTTP.Response.read_all(response),
        headers:
          Enum.map(HTTP.Headers.to_list(response.headers), fn {name, value} ->
            {String.downcase(name), value}
          end),
        status: response.status
      }
    end)
  end

  defp with_response(url, headers, consume) do
    promise =
      HTTP.fetch(url,
        headers: headers,
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
      %HTTP.Response{} = response = HTTP.Promise.await(promise)
      consume.(response)
    after
      :ok = HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise))
    end
  end

  defp recv_chunk_times(stream, monitor, times) do
    receive do
      {:stream_chunk, ^stream, _bytes, ref} ->
        now = System.monotonic_time(:millisecond)
        send(stream, {:stream_chunk_ack, ref})
        recv_chunk_times(stream, monitor, [now | times])

      {:stream_trailers, ^stream, _headers} ->
        recv_chunk_times(stream, monitor, times)

      {:stream_end, ^stream} ->
        Enum.reverse(times)

      {:stream_error, ^stream, _reason} ->
        Enum.reverse(times)

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        Enum.reverse(times)
    after
      @recv_timeout_ms -> Enum.reverse(times)
    end
  end
end
