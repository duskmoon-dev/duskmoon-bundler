defmodule QuickBEAM.Core.AwaitQueueTest do
  @moduledoc """
  Regression tests for requests that arrive while the runtime worker is
  awaiting a pending promise: they must be deferred (not dropped), must not
  clobber the in-flight eval's globals, and must not block shutdown.
  """
  use ExUnit.Case, async: true

  @prompt_ms 3_000

  defp async_eval(rt, code, opts \\ []) do
    Task.async(fn -> QuickBEAM.eval(rt, code, opts) end)
  end

  defp spawn_eval(rt, code) do
    spawn(fn ->
      try do
        QuickBEAM.eval(rt, code)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp stop_promptly(rt) do
    task = Task.async(fn -> GenServer.stop(rt) end)
    assert {:ok, :ok} = Task.yield(task, @prompt_ms) || Task.shutdown(task, :brutal_kill)
  end

  test "an eval queued behind an awaiting eval is not dropped" do
    {:ok, rt} = QuickBEAM.start()

    slow = async_eval(rt, "await new Promise(r => setTimeout(() => r('slow'), 200))")
    Process.sleep(50)
    fast = async_eval(rt, "1 + 1")

    assert {:ok, {:ok, 2}} = Task.yield(fast, @prompt_ms)
    assert {:ok, {:ok, "slow"}} = Task.yield(slow, @prompt_ms)

    QuickBEAM.stop(rt)
  end

  test "stop during an awaiting eval returns promptly" do
    {:ok, rt} = QuickBEAM.start()
    Process.unlink(rt)

    spawn_eval(rt, "await new Promise(() => {})")
    Process.sleep(100)

    stop_promptly(rt)
  end

  test "stop during an unbounded busy loop returns promptly" do
    {:ok, rt} = QuickBEAM.start()
    Process.unlink(rt)

    spawn_eval(rt, "while (true) {}")
    Process.sleep(100)

    stop_promptly(rt)
  end

  test "concurrent vars evals each see their own values" do
    {:ok, rt} = QuickBEAM.start()

    first =
      async_eval(rt, "await new Promise(r => setTimeout(r, 200)); x", vars: %{"x" => 1})

    Process.sleep(50)
    second = async_eval(rt, "x", vars: %{"x" => 2})

    assert {:ok, {:ok, 1}} = Task.yield(first, @prompt_ms)
    assert {:ok, {:ok, 2}} = Task.yield(second, @prompt_ms)

    QuickBEAM.stop(rt)
  end
end
