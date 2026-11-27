defmodule QuickBEAM.Core.TimeoutTest do
  use ExUnit.Case, async: true

  test "eval with timeout completes normally" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, 42} = QuickBEAM.eval(rt, "42", timeout: 5000)
    QuickBEAM.stop(rt)
  end

  test "eval with timeout aborts infinite loop" do
    {:ok, rt} = QuickBEAM.start()
    assert {:error, _} = QuickBEAM.eval(rt, "while(true) {}", timeout: 100)
    assert {:ok, 1} = QuickBEAM.eval(rt, "1")
    QuickBEAM.stop(rt)
  end

  test "call with timeout aborts infinite loop" do
    {:ok, rt} = QuickBEAM.start()
    QuickBEAM.eval(rt, "function spin() { while(true) {} }")
    assert {:error, _} = QuickBEAM.call(rt, "spin", [], timeout: 100)
    assert {:ok, 1} = QuickBEAM.eval(rt, "1")
    QuickBEAM.stop(rt)
  end

  # Each zero-delay timer runs on a separate pass through the worker.
  @long_promise """
  new Promise(resolve => {
    let count = 0;
    const next = () => ++count === 10_001 ? resolve(count) : setTimeout(next, 0);
    next();
  })
  """

  test "promise waiting honors the configured timeout instead of an iteration limit" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, 10_001} = QuickBEAM.eval(rt, @long_promise, timeout: 5000)
    QuickBEAM.stop(rt)
  end

  test "eval without timeout has no limit" do
    {:ok, rt} = QuickBEAM.start()

    assert {:ok, 5_000_000} =
             QuickBEAM.eval(rt, "let s = 0; for (let i = 0; i < 5_000_000; i++) s += 1; s")

    QuickBEAM.stop(rt)
  end

  test "default module waits retain the iteration limit" do
    rt = start_supervised!(QuickBEAM)

    assert {:error, %QuickBEAM.JSError{message: "Promise resolution timeout"}} =
             QuickBEAM.load_module(rt, "bounded", "await #{@long_promise}")
  end

  test "host-managed waits finish long modules and async generator continuations" do
    rt = start_supervised!({QuickBEAM, promise_wait: :infinity})

    assert :ok =
             QuickBEAM.load_module(rt, "long", """
             globalThis.answer = await #{@long_promise};
             const iterator = (async function* () { yield 0; return await #{@long_promise}; })();
             globalThis.resume = () => iterator.next();
             """)

    assert {:ok, 10_001} = QuickBEAM.get_global(rt, "answer")
    assert {:ok, %{"done" => false, "value" => 0}} = QuickBEAM.call(rt, "resume")
    assert {:ok, %{"done" => true, "value" => 10_001}} = QuickBEAM.call(rt, "resume")
  end

  test "explicit deadlines interrupt pending modules and calls on a host-managed runtime" do
    rt = start_supervised!({QuickBEAM, sandbox: :strict, promise_wait: :infinity})
    pending = "new Promise(() => {})"

    assert {:error, %QuickBEAM.JSError{message: "Promise resolution timeout"}} =
             QuickBEAM.load_module(
               rt,
               "busy",
               """
               const end = Date.now() + 1000;
               while (Date.now() < end) {}
               globalThis.finished = true;
               """,
               timeout: 25
             )

    assert {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof globalThis.finished")

    assert {:error, %QuickBEAM.JSError{message: "Promise resolution timeout"}} =
             QuickBEAM.load_module(rt, "pending", "await #{pending}", timeout: 25)

    assert {:ok, _} = QuickBEAM.eval(rt, "globalThis.pending = () => #{pending}")

    assert {:error, %QuickBEAM.JSError{message: "Promise resolution timeout"}} =
             QuickBEAM.call(rt, "pending", [], timeout: 25)

    assert {:ok, 42} = QuickBEAM.eval(rt, "42")
  end

  test "a strict runtime can stop while a host-managed module is pending" do
    parent = self()

    handlers = %{
      "ready" => fn [] ->
        send(parent, :waiting)
        42
      end
    }

    {:ok, rt} = QuickBEAM.start(sandbox: :strict, promise_wait: :infinity, handlers: handlers)
    ref = Process.monitor(rt)

    caller =
      Task.async(fn ->
        catch_exit(
          QuickBEAM.load_module(
            rt,
            "waiting",
            ~S|await Beam.call("ready"); await new Promise(() => {});|
          )
        )
      end)

    assert_receive :waiting, 3_000
    assert :ok = Task.await(Task.async(fn -> QuickBEAM.stop(rt) end), 3_000)
    assert_receive {:DOWN, ^ref, :process, ^rt, :normal}
    assert {:normal, _} = Task.await(caller)
  end

  test "rejects an unknown Promise wait mode before starting the runtime" do
    assert {:error, {:invalid_option, :promise_wait, :forever}} =
             QuickBEAM.start(promise_wait: :forever)
  end
end
