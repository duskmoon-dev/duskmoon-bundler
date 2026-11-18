defmodule NPM.HTTPStreamErrorsTest do
  use ExUnit.Case, async: true

  test "a truncated chunked response never returns its valid partial JSON" do
    {url, server} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, response_head() <> "b\r\n{\"ok\":true}\r\n")
      end)

    assert {:error, :closed} = NPM.HTTPClient.get(url)
    Task.await(server)
  end

  test "a stalled response reports its stream deadline without exposing partial data" do
    {url, server} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, response_head() <> "b\r\n{\"ok\":true}\r\n")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    assert {:error, :timeout} = NPM.HTTPClient.get(url, timeout: 100)
    Task.await(server)
  end

  defp response_head do
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
  end

  defp server(callback) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          callback.(socket)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}", task}
  end
end
