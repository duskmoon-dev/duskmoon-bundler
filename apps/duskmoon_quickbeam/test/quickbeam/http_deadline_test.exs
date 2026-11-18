defmodule QuickBEAM.HTTPDeadlineTest do
  use ExUnit.Case, async: false

  @tag timeout: 40_000
  test "fetch maps the current HTTP request deadline and closes its connection" do
    QuickBEAM.Fetch.init()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 35_000)
        after
          :gen_tcp.close(socket)
        end
      end)

    assert_raise RuntimeError, "fetch timed out", fn ->
      QuickBEAM.Fetch.fetch([
        %{"url" => "http://127.0.0.1:#{port}", "method" => "GET", "headers" => []}
      ])
    end

    Task.await(server, 2_000)
  end
end
