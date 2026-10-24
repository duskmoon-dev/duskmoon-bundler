defmodule HologramFeatureTests.SSEResponseTest do
  # No browser: the browsers the suite drives accept the header this test refutes, so the
  # response is read with an HTTP client that hands back the headers as the server sent
  # them. Over HTTPS the client negotiates HTTP/2, the protocol where the header is illegal.
  use ExUnit.Case, async: false

  alias Hologram.Realtime.Handshake
  alias Hologram.Runtime.Session
  alias HologramFeatureTestsWeb.Endpoint

  # Generous relative to loopback, where a response either arrives in milliseconds or is
  # never coming.
  @recv_timeout_ms 5_000

  test "the SSE response carries no connection-specific header" do
    {session_id, cookie} = mint_session()
    instance_id = "sse-response-test-instance-id"
    handshake_id = "sse-response-test-handshake-#{:erlang.unique_integer([:positive])}"
    expires_at = System.system_time(:millisecond) + Handshake.stash_ttl_ms()

    Handshake.insert(handshake_id, [], {instance_id, session_id, nil}, expires_at)

    uri = URI.parse(Endpoint.url())
    {protocol, connect_opts} = connection_for(uri.scheme)
    request_path = "/hologram/sse?instance_id=#{instance_id}&handshake_id=#{handshake_id}"

    promise =
      HTTP.fetch(
        uri |> URI.merge(request_path) |> URI.to_string(),
        [
          headers: [{"cookie", cookie}],
          http_version: protocol,
          stream_response: true,
          decode_body: false,
          redirect: :manual,
          timeout: @recv_timeout_ms,
          connect_timeout: @recv_timeout_ms
        ] ++ connect_opts
      )

    try do
      assert %HTTP.Response{} = response = HTTP.Promise.await(promise)
      assert response.http_version == protocol
      assert response.status == 200
      assert HTTP.Headers.get(response.headers, "content-type") == "text/event-stream"
      refute HTTP.Headers.has?(response.headers, "connection")
    after
      # The SSE body stays open; cancel after inspecting the final response headers.
      assert :ok = HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise))
    end
  end

  # Over TLS the server offers HTTP/2 and the client accepts nothing else, so a run that
  # somehow negotiated HTTP/1.1 fails at the protocol assertion rather than passing on
  # the wrong protocol. The cert is the self-signed test pair, hence no verification.
  defp connection_for("https") do
    {:http2, [ssl: [verify: :verify_none]]}
  end

  defp connection_for("http") do
    # Keep the request persistent rather than asking the server for Connection: close.
    {:http1, [http1_reuse: true]}
  end

  # Mints a Hologram session the way a page visit does, by running one page request
  # through the endpoint in-process, and returns the session id with the cookie a client
  # presents to reuse it.
  defp mint_session do
    conn =
      :get
      |> Plug.Test.conn("/realtime/1")
      |> Endpoint.call([])

    %{"phoenix_session" => %{value: cookie_value}} = conn.resp_cookies

    {Session.get_session_id(conn), "phoenix_session=#{cookie_value}"}
  end
end
